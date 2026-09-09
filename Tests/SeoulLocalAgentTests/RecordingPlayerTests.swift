import Foundation
import AVFoundation
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

@Suite("녹음 재생 상태")
struct RecordingPlayerTests {
    /// A real audio file, because the player's whole job is holding `AVAudioPlayer`
    /// state; a stub would test nothing that broke.
    private static func makeSilentWAV(seconds: Double = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
        let (rate, channels, bits) = (8_000, 1, 16)
        let frames = Int(Double(rate) * seconds)
        let dataBytes = frames * channels * bits / 8
        var file = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) } }
        file.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataBytes)); file.append(contentsOf: Array("WAVE".utf8))
        file.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(channels))
        append(UInt32(rate)); append(UInt32(rate * channels * bits / 8)); append(UInt16(channels * bits / 8)); append(UInt16(bits))
        file.append(contentsOf: Array("data".utf8)); append(UInt32(dataBytes))
        file.append(Data(count: dataBytes))
        try file.write(to: url)
        return url
    }

    private static func item(_ url: URL, id: String = "test") -> RecordingItem {
        RecordingItem(id: id, source: .file, title: "테스트 녹음", url: url, date: .now, duration: 2, isLocallyAvailable: true)
    }

    @Test("재생이 끝나면 버튼 상태가 재생으로 돌아온다")
    @MainActor func playbackStateResetsWhenTheTakeEnds() throws {
        let url = try Self.makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let recording = Self.item(url)
        let player = RecordingPlayer()

        player.play(recording)
        #expect(player.isPlaying(recording))
        // `AVAudioPlayer` reports the end of a take only here. Nothing listened to
        // it before, which is what left the 중지 button on screen for a recording
        // that had already finished.
        player.audioPlayerDidFinishPlaying(try AVAudioPlayer(contentsOf: url), successfully: true)
        #expect(!player.isPlaying(recording))
        #expect(player.position(of: recording) == 0)
        #expect(player.errorMessage == nil)
    }

    @Test("다른 녹음을 고르면 앞의 녹음 재생이 멈춘다")
    @MainActor func selectingAnotherRecordingStopsPlayback() throws {
        let url = try Self.makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = Self.item(url, id: "first")
        let second = Self.item(url, id: "second")
        let player = RecordingPlayer()

        player.play(first)
        #expect(player.isPlaying(first))
        // The button belongs to whichever take is selected, so an unrelated
        // recording must never inherit the running one's state.
        #expect(!player.isPlaying(second))
        player.stopUnless(second)
        #expect(!player.isPlaying(first))
        #expect(!player.isCurrent(first))
    }

    @Test("재생 전에도 재생바를 끌어 위치를 옮길 수 있다")
    @MainActor func scrubbingWorksBeforePlaybackStarts() throws {
        let url = try Self.makeSilentWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let recording = Self.item(url)
        let player = RecordingPlayer()

        player.seek(recording, to: 1)
        #expect(!player.isPlaying(recording))
        #expect(abs(player.position(of: recording) - 1) < 0.05)
        // Past the end the take would otherwise keep running; the last moment is
        // the furthest the scrubber may land.
        player.seek(recording, to: 99)
        #expect(player.position(of: recording) < player.duration(of: recording))
        player.skip(recording, by: -99)
        #expect(player.position(of: recording) == 0)
        player.stop()
        #expect(player.position(of: recording) == 0)
        #expect(!player.isCurrent(recording))
    }

    @Test("iCloud에만 있는 녹음은 재생하지 않고 안내한다")
    @MainActor func iCloudOnlyRecordingReportsInsteadOfPlaying() {
        let recording = RecordingItem(
            id: "cloud", source: .voiceMemos, title: "아이클라우드 녹음",
            url: URL(fileURLWithPath: "/nonexistent/cloud.m4a"), date: .now, duration: 60, isLocallyAvailable: false
        )
        let player = RecordingPlayer()
        player.play(recording)
        #expect(!player.isPlaying(recording))
        #expect(player.errorMessage?.contains("iCloud") == true)
    }

    @Test("재생 시간 표시는 한 시간이 넘어야 시간 자리를 쓴다")
    func playbackTimeLabelWidensOnlyWhenNeeded() {
        #expect(TimeInterval(0).playbackTimeLabel == "0:00")
        #expect(TimeInterval(9).playbackTimeLabel == "0:09")
        #expect(TimeInterval(125).playbackTimeLabel == "2:05")
        // 132:05 for a two-hour lecture is unreadable, so hours appear here.
        #expect(TimeInterval(7_925).playbackTimeLabel == "2:12:05")
    }
}
#endif
