import Foundation

/// Owns the resident Python process behind 소리 다듬기 (정밀) and 화질 올리기.
///
/// Built to the same rules as `MattingDaemon`, and for the same reason: both
/// models cost ten to fifteen seconds to load, which would otherwise be paid
/// once per file. Staying resident is only acceptable because the process is
/// guaranteed to die — it exits on stdin EOF (which the kernel delivers even if
/// the app is force-quit), on the parent PID disappearing, and after five idle
/// minutes. `shutdownNow()` is the fourth, explicit path for a clean quit.
///
/// One daemon rather than two: enhancement and upscaling never run at the same
/// time (they are different screens), they share a Python environment, and a
/// second resident torch process would hold another gigabyte for nothing. The
/// runner unloads whichever model is not being asked for.
///
/// Lock-based rather than an actor so `shutdownNow()` can be called
/// synchronously from `applicationWillTerminate`, where there is nothing left
/// to await with.
final class MediaDaemon: @unchecked Sendable {
    static let shared = MediaDaemon()

    static let executable = ProjectRoot.resolving(".venv-media/bin/python")
    static let runnerScript = ProjectRoot.resolving("scripts/media_runner.py")
    static let idleTimeout = 300

    /// Whatever the runner reports back on success.
    ///
    /// The measurements are flattened to `Double` rather than kept as the raw
    /// `[String: Any]` from the JSON: the two tasks report different keys, but
    /// every one of them is a number, and `Any` is not `Sendable`.
    struct Reply: Sendable {
        let output: URL
        let numbers: [String: Double]

        func number(_ key: String) -> Double? { numbers[key] }
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
            && FileManager.default.fileExists(atPath: runnerScript)
    }

    static let setupHint = "이 기능의 Python 환경을 찾지 못했습니다. 터미널에서 `scripts/setup-media-env.sh`를 실행해 주세요."

    private struct Waiter {
        let continuation: CheckedContinuation<Reply, Error>
        /// `(detail, fraction)` — the fraction is `nil` while the runner is
        /// loading weights and has nothing to measure yet.
        let progress: @Sendable (String, Double?) -> Void
    }

    private let lock = NSLock()
    private var process: Process?
    private var standardInput: FileHandle?
    private var waiters: [Int: Waiter] = [:]
    /// Requests cancelled before their continuation was registered; without this
    /// a cancel that lands first would be silently ignored.
    private var cancelled: Set<Int> = []
    private var nextIdentifier = 1
    private var lineBuffer = Data()
    private var errorTail = ""

    private init() {}

    // MARK: 요청

    /// `payload` is merged into the request JSON, so each task names its own
    /// options without this type having to know what they mean.
    func send(
        task: String,
        source: URL,
        destination: URL,
        payload: [String: Any] = [:],
        progress: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> Reply {
        guard Self.isInstalled else { throw AgentError.processFailed(Self.setupHint) }
        let identifier = reserveIdentifier()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request: Data
                do {
                    request = try Self.encode(
                        identifier: identifier, task: task,
                        source: source, destination: destination, payload: payload
                    )
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                lock.lock()
                if cancelled.remove(identifier) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try startLocked()
                } catch {
                    lock.unlock()
                    continuation.resume(throwing: error)
                    return
                }
                waiters[identifier] = Waiter(continuation: continuation, progress: progress)
                let handle = standardInput
                lock.unlock()
                do {
                    try handle?.write(contentsOf: request)
                } catch {
                    finish(identifier, with: .failure(AgentError.processFailed("로컬 러너에 요청을 전달하지 못했습니다.")))
                }
            }
        } onCancel: {
            abandon(identifier)
        }
    }

    static func encode(identifier: Int, task: String, source: URL, destination: URL, payload: [String: Any]) throws -> Data {
        var object: [String: Any] = [
            "id": identifier,
            "task": task,
            "input": source.path,
            "output": destination.path,
        ]
        object.merge(payload) { _, replacement in replacement }
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    /// Kept synchronous: `NSLock` may not be taken from an async context, and the
    /// continuation body above is the only place that needs it.
    private func reserveIdentifier() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let identifier = nextIdentifier
        nextIdentifier += 1
        return identifier
    }

    private func abandon(_ identifier: Int) {
        lock.lock()
        guard let waiter = waiters.removeValue(forKey: identifier) else {
            cancelled.insert(identifier)
            lock.unlock()
            return
        }
        lock.unlock()
        // The runner finishes this one file and its answer is dropped. Restarting
        // instead would throw away the warm model, which is the whole point of
        // keeping the process alive.
        waiter.continuation.resume(throwing: CancellationError())
    }

    // MARK: 프로세스 수명

    /// Must be called with `lock` held.
    private func startLocked() throws {
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: Self.executable),
              FileManager.default.fileExists(atPath: Self.runnerScript)
        else { throw AgentError.processFailed(Self.setupHint) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executable)
        process.arguments = [
            Self.runnerScript,
            "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)",
            "--idle-timeout", "\(Self.idleTimeout)",
        ]
        var environment = ProcessRunner.childEnvironment()
        // Alongside the other models rather than the default ~/.cache/huggingface,
        // so uninstalling this app means deleting one folder.
        environment["HF_HOME"] = NSString(string: "~/.cache/seoul-local-agent/hf").expandingTildeInPath
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        // The Xet transfer backend stalls part-way through on this machine, so
        // the weights come down over plain HTTP, as they do for 문서 인식.
        environment["HF_HUB_DISABLE_XET"] = "1"
        environment["TQDM_DISABLE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.ingest(data)
        }
        // Drained rather than discarded: a missing Python package shows up here
        // and nowhere else, and an unread pipe would eventually block the runner.
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.recordError(String(decoding: data, as: UTF8.self))
        }
        process.terminationHandler = { [weak self] _ in self?.handleTermination() }
        try process.run()
        ActiveProcessRegistry.shared.add(process)
        self.process = process
        self.standardInput = input.fileHandleForWriting
        lineBuffer = Data()
        errorTail = ""
    }

    /// Closes the pipe, then terminates, then kills. Returns only once the runner
    /// is gone, so `applicationWillTerminate` cannot race it.
    func shutdownNow() {
        lock.lock()
        let process = self.process
        let input = self.standardInput
        self.process = nil
        self.standardInput = nil
        let pending = waiters
        waiters.removeAll()
        cancelled.removeAll()
        lock.unlock()

        pending.values.forEach { $0.continuation.resume(throwing: AgentError.cancelled) }
        try? input?.close()
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        ActiveProcessRegistry.shared.remove(process)
    }

    private func handleTermination() {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        let reason = errorTail.trimmingCharacters(in: .whitespacesAndNewlines)
        if let process, !process.isRunning {
            ActiveProcessRegistry.shared.remove(process)
            self.process = nil
            self.standardInput = nil
        }
        lock.unlock()
        guard !pending.isEmpty else { return }
        let message = reason.isEmpty
            ? "로컬 러너가 예기치 않게 종료되었습니다."
            : "로컬 러너가 예기치 않게 종료되었습니다: \(reason)"
        pending.values.forEach { $0.continuation.resume(throwing: AgentError.processFailed(message)) }
    }

    // MARK: 응답 읽기

    private func ingest(_ data: Data) {
        lock.lock()
        lineBuffer.append(data)
        var lines: [Data] = []
        while let index = lineBuffer.firstIndex(of: 0x0A) {
            lines.append(lineBuffer[lineBuffer.startIndex ..< index])
            lineBuffer.removeSubrange(lineBuffer.startIndex ... index)
        }
        lock.unlock()
        lines.forEach(handle)
    }

    private func handle(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        guard let identifier = object["id"] as? Int else { return }

        if object["event"] as? String == "progress" {
            lock.lock()
            let waiter = waiters[identifier]
            lock.unlock()
            let detail = object["detail"] as? String ?? ""
            let fraction = object["fraction"] as? Double
            waiter?.progress(detail, fraction)
            return
        }
        if object["ok"] as? Bool == true, let path = object["output"] as? String {
            let numbers = object.compactMapValues { ($0 as? NSNumber).map(\.doubleValue) }
            finish(identifier, with: .success(Reply(output: URL(fileURLWithPath: path), numbers: numbers)))
        } else {
            let message = object["error"] as? String ?? "로컬 러너가 실패했습니다."
            finish(identifier, with: .failure(AgentError.processFailed(message)))
        }
    }

    private func finish(_ identifier: Int, with result: Result<Reply, any Error>) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: identifier)
        lock.unlock()
        guard let waiter else { return }
        waiter.continuation.resume(with: result)
    }

    /// Only the tail is kept: a torch traceback runs to dozens of lines and the
    /// last of them is the one that says what actually went wrong.
    private func recordError(_ text: String) {
        lock.lock()
        errorTail = String((errorTail + text).suffix(600))
        lock.unlock()
    }
}
