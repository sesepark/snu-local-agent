import Foundation
import AVFoundation
import Accelerate

// MARK: - 읽기

/// Streams a recording out of any container macOS can open, converted to
/// interleaved 32-bit float on the way.
///
/// Streaming rather than "load the file into an array": a three-hour lecture at
/// 48 kHz is two gigabytes of float samples per channel, and both this tool and
/// the transcription tab routinely see recordings that long.
final class AudioStreamReader {
    let sampleRate: Double
    let channelCount: Int
    let duration: Double
    /// Total frames the reader will produce, or `nil` when the container does
    /// not say. Used for the progress fraction, never for correctness.
    let frameCount: Int?

    private let reader: AVAssetReader
    private let output: AVAssetReaderOutput
    private var finished = false

    /// `targetSampleRate` and `forceMono` ask the decoder to resample and downmix
    /// on the way out, which is far cheaper than doing it afterwards.
    init(url: URL, targetSampleRate: Double? = nil, forceMono: Bool = false) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AgentError.processFailed("소리가 들어 있지 않은 파일입니다: \(url.lastPathComponent)")
        }
        let descriptions = try await track.load(.formatDescriptions)
        let basic = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sourceRate = basic.map { $0.mSampleRate } ?? 44_100
        let sourceChannels = basic.map { Int($0.mChannelsPerFrame) } ?? 1

        sampleRate = targetSampleRate ?? sourceRate
        // Capped at stereo on purpose: anything wider needs an explicit channel
        // layout in the output settings, and a lecture recording is never wider.
        channelCount = forceMono ? 1 : min(2, max(1, sourceChannels))
        duration = try await asset.load(.duration).seconds
        frameCount = duration.isFinite && duration > 0 ? Int(duration * sampleRate) : nil

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        reader = try AVAssetReader(asset: asset)
        // The mix output, not a plain track output: this is the one that downmixes
        // a stereo source to mono rather than silently keeping only one side.
        let mix = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output = mix
        guard reader.canAdd(mix) else {
            throw AgentError.processFailed("이 형식의 소리를 읽지 못했습니다: \(url.lastPathComponent)")
        }
        reader.add(mix)
        guard reader.startReading() else {
            throw AgentError.processFailed(reader.error?.localizedDescription ?? "소리를 읽지 못했습니다.")
        }
    }

    /// The next block of interleaved samples, or `nil` once the file is done.
    func next() throws -> [Float]? {
        guard !finished else { return nil }
        while true {
            guard let buffer = output.copyNextSampleBuffer() else {
                finished = true
                if reader.status == .failed {
                    throw AgentError.processFailed(reader.error?.localizedDescription ?? "소리를 읽는 중 오류가 발생했습니다.")
                }
                return nil
            }
            defer { CMSampleBufferInvalidate(buffer) }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer, length >= MemoryLayout<Float>.size
            else { continue }
            let count = length / MemoryLayout<Float>.size
            return pointer.withMemoryRebound(to: Float.self, capacity: count) {
                Array(UnsafeBufferPointer(start: $0, count: count))
            }
        }
    }

    func cancel() { reader.cancelReading() }
}

// MARK: - 쓰기

enum AudioOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a
    case wav

    var id: String { rawValue }

    var title: String {
        switch self {
        case .m4a: "M4A (AAC)"
        case .wav: "WAV (무압축)"
        }
    }

    var detail: String {
        switch self {
        case .m4a: "어디서나 열리고 용량이 작습니다. 다시 들으려고 보관할 때 고르세요."
        case .wav: "손실이 전혀 없지만 용량이 큽니다. 다른 프로그램에서 더 편집할 때 고르세요."
        }
    }

    var fileExtension: String { rawValue }
}

/// Writes interleaved float samples out to a real audio file.
///
/// Wraps `AVAudioFile` rather than `AVAssetWriter` because everything this app
/// produces is a single audio track and `AVAudioFile` does the format conversion
/// on the way in, so callers only ever deal in float.
final class AudioStreamWriter {
    private let file: AVAudioFile
    private let format: AVAudioFormat
    private let channelCount: Int

    /// `lossless` writes a 32-bit float WAV whatever `outputFormat` says. The
    /// stages between decoding and the final encode use it, because quantising
    /// to 16-bit and *then* applying the loudness gain would amplify the
    /// quantisation noise along with the recording.
    init(url: URL, sampleRate: Double, channelCount: Int, format outputFormat: AudioOutputFormat, bitrate: Int = 128_000, lossless: Bool = false) throws {
        self.channelCount = channelCount
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        switch outputFormat {
        case _ where lossless:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case .m4a:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            // Named only above 32 kHz: AAC's applicable bitrates narrow sharply
            // at 16 kHz and asking for one outside that set fails the encoder
            // outright rather than being rounded to the nearest allowed value.
            if sampleRate >= 32_000 { settings[AVEncoderBitRateKey] = bitrate }
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount), interleaved: true
        ) else { throw AgentError.processFailed("소리 형식을 만들지 못했습니다.") }
        self.format = format
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    }

    /// The lossless float WAV the stages in between hand to each other.
    static func intermediate(url: URL, sampleRate: Double, channelCount: Int) throws -> AudioStreamWriter {
        try AudioStreamWriter(url: url, sampleRate: sampleRate, channelCount: channelCount, format: .wav, lossless: true)
    }

    func write(_ samples: [Float], gain: Float = 1) throws {
        guard !samples.isEmpty else { return }
        let frames = samples.count / channelCount
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let used = frames * channelCount
        samples.withUnsafeBufferPointer { source in
            if gain == 1 {
                destination.update(from: source.baseAddress!, count: used)
            } else {
                var scale = gain
                vDSP_vsmul(source.baseAddress!, 1, &scale, destination, 1, vDSP_Length(used))
            }
        }
        try file.write(from: buffer)
    }
}

// MARK: - 잡음 바닥 측정

/// Measures the noise floor as "the median of the quietest moment in each
/// second", which is what the ear reads as hiss.
///
/// A plain RMS over the whole file would mostly measure how much speech there
/// is, so a recording with more talking in it would look noisier. Taking the
/// quietest window of every second and then the median across seconds ignores
/// both the speech and the occasional door slam.
struct NoiseFloorMeter {
    private var blockMinimums: [Float] = []
    private var currentMinimum = Float.greatestFiniteMagnitude
    private var samplesInBlock = 0
    private var samplesPerBlock: Int
    private var windowSum: Float = 0
    private var windowCount = 0
    private let windowSize: Int

    private(set) var peak: Float = 0
    private var totalSquares: Double = 0
    private var totalCount: Int = 0

    init(sampleRate: Double) {
        samplesPerBlock = max(1, Int(sampleRate))
        windowSize = max(1, Int(sampleRate / 50))
    }

    mutating func add(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var maximum: Float = 0
        vDSP_maxmgv(samples, 1, &maximum, vDSP_Length(samples.count))
        peak = max(peak, maximum)
        var squares: Float = 0
        vDSP_svesq(samples, 1, &squares, vDSP_Length(samples.count))
        totalSquares += Double(squares)
        totalCount += samples.count

        for sample in samples {
            windowSum += sample * sample
            windowCount += 1
            if windowCount == windowSize {
                currentMinimum = min(currentMinimum, (windowSum / Float(windowSize)).squareRoot())
                windowSum = 0
                windowCount = 0
            }
            samplesInBlock += 1
            if samplesInBlock >= samplesPerBlock {
                if currentMinimum < .greatestFiniteMagnitude { blockMinimums.append(currentMinimum) }
                currentMinimum = .greatestFiniteMagnitude
                samplesInBlock = 0
            }
        }
    }

    var rms: Float {
        guard totalCount > 0 else { return 0 }
        return Float((totalSquares / Double(totalCount)).squareRoot())
    }

    /// `nil` for a clip too short to have a single full block.
    var noiseFloor: Float? {
        var values = blockMinimums
        if currentMinimum < .greatestFiniteMagnitude { values.append(currentMinimum) }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[values.count / 2]
    }
}

// MARK: - 스펙트럴 게이트

enum AudioCleanupStrength: String, CaseIterable, Identifiable, Sendable {
    case light
    case standard
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "약하게"
        case .standard: "표준"
        case .strong: "강하게"
        }
    }

    var detail: String {
        switch self {
        case .light: "목소리를 최대한 그대로 두고 일정한 잡음만 덜어냅니다."
        case .standard: "에어컨·팬·웅웅거림에 맞춘 기본값입니다."
        case .strong: "잡음을 가장 많이 줄이지만 조용한 말끝이 함께 깎일 수 있습니다."
        }
    }

    /// How far above the estimated noise a bin has to be before it survives.
    var overSubtraction: Float {
        switch self {
        case .light: 1.2
        case .standard: 1.8
        case .strong: 2.6
        }
    }

    /// How far a gated bin is allowed to fall. Silencing it completely sounds
    /// worse than leaving a little behind — the residue turns into the warbling
    /// that makes cheap noise removal recognisable.
    var floorDecibels: Float {
        switch self {
        case .light: -12
        case .standard: -20
        case .strong: -30
        }
    }
}

/// Removes steady background noise without a model, a download or a network.
///
/// The noise estimate comes from minimum statistics: the quietest power seen in
/// each frequency bin over the last second and a half is, in a real recording,
/// the noise in that bin. That needs one pass and a fixed amount of memory, and
/// it tracks noise that changes — a projector fan starting up halfway through a
/// lecture — which a profile taken from the first few seconds cannot.
///
/// Everything here is per-channel; the worker runs one of these per channel.
final class SpectralGate {
    static let frameSize = 1024
    static let hop = 256
    /// Samples of algorithmic delay: the caller drops this many leading samples
    /// so the result lines up with the source.
    static var latency: Int { frameSize - hop }

    private let bins = frameSize / 2
    private let setup: FFTSetup
    private let log2n: vDSP_Length
    private let window: [Float]
    private let overSubtraction: Float
    private let floorGain: Float
    private let highPassBin: Int
    private let scale: Float

    private let historyLength: Int
    private var history: [Float]
    private var historyCursor = 0
    private var historyFilled = 0
    private var smoothedPower: [Float]

    private var pending: [Float] = []
    private var pendingStart = 0
    private var outputTail: [Float]
    private var weightTail: [Float]
    private var real: [Float]
    private var imag: [Float]

    init?(sampleRate: Double, strength: AudioCleanupStrength) {
        log2n = vDSP_Length(log2(Double(Self.frameSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        var hann = [Float](repeating: 0, count: Self.frameSize)
        vDSP_hann_window(&hann, vDSP_Length(Self.frameSize), Int32(vDSP_HANN_DENORM))
        window = hann
        overSubtraction = strength.overSubtraction
        floorGain = pow(10, strength.floorDecibels / 20)
        // 80 Hz: below this a lecture recording holds nothing but handling noise,
        // desk thumps and mains hum.
        highPassBin = max(1, Int((80 * Double(Self.frameSize) / sampleRate).rounded(.up)))
        scale = 1 / (2 * Float(Self.frameSize))
        historyLength = max(8, Int((1.5 * sampleRate / Double(Self.hop)).rounded()))
        history = [Float](repeating: .greatestFiniteMagnitude, count: bins * historyLength)
        smoothedPower = [Float](repeating: 0, count: bins)
        outputTail = [Float](repeating: 0, count: Self.frameSize)
        weightTail = [Float](repeating: 0, count: Self.frameSize)
        real = [Float](repeating: 0, count: bins)
        imag = [Float](repeating: 0, count: bins)
        // Leading zeros so the very first real sample is already fully overlapped;
        // without them the file opens with a short swell.
        pending = [Float](repeating: 0, count: Self.latency)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Accepts any number of samples and returns however many finished ones that
    /// made available — always a multiple of `hop`.
    func push(_ samples: [Float]) -> [Float] {
        pending.append(contentsOf: samples)
        return drain()
    }

    /// Flushes the tail by feeding in enough silence to push the last real
    /// samples through the overlap.
    func finish() -> [Float] {
        pending.append(contentsOf: [Float](repeating: 0, count: Self.frameSize))
        return drain()
    }

    private func drain() -> [Float] {
        var emitted: [Float] = []
        while pending.count - pendingStart >= Self.frameSize {
            processFrame(at: pendingStart)
            emitted.append(contentsOf: normalisedHop())
            shiftTail()
            pendingStart += Self.hop
        }
        // Compacted rather than removed on every frame: `removeFirst` is linear in
        // what is left, and a single push can hold a second of audio.
        if pendingStart > 1 << 16 {
            pending.removeFirst(pendingStart)
            pendingStart = 0
        }
        return emitted
    }

    private func processFrame(at offset: Int) {
        var frame = [Float](repeating: 0, count: Self.frameSize)
        pending.withUnsafeBufferPointer { source in
            vDSP_vmul(source.baseAddress! + offset, 1, window, 1, &frame, 1, vDSP_Length(Self.frameSize))
        }

        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                frame.withUnsafeBufferPointer { source in
                    source.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(bins))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        var gains = [Float](repeating: 1, count: bins)
        // Bin 0 carries DC in `real` and Nyquist in `imag`; both are inside the
        // high-pass region or inaudible, so one gain covers them.
        for bin in 0 ..< bins {
            let power = real[bin] * real[bin] + imag[bin] * imag[bin]
            // Smoothed before the minimum is taken, so a single loud frame cannot
            // push the noise estimate up for the next second and a half.
            smoothedPower[bin] = 0.7 * smoothedPower[bin] + 0.3 * power
            history[bin * historyLength + historyCursor] = smoothedPower[bin]

            var minimum = Float.greatestFiniteMagnitude
            let base = bin * historyLength
            let span = max(1, min(historyLength, historyFilled + 1))
            for index in 0 ..< span { minimum = min(minimum, history[base + index]) }
            // Minimum statistics under-estimates the true noise power because a
            // minimum is a biased estimator; 1.5 is the usual correction.
            let noise = minimum * 1.5

            if bin < highPassBin {
                gains[bin] = floorGain
            } else if power <= 1e-20 {
                gains[bin] = floorGain
            } else {
                let residual = max(0, power - overSubtraction * noise)
                gains[bin] = max(floorGain, min(1, (residual / power).squareRoot()))
            }
        }
        historyCursor = (historyCursor + 1) % historyLength
        historyFilled = min(historyLength, historyFilled + 1)

        // Three-tap smoothing across frequency: an unsmoothed mask leaves isolated
        // surviving bins that ring as tones — the "musical noise" of naive
        // spectral subtraction.
        var smoothed = gains
        for bin in 1 ..< bins - 1 {
            smoothed[bin] = (gains[bin - 1] + gains[bin] + gains[bin + 1]) / 3
        }

        for bin in 0 ..< bins {
            real[bin] *= smoothed[bin]
            imag[bin] *= smoothed[bin]
        }

        var restored = [Float](repeating: 0, count: Self.frameSize)
        real.withUnsafeMutableBufferPointer { realPointer in
            imag.withUnsafeMutableBufferPointer { imagPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                restored.withUnsafeMutableBufferPointer { destination in
                    destination.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { complex in
                        vDSP_ztoc(&split, 1, complex, 2, vDSP_Length(bins))
                    }
                }
            }
        }
        var factor = scale
        vDSP_vsmul(restored, 1, &factor, &restored, 1, vDSP_Length(Self.frameSize))
        // Windowed again on the way out, which is what makes the overlap-add
        // seamless; the running weight sum below undoes the double windowing.
        vDSP_vmul(restored, 1, window, 1, &restored, 1, vDSP_Length(Self.frameSize))

        vDSP_vadd(outputTail, 1, restored, 1, &outputTail, 1, vDSP_Length(Self.frameSize))
        var squares = [Float](repeating: 0, count: Self.frameSize)
        vDSP_vmul(window, 1, window, 1, &squares, 1, vDSP_Length(Self.frameSize))
        vDSP_vadd(weightTail, 1, squares, 1, &weightTail, 1, vDSP_Length(Self.frameSize))
    }

    private func normalisedHop() -> [Float] {
        var result = [Float](repeating: 0, count: Self.hop)
        for index in 0 ..< Self.hop {
            let weight = weightTail[index]
            result[index] = weight > 1e-6 ? outputTail[index] / weight : 0
        }
        return result
    }

    private func shiftTail() {
        outputTail.removeFirst(Self.hop)
        outputTail.append(contentsOf: [Float](repeating: 0, count: Self.hop))
        weightTail.removeFirst(Self.hop)
        weightTail.append(contentsOf: [Float](repeating: 0, count: Self.hop))
    }
}
