import Foundation
import PDFKit

/// Precise document parsing for the 문서 인식 tab.
///
/// macOS Vision reads glyphs, so a slide with an integral or a two-column table
/// comes back as scrambled plain text. MinerU is a document model that keeps
/// formulas as LaTeX and tables as HTML and emits Markdown, which is what a
/// lecture handout or problem set actually needs.
///
/// It runs as a one-shot command rather than a resident process: parsing is
/// measured in seconds per page and nobody parses documents back to back the
/// way they crop photos, so paying the model load each time is cheaper than
/// holding gigabytes for a tab that is idle most of the day.
struct DocumentParsingService {
    static let executable = ProjectRoot.resolving(".venv-docparse/bin/mineru")
    /// Weights live next to the other local models so uninstalling is one folder.
    static let modelCache = NSString(string: "~/.cache/seoul-local-agent/hf").expandingTildeInPath

    struct Result {
        let markdown: String
        let pageCount: Int
    }

    private let runner = ProcessRunner()

    static func isSupported(_ url: URL) -> Bool {
        DocumentRecognizer.isSupported(url)
    }

    func parse(fileURL: URL, progress: @escaping @Sendable (String) async -> Void) async throws -> Result {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentError.processFailed("파일을 찾을 수 없습니다: \(fileURL.lastPathComponent)")
        }
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else {
            throw AgentError.processFailed("정밀 인식용 환경을 찾지 못했습니다. 터미널에서 `scripts/setup-docparse-env.sh`를 실행해 주세요.")
        }
        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SeoulLocalAgent-Docparse-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        // MinerU reports through progress bars on stderr, which the streaming
        // runner keeps back for error reporting. Drive the wording from elapsed
        // time instead, the way the transcription screen does.
        let monitor = Task {
            let started = Date()
            while !Task.isCancelled {
                let elapsed = Int(Date().timeIntervalSince(started))
                if elapsed < 5 {
                    await progress("정밀 인식을 준비하고 있습니다.")
                } else if Self.modelsPresent {
                    await progress("수식과 표를 인식하고 있습니다. (\(elapsed)초)")
                } else {
                    await progress("문서 모델을 처음 내려받고 있습니다. 몇 분 걸립니다. (\(elapsed)초)")
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { monitor.cancel() }

        // MinerU starts a local API service of its own, so cancelling or failing
        // has to take down the whole tree; terminating just the CLI leaves that
        // service running and reparented to launchd.
        let child = ChildProcess()
        defer { ActiveProcessRegistry.shared.terminateTree(of: child.identifier, matching: Self.processMarker) }

        try await runner.runStreamingLines(
            Self.executable,
            [
                "-p", fileURL.path,
                "-o", outputDirectory.path,
                "-b", Self.backend,
            ],
            environment: [
                "HF_HOME": Self.modelCache,
                "MINERU_MODEL_SOURCE": "huggingface",
                // The Xet transfer backend stalled partway through the model
                // download on this machine; plain HTTP finishes.
                "HF_HUB_DISABLE_XET": "1",
                "HF_HUB_DISABLE_PROGRESS_BARS": "1",
                "TQDM_DISABLE": "1",
                // Left to auto-detect, MinerU reads 1GB of VRAM on Apple Silicon
                // and drops to a batch of one page. This machine has 64GB of
                // unified memory, so tell it what is actually available.
                "MINERU_VIRTUAL_VRAM_SIZE": "\(Self.virtualVRAMGigabytes)",
            ],
            onLaunch: { child.identifier = $0 }
        ) { _ in }

        await progress("인식 결과를 정리하고 있습니다.")
        let markdown = try Self.markdown(in: outputDirectory)
        return Result(markdown: markdown, pageCount: Self.pageCount(of: fileURL))
    }

    /// MinerU's own default and its highest-accuracy local option; it picks the
    /// Apple Silicon path by itself.
    static let backend = "hybrid-engine"
    /// Matched against `ps` output when cleaning up the process tree.
    static let processMarker = "bin/mineru"

    /// A quarter of physical memory, so the setting follows the machine instead
    /// of hard-coding this Mac's 64GB, and leaves room for everything else.
    static var virtualVRAMGigabytes: Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return max(8, min(32, Int(bytes / 4 / 1_073_741_824)))
    }

    static var modelsPresent: Bool {
        FileManager.default.fileExists(atPath: "\(modelCache)/hub/models--opendatalab--MinerU2.5-Pro-2605-1.2B")
    }

    /// The child's PID, filled in once the process actually starts.
    private final class ChildProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32 = 0
        var identifier: Int32 {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                value = newValue
                lock.unlock()
            }
        }
    }

    /// MinerU writes `<out>/<stem>/<backend>/<stem>.md` plus extracted images.
    /// Find the Markdown wherever it landed rather than hard-coding that shape.
    static func markdown(in directory: URL) throws -> String {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var candidates: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "md" { candidates.append(url) }
        }
        // A run can leave more than one Markdown file behind; the document is
        // the substantial one.
        guard let best = candidates.max(by: { Self.size(of: $0) < Self.size(of: $1) }) else {
            throw AgentError.processFailed("정밀 인식 결과를 찾지 못했습니다.")
        }
        let text = (try? String(contentsOf: best, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            throw AgentError.processFailed("문서에서 내용을 찾지 못했습니다.")
        }
        return text
    }

    private static func size(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func pageCount(of url: URL) -> Int {
        guard url.pathExtension.lowercased() == "pdf" else { return 1 }
        return PDFDocument(url: url)?.pageCount ?? 1
    }
}
