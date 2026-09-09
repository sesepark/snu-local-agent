import Foundation
import AppKit

// MARK: - 작업 항목

/// One file on its way through a batch tool.
///
/// 용량 줄이기 grew its own `CompressionItem` first, with before/after byte
/// counts baked in. Four more tools arrived that all have the same shape —
/// files in, files out, one progress bar each — but measure completely
/// different things, so the headline is a plain string the worker fills in
/// rather than a number this type knows how to interpret.
struct ToolJob: Identifiable, Sendable {
    enum State: Sendable, Equatable {
        case waiting
        case working(Double)
        case done
        case skipped(String)
        case failed(String)
    }

    let id = UUID()
    let source: URL
    var output: URL?
    var state: State = .waiting
    /// What changed, in the tool's own terms: "1920×1080 → 3840×2160".
    var detail = ""
    /// The one measured number worth reading at a glance: "−12 dB", "4.1 MB".
    var headline = ""
    /// Something the user needs told that is not a failure.
    var note: String?

    var isFinished: Bool { if case .done = state { true } else { false } }

    var isFailed: Bool {
        switch state {
        case .failed, .skipped: true
        default: false
        }
    }

    var statusText: String {
        switch state {
        case .waiting: "대기 중"
        case .working(let fraction): fraction > 0 ? "처리 중 \(Int(fraction * 100))%" : "처리 중"
        case .done: note ?? headline
        case .skipped(let reason): reason
        case .failed(let message): message
        }
    }
}

/// Read from a file before any work starts, so the estimate knows how big the
/// job is and the card has something to show immediately.
struct ToolJobInfo: Sendable {
    var detail: String
    var estimatedSeconds: Double
}

struct ToolOutcome: Sendable {
    let output: URL
    var detail: String
    var headline: String
    var note: String?
}

// MARK: - 작업자

/// What a batch tool has to provide. Frozen at the moment the run starts, the
/// same way `CompressionRequest` is, so changing a picker mid-run cannot make
/// half the files come out differently from the other half.
protocol BatchToolWorker: Sendable {
    /// Lower-cased extensions this tool can handle. A dropped folder is filtered
    /// through this, and a file that does not match is never queued.
    var accepts: Set<String> { get }
    /// How many files may run at once. One for anything that goes through a
    /// single resident model or the one hardware encoder.
    var concurrency: Int { get }
    /// The suffix that lands in the saved file name: `강의-다듬음.m4a`.
    var saveSuffix: String { get }
    func outputExtension(for source: URL) -> String
    func inspect(_ source: URL) async throws -> ToolJobInfo
    func run(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ToolOutcome
}

extension BatchToolWorker {
    var concurrency: Int { max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)) }
}

// MARK: - 남은 시간

/// The same idea as `CompressionProgressEstimator`, keyed by a plain string.
///
/// Deliberately a second, smaller copy rather than a generalisation of that
/// one: 용량 줄이기 is the most-used tab in the app and works, and rewriting its
/// estimator to add four callers would risk it for no gain the user can see.
struct ToolETA: Sendable {
    private struct Entry: Sendable {
        let bucket: String
        let estimate: Double
    }

    private var entries: [UUID: Entry] = [:]
    private var calibration: [String: Double] = [:]

    var isEmpty: Bool { entries.isEmpty }

    mutating func add(id: UUID, bucket: String, estimate: Double) {
        entries[id] = Entry(bucket: bucket, estimate: max(0.01, estimate))
    }

    mutating func finish(id: UUID, actual: Double) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        guard actual > 0.05, entry.estimate > 0 else { return }
        let ratio = min(10, max(0.1, actual / entry.estimate))
        calibration[entry.bucket] = (calibration[entry.bucket] ?? 1) * 0.6 + ratio * 0.4
    }

    mutating func drop(id: UUID) { entries.removeValue(forKey: id) }

    var remainingSeconds: Double {
        entries.values.reduce(0) { $0 + $1.estimate * (calibration[$1.bucket] ?? 1) }
    }

    static func text(_ seconds: Double) -> String {
        guard seconds > 0.5 else { return "" }
        if seconds < 60 { return "예상 남은 시간 약 \(max(1, Int(seconds.rounded())))초" }
        return "예상 남은 시간 약 \(max(1, Int((seconds / 60).rounded())))분"
    }
}

// MARK: - 작업 폴더

enum ToolWorkspace {
    /// One folder per tool, so clearing one never disturbs another.
    static func directory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SeoulLocalAgent-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// An empty extension means the result is a folder rather than a file —
    /// `PDF를 쪽마다 PNG로` produces one — so the trailing dot has to go.
    static func outputURL(for source: URL, extension fileExtension: String, in directory: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let name = "\(stem)-\(UUID().uuidString.prefix(6))"
        return directory.appending(path: fileExtension.isEmpty ? name : "\(name).\(fileExtension)")
    }

    /// Walks dropped folders for anything this tool accepts. Bounded on depth and
    /// count so dropping a home folder by accident cannot hang the app.
    static func expand(_ urls: [URL], accepting extensions: Set<String>, maxDepth: Int = 3, limit: Int = 500) -> (files: [URL], truncated: Bool) {
        var files: [URL] = []
        var truncated = false
        var queue: [(URL, Int)] = urls.map { ($0, 0) }
        while !queue.isEmpty {
            let (url, depth) = queue.removeFirst()
            if files.count >= limit { truncated = true; break }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard depth < maxDepth else { continue }
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                queue.append(contentsOf: children.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { ($0, depth + 1) })
            } else if extensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return (files, truncated)
    }
}

// MARK: - 배치 실행

/// The engine behind 소리 다듬기, 화질 올리기, 스캔 보정 and 형식 변환.
///
/// Each of those screens is a picker panel and a grid of cards; everything
/// between — queueing, bounded concurrency, per-file progress, the estimate,
/// cancellation, saving one or all — is identical, and lives here instead of
/// four times over in `AutomationController`. The controller owns one of these
/// per tool and the views observe it directly, which also keeps forty more
/// `@Published` properties out of a class that already has ninety.
@MainActor
final class BatchToolModel: ObservableObject {
    @Published private(set) var jobs: [ToolJob] = []
    @Published private(set) var isRunning = false
    @Published private(set) var status: String
    @Published private(set) var eta: TimeInterval?
    @Published var error: String?

    /// Names the temporary folder and the `UserDefaults` key for the last save
    /// location, so two tools never fight over either.
    let name: String
    private let idleStatus: String
    private var task: Task<Void, Never>?
    private var estimator = ToolETA()
    private var etaUpdatedAt = Date.distantPast
    private var lastWorker: (any BatchToolWorker)?

    init(name: String, idleStatus: String) {
        self.name = name
        self.idleStatus = idleStatus
        self.status = idleStatus
    }

    // MARK: 상태

    var progressValue: Double {
        guard !jobs.isEmpty else { return 0 }
        let settled = jobs.filter { $0.isFinished || $0.isFailed }.count
        let running = jobs.reduce(0.0) { total, job in
            if case .working(let fraction) = job.state { return total + fraction }
            return total
        }
        return min(1, (Double(settled) + running) / Double(jobs.count))
    }

    var countText: String {
        let settled = jobs.filter { $0.isFinished || $0.isFailed }.count
        return "\(settled)/\(jobs.count)개"
    }

    var etaText: String {
        guard isRunning, let eta else { return "" }
        return ToolETA.text(eta)
    }

    var hasFinished: Bool { jobs.contains(where: \.isFinished) }
    var canRerun: Bool { !isRunning && !jobs.isEmpty }

    var lastSaveFolder: URL? {
        get { UserDefaults.standard.string(forKey: "\(name)SaveFolder").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "\(name)SaveFolder") }
    }

    // MARK: 넣기

    /// Replaces the list rather than appending: every one of these tools has a
    /// settings panel above the grid, and mixing files run under two different
    /// settings into one grid makes the before/after numbers meaningless.
    func load(_ urls: [URL], worker: any BatchToolWorker) {
        guard !isRunning else {
            error = "처리 중입니다. 끝나거나 중단한 뒤에 넣어 주세요."
            return
        }
        let (files, truncated) = ToolWorkspace.expand(urls, accepting: worker.accepts)
        guard !files.isEmpty else {
            error = "이 도구가 다룰 수 있는 파일이 없습니다."
            return
        }
        error = truncated ? "한 번에 500개까지만 처리합니다. 나머지는 다시 넣어 주세요." : nil
        jobs = files.map { ToolJob(source: $0) }
        start(worker)
    }

    /// Runs whatever is already on screen again, under the current settings.
    func rerun(_ worker: any BatchToolWorker) {
        guard canRerun else { return }
        for index in jobs.indices {
            jobs[index].state = .waiting
            jobs[index].output = nil
            jobs[index].note = nil
            jobs[index].headline = ""
        }
        error = nil
        start(worker)
    }

    private func start(_ worker: any BatchToolWorker) {
        lastWorker = worker
        let total = jobs.count
        estimator = ToolETA()
        eta = nil
        isRunning = true
        status = "\(total)개를 확인하고 있습니다."

        task = Task { [weak self] in
            guard let self else { return }
            let directory: URL
            do {
                directory = try ToolWorkspace.directory(self.name)
            } catch {
                self.error = "작업 폴더를 만들지 못했습니다: \(error.localizedDescription)"
                self.isRunning = false
                self.task = nil
                return
            }
            await self.inspectAll(worker)
            await self.runAll(worker, directory: directory)
            self.finish(total: total)
        }
    }

    /// Headers only, before any real work: this is what makes the estimate
    /// size-aware instead of a file count.
    private func inspectAll(_ worker: any BatchToolWorker) async {
        for index in jobs.indices {
            if Task.isCancelled { return }
            let job = jobs[index]
            do {
                let info = try await worker.inspect(job.source)
                update(at: index) { $0.detail = info.detail }
                estimator.add(id: job.id, bucket: job.source.pathExtension.lowercased(), estimate: info.estimatedSeconds)
            } catch {
                update(at: index) { $0.state = .failed(Self.message(for: error)) }
            }
        }
        refreshETA(force: true)
        status = "\(jobs.count)개를 처리하고 있습니다."
    }

    private func runAll(_ worker: any BatchToolWorker, directory: URL) async {
        let pending = jobs.indices.filter { !jobs[$0].isFailed }
        let limit = max(1, worker.concurrency)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(limit, pending.count) {
                let index = pending[next]
                next += 1
                group.addTask { await self.runOne(at: index, worker: worker, directory: directory) }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, next < pending.count else { continue }
                let index = pending[next]
                next += 1
                group.addTask { await self.runOne(at: index, worker: worker, directory: directory) }
            }
        }
    }

    private func runOne(at index: Int, worker: any BatchToolWorker, directory: URL) async {
        guard jobs.indices.contains(index) else { return }
        let job = jobs[index]
        let identifier = job.id
        let destination = ToolWorkspace.outputURL(
            for: job.source, extension: worker.outputExtension(for: job.source), in: directory
        )
        let started = Date()
        update(at: index) { $0.state = .working(0) }
        do {
            let outcome = try await worker.run(job.source, to: destination) { fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Unstructured hops can land after the file has finished;
                    // without the guard a late report flips a done card back to
                    // 처리 중.
                    self.update(at: index) {
                        if case .working = $0.state { $0.state = .working(fraction) }
                    }
                    self.refreshETA()
                }
            }
            update(at: index) {
                $0.output = outcome.output
                $0.detail = outcome.detail
                $0.headline = outcome.headline
                $0.note = outcome.note
                $0.state = .done
            }
            estimator.finish(id: identifier, actual: Date().timeIntervalSince(started))
        } catch is CancellationError {
            update(at: index) { $0.state = .skipped("중단했습니다.") }
            estimator.drop(id: identifier)
        } catch {
            update(at: index) { $0.state = .failed(Self.message(for: error)) }
            estimator.drop(id: identifier)
        }
        refreshETA(force: true)
    }

    private func finish(total: Int) {
        let succeeded = jobs.filter(\.isFinished).count
        if Task.isCancelled {
            status = "중단했습니다."
        } else if succeeded == total {
            status = "\(succeeded)개를 마쳤습니다."
        } else {
            status = "\(succeeded)/\(total)개를 마쳤습니다."
        }
        isRunning = false
        eta = nil
        task = nil
    }

    func stop() {
        guard isRunning else { return }
        status = "중단하는 중"
        task?.cancel()
        // ffmpeg and the Python runners are the only helpers here that live long
        // enough to need chasing.
        ActiveProcessRegistry.shared.terminateProcesses(containing: "-progress")
    }

    func clear() {
        guard !isRunning else { return }
        jobs = []
        error = nil
        status = idleStatus
    }

    func report(_ text: String) { status = text }

    private func update(at index: Int, _ change: (inout ToolJob) -> Void) {
        guard jobs.indices.contains(index) else { return }
        change(&jobs[index])
    }

    /// Throttled: several files can report at once and republishing the estimate
    /// on every one of them makes the whole screen flicker.
    private func refreshETA(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(etaUpdatedAt) >= 0.25 else { return }
        etaUpdatedAt = now
        eta = estimator.isEmpty ? nil : estimator.remainingSeconds
    }

    /// `AgentError` already carries a Korean sentence; anything else would show
    /// its English `NSError` description, so it gets a plain fallback.
    private static func message(for error: any Error) -> String {
        if let agent = error as? AgentError { return agent.errorDescription ?? "처리하지 못했습니다." }
        return error.localizedDescription
    }

    // MARK: 저장

    func saveName(for job: ToolJob) -> String {
        let stem = job.source.deletingPathExtension().lastPathComponent
        let suffix = lastWorker?.saveSuffix ?? name
        let ext = job.output?.pathExtension ?? job.source.pathExtension
        return ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
    }

    func save(_ job: ToolJob) {
        guard let output = job.output else {
            error = "결과 파일을 찾지 못했습니다."
            return
        }
        let panel = NSSavePanel()
        panel.title = "결과 저장"
        panel.nameFieldStringValue = saveName(for: job)
        if let folder = lastSaveFolder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: output, to: url)
            lastSaveFolder = url.deletingLastPathComponent()
            status = "저장했습니다: \(url.lastPathComponent)"
        } catch {
            self.error = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func saveAll() {
        let finished = jobs.filter(\.isFinished)
        guard !finished.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "결과를 저장할 폴더 선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "저장"
        if let folder = lastSaveFolder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        var saved = 0
        for job in finished {
            guard let output = job.output else { continue }
            // Two files from different folders can share a name, and a batch save
            // must not have the second silently replace the first.
            let target = CompressionWorkspace.uniqueURL(in: directory, name: saveName(for: job))
            do {
                try FileManager.default.copyItem(at: output, to: target)
                saved += 1
            } catch {
                self.error = "저장하지 못했습니다: \(error.localizedDescription)"
            }
        }
        lastSaveFolder = directory
        status = "\(saved)개를 저장했습니다: \(directory.lastPathComponent)"
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func copy(_ job: ToolJob) {
        guard let output = job.output else {
            error = "결과 파일을 찾지 못했습니다."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([output as NSURL])
        status = "클립보드에 복사했습니다: \(job.source.lastPathComponent)"
    }

    func reveal(_ job: ToolJob) {
        guard let output = job.output else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }
}
