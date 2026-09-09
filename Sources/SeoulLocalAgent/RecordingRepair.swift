import AVFoundation
import AudioToolbox
import Foundation

/// Rebuilds a take that the recorder never got to finish writing.
///
/// `AVAudioRecorder` writes an MPEG-4 file back to front. The audio goes down as
/// it arrives, but the index that says where each frame begins — the `moov` atom —
/// is written only when `stop()` runs. Quit, force-quit or crash while a take is
/// running and the file is left as a header, a stretch of reserved zeros, and a
/// wall of AAC frames with nothing pointing into it. Every player then refuses it:
/// `AVAudioPlayer` throws OSStatus 1685348671 — `'dta?'`, *not a valid file* — and
/// the library, which measures a take by opening it, shows the recording as 0초.
///
/// Only the index is missing; the audio is all there. AAC frames carry no length
/// field, but a frame is exactly as long as the decoder needs to reach its end
/// marker: give the decoder one byte less and it produces nothing. So the shortest
/// prefix that still decodes *is* the frame, and a binary search finds it in about
/// ten attempts. Walking a file that way recovers every boundary, after which the
/// frames go into a fresh container untouched — the same bytes, no second encode,
/// no quality lost.
enum RecordingRepair {
    /// A file is only tried once per launch. A take that cannot be rebuilt would
    /// otherwise be re-scanned on every refresh of the library, which is minutes of
    /// decoding for a recording that is not going to come back.
    private static let attempted = Attempted()

    /// Rebuilds `url` in place when it is a take that was cut off mid-recording.
    /// Cheap for a healthy file — it walks the box headers and stops — so the
    /// library can call it for everything it lists.
    ///
    /// Returns true when a take was actually rebuilt, so the caller can say so.
    @discardableResult
    static func repairIfUnfinished(_ url: URL) -> Bool {
        // 마이크가 지금 쓰고 있는 파일은 손대지 않는다. **이 검사가 여기 있는 이유가
        // 따로 있다.** 부르는 쪽에도 같은 뜻의 가드가 있지만 그것은 폴더를 훑기 전에 찍은
        // 사진이고, 사진과 훑기 사이에 시작된 녹음은 거기에 없다. 덮어쓰기 직전인 이
        // 자리에서 읽으면 그 틈이 사라진다 — 아래 `repair`는 원본 자리에 새 파일을 놓으므로,
        // 자라고 있는 녹음에 그 일을 하면 강의가 통째로 사라진다.
        guard !LiveTakes.shared.contains(url) else { return false }
        guard isUnfinished(url), attempted.claim(url) else { return false }
        do {
            try repair(url)
            return true
        } catch {
            // Nothing was written over: `repair` only replaces the original once it
            // has a whole file to put there. A take that cannot be rebuilt keeps
            // showing the player's error, which is the honest outcome.
            return false
        }
    }

    /// True for a recording whose index was never written. Reads only box headers.
    static func isUnfinished(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "m4a",
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 8 else { return false }
        var offset: UInt64 = 0
        var sawFileType = false
        while offset + 8 <= end {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 8), header.count == 8 else { return false }
            let type = header.suffix(4)
            // A run of zeros — the room `AVAudioRecorder` reserves for the index —
            // reads as a box of size 0 and type "\0\0\0\0", which is where the walk
            // of an unfinished take always ends.
            guard type.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return sawFileType }
            var size = UInt64(header.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            if size == 1 {
                guard let large = try? handle.read(upToCount: 8), large.count == 8 else { return sawFileType }
                size = large.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }
            switch String(decoding: type, as: UTF8.self) {
            case "ftyp": sawFileType = true
            case "moov": return false // the index is there: the file is whole
            default: break
            }
            guard size >= 8 else { return sawFileType }
            offset += size
        }
        return sawFileType
    }

    private static func repair(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let start = try audioStart(in: data)
        let scanner = FrameScanner()
        let lengths = scanner.frameLengths(in: data, from: start)
        let recovered = lengths.reduce(0, +)
        // A take is one unbroken run of frames, so a scan either reaches the end or
        // has lost sync — and a rebuild from a lost-sync scan would throw away real
        // audio. Only the last frame may be half-written, which is why one frame's
        // worth of slack is allowed and no more.
        guard !lengths.isEmpty, data.count - start - recovered < FrameScanner.maximumFrameBytes else {
            throw AgentError.processFailed("녹음을 복구하지 못했습니다.")
        }

        // Beside the original, so the replace is a rename on the same volume, and
        // under an extension the library does not list — a rebuild interrupted
        // halfway must not leave something that looks like another recording.
        let rebuilt = url.appendingPathExtension("rebuilding")
        defer { try? FileManager.default.removeItem(at: rebuilt) }
        try write(data, from: start, lengths: lengths, to: rebuilt)
        // Opening it is the only proof that matters: this is the exact call that was
        // failing, made against the new file before the old one is given up.
        guard let player = try? AVAudioPlayer(contentsOf: rebuilt), player.duration > 0 else {
            throw AgentError.processFailed("복구한 녹음을 열지 못했습니다.")
        }

        // The library dates and sorts takes by modification date, so the rebuilt file
        // has to keep the moment the recording actually ended.
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try FileManager.default.replaceItemAt(url, withItemAt: rebuilt)
        if let modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    /// Where the first AAC frame sits.
    ///
    /// `AVAudioRecorder` leaves a fixed gap after the file-type box for the index it
    /// means to write later, so in practice the audio starts at a known offset. That
    /// is only a convention of the framework, though, so it is checked by decoding
    /// rather than trusted, and a short search around the end of the reserved zeros
    /// covers a version of macOS that reserves a different amount.
    private static func audioStart(in data: Data) throws -> Int {
        let reserved = 0x6000
        // Clamped, because the size in a header of a file that was cut off is not
        // something to trust with an index into it.
        let afterHeader = min(boxSize(of: data, at: 0) ?? 28, data.count)
        let zeroEnd = data[afterHeader...].firstIndex(where: { $0 != 0 }) ?? afterHeader
        // A frame may legitimately begin with a zero byte, so the true start can sit
        // a little before the first byte that is not zero.
        let nearby = Array((max(afterHeader, zeroEnd - 16) ... zeroEnd).reversed())
        for candidate in ([reserved] + nearby) where candidate < data.count {
            if reaches(end: data, from: candidate) { return candidate }
        }
        throw AgentError.processFailed("녹음에서 오디오가 시작하는 자리를 찾지 못했습니다.")
    }

    /// Whether frames read from `start` line up. A wrong start desynchronises within
    /// a frame or two, so either running out of file or getting this far without a
    /// break is enough to settle it — and a short take has to be able to prove itself
    /// by reaching its own end.
    private static func reaches(end data: Data, from start: Int) -> Bool {
        let probe = 64
        let lengths = FrameScanner().frameLengths(in: data, from: start, limit: probe)
        guard !lengths.isEmpty else { return false }
        return lengths.count == probe || data.count - start - lengths.reduce(0, +) < FrameScanner.maximumFrameBytes
    }

    private static func boxSize(of data: Data, at offset: Int) -> Int? {
        guard offset + 8 <= data.count else { return nil }
        let size = Int(data[offset ..< offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        return size >= 8 ? offset + size : nil
    }

    private static func write(_ data: Data, from start: Int, lengths: [Int], to url: URL) throws {
        var format = AudioRecorder.Format.streamDescription
        var file: AudioFileID?
        try check(AudioFileCreateWithURL(url as CFURL, kAudioFileM4AType, &format, .eraseFile, &file))
        guard let file else { throw AgentError.processFailed("녹음 파일을 새로 만들지 못했습니다.") }
        defer { AudioFileClose(file) }
        // Without the decoder configuration the container claims the wrong channel
        // count and nothing on the system will open the result. The encoder that
        // would have written this take is asked for it, so it always matches.
        var cookie = try magicCookie()
        try check(AudioFileSetProperty(file, kAudioFilePropertyMagicCookieData, UInt32(cookie.count), &cookie))

        try data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: start)
            var offset = 0
            var packet: Int64 = 0
            // Written in batches so neither the descriptions nor the byte count ever
            // has to be sized for the whole of a two-hour lecture at once.
            for batch in stride(from: 0, to: lengths.count, by: 4_096) {
                let slice = lengths[batch ..< min(batch + 4_096, lengths.count)]
                var descriptions: [AudioStreamPacketDescription] = []
                var bytes = 0
                descriptions.reserveCapacity(slice.count)
                for length in slice {
                    descriptions.append(AudioStreamPacketDescription(mStartOffset: Int64(bytes), mVariableFramesInPacket: 0, mDataByteSize: UInt32(length)))
                    bytes += length
                }
                var count = UInt32(slice.count)
                try check(AudioFileWritePackets(file, false, UInt32(bytes), descriptions, packet, &count, base.advanced(by: offset)))
                offset += bytes
                packet += Int64(count)
            }
        }
    }

    /// The `esds` blob an AAC encoder set up the way this app records would produce.
    private static func magicCookie() throws -> [UInt8] {
        var source = AudioRecorder.Format.pcmStreamDescription
        var destination = AudioRecorder.Format.streamDescription
        var converter: AudioConverterRef?
        try check(AudioConverterNew(&source, &destination, &converter))
        guard let converter else { throw AgentError.processFailed("오디오 형식을 준비하지 못했습니다.") }
        defer { AudioConverterDispose(converter) }
        var rate = AudioRecorder.Format.bitRate
        try check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate))
        var size: UInt32 = 0
        try check(AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &size, nil))
        var cookie = [UInt8](repeating: 0, count: Int(size))
        try check(AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &size, &cookie))
        return cookie
    }

    private static func check(_ status: OSStatus) throws {
        guard status != noErr else { return }
        throw AgentError.processFailed("오디오 파일을 다루지 못했습니다 (\(status)).")
    }
}

/// Finds AAC frame boundaries by asking the system decoder where each frame ends.
private final class FrameScanner {
    /// An AAC-LC frame cannot exceed 6144 bits per channel, so nothing this app
    /// records is longer than this — and the decoder rejects a packet buffer much
    /// larger than a frame, so the bound has to be real rather than generous.
    static let maximumFrameBytes = 768

    private let converter: AVAudioConverter
    private let packet: AVAudioCompressedBuffer
    private let decoded: AVAudioPCMBuffer
    private let capacity = FrameScanner.maximumFrameBytes * Int(AudioRecorder.Format.channels)

    init() {
        var description = AudioRecorder.Format.streamDescription
        let input = AVAudioFormat(streamDescription: &description)!
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.Format.sampleRate, channels: AVAudioChannelCount(AudioRecorder.Format.channels), interleaved: false)!
        converter = AVAudioConverter(from: input, to: output)!
        packet = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: capacity)
        decoded = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(AudioRecorder.Format.framesPerPacket) * 2)!
    }

    /// The byte length of every complete frame from `start` onwards. Stops at the
    /// first thing that will not decode, which for a cut-off take is its half
    /// written last frame.
    func frameLengths(in data: Data, from start: Int, limit: Int = .max) -> [Int] {
        var lengths: [Int] = []
        var position = start
        while position < data.count, lengths.count < limit {
            let window = min(capacity, data.count - position)
            data.copyBytes(to: UnsafeMutableRawBufferPointer(start: packet.data, count: window), from: position ..< position + window)
            guard decodes(window) else { break }
            // The shortest prefix that still decodes is the frame itself: one byte
            // less and the decoder runs out of bits before the end marker.
            var low = 1, high = window
            while low < high {
                let middle = (low + high) / 2
                if decodes(middle) { high = middle } else { low = middle + 1 }
            }
            lengths.append(low)
            position += low
        }
        return lengths
    }

    /// Whether the first `length` bytes now in `packet` decode as a whole frame.
    private func decodes(_ length: Int) -> Bool {
        packet.byteLength = UInt32(length)
        packet.packetCount = 1
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(length))
        decoded.frameLength = 0
        var error: NSError?
        // The converter asks for input on the calling thread, but the block is typed
        // `@Sendable`; the buffer and the flag never leave this call.
        nonisolated(unsafe) let buffer = packet
        nonisolated(unsafe) var served = false
        converter.reset()
        // The status is `.inputRanDry` even on success — the block has only one
        // packet to give — so what was decoded is the answer, not the status.
        _ = converter.convert(to: decoded, error: &error) { _, status in
            if served { status.pointee = .noDataNow; return nil }
            served = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && decoded.frameLength > 0
    }
}

/// Paths already tried this launch.
private final class Attempted: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func claim(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.insert(url.standardizedFileURL.path).inserted
    }
}
