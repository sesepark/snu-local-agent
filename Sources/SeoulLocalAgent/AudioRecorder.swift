import AVFoundation
import AudioToolbox
import AppKit
import IOKit

/// 지금 마이크가 쓰고 있는 파일들.
///
/// `RecordingRepair`는 끊긴 녹음을 **새 파일로 다시 써서 원본 자리에 덮는다.** 마이크가
/// 아직 쓰고 있는 파일에 그 일을 하면 녹음은 통째로 사라진다. 보관함은 그동안 살아 있는
/// 녹음의 경로를 메인 액터에서 찍어 아래로 내려 주는 방식으로 막고 있었는데, 그것은
/// **한 순간의 사진**이다. 사진을 찍은 뒤 폴더를 훑기 전에 녹음이 시작되면 그 파일은
/// 사진에 없고, 복구 루프는 자라고 있는 파일을 붙잡는다. 여기 있는 값은 덮어쓰기 **직전에**
/// 읽히므로 그 틈이 없다.
///
/// 자물쇠 하나짜리 집합인 이유는 읽는 쪽이 메인 액터가 아니기 때문이다 — 보관함은
/// `Task.detached`에서 폴더를 훑는다.
final class LiveTakes: @unchecked Sendable {
    static let shared = LiveTakes()

    private let lock = NSLock()
    private var paths: Set<String> = []

    func insert(_ url: URL) {
        lock.lock()
        paths.insert(url.standardizedFileURL.path)
        lock.unlock()
    }

    func remove(_ url: URL) {
        lock.lock()
        paths.remove(url.standardizedFileURL.path)
        lock.unlock()
    }

    func contains(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.contains(url.standardizedFileURL.path)
    }
}

/// 노트북 뚜껑. IOKit이 `IOPMrootDomain`에 그대로 적어 두는 값이다.
///
/// 뚜껑을 닫으면 대개 `NSWorkspace.willSleepNotification`이 먼저 오지만, **언제나 그런
/// 것은 아니다.** 외부 화면과 전원이 붙어 있는 클램셸에서는 닫아도 시스템이 잠들지 않아서
/// 그 알림이 오지 않는다. 뚜껑을 닫는 것과 잠드는 것은 다른 사건이므로 둘 다 본다.
///
/// 뚜껑이 없는 Mac(mini·Studio)에는 이 값이 아예 없고, 그때는 `false`가 정답이다.
enum LidState {
    static var isClosed: Bool {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return false }
        defer { IOObjectRelease(entry) }
        guard let value = IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return false }
        if let flag = value as? Bool { return flag }
        return (value as? NSNumber)?.boolValue ?? false
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    /// One description of what a take is made of, because `RecordingRepair` has to
    /// decode a cut-off recording with exactly the format that wrote it. Two copies
    /// of these numbers would eventually disagree, and a rebuilt file would come out
    /// at the wrong speed or the wrong channel count with nothing to flag it.
    enum Format {
        static let sampleRate = 16_000.0
        static let channels: UInt32 = 1
        static let bitRate: UInt32 = 48_000
        static let framesPerPacket: UInt32 = 1_024

        static var settings: [String: Any] {
            [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: Int(channels),
             AVEncoderBitRateKey: Int(bitRate), AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        }

        static var streamDescription: AudioStreamBasicDescription {
            AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                        mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        }

        /// What the encoder would have been fed, which is what an encoder has to be
        /// built from before it will hand over the decoder configuration.
        static var pcmStreamDescription: AudioStreamBasicDescription {
            AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                        mBytesPerPacket: 2 * channels, mFramesPerPacket: 1, mBytesPerFrame: 2 * channels,
                                        mChannelsPerFrame: channels, mBitsPerChannel: 16, mReserved: 0)
        }
    }

    /// 사람이 `녹음 중지`를 누르지 않았는데 녹음이 끝나는 경우들.
    ///
    /// 넷 다 **여기까지는 저장된다.** 파일을 닫는 것과 녹음을 버리는 것은 다른 일이고,
    /// 이 갈래들은 전부 닫기만 한다.
    enum StopReason: Equatable {
        /// 노트북 뚜껑을 닫았다.
        case lidClosed
        /// Mac이 잠들기 직전이다. 뚜껑이 아니라 시간이나 메뉴로 잠드는 경우.
        case systemSleep
        /// 로그아웃·재시동·시스템 종료.
        case shuttingDown
        /// 마이크가 프레임을 더 내놓지 않는다. 장치가 뽑혔거나 입력이 바뀌었다.
        case inputStopped

        var message: String {
            switch self {
            case .lidClosed: "노트북을 닫아서 녹음을 끝내고 보관함에 넣었습니다."
            case .systemSleep: "Mac이 잠들기 전에 녹음을 끝내고 보관함에 넣었습니다."
            case .shuttingDown: "시스템이 꺼지기 전에 녹음을 끝내고 보관함에 넣었습니다."
            case .inputStopped: "마이크에서 소리가 더 들어오지 않아 녹음을 끝냈습니다. 여기까지는 보관함에 저장되어 있습니다 — 입력 장치를 확인해 주세요."
            }
        }
    }

    /// 마이크가 이만큼 조용히 멈춰 있으면 장치가 사라진 것으로 본다.
    ///
    /// `AVAudioRecorder`는 입력 장치가 없어져도 `isRecording`을 내리지 않는 경우가 있다.
    /// 그때 화면은 시계만 올라가는 채로 "녹음 중"이라고 말하고, 강의가 끝나서야 아무것도
    /// 없다는 것을 알게 된다. 8초는 잠깐의 끊김으로는 넘지 않고 장치가 사라진 것은
    /// 확실히 넘는 값이다.
    private static let stallTimeout: TimeInterval = 8

    /// `applicationWillTerminate` is outside the view tree, and a take that is not
    /// closed there is a file no player can open. Same reason as
    /// `MusicPlayerModel.current`.
    private(set) static weak var current: AudioRecorder?

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    /// 사람이 누르지 않았는데 녹음이 끝났을 때 부른다. 보관함에 넣고 왜 끝났는지 적는 것은
    /// 화면을 쥐고 있는 쪽의 일이라 여기서는 알리기만 한다.
    var onUnattendedStop: ((URL?, String) -> Void)?

    /// The banner is dismissible, so the view needs a way to clear a message it
    /// has finished showing without the setter becoming public.
    func dismissError() { errorMessage = nil }
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    /// 지금 쓰고 있는 파일. `recorder`를 비운 뒤에도 누구에게 알릴지 알아야 한다.
    private var activeURL: URL?
    /// 마지막으로 **길어진** 녹음 길이와 그 시각. 둘의 차이가 멈춤을 재는 자다.
    private var lastProgress: TimeInterval = 0
    private var lastProgressAt = Date.distantPast
    /// 뚜껑은 1초에 한 번만 본다. 시계는 0.25초마다 도는데 IORegistry를 그만큼 읽을 이유가 없다.
    private var lidTicks = 0

    override init() {
        super.init()
        Self.current = self
        observeSystemPower()
    }

    /// 잠들기 전과 꺼지기 전. **관찰만 붙이고 떼지 않는다** — 이 객체는 앱과 수명이 같고,
    /// 떼는 코드는 메인 액터 밖의 `deinit`에서만 돌 수 있어 얻는 것 없이 위험만 는다.
    private func observeSystemPower() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(.systemSleep) }
        }
        center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end(.shuttingDown) }
        }
    }

    func start() async -> Bool {
        errorMessage = nil
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            errorMessage = "마이크 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 이 앱을 허용해 주세요."
            return false
        }
        // 뚜껑이 닫힌 채로 시작할 수는 없다. 시작하자마자 아래의 감시가 끝내 버리므로,
        // 0초짜리 파일을 남기는 대신 시작 자체를 하지 않고 이유를 적는다.
        guard !LidState.isClosed else {
            errorMessage = "노트북이 닫혀 있습니다. 열고 다시 시작해 주세요 — 닫힌 채로는 녹음이 곧바로 끝납니다."
            return false
        }
        do {
            let directory = try Self.recordingsDirectory()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy-MM-dd HHmmss"
            let url = directory.appending(path: "녹음 \(formatter.string(from: Date())).m4a")
            let recorder = try AVAudioRecorder(url: url, settings: Format.settings)
            recorder.delegate = self
            // 복구 루프보다 **먼저** 등록한다. 이 줄과 `record()` 사이에 보관함이 폴더를
            // 훑더라도 파일은 아직 없거나 이미 보호받는 상태다.
            LiveTakes.shared.insert(url)
            guard recorder.record() else {
                LiveTakes.shared.remove(url)
                throw AgentError.processFailed("마이크 녹음을 시작하지 못했습니다.")
            }
            self.recorder = recorder
            activeURL = url
            startedAt = Date()
            elapsed = 0
            lastProgress = 0
            lastProgressAt = Date()
            lidTicks = 0
            isRecording = true
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            // .common, not the default mode: the counter has to keep ticking while
            // the user scrolls or drags in the window.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    /// 0.25초마다. 시계를 고치고, 뚜껑과 마이크를 살핀다.
    ///
    /// 시계가 `Date()`가 아니라 `recorder.currentTime`을 읽는 것은 우연이 아니다. 벽시계는
    /// 마이크가 멈춰도 계속 올라가므로, 그것을 적어 두면 화면이 **녹음되지 않은 시간을
    /// 녹음된 것처럼** 말한다. 파일에 실제로 들어간 길이를 읽으면 시계가 사실을 말하고,
    /// 같은 값이 멈춤을 재는 자가 되어 준다.
    private func tick() {
        guard isRecording, let recorder else { return }
        guard recorder.isRecording else { end(.inputStopped); return }

        let recorded = recorder.currentTime
        if recorded > lastProgress + 0.01 {
            lastProgress = recorded
            lastProgressAt = Date()
        }
        elapsed = recorded

        lidTicks += 1
        if lidTicks >= 4 {
            lidTicks = 0
            if LidState.isClosed { end(.lidClosed); return }
        }

        if Date().timeIntervalSince(lastProgressAt) > Self.stallTimeout { end(.inputStopped) }
    }

    /// The file still being written. Transcription reads a recording whole, so
    /// nothing may queue the take that is currently growing.
    var currentFileURL: URL? { isRecording ? recorder?.url : nil }

    func stop() -> URL? {
        guard let recorder else { return nil }
        recorder.stop()
        let url = recorder.url
        finish()
        return url
    }

    /// Closes the take that is running, synchronously, so quitting mid-recording
    /// leaves a file that plays instead of one that no player will open.
    ///
    /// `AVAudioRecorder` writes its index only on `stop()`. Nothing used to call
    /// it at quit, so a ⌘Q during a lecture left the whole recording behind an
    /// OSStatus error — the audio was on disk, but unreachable.
    func stopNow() {
        guard isRecording else { return }
        recorder?.stop()
        finish()
    }

    /// 사람이 누르지 않았는데 끝내야 할 때. 파일은 닫아서 남기고, 왜 끝났는지 알린다.
    private func end(_ reason: StopReason) {
        guard isRecording else { return }
        let url = activeURL
        recorder?.stop()
        finish()
        onUnattendedStop?(url, reason.message)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        errorMessage = error?.localizedDescription ?? "녹음 파일을 저장하지 못했습니다."
        finish()
    }

    /// 녹음이 스스로 끝났다. **이 자리가 비어 있던 것이 문제였다.**
    ///
    /// 입력 장치가 사라지면 `AVAudioRecorder`는 여기로 `successfully: false`를 들고
    /// 온다. 아무도 받지 않으면 `isRecording`은 계속 참이고, 화면은 아무것도 녹음되지
    /// 않는 동안 "녹음 중"이라고 말한다. 사람이 누른 `stop()`으로 끝난 경우에도 불리므로,
    /// 이미 정리가 끝난 뒤라면 `end`가 알아서 조용히 지나간다.
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard isRecording else { return }
        if !flag { errorMessage = "녹음을 정상적으로 마치지 못했습니다. 저장된 부분까지는 보관함에서 확인할 수 있습니다." }
        end(.inputStopped)
    }

    private func finish() {
        if let activeURL { LiveTakes.shared.remove(activeURL) }
        activeURL = nil
        timer?.invalidate(); timer = nil; recorder = nil; startedAt = nil; isRecording = false
    }

    nonisolated static func recordingsDirectory() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "SeoulLocalAgent/Recordings", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
