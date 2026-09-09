import Foundation
import AppKit
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - 모델 선택

/// The three ways this app can separate a subject from its background, ordered
/// from best quality to fastest. The first two run BiRefNet (MIT) through the
/// resident Python runner; the third uses the subject lifting that ships with
/// macOS, so it needs no download at all.
enum MattingModelChoice: String, CaseIterable, Identifiable, Sendable {
    case highResolution
    case balanced
    case appleVision

    var id: String { rawValue }

    var title: String {
        switch self {
        case .highResolution: "정밀 (BiRefNet HR · 2048)"
        case .balanced: "균형 (BiRefNet · 1024)"
        case .appleVision: "빠름 (macOS 내장)"
        }
    }

    var detail: String {
        switch self {
        case .highResolution: "머리카락과 털까지 가장 정확합니다. 장당 3~8초, 첫 실행 시 약 900MB를 내려받습니다."
        case .balanced: "일반 사진에 충분한 품질로 장당 1~2초입니다."
        case .appleVision: "macOS에 내장된 피사체 분리라 다운로드 없이 즉시 처리하지만 경계가 거칩니다."
        }
    }

    /// The `model` value understood by `scripts/matting_runner.py`; `nil` means
    /// this choice never launches Python.
    var runnerValue: String? {
        switch self {
        case .highResolution: "hr-matting"
        case .balanced: "matting"
        case .appleVision: nil
        }
    }

    var usesPythonRunner: Bool { runnerValue != nil }
}

// MARK: - 배경 옵션

enum CutoutBackground: String, CaseIterable, Identifiable, Sendable {
    case transparent, white, black, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transparent: "투명"
        case .white: "흰색"
        case .black: "검정"
        case .custom: "직접 선택"
        }
    }

    /// `nil` keeps the alpha channel; any other value is painted behind it.
    func color(custom: Color?) -> CGColor? {
        switch self {
        case .transparent: nil
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .custom: custom?.cgColor
        }
    }

    /// A minimal sRGB colour so the composer stays testable without SwiftUI.
    struct Color: Sendable, Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    }
}

// MARK: - 합성

/// Turns a cutout into the PNG that finally reaches disk or the clipboard.
/// Kept free of any model or process work: changing the background colour must
/// never cost another inference pass.
enum CutoutComposer {
    static func pngData(from image: CGImage, background: CGColor?) -> Data? {
        guard let composed = compose(image, background: background) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, composed, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func compose(_ image: CGImage, background: CGColor?) -> CGImage? {
        guard let background else { return image }
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(background)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    /// Downscales and composites in one pass for the card thumbnails. A phone
    /// photo is far larger than the card, and SwiftUI would otherwise redo the
    /// full-resolution work on every redraw.
    static func preview(of url: URL, maxPixel: Int, background: CGColor?, edit: PhotoEdit = .identity) -> CGImage? {
        guard let loaded = load(url) else { return nil }
        // Before the downscale: the crop is a fraction of the original, and doing it
        // first also means fewer pixels to resample.
        let image = edit.apply(to: loaded)
        let scale = min(1, Double(maxPixel) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            context.setFillColor(background)
            context.fill(bounds)
        }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        return context.makeImage()
    }

    /// Header only: the card needs the size, not several megapixels of decoded image.
    static func size(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
}

// MARK: - macOS 내장 피사체 분리

/// The zero-download path: Vision's foreground instance mask, which is what
/// "Copy Subject" in Preview uses. `DocumentRecognition.swift` reaches for
/// Vision the same way for text.
enum VisionSubjectMatting {
    private static let context = CIContext()

    static func cutout(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw AgentError.processFailed("사진에서 피사체를 찾지 못했습니다. 다른 모델로 시도해 보세요.")
        }
        // `generateMaskedImage` applies the mask at the photo's own resolution
        // and hands back straight alpha, which is exactly the cutout we want;
        // building it from the raw mask would mean matching Vision's scale and
        // premultiplication by hand.
        let masked = try observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: handler,
            croppedToInstancesExtent: false
        )
        let cutout = CIImage(cvPixelBuffer: masked)
        guard let result = context.createCGImage(cutout, from: cutout.extent) else {
            throw AgentError.processFailed("피사체를 분리하지 못했습니다.")
        }
        return result
    }
}

// MARK: - 상주 러너

/// Owns the resident Python process.
///
/// The model costs 10~15 seconds to load, so it is kept warm between photos.
/// That is only acceptable because the process cannot outlive the app: the
/// runner exits on stdin EOF (which the kernel delivers even if the app is
/// force-quit), on the parent PID disappearing, and after five idle minutes.
/// `shutdownNow()` adds a fourth, explicit path for a clean quit.
///
/// Lock-based rather than an actor so `shutdownNow()` can be called
/// synchronously from `applicationWillTerminate`, where there is no time left
/// to await anything.
final class MattingDaemon: @unchecked Sendable {
    static let shared = MattingDaemon()

    static let executable = ProjectRoot.resolving(".venv-matting/bin/python")
    static let runnerScript = ProjectRoot.resolving("scripts/matting_runner.py")
    /// Idle seconds before the runner unloads the weights and exits by itself.
    static let idleTimeout = 300

    struct Reply: Sendable {
        let output: URL
        let milliseconds: Int
    }

    private struct Waiter {
        let continuation: CheckedContinuation<Reply, Error>
        let progress: @Sendable (String) -> Void
    }

    private let lock = NSLock()
    private var process: Process?
    private var standardInput: FileHandle?
    private var waiters: [Int: Waiter] = [:]
    /// Requests cancelled before their continuation was registered; without
    /// this a cancel that lands first would be silently ignored.
    private var cancelled: Set<Int> = []
    private var nextIdentifier = 1
    private var lineBuffer = Data()
    private var errorTail = ""

    private init() {}

    // MARK: 요청

    func cutout(
        source: URL,
        destination: URL,
        model: MattingModelChoice,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> Reply {
        guard let runnerValue = model.runnerValue else {
            throw AgentError.processFailed("이 모델은 Python 러너를 사용하지 않습니다.")
        }
        let identifier = reserveIdentifier()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request: Data
                do {
                    request = try Self.encode(
                        identifier: identifier, source: source, destination: destination, model: runnerValue
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
                    finish(identifier, with: .failure(AgentError.processFailed("누끼 러너에 요청을 전달하지 못했습니다.")))
                }
            }
        } onCancel: {
            abandon(identifier)
        }
    }

    /// Kept synchronous: `NSLock` may not be taken directly from an async
    /// context, and the continuation body below is the only place that needs it.
    private func reserveIdentifier() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let identifier = nextIdentifier
        nextIdentifier += 1
        return identifier
    }

    static func encode(identifier: Int, source: URL, destination: URL, model: String) throws -> Data {
        let payload: [String: Any] = [
            "id": identifier,
            "input": source.path,
            "output": destination.path,
            "model": model,
        ]
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private func abandon(_ identifier: Int) {
        lock.lock()
        guard let waiter = waiters.removeValue(forKey: identifier) else {
            // The cancel beat the registration; remember it so the request is
            // never actually sent.
            cancelled.insert(identifier)
            lock.unlock()
            return
        }
        lock.unlock()
        // The runner keeps working on this one photo and its answer is dropped.
        // Restarting instead would throw away the warm model, which is the whole
        // point of keeping the process alive.
        waiter.continuation.resume(throwing: CancellationError())
    }

    // MARK: 프로세스 수명

    /// Must be called with `lock` held.
    private func startLocked() throws {
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: Self.executable) else {
            throw AgentError.processFailed("누끼용 Python 환경을 찾지 못했습니다. 터미널에서 `scripts/setup-matting-env.sh`를 실행해 주세요.")
        }
        guard FileManager.default.fileExists(atPath: Self.runnerScript) else {
            throw AgentError.processFailed("누끼 실행 스크립트를 찾지 못했습니다: \(Self.runnerScript)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.executable)
        process.arguments = [
            Self.runnerScript,
            "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)",
            "--idle-timeout", "\(Self.idleTimeout)",
        ]
        var environment = ProcessInfo.processInfo.environment
        // Keep the weights next to the transcription models instead of the
        // default ~/.cache/huggingface, so uninstalling means one folder.
        environment["HF_HOME"] = NSString(string: "~/.cache/seoul-local-agent/hf").expandingTildeInPath
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        environment["TQDM_DISABLE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
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

    /// Closes the pipe, then terminates, then kills. Returns only once the
    /// runner is gone so `applicationWillTerminate` cannot race it.
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
            ? "누끼 러너가 예기치 않게 종료되었습니다."
            : "누끼 러너가 예기치 않게 종료되었습니다: \(reason)"
        pending.values.forEach { $0.continuation.resume(throwing: AgentError.processFailed(message)) }
    }

    private func recordError(_ text: String) {
        lock.lock()
        errorTail = String((errorTail + text).suffix(2_000))
        lock.unlock()
    }

    // MARK: 응답 해석

    private func ingest(_ data: Data) {
        lock.lock()
        lineBuffer.append(data)
        var lines: [Data] = []
        while let index = lineBuffer.firstIndex(of: 0x0A) {
            lines.append(lineBuffer[lineBuffer.startIndex ..< index])
            lineBuffer.removeSubrange(lineBuffer.startIndex ... index)
        }
        lock.unlock()
        lines.forEach(deliver)
    }

    private func deliver(_ line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        guard let identifier = object["id"] as? Int else { return }
        if object["event"] as? String == "progress" {
            lock.lock()
            let waiter = waiters[identifier]
            lock.unlock()
            waiter?.progress((object["detail"] as? String) ?? "")
            return
        }
        if object["ok"] as? Bool == true, let path = object["output"] as? String {
            let reply = Reply(output: URL(fileURLWithPath: path), milliseconds: (object["ms"] as? Int) ?? 0)
            finish(identifier, with: .success(reply))
        } else {
            let message = (object["error"] as? String) ?? "배경을 분리하지 못했습니다."
            finish(identifier, with: .failure(AgentError.processFailed(message)))
        }
    }

    private func finish(_ identifier: Int, with result: Result<Reply, Error>) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: identifier)
        lock.unlock()
        waiter?.continuation.resume(with: result)
    }
}

// MARK: - 대기열 항목

/// One dropped photo and whatever has happened to it so far. Several photos can
/// be dropped at once, so each carries its own state instead of the tab sharing
/// a single status line.
struct CutoutItem: Identifiable, Sendable {
    enum State: Sendable, Equatable {
        case waiting
        case working(String)
        case done(milliseconds: Int)
        case failed(String)
    }

    let id = UUID()
    let source: URL
    var output: URL?
    var state: State = .waiting
    /// Kept beside the result rather than burned into the file, so the cutout can
    /// be re-cropped or un-flipped without running the model again.
    var edit: PhotoEdit = .identity

    var isFinished: Bool { if case .done = state { true } else { false } }

    var statusText: String {
        switch state {
        case .waiting: "대기 중"
        case .working(let detail): detail.isEmpty ? "처리 중" : detail
        case .done(let milliseconds): String(format: "완료 · %.1f초", Double(milliseconds) / 1000)
        case .failed(let message): message
        }
    }
}

// MARK: - 서비스

/// The one entry point the app uses: hands a photo to whichever backend the
/// chosen model needs and returns the transparent PNG.
struct BackgroundRemovalService {
    static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "webp"]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Where a finished cutout lands before the user saves it somewhere real.
    static func workingDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SeoulLocalAgent-Cutout", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func outputURL(for source: URL, in directory: URL) -> URL {
        directory.appending(path: "\(source.deletingPathExtension().lastPathComponent)-누끼-\(UUID().uuidString.prefix(6)).png")
    }

    func removeBackground(
        from source: URL,
        model: MattingModelChoice,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        guard Self.isSupported(source) else {
            throw AgentError.processFailed("이미지 파일만 누끼를 딸 수 있습니다: \(source.lastPathComponent)")
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AgentError.processFailed("사진을 찾지 못했습니다: \(source.lastPathComponent)")
        }
        let destination = Self.outputURL(for: source, in: try Self.workingDirectory())
        guard model.usesPythonRunner else {
            return try Self.runVision(source: source, destination: destination, progress: progress)
        }
        let reply = try await MattingDaemon.shared.cutout(
            source: source, destination: destination, model: model, progress: progress
        )
        return reply.output
    }

    private static func runVision(
        source: URL,
        destination: URL,
        progress: @escaping @Sendable (String) -> Void
    ) throws -> URL {
        progress("macOS 내장 피사체 분리를 실행하고 있습니다.")
        guard let image = CutoutComposer.load(source) else {
            throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
        }
        let cutout = try VisionSubjectMatting.cutout(image)
        guard let data = CutoutComposer.pngData(from: cutout, background: nil) else {
            throw AgentError.processFailed("PNG로 변환하지 못했습니다.")
        }
        try data.write(to: destination)
        return destination
    }
}
