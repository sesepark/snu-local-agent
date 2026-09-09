import Foundation
import AVFoundation

// MARK: - 방식

/// The two ways this app can clean up a recording.
///
/// The fast one is real signal processing rather than a cut-down model: it runs
/// on every recording with no download, no Python and no network, which makes it
/// the right default for a tool whose whole job is to be reached for without
/// thinking. The precise one is worth its cost when the noise is not steady —
/// people talking in the row behind, a corridor door, traffic.
enum AudioCleanupMethod: String, CaseIterable, Identifiable, Sendable {
    case gate
    case model

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gate: "빠름 (내장)"
        case .model: "정밀 (AI 모델)"
        }
    }

    var detail: String {
        switch self {
        case .gate: "다운로드 없이 즉시 처리합니다. 에어컨·팬·웅웅거림 같은 일정한 잡음에 가장 잘 듣습니다. 실측 한 시간 녹음에 10초 안팎."
        case .model: "SepFormer 음성 분리 모델이 사람 목소리만 남깁니다. 웅성거림처럼 변하는 잡음까지 잡지만 16 kHz 모노로 나오고, 실측 한 시간 녹음에 13분쯤 걸립니다."
        }
    }

    var usesRunner: Bool { self == .model }
}

/// Everything the screen has configured, frozen when the run starts.
struct AudioCleanupRequest: Sendable {
    var method: AudioCleanupMethod = .gate
    var strength: AudioCleanupStrength = .standard
    var normalisesLoudness = true
    var format: AudioOutputFormat = .m4a
}

// MARK: - 작업자

struct AudioCleanupWorker: BatchToolWorker {
    let request: AudioCleanupRequest

    /// Video is accepted and yields the cleaned soundtrack as an audio file:
    /// a lecture recorded on a phone arrives as a .mov far more often than as
    /// a .m4a, and refusing it would send the user through 형식 변환 first.
    var accepts: Set<String> { MediaImporter.audioExtensions.union(MediaImporter.videoExtensions) }

    /// The model path goes through one resident process, so two files at once
    /// would only queue inside it. The gate is pure CPU and scales.
    var concurrency: Int { request.method == .model ? 1 : 2 }

    var saveSuffix: String { "다듬음" }

    func outputExtension(for source: URL) -> String { request.format.fileExtension }

    func inspect(_ source: URL) async throws -> ToolJobInfo {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw AgentError.processFailed("길이를 읽지 못했습니다: \(source.lastPathComponent)")
        }
        // Seeds only; `ToolETA` recalibrates from the first file that finishes.
        let rate = request.method == .model ? 4.0 : 80.0
        return ToolJobInfo(
            detail: CompressionFormat.duration(duration),
            estimatedSeconds: duration / rate + 1
        )
    }

    func run(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ToolOutcome {
        let scratch = try ToolWorkspace.directory("AudioCleanup")
        let stage = scratch.appending(path: "작업-\(UUID().uuidString.prefix(6)).wav")
        defer { try? FileManager.default.removeItem(at: stage) }

        let cleaned: CleanedStage
        switch request.method {
        case .gate:
            cleaned = try await gate(source, to: stage, progress: progress)
        case .model:
            cleaned = try await enhance(source, to: stage, scratch: scratch, progress: progress)
        }

        try Task.checkCancellation()
        let after = try await Self.measure(stage)
        let gain = request.normalisesLoudness ? Self.loudnessGain(rms: after.rms, peak: after.peak) : 1
        progress(0.92)
        try await Self.encode(stage, to: destination, format: request.format, gain: gain, sampleRate: cleaned.sampleRate, channelCount: cleaned.channelCount)
        progress(1)

        var parts: [String] = []
        if let before = cleaned.inputNoiseFloor, let now = after.noiseFloor, before > 0, now > 0 {
            let drop = 20 * log10(before / now)
            parts.append(drop >= 0.5 ? String(format: "잡음 −%.1f dB", drop) : "잡음 변화 거의 없음")
        } else {
            parts.append("정리했습니다")
        }
        if gain != 1 {
            let decibels = 20 * log10(gain)
            // A real minus sign, to match the 잡음 figure beside it. `%+.1f`
            // writes an ASCII hyphen, and the two sitting together in one line
            // read as a typo.
            parts.append(String(format: "음량 %@%.1f dB", decibels < 0 ? "−" : "+", abs(decibels)))
        }

        let channels = cleaned.channelCount == 1 ? "모노" : "스테레오"
        return ToolOutcome(
            output: destination,
            detail: "\(Int(cleaned.sampleRate / 1000)) kHz \(channels) · \(CompressionFormat.duration(cleaned.duration))",
            headline: parts.joined(separator: " · "),
            note: request.method == .model && cleaned.sampleRate <= 16_000
                ? "정밀 모드는 16 kHz 모노로 나옵니다. 음악이 섞인 녹음이라면 빠름을 쓰세요."
                : nil
        )
    }

    // MARK: 빠름 · 스펙트럴 게이트

    private struct CleanedStage {
        let sampleRate: Double
        let channelCount: Int
        let duration: Double
        let inputNoiseFloor: Float?
    }

    /// Decode, gate and write in one streaming pass, so a three-hour lecture
    /// never has more than a second of audio in memory at a time.
    private func gate(_ source: URL, to stage: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> CleanedStage {
        let reader = try await AudioStreamReader(url: source)
        let channels = reader.channelCount
        guard let gates = (0 ..< channels).map({ _ in SpectralGate(sampleRate: reader.sampleRate, strength: request.strength) })
            .allSatisfyNonNil()
        else { throw AgentError.processFailed("신호 처리를 준비하지 못했습니다.") }

        let writer = try AudioStreamWriter.intermediate(url: stage, sampleRate: reader.sampleRate, channelCount: channels)
        var meter = NoiseFloorMeter(sampleRate: reader.sampleRate)
        var skipped = 0
        var written = 0
        var read = 0
        let expected = reader.frameCount

        while let block = try reader.next() {
            try Task.checkCancellation()
            meter.add(block)
            read += block.count / channels
            let gated = Self.applyPerChannel(block, channels: channels, gates: gates)
            try Self.append(gated, to: writer, channels: channels, skipped: &skipped, written: &written, limit: expected)
            if let expected, expected > 0 { progress(min(0.9, 0.9 * Double(read) / Double(expected))) }
        }
        let tail = Self.flushPerChannel(channels: channels, gates: gates)
        try Self.append(tail, to: writer, channels: channels, skipped: &skipped, written: &written, limit: expected)

        return CleanedStage(
            sampleRate: reader.sampleRate,
            channelCount: channels,
            duration: reader.duration,
            inputNoiseFloor: meter.noiseFloor
        )
    }

    /// Splits interleaved samples into channels, gates each one, and interleaves
    /// the result again. Each channel needs its own gate because its noise is its
    /// own — a lapel mic on one side and room tone on the other are not the same
    /// signal.
    private static func applyPerChannel(_ block: [Float], channels: Int, gates: [SpectralGate]) -> [Float] {
        if channels == 1 { return gates[0].push(block) }
        let frames = block.count / channels
        var outputs: [[Float]] = []
        for channel in 0 ..< channels {
            var lane = [Float](repeating: 0, count: frames)
            for frame in 0 ..< frames { lane[frame] = block[frame * channels + channel] }
            outputs.append(gates[channel].push(lane))
        }
        return interleave(outputs, channels: channels)
    }

    private static func flushPerChannel(channels: Int, gates: [SpectralGate]) -> [Float] {
        let outputs = gates.map { $0.finish() }
        return channels == 1 ? outputs[0] : interleave(outputs, channels: channels)
    }

    private static func interleave(_ lanes: [[Float]], channels: Int) -> [Float] {
        let frames = lanes.map(\.count).min() ?? 0
        var result = [Float](repeating: 0, count: frames * channels)
        for channel in 0 ..< channels {
            for frame in 0 ..< frames { result[frame * channels + channel] = lanes[channel][frame] }
        }
        return result
    }

    /// Drops the gate's algorithmic delay from the head and the padding from the
    /// tail, so the cleaned file is sample-for-sample the same length as the
    /// original rather than a fifth of a second longer.
    private static func append(
        _ samples: [Float], to writer: AudioStreamWriter, channels: Int,
        skipped: inout Int, written: inout Int, limit: Int?
    ) throws {
        guard !samples.isEmpty else { return }
        var block = samples
        if skipped < SpectralGate.latency {
            let drop = min(block.count / channels, SpectralGate.latency - skipped)
            skipped += drop
            block.removeFirst(drop * channels)
            guard !block.isEmpty else { return }
        }
        if let limit, written + block.count / channels > limit {
            let keep = max(0, limit - written)
            block = Array(block.prefix(keep * channels))
            guard !block.isEmpty else { return }
        }
        written += block.count / channels
        try writer.write(block)
    }

    // MARK: 정밀 · 모델

    private func enhance(
        _ source: URL, to stage: URL, scratch: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> CleanedStage {
        // The model is 16 kHz mono; decoding straight to that is both what it
        // wants and the smallest file to hand across the pipe.
        let reader = try await AudioStreamReader(url: source, targetSampleRate: 16_000, forceMono: true)
        let input = scratch.appending(path: "입력-\(UUID().uuidString.prefix(6)).wav")
        defer { try? FileManager.default.removeItem(at: input) }
        let writer = try AudioStreamWriter.intermediate(url: input, sampleRate: 16_000, channelCount: 1)
        var meter = NoiseFloorMeter(sampleRate: 16_000)
        var read = 0
        while let block = try reader.next() {
            try Task.checkCancellation()
            meter.add(block)
            read += block.count
            try writer.write(block)
            if let expected = reader.frameCount, expected > 0 {
                progress(min(0.1, 0.1 * Double(read) / Double(expected)))
            }
        }

        _ = try await MediaDaemon.shared.send(
            task: "enhance", source: input, destination: stage,
            payload: ["chunkSeconds": 30]
        ) { _, fraction in
            if let fraction { progress(0.1 + 0.8 * fraction) }
        }
        guard FileManager.default.fileExists(atPath: stage.path) else {
            throw AgentError.processFailed("정리한 소리 파일을 만들지 못했습니다.")
        }
        return CleanedStage(sampleRate: 16_000, channelCount: 1, duration: reader.duration, inputNoiseFloor: meter.noiseFloor)
    }

    // MARK: 마무리

    private struct Measurement {
        let rms: Float
        let peak: Float
        let noiseFloor: Float?
    }

    private static func measure(_ url: URL) async throws -> Measurement {
        let reader = try await AudioStreamReader(url: url)
        var meter = NoiseFloorMeter(sampleRate: reader.sampleRate)
        while let block = try reader.next() {
            try Task.checkCancellation()
            meter.add(block)
        }
        return Measurement(rms: meter.rms, peak: meter.peak, noiseFloor: meter.noiseFloor)
    }

    /// Brings the recording to a comfortable listening level without clipping.
    ///
    /// Deliberately RMS rather than true LUFS: the K-weighted filter and gating
    /// of BS.1770 would be a lot of code for a difference nobody would hear on a
    /// lecture recording, and overstating what this does would be worse than
    /// doing the simple thing and saying so.
    static func loudnessGain(rms: Float, peak: Float, target: Float = 0.1) -> Float {
        guard rms > 1e-6 else { return 1 }
        var gain = target / rms
        if peak > 0 { gain = min(gain, 0.97 / peak) }
        return min(8, max(0.2, gain))
    }

    private static func encode(
        _ stage: URL, to destination: URL, format: AudioOutputFormat,
        gain: Float, sampleRate: Double, channelCount: Int
    ) async throws {
        let reader = try await AudioStreamReader(url: stage)
        let bitrate = sampleRate >= 32_000 ? 128_000 * max(1, channelCount) : 64_000 * max(1, channelCount)
        let writer = try AudioStreamWriter(
            url: destination, sampleRate: reader.sampleRate,
            channelCount: reader.channelCount, format: format, bitrate: bitrate
        )
        while let block = try reader.next() {
            try Task.checkCancellation()
            try writer.write(block, gain: gain)
        }
    }
}

private extension Array {
    /// `[T?] -> [T]?`, so a failed FFT setup on any channel fails the whole file
    /// rather than half-processing it.
    func allSatisfyNonNil<Wrapped>() -> [Wrapped]? where Element == Wrapped? {
        var result: [Wrapped] = []
        result.reserveCapacity(count)
        for element in self {
            guard let element else { return nil }
            result.append(element)
        }
        return result
    }
}
