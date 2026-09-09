import AVFoundation
import Foundation

/// Playback for the 녹음 보관함.
///
/// `AVAudioPlayer` announces the end of a take only through its delegate, so a
/// view that flips a flag when playback starts and never hears about the end
/// keeps showing the stop button for a recording that already finished. This
/// object owns the flag, the delegate callback and the progress timer together,
/// which is also what lets the scrubber follow the take and seek inside it.
@MainActor
final class RecordingPlayer: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    /// The take that is loaded, playing or paused. Views compare it with the
    /// selected recording so the button never reports another take's state.
    @Published private(set) var recordingID: RecordingItem.ID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func isCurrent(_ recording: RecordingItem) -> Bool { recordingID == recording.id }

    func isPlaying(_ recording: RecordingItem) -> Bool { isPlaying && isCurrent(recording) }

    /// The position to draw for `recording`: a take that is not loaded sits at the
    /// start rather than inheriting the previous take's position.
    func position(of recording: RecordingItem) -> TimeInterval { isCurrent(recording) ? currentTime : 0 }

    func duration(of recording: RecordingItem) -> TimeInterval {
        let loaded = isCurrent(recording) ? duration : 0
        // The library duration comes from the Voice Memos database and can be
        // missing or stale; the decoded file wins once it is open.
        return loaded > 0 ? loaded : max(recording.duration, 0)
    }

    func toggle(_ recording: RecordingItem) {
        isPlaying(recording) ? pause() : play(recording)
    }

    func play(_ recording: RecordingItem) {
        errorMessage = nil
        // Resume in place: a take that was paused, or scrubbed before it ever
        // played, continues from where the scrubber is rather than the start.
        guard prepare(recording), let player else { return }
        guard player.play() else {
            fail("녹음을 재생하지 못했습니다.")
            return
        }
        isPlaying = true
        startTimer()
    }

    /// Opens the file without starting it, so the scrubber can move inside a take
    /// that has not been played yet. Returns false only when it cannot be opened.
    @discardableResult
    func prepare(_ recording: RecordingItem) -> Bool {
        if isCurrent(recording), player != nil { return true }
        guard recording.isLocallyAvailable else {
            errorMessage = "이 녹음은 iCloud에만 있습니다. 음성 메모 앱에서 먼저 재생해 다운로드해 주세요."
            return false
        }
        stop()
        do {
            let opened = try AVAudioPlayer(contentsOf: recording.url)
            opened.delegate = self
            opened.prepareToPlay()
            player = opened
            recordingID = recording.id
            duration = opened.duration
            currentTime = 0
            return true
        } catch {
            // The OSStatus behind this is `'dta?'` — 1685348671 — which said nothing
            // to anyone reading it. A take that ends without its index has a cause and
            // a cure worth naming instead.
            fail(RecordingRepair.isUnfinished(recording.url)
                 ? "녹음이 저장되지 않은 채로 끝났습니다. 보관함을 새로 고치면 복구를 시도합니다."
                 : "녹음 파일이 손상되어 재생할 수 없습니다.")
            return false
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        if let player { currentTime = player.currentTime }
    }

    /// Unloads the take entirely. Used when the selection moves elsewhere or the
    /// file is deleted, so playback never outlives what the window is showing.
    func stop() {
        player?.stop()
        player = nil
        stopTimer()
        recordingID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func stop(ifPlaying recording: RecordingItem) {
        if isCurrent(recording) { stop() }
    }

    func stopUnless(_ recording: RecordingItem?) {
        guard let recordingID else { return }
        if recording?.id != recordingID { stop() }
    }

    func seek(_ recording: RecordingItem, to time: TimeInterval) {
        guard prepare(recording), let player else { return }
        // `AVAudioPlayer` keeps playing past a `currentTime` set at or beyond the
        // end, so the last moment of the take is the furthest seek target.
        let clamped = min(max(0, time), max(0, player.duration - 0.05))
        player.currentTime = clamped
        currentTime = clamped
    }

    func skip(_ recording: RecordingItem, by seconds: TimeInterval) {
        seek(recording, to: position(of: recording) + seconds)
    }

    private func fail(_ message: String) {
        stop()
        errorMessage = message
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        // .common, not the default mode: the scrubber has to keep moving while
        // the user scrolls the transcript or drags the window.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        // The delegate covers the ordinary end of a take; this catches a player
        // that stopped for any other reason, which is exactly the case that used
        // to strand the button in its playing state.
        if !player.isPlaying { finishPlayback() }
    }

    private func finishPlayback() {
        isPlaying = false
        stopTimer()
        player?.currentTime = 0
        currentTime = 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finishPlayback()
        if !flag { errorMessage = "녹음을 끝까지 재생하지 못했습니다." }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        fail("녹음을 재생하지 못했습니다: \(error?.localizedDescription ?? "오디오를 해독하지 못했습니다.")")
    }
}

extension TimeInterval {
    /// `mm:ss`, widening to `h:mm:ss` only for takes that need it, so an hour-long
    /// lecture does not show up as `132:05`.
    var playbackTimeLabel: String {
        guard isFinite, self > 0 else { return "0:00" }
        let total = Int(self.rounded())
        let (hours, minutes, seconds) = (total / 3_600, (total % 3_600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
