import Foundation
import AVFoundation

// MARK: - 출력 코덱

enum VideoOutputCodec: String, CaseIterable, Identifiable, Sendable {
    case h264
    case hevc
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: "MP4 (H.264)"
        case .hevc: "MP4 (HEVC)"
        case .original: "원본 코덱 유지"
        }
    }

    var detail: String {
        switch self {
        case .h264: "10년 된 기기에서도 재생됩니다. 확실하지 않을 때 고르면 되는 기본값입니다."
        case .hevc: "같은 화질에 용량이 절반쯤이지만 오래된 윈도우·안드로이드에서는 못 열 수 있습니다."
        case .original: "원본과 같은 코덱으로 다시 인코딩합니다."
        }
    }

    var fileExtension: String { "mp4" }

    var hardwareEncoder: String {
        switch self {
        case .hevc: "hevc_videotoolbox"
        case .h264, .original: "h264_videotoolbox"
        }
    }

    var softwareEncoder: String {
        switch self {
        case .hevc: "libx265"
        case .h264, .original: "libx264"
        }
    }

    /// QuickTime and iOS refuse HEVC in MP4 unless it is tagged this way.
    var needsHVC1Tag: Bool { self == .hevc }

    /// `원본 유지` follows whatever the source already is, so an HEVC recording
    /// does not silently get inflated back into H.264.
    static func resolved(_ choice: VideoOutputCodec, sourceIsHEVC: Bool) -> VideoOutputCodec {
        guard choice == .original else { return choice }
        return sourceIsHEVC ? .hevc : .h264
    }
}

// MARK: - ffmpeg 진행 상황

/// Parses the `key=value` stream that `-progress pipe:1` writes. Kept separate
/// from the process plumbing so the parsing can be tested on its own.
struct FFmpegProgress: Sendable, Equatable {
    var outSeconds: Double?
    var speed: Double?
    var finished = false

    /// Returns how much wall-clock time is left, when ffmpeg has told us enough
    /// to say. This is a measurement rather than an estimate, which is why the
    /// batch estimator prefers it over its own guess.
    func remaining(of duration: Double) -> Double? {
        guard let outSeconds, let speed, speed > 0.01, duration > 0 else { return nil }
        return max(0, (duration - outSeconds) / speed)
    }

    func fraction(of duration: Double) -> Double {
        guard let outSeconds, duration > 0 else { return 0 }
        return min(1, max(0, outSeconds / duration))
    }

    static func apply(_ line: String, to progress: inout FFmpegProgress) {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "out_time_us", "out_time_ms":
            // Despite the name ffmpeg reports both of these in microseconds.
            if let value = Double(parts[1]), value >= 0 { progress.outSeconds = value / 1_000_000 }
        case "speed":
            progress.speed = Double(parts[1].replacingOccurrences(of: "x", with: ""))
        case "progress":
            if parts[1] == "end" { progress.finished = true }
        default:
            break
        }
    }
}

// MARK: - 인코더 확인

/// Asks ffmpeg once which encoders it has. Apple Silicon always answers yes to
/// VideoToolbox, but a fallback keeps the feature working on an older machine
/// (and makes the honest 10x-versus-realtime difference visible in the status
/// line rather than as a mysterious wait).
final class VideoEncoderProbe: @unchecked Sendable {
    static let shared = VideoEncoderProbe()

    private let lock = NSLock()
    private var cachedEncoders: Set<String>?

    private init() {}

    func supports(_ encoder: String) async -> Bool {
        await available().contains(encoder)
    }

    /// Split from the async work below: `NSLock` may not be held across a
    /// suspension point, so every touch of the cache happens synchronously.
    private func cached() -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return cachedEncoders
    }

    private func store(_ encoders: Set<String>) {
        lock.lock()
        cachedEncoders = encoders
        lock.unlock()
    }

    private func available() async -> Set<String> {
        if let cached = cached() { return cached }
        var found: Set<String> = []
        if let ffmpeg = MediaImporter.ffmpegPath,
           let data = try? await ProcessRunner().run(ffmpeg, ["-hide_banner", "-encoders"], expectsStandardOutput: false) {
            let text = String(decoding: data, as: UTF8.self)
            for name in ["h264_videotoolbox", "hevc_videotoolbox", "libx264", "libx265"] where text.contains(name) {
                found.insert(name)
            }
        }
        store(found)
        return found
    }
}

// MARK: - 영상 압축

struct VideoCompressor: FileCompressor {
    /// What `AVAsset` tells us before anything is spawned.
    struct SourceSpec: Sendable {
        var duration: Double
        var width: Int
        var height: Int
        var hasAudio: Bool
        var isHEVC: Bool

        var longEdge: Int { max(width, height) }
    }

    // MARK: 미리 읽기

    func inspect(_ source: URL, request: CompressionRequest) async throws -> CompressionSourceInfo {
        guard MediaImporter.ffmpegPath != nil else {
            throw AgentError.processFailed("영상을 압축하려면 `brew install ffmpeg`가 필요합니다.")
        }
        let spec = try await Self.probe(source)
        let hardware = await VideoEncoderProbe.shared.supports(
            VideoOutputCodec.resolved(request.videoCodec, sourceIsHEVC: spec.isHEVC).hardwareEncoder
        )
        let speed = hardware ? CompressionProgressEstimator.videoSpeed : 1.0
        return CompressionSourceInfo(
            bytes: CompressionWorkspace.fileSize(of: source),
            detail: "\(spec.width)×\(spec.height) · \(CompressionFormat.duration(spec.duration))",
            estimatedSeconds: max(0.5, spec.duration / speed)
        )
    }

    static func probe(_ source: URL) async throws -> SourceSpec {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw AgentError.processFailed("영상 길이를 읽지 못했습니다: \(source.lastPathComponent)")
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AgentError.processFailed("영상 트랙을 찾지 못했습니다: \(source.lastPathComponent)")
        }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        // A phone clip records sideways and carries the rotation in its transform,
        // so the displayed size is what the user recognises.
        let displayed = natural.applying(transform)
        let width = Int(abs(displayed.width).rounded())
        let height = Int(abs(displayed.height).rounded())
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let formats = try await track.load(.formatDescriptions)
        let isHEVC = formats.contains { description in
            let type = CMFormatDescriptionGetMediaSubType(description)
            return type == kCMVideoCodecType_HEVC
        }
        return SourceSpec(duration: duration, width: width, height: height, hasAudio: hasAudio, isHEVC: isHEVC)
    }

    // MARK: 본 처리

    func compress(
        _ source: URL,
        to destination: URL,
        request: CompressionRequest,
        progress: @escaping @Sendable (Double, Double?) -> Void
    ) async throws -> CompressionOutcome {
        guard let ffmpeg = MediaImporter.ffmpegPath else {
            throw AgentError.processFailed("영상을 압축하려면 `brew install ffmpeg`가 필요합니다.")
        }
        let spec = try await Self.probe(source)
        let codec = VideoOutputCodec.resolved(request.videoCodec, sourceIsHEVC: spec.isHEVC)
        let hardware = await VideoEncoderProbe.shared.supports(codec.hardwareEncoder)
        let encoder = hardware ? codec.hardwareEncoder : codec.softwareEncoder
        let arguments = Self.arguments(
            input: source, output: destination, request: request, spec: spec, codec: codec, encoder: encoder
        )
        try await Self.run(ffmpeg, arguments, duration: spec.duration) { fraction, remaining in
            progress(0.05 + 0.9 * fraction, remaining)
        }
        let bytes = CompressionWorkspace.fileSize(of: destination)
        guard bytes > 0 else {
            throw AgentError.processFailed("영상을 압축하지 못했습니다: \(source.lastPathComponent)")
        }
        let cap = request.level.videoMaxPixel ?? spec.longEdge
        let scale = min(1, Double(cap) / Double(max(1, spec.longEdge)))
        let width = Int((Double(spec.width) * scale).rounded()) / 2 * 2
        let height = Int((Double(spec.height) * scale).rounded()) / 2 * 2
        return CompressionOutcome(
            output: destination,
            bytes: bytes,
            detail: "\(width)×\(height) · \(CompressionFormat.duration(spec.duration))",
            note: hardware ? nil : "하드웨어 인코더가 없어 느린 소프트웨어 인코딩을 썼습니다"
        )
    }

    // MARK: 인자 조립

    /// Pure, so the whole command line is covered by tests without spawning
    /// anything.
    static func arguments(
        input: URL,
        output: URL,
        request: CompressionRequest,
        spec: SourceSpec,
        codec: VideoOutputCodec,
        encoder: String
    ) -> [String] {
        var arguments = ["-hide_banner", "-nostdin", "-y", "-i", input.path]

        if let cap = request.level.videoMaxPixel, spec.longEdge > cap {
            // Fits the frame inside a cap×cap box without ever enlarging it, and
            // keeps both sides even because the encoders require it.
            arguments += ["-vf", "scale='min(\(cap),iw)':'min(\(cap),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"]
        }

        arguments += ["-c:v", encoder]
        let isHardware = encoder.hasSuffix("_videotoolbox")
        if request.isTargeting {
            // Unlike a photo, a video's size follows directly from its bitrate,
            // so the target needs no search at all — one division does it.
            let kbps = bitrateKbps(targetBytes: request.targetBytes, duration: spec.duration,
                                   audioKbps: spec.hasAudio ? request.level.audioBitrateKbps : 0)
            arguments += ["-b:v", "\(kbps)k", "-maxrate", "\(kbps * 3 / 2)k", "-bufsize", "\(kbps * 3)k"]
        } else if isHardware {
            arguments += ["-q:v", "\(request.level.videoQuality)"]
        } else {
            arguments += ["-crf", "\(softwareCRF(for: request.level))", "-preset", "medium"]
        }
        if codec.needsHVC1Tag { arguments += ["-tag:v", "hvc1"] }

        if spec.hasAudio {
            arguments += ["-c:a", "aac", "-b:a", "\(request.level.audioBitrateKbps)k"]
        } else {
            arguments += ["-an"]
        }

        arguments += ["-movflags", "+faststart", "-progress", "pipe:1", "-nostats", output.path]
        return arguments
    }

    /// Leaves 3% for the container so a "1 MB 이하" request is not blown by the
    /// muxing overhead.
    static func bitrateKbps(targetBytes: Int, duration: Double, audioKbps: Int) -> Int {
        guard duration > 0 else { return 1_000 }
        let totalKbps = Double(targetBytes) * 8 / duration / 1000 * 0.97
        return max(100, Int(totalKbps) - audioKbps)
    }

    static func softwareCRF(for level: CompressionLevel) -> Int {
        switch level {
        case .light: 21
        case .standard: 24
        case .strong: 28
        }
    }

    // MARK: 실행

    /// A short-lived child, but one that runs for minutes rather than
    /// milliseconds, so it gets the same treatment as every other helper: it is
    /// registered the moment it starts, torn down on cancellation, and reachable
    /// by the quit-time sweep in `applicationWillTerminate`.
    static func run(
        _ executable: String,
        _ arguments: [String],
        duration: Double,
        progress: @escaping @Sendable (Double, Double?) -> Void
    ) async throws {
        let handle = FFmpegHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = ProcessRunner.childEnvironment()
                let output = Pipe()
                let errors = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = output
                process.standardError = errors
                guard handle.adopt(process) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                output.fileHandleForReading.readabilityHandler = { reader in
                    let data = reader.availableData
                    if data.isEmpty {
                        reader.readabilityHandler = nil
                        return
                    }
                    handle.ingest(data) { state in
                        progress(state.fraction(of: duration), state.remaining(of: duration))
                    }
                }
                // ffmpeg says why it failed on stderr and nowhere else, and an
                // unread pipe would eventually stall the encode.
                errors.fileHandleForReading.readabilityHandler = { reader in
                    let data = reader.availableData
                    if data.isEmpty {
                        reader.readabilityHandler = nil
                        return
                    }
                    handle.recordError(String(decoding: data, as: UTF8.self))
                }
                process.terminationHandler = { finished in
                    ActiveProcessRegistry.shared.remove(finished)
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    guard handle.finish() else { return }
                    if finished.terminationStatus == 0 {
                        continuation.resume()
                    } else if handle.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: AgentError.processFailed(
                            "영상을 압축하지 못했습니다: \(handle.errorTail)"
                        ))
                    }
                }
                do {
                    try process.run()
                    ActiveProcessRegistry.shared.add(process)
                } catch {
                    guard handle.finish() else { return }
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

/// Holds the running ffmpeg and its partially-read output. Lock-based rather
/// than an actor because the pipe callbacks arrive on their own queues and the
/// cancellation handler is synchronous.
private final class FFmpegHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var buffer = Data()
    private var progress = FFmpegProgress()
    private var errorText = ""
    private var cancelled = false
    private var completed = false

    var wasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var errorTail: String {
        lock.lock()
        defer { lock.unlock() }
        return errorText
            .split(separator: "\n")
            .suffix(3)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `false` when the run was cancelled before the process even started.
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    /// Guarantees the continuation is resumed exactly once.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    func ingest(_ data: Data, report: (FFmpegProgress) -> Void) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex ..< index], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex ... index)
        }
        lines.forEach { FFmpegProgress.apply($0, to: &progress) }
        let snapshot = progress
        lock.unlock()
        guard !lines.isEmpty else { return }
        report(snapshot)
    }

    func recordError(_ text: String) {
        lock.lock()
        errorText = String((errorText + text).suffix(2_000))
        lock.unlock()
    }
}
