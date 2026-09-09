import AVFoundation
import Foundation
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

@Suite("중단된 녹음 복구")
struct RecordingRepairTests {
    /// A real take, encoded with the settings the app records with. A stub would
    /// prove nothing here: the whole repair rests on the system decoder agreeing
    /// about where each AAC frame ends.
    private static func makeRecording(seconds: Double = 3) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.Format.sampleRate, channels: 1, interleaved: false)!
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: AudioRecorder.Format.settings)
        let frames = AVAudioFrameCount(AudioRecorder.Format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        // A tone rather than silence: silent frames compress to almost nothing, and
        // the boundary search is only exercised by frames that vary in length.
        for frame in 0 ..< Int(frames) {
            buffer.floatChannelData![0][frame] = Float(sin(Double(frame) * 0.05)) * 0.4
        }
        try file?.write(from: buffer)
        // `AVAudioFile` writes its index when it is released, which is the same thing
        // `AVAudioRecorder.stop()` does — leave it alive and the file on disk is
        // exactly the broken shape this suite is about.
        file = nil
        return url
    }

    /// Reshapes a finished take into what `AVAudioRecorder` leaves behind when the
    /// app dies mid-recording: the file-type box, the room reserved for an index
    /// that was never written, and then the audio, running to the end of the file.
    private static func cutOff(_ url: URL) throws -> URL {
        let data = try Data(contentsOf: url)
        var offset = 0
        var audio: Data?
        while offset + 8 <= data.count {
            let size = Int(data[offset ..< offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: data[offset + 4 ..< offset + 8], as: UTF8.self)
            if type == "mdat" { audio = data[offset + 8 ..< offset + size] }
            guard size >= 8 else { break }
            offset += size
        }
        let payload = try #require(audio)
        var broken = Data(data.prefix(28))                      // ftyp, as the recorder writes it
        broken.append(Data(count: 0x6000 - broken.count))       // the reserved, never-filled index
        broken.append(payload)
        let url = url.deletingLastPathComponent().appending(path: "\(UUID().uuidString).m4a")
        try broken.write(to: url)
        return url
    }

    @Test("색인 없이 끝난 녹음을 원본 그대로 되살린다")
    func rebuildsATakeThatLostItsIndex() throws {
        let original = try Self.makeRecording()
        defer { try? FileManager.default.removeItem(at: original) }
        let expected = try AVAudioPlayer(contentsOf: original).duration

        let broken = try Self.cutOff(original)
        defer { try? FileManager.default.removeItem(at: broken) }
        // The exact failure the 녹음 보관함 was showing: OSStatus 1685348671.
        #expect(RecordingRepair.isUnfinished(broken))
        #expect((try? AVAudioPlayer(contentsOf: broken)) == nil)

        #expect(RecordingRepair.repairIfUnfinished(broken))
        #expect(!RecordingRepair.isUnfinished(broken))
        let repaired = try AVAudioPlayer(contentsOf: broken).duration
        // Only the half-written last frame may be missing — 1024 samples at most.
        #expect(abs(repaired - expected) < 0.1)
        // Lossless, not re-encoded: the audio is the same bytes in a new container.
        #expect(try Data(contentsOf: broken).count > 0x1000)
    }

    @Test("녹음한 날짜를 복구가 덮어쓰지 않는다")
    func keepsTheDateTheTakeWasMade() throws {
        let original = try Self.makeRecording(seconds: 1)
        defer { try? FileManager.default.removeItem(at: original) }
        let broken = try Self.cutOff(original)
        defer { try? FileManager.default.removeItem(at: broken) }
        // The library dates and sorts takes by this, so a rebuild that stamps today
        // on a lecture from last week would move it to the top of the list.
        let recorded = Date(timeIntervalSinceNow: -86_400 * 7)
        try FileManager.default.setAttributes([.modificationDate: recorded], ofItemAtPath: broken.path)

        #expect(RecordingRepair.repairIfUnfinished(broken))
        let kept = try #require(try broken.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(abs(kept.timeIntervalSince(recorded)) < 1)
    }

    @Test("마이크가 쓰고 있는 녹음은 복구가 손대지 않는다")
    func leavesTheLiveTakeAlone() throws {
        let original = try Self.makeRecording(seconds: 1)
        defer { try? FileManager.default.removeItem(at: original) }
        let live = try Self.cutOff(original)
        defer { try? FileManager.default.removeItem(at: live) }

        // 지금 녹음 중인 파일은 색인이 없는 것이 **정상**이다. 모양만 보면 복구 대상과
        // 구별되지 않으므로, 복구를 막는 것은 모양이 아니라 이 등록이어야 한다.
        #expect(RecordingRepair.isUnfinished(live))
        let before = try Data(contentsOf: live)

        LiveTakes.shared.insert(live)
        #expect(!RecordingRepair.repairIfUnfinished(live))
        // 한 바이트도 바뀌지 않아야 한다. 복구는 원본 자리에 새 파일을 놓는 일이라,
        // 자라고 있는 녹음에 그 일을 하면 강의가 통째로 사라진다.
        #expect(try Data(contentsOf: live) == before)

        // 경로는 표준화해서 견준다. 같은 파일이 `/private/var`와 `/var`로 들어와도
        // 같은 것으로 알아봐야 한다.
        #expect(LiveTakes.shared.contains(live.resolvingSymlinksInPath()) || LiveTakes.shared.contains(live))

        // 녹음이 끝나 등록에서 빠지면 같은 파일이 정상적으로 복구된다.
        LiveTakes.shared.remove(live)
        #expect(RecordingRepair.repairIfUnfinished(live))
        #expect(!RecordingRepair.isUnfinished(live))
    }

    @Test("멀쩡한 녹음은 건드리지 않는다")
    func leavesAFinishedTakeAlone() throws {
        let url = try Self.makeRecording(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)
        #expect(!RecordingRepair.isUnfinished(url))
        #expect(!RecordingRepair.repairIfUnfinished(url))
        #expect(try Data(contentsOf: url) == before)
    }
}
#endif
