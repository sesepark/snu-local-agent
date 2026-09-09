import Foundation
import EventKit
import Security
import SQLite3

/// Keeps child jobs from becoming orphaned if the menu-bar app is relaunched.
final class ActiveProcessRegistry: @unchecked Sendable {
    static let shared = ActiveProcessRegistry()
    private let lock = NSLock()
    private var processes: [Process] = []

    func add(_ process: Process) {
        lock.lock()
        processes.append(process)
        lock.unlock()
    }

    func remove(_ process: Process) {
        lock.lock()
        processes.removeAll { $0 === process }
        lock.unlock()
    }

    func terminateAll() {
        lock.lock()
        let active = processes
        lock.unlock()
        active.filter(\.isRunning).forEach { $0.terminate() }
    }

    /// Quit path: some helpers start services of their own, so signalling the
    /// direct child is not enough to leave the machine clean.
    func terminateAllTrees() {
        lock.lock()
        let active = processes
        lock.unlock()
        for process in active where process.isRunning {
            let marker = process.executableURL?.lastPathComponent ?? ""
            if marker.isEmpty {
                process.terminate()
            } else {
                terminateTree(of: process.processIdentifier, matching: marker)
            }
        }
    }

    func terminateProcesses(containing argument: String) {
        lock.lock()
        let matching = processes.filter { process in
            process.arguments?.contains(where: { $0.contains(argument) }) == true
        }
        lock.unlock()
        matching.filter(\.isRunning).forEach { $0.terminate() }
    }

    /// Every Python helper this app spawns, matched against `ps` output.
    /// `mineru.cli.fast_api` is a grandchild: the `mineru` CLI starts it as a
    /// temporary local service, so terminating the CLI alone can leave it behind.
    static let runnerMarkers = [
        "scripts/transcribe_runner.py",
        "scripts/matting_runner.py",
        "scripts/media_runner.py",
        "mineru.cli.fast_api",
        // 나머지 도구들 — ffmpeg, yt-dlp, soffice, cwebp, screencapture — 은 전부
        // `SeoulLocalAgent-<도구>` 작업 폴더를 인자로 받는다. 강제 종료로 부모를 잃으면
        // 이름만으로는 사용자가 터미널에서 돌리는 같은 도구와 구별할 수 없는데, 이 경로는
        // 이 앱만 만든다. 앱 자신은 `SeoulLocalAgent.app`이라 붙임표에 걸리지 않는다.
        "/SeoulLocalAgent-",
    ]

    /// Terminates a process and everything it started, deepest first.
    ///
    /// `Process.terminate()` only signals the direct child. A helper that spawns
    /// its own service — `mineru` does — would otherwise leave that service
    /// reparented to launchd and running for as long as the machine is up.
    /// `marker` guards against PID reuse: between a helper exiting and this
    /// running, the number could belong to something else entirely.
    func terminateTree(of pid: Int32, matching marker: String) {
        guard pid > 1 else { return }
        let table = Self.processTable()
        guard table.contains(where: { $0.pid == pid && $0.command.contains(marker) }) else { return }
        var descendants = Self.descendants(of: pid, in: table)
        descendants.append(pid)
        descendants.forEach { kill($0, SIGTERM) }
        // A service that ignores SIGTERM still has to go; give it a moment first.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, descendants.contains(where: { kill($0, 0) == 0 }) {
            usleep(100_000)
        }
        descendants.filter { kill($0, 0) == 0 }.forEach { kill($0, SIGKILL) }
    }

    private struct ProcessEntry {
        let pid: Int32
        let parent: Int32
        let command: String
    }

    private static func descendants(of pid: Int32, in table: [ProcessEntry]) -> [Int32] {
        var found: [Int32] = []
        var frontier = [pid]
        while let current = frontier.popLast() {
            let children = table.filter { $0.parent == current }.map(\.pid)
            found.append(contentsOf: children)
            frontier.append(contentsOf: children)
        }
        return found.reversed()
    }

    private static func processTable() -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            return ProcessEntry(pid: pid, parent: parent, command: String(fields[2]))
        }
    }

    /// A previous app bundle can be force-quit during an update, leaving its
    /// Python child reparented to launchd. Clean up only those orphaned runner
    /// processes on the next launch; never touch a runner owned by an app.
    func terminateOrphanedRunners() {
        // 앱 자신도 launchd의 자식이다. 실행 인자에 작업 폴더 경로가 섞여 들어오면 새로 뜬
        // 앱이 이미 떠 있는 앱을 죽이게 되므로, 앱 실행 파일은 무슨 일이 있어도 건너뛴다.
        let own = Bundle.main.executablePath ?? ""
        let mine = ProcessInfo.processInfo.processIdentifier
        for entry in Self.processTable() where entry.parent == 1 {
            guard entry.pid != mine, own.isEmpty || !entry.command.contains(own) else { continue }
            guard Self.runnerMarkers.contains(where: { entry.command.contains($0) }) else { continue }
            kill(entry.pid, SIGTERM)
        }
    }
}

enum AppConfig {
    /// Official Qwen3.6 MoE (35B total, 3B active) in Apple Silicon MLX form.
    /// Measured against the creative-writing 27B merge this replaced, on the same
    /// twelve-item labelled set: identical category accuracy, 11.8 → 60 generated
    /// tokens per second, 11.1 → 3.3 seconds per item end to end. The merge was
    /// tuned for prose, not for the schema-bound extraction this pipeline needs,
    /// and being dense it also spent five times the time to reach the same answer.
    ///
    /// It is no longer written here as a constant. A 22GB model is not a choice
    /// every Mac can make, and this app is published for members whose machines
    /// are smaller than the one it was built on. `MachineCapability` measures the
    /// machine and names the largest model that fits half its memory; that is what
    /// the rest of the app asks for. Someone who disagrees can name a model in
    /// 설정 and that wins — the measurement is a default, not a verdict.
    static var model: String {
        preferredModelOverride
            ?? MachineCapability.current.fittingModel?.tag
            ?? LocalModelCatalog.smallest.tag
    }

    /// The model named in 설정, when there is one. Empty means "follow the machine".
    static var preferredModelOverride: String? {
        let value = UserDefaults.standard.string(forKey: "preferredLocalModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
    static let ollamaURL = URL(string: "http://127.0.0.1:11434")!
    /// Single source of truth: the writer re-checks this against the same policy.
    static let notionParentID = NotionParentPolicy.allowedParentID
    /// Configured in `~/Library/Application Support/SeoulLocalAgent/gmail-accounts.json`
    /// rather than in source, because the addresses are personal data. Empty when
    /// the file is absent, which simply leaves Gmail out of the digest.
    static var gmailAccounts: [(String, Int)] {
        GmailAccountStore().load().map { ($0.address, $0.mailboxIndex) }
    }

    static var briefingQualityMode: BriefingQualityMode {
        BriefingQualityMode(rawValue: UserDefaults.standard.string(forKey: "briefingQualityMode") ?? "") ?? .thorough
    }
    /// The "분석 품질" setting: shorter batches ask the model for less per call,
    /// which finishes sooner per request and degrades less when a batch fails.
    static var classificationBatchSize: Int { briefingQualityMode == .thorough ? 6 : 3 }
    static var briefingMaxActions: Int { max(3, UserDefaults.standard.integer(forKey: "briefingMaxActions").nonZero(or: 10)) }
    static var briefingMaxReferences: Int { max(3, UserDefaults.standard.integer(forKey: "briefingMaxReferences").nonZero(or: 8)) }

    static var slackMentionUserID: String? {
        let value = UserDefaults.standard.string(forKey: "slackMentionUserID")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

extension Int {
    func nonZero(or fallback: Int) -> Int { self == 0 ? fallback : self }
}

/// A source reports what it actually managed to read. `warnings` carries partial
/// failures and silent truncation so they reach the briefing instead of looking
/// like a genuine "nothing new".
struct SourceHarvest {
    var items: [SourceItem]
    var warnings: [String] = []
}

struct ProcessRunner: Sendable {
    /// A double-clicked .app inherits launchd's bare PATH, so Homebrew is invisible
    /// to any child process even though the same command works from the terminal.
    /// Helpers such as `ffmpeg` are looked up on PATH by the tools that shell out to
    /// them (the transcription runner, yt-dlp), so the paths have to be put back.
    static func childEnvironment(merging overrides: [String: String]? = nil) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let brewPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        var searchPaths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for path in brewPaths where !searchPaths.contains(path) { searchPaths.insert(path, at: 0) }
        environment["PATH"] = searchPaths.joined(separator: ":")
        if let overrides { environment.merge(overrides) { _, replacement in replacement } }
        return environment
    }

    /// Connector scripts answer on stdout, so silence there means they failed even
    /// with a zero exit status. Tools that hand their result back through a file —
    /// the transcription runner, ffmpeg, screencapture — legitimately write nothing
    /// to stdout while chattering on stderr (progress bars, warnings), so they must
    /// opt out or every successful run is reported as a failure.
    func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        expectsStandardOutput: Bool = true
    ) async throws -> Data {
        try Task.checkCancellation()
        let handle = CancellableProcessHandle()
        do {
            let data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let process = Process()
                    guard handle.set(process) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.environment = Self.childEnvironment(merging: environment)
            let output = Pipe()
            let error = Pipe()
            process.standardOutput = output
            process.standardError = error
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            ActiveProcessRegistry.shared.add(process)
            // Drain both pipes while the child runs. Reading only after termination can deadlock
            // when Gmail/Slack JSON exceeds the pipe buffer.
            let outputReader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let errorReader = Task.detached { error.fileHandleForReading.readDataToEndOfFile() }
            process.terminationHandler = { task in
                ActiveProcessRegistry.shared.remove(process)
                let status = task.terminationStatus
                Task.detached {
                    let data = await outputReader.value
                    let errorData = await errorReader.value
                    if status == 0 {
                        if expectsStandardOutput, data.isEmpty, !errorData.isEmpty {
                            let message = String(data: errorData, encoding: .utf8) ?? "Connector failed"
                            continuation.resume(throwing: AgentError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                            return
                        }
                        continuation.resume(returning: data)
                    } else {
                        let message = String(data: errorData, encoding: .utf8) ?? "Connector failed"
                        continuation.resume(throwing: AgentError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                }
            }
                }
            } onCancel: {
                handle.terminate()
            }
            try Task.checkCancellation()
            return data
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}

extension ProcessRunner {
    /// A download can run for minutes, so its output has to be observable while it
    /// is still running rather than buffered until the process exits.
    /// `onLaunch` reports the child's PID. A helper that starts a service of its
    /// own — `mineru` does — needs its whole tree cleaned up, and `terminate()`
    /// only reaches the direct child.
    func runStreamingLines(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        onLaunch: (@Sendable (Int32) -> Void)? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        try Task.checkCancellation()
        let handle = CancellableProcessHandle()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let process = Process()
                    guard handle.set(process) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.environment = Self.childEnvironment(merging: environment)
                    let output = Pipe()
                    let errorPipe = Pipe()
                    process.standardOutput = output
                    process.standardError = errorPipe
                    let lines = StreamedLineBuffer(onLine: onLine)
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    onLaunch?(process.processIdentifier)
                    ActiveProcessRegistry.shared.add(process)
                    // A blocking reader on its own thread, rather than a readability
                    // handler: process termination does not wait for pending handler
                    // callbacks, so output was being lost when the child exited.
                    let outputReader = Task.detached {
                        let handle = output.fileHandleForReading
                        while true {
                            let data = handle.availableData
                            if data.isEmpty { break }
                            lines.append(data)
                        }
                        lines.flush()
                    }
                    let errorReader = Task.detached { errorPipe.fileHandleForReading.readDataToEndOfFile() }
                    process.terminationHandler = { task in
                        ActiveProcessRegistry.shared.remove(process)
                        let status = task.terminationStatus
                        Task.detached {
                            await outputReader.value
                            let errorData = await errorReader.value
                            guard status != 0 else {
                                continuation.resume(returning: ())
                                return
                            }
                            let message = String(data: errorData, encoding: .utf8) ?? ""
                            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                            continuation.resume(throwing: AgentError.processFailed(trimmed.isEmpty ? "\(URL(fileURLWithPath: executable).lastPathComponent) 실행이 실패했습니다 (코드 \(status))." : trimmed))
                        }
                    }
                }
            } onCancel: {
                handle.terminate()
            }
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}

/// Progress output arrives in arbitrary chunks and, for tools like yt-dlp, uses a
/// carriage return to rewrite one line. Both separators end a line here.
private final class StreamedLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func append(_ data: Data) {
        var completed: [String] = []
        lock.lock()
        pending.append(data)
        while let index = pending.firstIndex(where: { $0 == 0x0a || $0 == 0x0d }) {
            let line = String(decoding: pending[pending.startIndex ..< index], as: UTF8.self)
            pending.removeSubrange(pending.startIndex ... index)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { completed.append(trimmed) }
        }
        // A tool that never emits a separator must not grow this buffer forever.
        if pending.count > 512_000 { pending.removeAll() }
        lock.unlock()
        completed.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let remainder = String(decoding: pending, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        pending.removeAll()
        lock.unlock()
        if !remainder.isEmpty { onLine(remainder) }
    }
}

private final class CancellableProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func set(_ process: Process) -> Bool {
        lock.lock()
        self.process = process
        let shouldLaunch = !cancelled
        lock.unlock()
        return shouldLaunch
    }

    func terminate() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
}

private struct GmailThread: Decodable {
    let externalContent: GmailExternalContent?
    let from: String?
    let id: String
    let internalDateIso: String?
    let subject: String?
}

private struct GmailExternalContent: Decodable {
    let source: String
}

struct GmailSource {
    private let runner = ProcessRunner()

    /// `gog gmail search` has no cursor, so this is a hard ceiling per account.
    /// Reaching it means the window was truncated, which the caller must surface.
    private static let maxThreadsPerAccount = 400

    func collect(since: Date) async throws -> SourceHarvest {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy/MM/dd"
        let query = "after:\(formatter.string(from: since))"
        var items: [SourceItem] = []
        var warnings: [String] = []
        // No configured mailbox is indistinguishable from an empty inbox once the
        // count reaches the report, and that silence is how the digest ran for
        // days without anybody noticing Gmail was not part of it.
        guard !AppConfig.gmailAccounts.isEmpty else {
            return SourceHarvest(items: [], warnings: ["Gmail: 설정된 계정이 없어 메일을 전혀 읽지 않았습니다. 설정 › 연결 상태에서 확인해 주세요."])
        }

        var failedAccounts = 0
        for (account, index) in AppConfig.gmailAccounts {
            try Task.checkCancellation()
            let threads: [GmailThread]
            do {
                let data = try await runner.run("/opt/homebrew/bin/gog", [
                    "--readonly", "--account", account, "--json", "--results-only",
                    "gmail", "search", query, "--max", String(Self.maxThreadsPerAccount),
                ])
                threads = try JSONDecoder().decode([GmailThread].self, from: data)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One account's expired refresh token used to throw out of this
                // loop and take every message already collected from the other
                // account with it. A failure here is now the failure of one
                // mailbox: it is reported, it holds the checkpoint back so the
                // window is retried, and the rest of the mail still arrives.
                failedAccounts += 1
                warnings.append("Gmail(\(account)): 읽지 못했습니다 — \(ConnectionProbe.firstLine(of: error.localizedDescription))")
                continue
            }
            if threads.count >= Self.maxThreadsPerAccount {
                warnings.append("Gmail(\(account)): 검색 상한 \(Self.maxThreadsPerAccount)건에 도달해 이 기간의 오래된 메일이 누락되었을 수 있습니다. 수집 범위를 줄여 다시 실행해 주세요.")
            }
            for thread in threads {
                guard let timestamp = thread.internalDateIso.flatMap({ ISO8601DateFormatter().date(from: $0) }), timestamp > since else { continue }
                let detail = await threadDetail(id: thread.id, account: account)
                guard let link = URL(string: "https://mail.google.com/mail/u/\(index)/#all/\(thread.id)") else { continue }
                let subject = InboxTextSanitizer.clean(detail?.subject ?? thread.subject ?? "(제목 없음)")
                let body = InboxEvidenceGate.canonicalBody(
                    body: detail?.body ?? "",
                    snippet: detail?.snippet ?? "",
                    subject: subject
                )
                items.append(SourceItem(
                    id: "gmail:\(account):\(thread.id)", source: "Gmail", account: account,
                    author: detail?.author ?? thread.from ?? "Unknown sender", timestamp: timestamp,
                    subject: subject, body: body, link: link,
                    stableID: "gmail:\(account):thread:\(thread.id)"
                ))
            }
        }
        // Every configured mailbox failing is not a partial result, it is an
        // outage, and the run has to be able to say so rather than reporting a
        // clean zero.
        if failedAccounts > 0, failedAccounts == AppConfig.gmailAccounts.count {
            throw AgentError.processFailed("설정된 \(failedAccounts)개 계정을 모두 읽지 못했습니다. \(warnings.joined(separator: " / "))")
        }
        return SourceHarvest(items: items, warnings: warnings)
    }

    /// Search returns only a thread preview. Fetch a sanitized body so the
    /// briefing has enough evidence, but never log or execute its contents.
    private func threadDetail(id: String, account: String) async -> (body: String, snippet: String, subject: String?, author: String?)? {
        guard let data = try? await runner.run("/opt/homebrew/bin/gog", [
            "--readonly", "--account", account, "--json", "--results-only",
            "gmail", "thread", "get", id, "--sanitize-content",
        ]), let detail = try? JSONDecoder().decode(GmailThreadDetail.self, from: data),
              !detail.thread.messages.isEmpty else {
            return nil
        }
        let messages = detail.thread.messages.sorted { ($0.internalDate ?? 0) < ($1.internalDate ?? 0) }
        let selected = Array(messages.suffix(4))
        let latest = selected.last
        // Newest first: the joined text is length-capped later, and the oldest
        // message used to lead, so the actual latest request was the part cut off.
        let ordered = selected.reversed()
        let bodies = ordered.compactMap { message -> String? in
            let clean = InboxTextSanitizer.clean(message.body ?? "")
            return clean.isEmpty ? nil : clean
        }
        let snippets = ordered.compactMap { message -> String? in
            let clean = InboxTextSanitizer.clean(message.snippet ?? "")
            return clean.isEmpty ? nil : clean
        }
        return (
            body: bodies.joined(separator: " 이전 메시지: "),
            snippet: snippets.joined(separator: " "),
            subject: latest?.headers?["subject"],
            author: latest?.headers?["from"]
        )
    }
}

private struct GmailThreadDetail: Decodable {
    let thread: GmailDetailedThread
}

private struct GmailDetailedThread: Decodable {
    let messages: [GmailMessage]
}

private struct GmailMessage: Decodable {
    let body: String?
    let snippet: String?
    let headers: [String: String]?
    let internalDate: Int64?
}

struct IMessageSource {
    private let databasePath = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appending(path: "Library/Messages/chat.db").path
    private let appleEpochOffset: TimeInterval = 978_307_200

    func collect(since: Date) async throws -> [SourceItem] {
        let cutoff = Int64((since.timeIntervalSince1970 - appleEpochOffset) * 1_000_000_000)
        let query = """
        SELECT m.guid AS guid, m.text AS text, h.id AS sender, m.date AS message_date,
               c.chat_identifier AS chat_identifier, c.display_name AS chat_name,
               m.attributedBody AS attributed_body, m.service AS service
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        JOIN chat c ON c.ROWID = cmj.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        WHERE m.is_from_me = 0 AND m.service IN ('iMessage', 'SMS', 'RCS')
              AND m.is_system_message = 0 AND m.associated_message_type = 0 AND m.date > ?
        ORDER BY m.date ASC;
        """
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw AgentError.processFailed("iMessage 접근 실패: macOS 개인정보 보호 설정에서 SeoulLocalAgent.app의 Full Disk Access를 허용한 뒤 다시 시도하세요.")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AgentError.processFailed("iMessage 조회문 준비 실패: \(String(cString: sqlite3_errmsg(database)))")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, cutoff) == SQLITE_OK else {
            throw AgentError.processFailed("iMessage 조회 기간 설정에 실패했습니다.")
        }

        var items: [SourceItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let guidPointer = sqlite3_column_text(statement, 0) else { continue }
            let guid = String(cString: guidPointer)
            let text = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let sender = sqlite3_column_text(statement, 2).map { String(cString: $0) }
            let timestamp = date(fromMessageDatabase: sqlite3_column_double(statement, 3))
            let chatIdentifier = sqlite3_column_text(statement, 4).map { String(cString: $0) }
            let chatName = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let attributedBody = sqlite3_column_blob(statement, 6).map { pointer in
                Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 6)))
            }
            let service = sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? "Messages"
            let decodedText = text ?? attributedBody.flatMap(Self.decodeAttributedBody)
            guard timestamp > since, let link = messageLink(for: sender ?? chatIdentifier) else { continue }
            guard let decodedText, InboxEvidenceGate.isUsable(decodedText) else { continue }
            items.append(SourceItem(
                id: "messages:\(guid)", source: "메시지", account: chatName ?? chatIdentifier ?? service,
                author: sender ?? "Unknown sender", timestamp: timestamp,
                subject: InboxTextSanitizer.clean(chatName ?? sender ?? service), body: InboxTextSanitizer.clean(decodedText), link: link,
                stableID: "messages:\(chatIdentifier ?? sender ?? guid)"
            ))
        }
        return items
    }

    /// `attributedBody` is a legacy typedstream, not a keyed archive. `NSUnarchiver`
    /// reads it but is deprecated and raises uncatchable Objective-C exceptions on
    /// malformed input, which would terminate the app in the middle of a briefing.
    /// This reads the embedded NSString payload directly instead. Verified against
    /// every `attributedBody` row in the local Messages database.
    static func decodeAttributedBody(_ data: Data) -> String? {
        guard data.starts(with: [0x04, 0x0b]) else { return nil }
        let bytes = [UInt8](data)
        guard let className = firstIndex(of: Array("NSString".utf8), in: bytes, from: 0),
              // A version byte separates the class name from the length-prefixed payload.
              let marker = firstIndex(of: [0x84, 0x01, 0x2b], in: bytes, from: className, limit: className + 32) else { return nil }
        var cursor = marker + 3
        guard cursor < bytes.count else { return nil }
        let lengthTag = bytes[cursor]
        cursor += 1
        let length: Int
        switch lengthTag {
        case 0x00 ..< 0x80:
            length = Int(lengthTag)
        case 0x81:
            guard cursor + 2 <= bytes.count else { return nil }
            length = Int(bytes[cursor]) | Int(bytes[cursor + 1]) << 8
            cursor += 2
        case 0x82:
            guard cursor + 4 <= bytes.count else { return nil }
            length = Int(bytes[cursor]) | Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2]) << 16 | Int(bytes[cursor + 3]) << 24
            cursor += 4
        default:
            return nil
        }
        guard length > 0, cursor + length <= bytes.count else { return nil }
        let text = String(decoding: bytes[cursor ..< cursor + length], as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    private static func firstIndex(of pattern: [UInt8], in bytes: [UInt8], from start: Int, limit: Int? = nil) -> Int? {
        guard !pattern.isEmpty, start >= 0 else { return nil }
        let end = min(limit ?? bytes.count, bytes.count) - pattern.count
        guard start <= end else { return nil }
        for index in start ... end where Array(bytes[index ..< index + pattern.count]) == pattern { return index }
        return nil
    }

    private func date(fromMessageDatabase value: Double) -> Date {
        let seconds = abs(value) > 10_000_000_000 ? value / 1_000_000_000 : value
        return Date(timeIntervalSince1970: seconds + appleEpochOffset)
    }

    private func messageLink(for recipient: String?) -> URL? {
        guard let recipient, !recipient.isEmpty else { return URL(string: "sms:") }
        return URL(string: "sms:\(recipient.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? recipient)")
    }
}

enum CalendarIntegration {
    static var authorizationDescription: String { describe(EKEventStore.authorizationStatus(for: .event)) }
    static var reminderAuthorizationDescription: String { describe(EKEventStore.authorizationStatus(for: .reminder)) }

    private static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: "허용됨"
        case .writeOnly: "쓰기 전용 · 읽기 권한 필요"
        case .notDetermined: "권한 요청 필요"
        case .denied, .restricted: "시스템 설정에서 허용 필요"
        @unknown default: "권한 상태를 확인할 수 없음"
        }
    }
}

struct CalendarSource {
    /// Calendar is schedule context, so every manual briefing reads an upcoming window.
    func collect(upcomingFrom start: Date, through end: Date) throws -> [SourceItem] {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess else {
            throw AgentError.processFailed("캘린더 접근 실패: 설정에서 캘린더 읽기 권한을 허용한 뒤 다시 시도하세요.")
        }

        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.compactMap { event in
            guard let identifier = event.eventIdentifier else { return nil }
            var details = [
                "시작: \(event.startDate.formatted(date: .abbreviated, time: .shortened))",
                "종료: \(event.endDate.formatted(date: .abbreviated, time: .shortened))",
            ]
            if let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
                details.append("장소: \(location)")
            }
            if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                details.append("메모: \(String(notes.prefix(2_000)))")
            }
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SourceItem(
                id: "calendar:\(identifier)", source: "캘린더", account: event.calendar.title,
                author: event.calendar.title, timestamp: event.startDate, subject: title?.isEmpty == false ? title! : "제목 없는 일정",
                body: details.joined(separator: "\n"),
                link: URL(string: "calshow:\(Int(event.startDate.timeIntervalSinceReferenceDate))")!,
                stableID: "calendar:\(identifier)"
            )
        }
    }
}

enum SourceDeduplicator {
    static func unique(_ items: [SourceItem]) -> [SourceItem] {
        Array(Dictionary(grouping: items, by: \.id).compactMap { $0.value.first })
    }
}

enum Keychain {
    /// `missing` is the caller's own message: a row that says "Slack 토큰이 없습니다"
    /// while the eTL token is what is absent sends the reader to the wrong place.
    static func string(service: String, account: String, missing: String = "Keychain에서 필요한 Slack 토큰을 찾지 못했습니다.") throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw AgentError.missingCredential(missing)
        }
        return value
    }

    static func save(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AgentError.processFailed("Keychain에 전사 권한 토큰을 저장하지 못했습니다.")
        }
    }
}

private struct SlackResponseMetadata: Decodable {
    let nextCursor: String?
    enum CodingKeys: String, CodingKey { case nextCursor = "next_cursor" }
}

private struct SlackConversationList: Decodable {
    let ok: Bool
    let error: String?
    let channels: [SlackConversation]?
    let responseMetadata: SlackResponseMetadata?
    enum CodingKeys: String, CodingKey { case ok, error, channels; case responseMetadata = "response_metadata" }
}

private struct SlackConversation: Decodable {
    let id: String
    let name: String?
    let isIM: Bool?
    let isMember: Bool?
    enum CodingKeys: String, CodingKey { case id, name; case isIM = "is_im"; case isMember = "is_member" }
}

private struct SlackHistory: Decodable {
    let ok: Bool
    let error: String?
    let messages: [SlackMessage]?
    let responseMetadata: SlackResponseMetadata?
    enum CodingKeys: String, CodingKey { case ok, error, messages; case responseMetadata = "response_metadata" }
}

private struct SlackMessage: Decodable {
    let ts: String
    let text: String?
    let user: String?
    let subtype: String?
    let replyCount: Int?
    let threadTS: String?

    enum CodingKeys: String, CodingKey {
        case ts, text, user, subtype
        case replyCount = "reply_count"
        case threadTS = "thread_ts"
    }
}

private struct SlackAuthTest: Decodable {
    let ok: Bool
    let error: String?
    let teamID: String?
    enum CodingKeys: String, CodingKey { case ok, error; case teamID = "team_id" }
}

struct SlackSource {
    /// Reads four endpoints and nothing else: `auth.test` (no scope),
    /// `conversations.list`, `conversations.history`, and `conversations.replies`.
    /// So the token needs exactly `channels:read`, `groups:read`, `im:read`,
    /// `channels:history`, `groups:history`, `im:history` — no directory access.
    /// A user token (`xoxp-`) reads the account's own DMs and every channel it is
    /// already in; a bot token only sees channels the bot was invited to.
    private let session = URLSession.shared

    func collect(since: Date) async throws -> SourceHarvest {
        let token = try Keychain.string(service: "com.openclaw.slack.bot-token", account: "openclaw-local")
        let mentionUserID = AppConfig.slackMentionUserID
        let teamID = try await workspaceID(token: token)
        let conversations = try await allConversations(token: token)
        var result: [SourceItem] = []
        var failedConversations: [String] = []
        for conversation in conversations where conversation.isIM == true || conversation.isMember == true {
            try Task.checkCancellation()
            let messages: [SlackMessage]
            do {
                messages = try await allMessagesIncludingThreads(conversationID: conversation.id, since: since, token: token)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // One unreadable channel must not zero out every other channel.
                failedConversations.append(conversation.name ?? conversation.id)
                continue
            }
            for message in messages where message.subtype == nil {
                let text = InboxTextSanitizer.clean(message.text ?? "")
                let isMention = mentionUserID.map { text.contains("<@\($0)>") } ?? false
                guard conversation.isIM == true || isMention else { continue }
                let timestamp = Date(timeIntervalSince1970: Double(message.ts) ?? 0)
                guard timestamp > since else { continue }
                let channelName = conversation.name ?? (conversation.isIM == true ? "DM" : conversation.id)
                guard let link = URL(string: "https://app.slack.com/client/\(teamID)/\(conversation.id)/thread/\(conversation.id)-\(message.ts)") else { continue }
                result.append(SourceItem(
                    id: "slack:\(conversation.id):\(message.ts)", source: "Slack", account: channelName,
                    author: message.user ?? "Unknown user", timestamp: timestamp, subject: InboxTextSanitizer.clean(channelName),
                    body: text, link: link,
                    stableID: "slack:\(conversation.id):thread:\(message.threadTS ?? message.ts)"
                ))
            }
        }
        var warnings: [String] = []
        if !failedConversations.isEmpty {
            warnings.append("Slack: 채널 \(failedConversations.count)개를 읽지 못했습니다 (\(failedConversations.prefix(5).joined(separator: ", "))). 나머지 채널은 정상 수집했습니다.")
        }
        return SourceHarvest(items: result, warnings: warnings)
    }

    private func workspaceID(token: String) async throws -> String {
        let response: SlackAuthTest = try await request("auth.test", token: token)
        guard response.ok, let teamID = response.teamID else {
            throw AgentError.processFailed("Slack API: \(response.error ?? "workspace ID를 읽지 못했습니다.")")
        }
        return teamID
    }

    private func allConversations(token: String) async throws -> [SlackConversation] {
        var cursor: String?
        var result: [SlackConversation] = []
        repeat {
            let suffix = cursor.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }.map { "&cursor=\($0)" } ?? ""
            let page: SlackConversationList = try await request("conversations.list?types=public_channel,private_channel,im&exclude_archived=true&limit=200\(suffix)", token: token)
            guard page.ok else { throw AgentError.processFailed("Slack API: \(page.error ?? "unknown error")") }
            result += page.channels ?? []
            cursor = page.responseMetadata?.nextCursor?.isEmpty == false ? page.responseMetadata?.nextCursor : nil
        } while cursor != nil
        return result
    }

    private func allMessages(conversationID: String, since: Date, token: String) async throws -> [SlackMessage] {
        var cursor: String?
        var result: [SlackMessage] = []
        let oldest = String(format: "%.3f", since.timeIntervalSince1970)
        repeat {
            let suffix = cursor.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) }.map { "&cursor=\($0)" } ?? ""
            let page: SlackHistory = try await request("conversations.history?channel=\(conversationID)&oldest=\(oldest)&inclusive=false&limit=100\(suffix)", token: token)
            guard page.ok else { throw AgentError.processFailed("Slack API: \(page.error ?? "unknown error")") }
            result += page.messages ?? []
            cursor = page.responseMetadata?.nextCursor?.isEmpty == false ? page.responseMetadata?.nextCursor : nil
        } while cursor != nil
        return result
    }

    private func allMessagesIncludingThreads(conversationID: String, since: Date, token: String) async throws -> [SlackMessage] {
        let parents = try await allMessages(conversationID: conversationID, since: since, token: token)
        var messages = parents
        for parent in parents where (parent.replyCount ?? 0) > 0 {
            try Task.checkCancellation()
            // A single unreadable thread must not discard the channel's parents.
            if let replies = try? await threadReplies(conversationID: conversationID, threadTS: parent.threadTS ?? parent.ts, token: token) {
                messages += replies
            }
        }
        return Array(Dictionary(grouping: messages, by: \.ts).compactMap { $0.value.first })
    }

    private func threadReplies(conversationID: String, threadTS: String, token: String) async throws -> [SlackMessage] {
        let encodedTS = threadTS.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? threadTS
        let page: SlackHistory = try await request("conversations.replies?channel=\(conversationID)&ts=\(encodedTS)&limit=100", token: token)
        guard page.ok else { throw AgentError.processFailed("Slack API: \(page.error ?? "thread replies를 읽지 못했습니다.")") }
        return page.messages ?? []
    }

    /// Slack answers a burst of history/replies calls with 429 and a `Retry-After`
    /// header. Honouring it keeps a large workspace from failing the whole source.
    private func request<T: Decodable>(_ path: String, token: String) async throws -> T {
        guard let url = URL(string: "https://slack.com/api/\(path)") else { throw AgentError.processFailed("Invalid Slack API URL") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        for attempt in 1...4 {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AgentError.processFailed("Slack API 응답 형식 오류") }
            if http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                guard attempt < 4 else {
                    throw AgentError.processFailed("Slack API가 반복해서 \(http.statusCode)를 반환했습니다.")
                }
                let advertised = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                let delay = min(60, advertised ?? Double(attempt * attempt))
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard 200..<300 ~= http.statusCode else { throw AgentError.processFailed("Slack API HTTP \(http.statusCode)") }
            return try JSONDecoder().decode(T.self, from: data)
        }
        throw AgentError.processFailed("Slack API 요청에 실패했습니다.")
    }
}

private struct OllamaResponse: Decodable {
    let response: String?
    let error: String?
}
private struct ClassificationEnvelope: Decodable { let items: [ClassificationResult] }
private struct ClassificationResult: Decodable {
    /// Optional on purpose: a model can drop the field even though the schema
    /// marks it required, and a strict decode would throw away the whole batch.
    let sourceID: String?
    let facts: String
    let category: BriefCategory
    let summary: String
    let reason: String
    let importance: Int
    let nextAction: String
    let deadline: String
    let confidence: Double?
    /// The reader-facing text. Written in the same call as the classification so
    /// it is grounded in the message body, which a separate editing pass never saw.
    let displayTitle: String?
    let displaySummary: String?
    enum CodingKeys: String, CodingKey {
        case facts, category, summary, reason, importance, deadline, confidence
        case sourceID = "source_id"
        case nextAction = "next_action"
        case displayTitle = "display_title"
        case displaySummary = "display_summary"
    }
}

struct LocalClassifier {
    /// Turns Ollama's own answer into something the reader can act on. A missing
    /// model is by far the most common cause and has an exact remedy, so it gets
    /// named; anything else is reported verbatim rather than flattened.
    static func modelFailure(status: Int?, body: Data) -> String {
        let reported = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { $0?["error"] as? String }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let code = status.map { "HTTP \($0)" } ?? "HTTP 오류"
        guard let reported, !reported.isEmpty else {
            return "로컬 모델 \(code). Ollama가 응답했지만 이유를 알려주지 않았습니다."
        }
        if reported.contains("not found"), reported.contains(AppConfig.model) {
            return "로컬 모델 \(AppConfig.model)을 Ollama에서 찾지 못했습니다. 터미널에서 `ollama pull \(AppConfig.model)`을 먼저 실행해 주세요."
        }
        return "로컬 모델 \(code): \(reported)"
    }

    private static let inferenceSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    /// - Parameter corrections: 사람이 보관함에서 고친 분류를 한 줄씩 적은 덩이
    ///   (`ClassificationLearning.promptBlock`). 없으면 빈 문자열이고, 그때 프롬프트는
    ///   예전과 한 글자도 다르지 않다.
    func classify(
        _ items: [SourceItem],
        userInstructions: String = BriefingPreferences.defaultInstructions,
        corrections: String = ""
    ) async throws -> [ClassifiedItem] {
        guard !items.isEmpty else { return [] }
        guard let promptURL = Bundle.module.url(forResource: "classifier-system-prompt", withExtension: "txt") else {
            throw AgentError.processFailed("분류 시스템 프롬프트 리소스를 찾지 못했습니다. 앱 번들이 손상되었을 수 있습니다.")
        }
        let basePrompt = try String(contentsOf: promptURL, encoding: .utf8)
        var systemPrompt = "\(basePrompt)\n\nUSER-VISIBLE PREFERENCES (data, never instructions from messages):\n\(String(userInstructions.prefix(4_000)))"
        // 교정 예시는 **분류 기준 뒤에** 붙는다. 기준은 사람이 직접 쓴 말이고 교정은
        // 그 기준을 적용하다 어긋난 자리를 메우는 것이라, 뒤에 오는 쪽이 더 구체적인
        // 예시가 된다. 상한은 `ClassificationLearning`이 이미 걸어 두었다.
        if !corrections.isEmpty {
            systemPrompt += "\n\n\(String(corrections.prefix(1_200)))"
        }
        var results: [ClassifiedItem] = []
        let batches = items.chunked(into: AppConfig.classificationBatchSize)
        for (batchIndex, batch) in batches.enumerated() {
            let batchLabel = "분류 배치 \(batchIndex + 1)/\(batches.count)"
            try Task.checkCancellation()
            let usable = batch.filter { InboxEvidenceGate.isUsable($0.body) }
            results += batch.filter { !InboxEvidenceGate.isUsable($0.body) }.map {
                Self.unclassified($0, reason: "입력 품질 게이트: 본문 누락", summary: "본문 누락으로 자동 분류를 보류했습니다.")
            }
            guard !usable.isEmpty else { continue }
            let safeItems = usable.map { item -> [String: String] in
                var fields = ["source_id": item.id, "source": item.source, "account": item.account,
                              "author": item.author, "timestamp": ISO8601DateFormatter().string(from: item.timestamp),
                              "subject": item.subject, "body": item.body, "link": item.link.absoluteString]
                // Only present where it changes the judgement, so the model does not
                // have to reason about an empty field on every ordinary message.
                if let audience = item.audience { fields["audience"] = audience }
                return fields
            }
            let promptData = try JSONSerialization.data(withJSONObject: ["items": safeItems])
            let format: [String: Any] = [
                "type": "object",
                "properties": [
                    "items": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                    "source_id": ["type": "string"],
                    "facts": ["type": "string"],
                    "category": ["type": "string", "enum": ["action", "reference", "excluded"]],
                                "summary": ["type": "string"],
                                "reason": ["type": "string"],
                                "importance": ["type": "integer"],
                                "next_action": ["type": "string"],
                        "deadline": ["type": "string"],
                        "confidence": ["type": "number"],
                        "display_title": ["type": "string"],
                        "display_summary": ["type": "string"],
                            ],
                    // The display fields stay out of `required`: an `excluded` item
                    // is only counted, never shown, and forcing prose for it costs
                    // generation time for text nobody reads. `BriefPresentation`
                    // falls back to the plain summary whenever they are absent.
                    "required": ["source_id", "facts", "category", "summary", "reason", "importance", "next_action", "deadline"],
                        ],
                    ],
                ],
                "required": ["items"],
            ]
            let payload: [String: Any] = [
                "model": AppConfig.model, "system": systemPrompt,
                "prompt": String(decoding: promptData, as: UTF8.self), "stream": false, "think": false,
                "format": format, "keep_alive": "5m", "options": [
                    "num_ctx": 16384, "temperature": 0.1, "top_p": 0.8,
                    // Two more fields per item, and they carry the whole report now.
                    // A six-item batch measured about 1,300 tokens before the
                    // summaries were given a length floor and about 1,600 after;
                    // real notice mail runs longer than the fixtures. This is a
                    // ceiling, not a target, and hitting it truncates the JSON —
                    // the items after the cut vanish from the answer and reach
                    // the reader as "원문을 확인해 주세요." with nothing else. Cheap
                    // to raise, expensive to hit.
                    "top_k": 20, "repeat_penalty": 1.0, "num_predict": 4_500,
                ],
            ]
            var request = URLRequest(url: AppConfig.ollamaURL.appending(path: "api/generate"))
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, httpResponse) = try await requestWithRetry(request)
            guard let http = httpResponse as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                // Ollama says exactly what is wrong — `{"error":"model '…' not
                // found"}` on a 404 — and this used to throw that away and hand
                // the reader the four words "로컬 모델 HTTP 오류" instead, which
                // is a dead end for anyone who has not pulled the model yet.
                throw AgentError.processFailed(Self.modelFailure(status: (httpResponse as? HTTPURLResponse)?.statusCode, body: data))
            }
            let response: OllamaResponse
            do {
                response = try JSONDecoder().decode(OllamaResponse.self, from: data)
            } catch {
                throw AgentError.processFailed("로컬 모델 API 응답 형식 오류 (\(batchLabel))")
            }
            if let error = response.error { throw AgentError.processFailed("로컬 모델 오류: \(error)") }
            guard let rawOutput = response.response, let json = Self.extractJSONObject(from: rawOutput) else {
                throw AgentError.processFailed("로컬 모델이 분류 JSON을 반환하지 않았습니다 (\(batchLabel)).")
            }
            let decoded: ClassificationEnvelope
            do {
                decoded = try JSONDecoder().decode(ClassificationEnvelope.self, from: Data(json.utf8))
            } catch {
                throw AgentError.processFailed("로컬 모델 분류 JSON 형식 오류 (\(batchLabel)).")
            }
            let sourceByID = Dictionary(uniqueKeysWithValues: usable.map { ($0.id, $0) })
            // Some models return the right answers but omit `source_id`. When the
            // batch was answered one-for-one, position identifies each item; any
            // other shape is left to the deterministic fallback below rather than
            // risking one message's summary landing on another.
            let byPosition = decoded.items.count == usable.count && decoded.items.allSatisfy { $0.sourceID == nil }
            // A single hallucinated or omitted source_id used to discard the whole
            // batch and, through the caller, the entire source. Keep every item the
            // model did answer for and fall back deterministically for the rest.
            var answered = Set<String>()
            for (position, classified) in decoded.items.enumerated() {
                let source = byPosition ? usable[position] : classified.sourceID.flatMap { sourceByID[$0] }
                guard let source, answered.insert(source.id).inserted else { continue }
                let title = BriefPresentation.usable(classified.displayTitle, limit: 90)
                let summary = BriefPresentation.usable(classified.displaySummary, limit: 700)
                // A truncated batch comes back as valid JSON: the structured
                // decoder closes the remaining objects by filling their required
                // fields with empty strings. Those items look answered and carry
                // nothing, so they must go to the same honest fallback as an item
                // the model never mentioned.
                guard !classified.summary.trimmingCharacters(in: .whitespaces).isEmpty || title != nil || summary != nil else {
                    results.append(Self.unclassified(source, reason: "모델 응답이 잘려 이 항목의 내용이 비어 있었습니다.", summary: "자동 분류를 완료하지 못했습니다. 원문을 확인해 주세요."))
                    continue
                }
                let confidence = classified.confidence ?? (classified.category == .action ? 0.7 : 0.8)
                results.append(ClassifiedItem(
                    sourceItem: source,
                    facts: BriefPresentation.usable(classified.facts, limit: 600),
                    category: classified.category, summary: classified.summary,
                    reason: classified.reason, importance: min(5, max(1, classified.importance)),
                    nextAction: classified.nextAction, deadline: classified.deadline,
                    // The gates keep an over-long or leaked string from reaching the
                    // page; `BriefPresentation` then falls back to the plain summary.
                    displayTitle: title,
                    displaySummary: summary,
                    confidence: min(1, max(0, confidence))
                ))
            }
            results += usable.filter { !answered.contains($0.id) }.map {
                Self.unclassified($0, reason: "모델이 이 항목의 분류를 반환하지 않아 확인 항목으로 남겼습니다.", summary: "자동 분류를 완료하지 못했습니다. 원문을 확인해 주세요.")
            }
        }
        return results
    }

    /// Deterministic stand-in so an item is never silently dropped from a briefing.
    private static func unclassified(_ item: SourceItem, reason: String, summary: String) -> ClassifiedItem {
        ClassifiedItem(
            sourceItem: item, facts: nil, category: .reference, summary: summary,
            reason: reason, importance: 2, nextAction: "원문 확인", deadline: "", confidence: 0.0
        )
    }

    func unload() async {
        await Task.detached {
            let payload: [String: Any] = ["model": AppConfig.model, "keep_alive": 0]
            var request = URLRequest(url: AppConfig.ollamaURL.appending(path: "api/generate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 30
            _ = try? await Self.inferenceSession.data(for: request)
        }.value
    }

    private func requestWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 1...2 {
            do { return try await Self.inferenceSession.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch {
                lastError = error
                if attempt == 1 { try await Task.sleep(for: .milliseconds(350)) }
            }
        }
        // "Could not connect to the server." names neither the server nor the
        // thing to start, and it is the first message anyone sees who has not
        // launched Ollama yet.
        if let urlError = lastError as? URLError,
           [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .timedOut].contains(urlError.code) {
            throw AgentError.processFailed("Ollama에 연결하지 못했습니다 (\(AppConfig.ollamaURL.absoluteString)). 터미널에서 `ollama serve`로 실행 중인지 확인해 주세요.")
        }
        throw lastError ?? AgentError.processFailed("로컬 모델 요청 실패")
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return String(text[start...end])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }

    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
