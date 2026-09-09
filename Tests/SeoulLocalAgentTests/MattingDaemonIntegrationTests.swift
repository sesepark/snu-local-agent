import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

/// Exercises the real Python runner: pipe framing, request/response matching,
/// and the promise that nothing survives `shutdownNow()`.
///
/// Off by default because it needs `.venv-matting` and the downloaded weights,
/// and takes tens of seconds. Run it deliberately after touching either side of
/// the protocol:
///
///     SEOUL_MATTING_INTEGRATION=1 scripts/run-tests.sh
// Serialized so the shutdown check cannot run while the round-trip is still
// mid-inference and see that runner as a leak.
@Suite("Matting daemon integration", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SEOUL_MATTING_INTEGRATION"] == "1"))
struct MattingDaemonIntegrationTests {
    @Test("A photo round-trips through the resident runner", .timeLimit(.minutes(5)))
    func roundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "subject.png")
        try Self.writeSubject(to: source)

        // The progress callback is invoked from the runner's reader thread, so
        // the counter has to be safe to touch from there.
        let progressed = Progress()
        let output = try await BackgroundRemovalService().removeBackground(from: source, model: .balanced) { _ in
            progressed.record()
        }
        defer { try? FileManager.default.removeItem(at: output) }

        #expect(progressed.count > 0)
        let cutout = try #require(CutoutComposer.load(output))
        #expect(cutout.width == 600 && cutout.height == 600)
        #expect(cutout.alphaInfo != .none)
    }

    @Test("Shutting down leaves no runner process behind")
    func shutdownLeavesNothing() async throws {
        MattingDaemon.shared.shutdownNow()
        // `shutdownNow` returns only once the child is reaped, so a survivor
        // here is a real leak rather than a race.
        #expect(Self.runningRunners().isEmpty)
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func record() {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }

    private static func runningRunners() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fl", "scripts/matting_runner.py"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }

    /// A plain blob on a flat field: enough for the model to return a mask
    /// without shipping a photo into the repository.
    private static func writeSubject(to url: URL) throws {
        guard let context = CGContext(
            data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw AgentError.processFailed("test image") }
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.55, blue: 0.25, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        context.setFillColor(CGColor(srgbRed: 0.86, green: 0.24, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 140, y: 120, width: 320, height: 360))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw AgentError.processFailed("test image") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AgentError.processFailed("test image") }
    }
}
#endif
