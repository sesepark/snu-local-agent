import Foundation
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

/// The 정밀 (수식·표) mode and the process-tree cleanup it needs. MinerU itself
/// is exercised by hand; everything here runs without it.
@Suite("Document parsing")
struct DocumentParsingTests {
    @Test("Only 정밀 mode produces Markdown")
    func modeMapping() {
        #expect(!DocumentRecognitionMode.vision.producesMarkdown)
        #expect(DocumentRecognitionMode.precise.producesMarkdown)
        #expect(DocumentRecognitionMode.allCases.count == 2)
    }

    @Test("Precise parsing accepts the same files as Vision")
    func supportedFiles() {
        #expect(DocumentParsingService.isSupported(URL(fileURLWithPath: "/tmp/slides.pdf")))
        #expect(DocumentParsingService.isSupported(URL(fileURLWithPath: "/tmp/handout.png")))
        #expect(!DocumentParsingService.isSupported(URL(fileURLWithPath: "/tmp/lecture.m4a")))
    }

    @Test("The document Markdown is picked out of MinerU's output tree")
    func findsMarkdownOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let nested = directory.appending(path: "paper/hybrid-engine", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A run leaves more than one Markdown file behind; the document is the
        // substantial one, not the stub beside it.
        try "note".write(to: nested.appending(path: "aside.md"), atomically: true, encoding: .utf8)
        let document = "# 3장\n\n$$E = mc^2$$\n\n| 항목 | 값 |\n| --- | --- |\n| a | 1 |"
        try document.write(to: nested.appending(path: "paper.md"), atomically: true, encoding: .utf8)

        let markdown = try DocumentParsingService.markdown(in: directory)
        #expect(markdown.contains("E = mc^2"))
        #expect(markdown.contains("| 항목 | 값 |"))
    }

    @Test("A run that produced nothing is reported, not returned empty")
    func missingMarkdownThrows() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: AgentError.self) { try DocumentParsingService.markdown(in: directory) }
    }

    @Test("Missing environment is reported in Korean rather than a launch error")
    func missingEnvironmentIsExplained() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        guard !FileManager.default.isExecutableFile(atPath: DocumentParsingService.executable) else { return }
        await #expect(throws: AgentError.self) {
            _ = try await DocumentParsingService().parse(fileURL: file) { _ in }
        }
    }
}

/// Runs MinerU for real. Off by default because it needs `.venv-docparse` and
/// the downloaded weights and takes a minute or more:
///
///     SEOUL_DOCPARSE_INTEGRATION=1 scripts/run-tests.sh
@Suite(
    "Document parsing integration",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["SEOUL_DOCPARSE_INTEGRATION"] == "1")
)
struct DocumentParsingIntegrationTests {
    @Test("A page of a paper comes back as Markdown", .timeLimit(.minutes(10)))
    func parsesPaper() async throws {
        let source = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SEOUL_DOCPARSE_SAMPLE"] ?? "")
        try #require(FileManager.default.fileExists(atPath: source.path), "SEOUL_DOCPARSE_SAMPLE에 PDF 경로를 지정해 주세요.")

        let result = try await DocumentParsingService().parse(fileURL: source) { _ in }
        #expect(!result.markdown.isEmpty)
        #expect(result.pageCount > 0)
    }

    @Test("Parsing leaves no MinerU service behind")
    func leavesNoService() {
        #expect(ProcessTreeTests.count(matching: "mineru.cli.fast_api") == 0)
    }
}

/// MinerU starts a service of its own, so the app has to be able to take down a
/// whole tree. This is the guarantee that nothing survives a cancel.
@Suite("Process tree cleanup", .serialized)
struct ProcessTreeTests {
    @Test("Terminating a tree kills grandchildren, not just the direct child")
    func killsGrandchildren() throws {
        let marker = "seoul-tree-test-\(UUID().uuidString.prefix(8))"
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The inner `sh` is the grandchild: killing only the outer one would
        // leave it running, reparented to launchd.
        parent.arguments = ["-c", "/bin/sh -c 'sleep 120' & sleep 120 # \(marker)"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }

        // Give the shell a moment to fork its child before counting.
        Thread.sleep(forTimeInterval: 0.5)
        #expect(Self.count(matching: marker) >= 1)

        ActiveProcessRegistry.shared.terminateTree(of: parent.processIdentifier, matching: marker)
        #expect(Self.count(matching: marker) == 0)
        #expect(!parent.isRunning)
    }

    @Test("A PID that no longer belongs to the helper is left alone")
    func refusesUnrelatedPID() throws {
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sh")
        bystander.arguments = ["-c", "sleep 30"]
        try bystander.run()
        defer { if bystander.isRunning { bystander.terminate() } }

        // Same PID, wrong command: this is the PID-reuse case, and it must not
        // kill whatever now owns the number.
        ActiveProcessRegistry.shared.terminateTree(of: bystander.processIdentifier, matching: "scripts/matting_runner.py")
        Thread.sleep(forTimeInterval: 0.3)
        #expect(bystander.isRunning)
    }

    static func count(matching marker: String) -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", marker]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { Int32($0.trimmingCharacters(in: .whitespaces)) != nil }
            .count
    }
}
#endif
