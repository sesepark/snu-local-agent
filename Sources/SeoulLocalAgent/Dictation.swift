import Foundation
import AVFoundation
import AppKit
import Carbon.HIToolbox

/// A small fixed set of shortcuts, chosen so they do not collide with macOS or
/// with common app shortcuts. A full key recorder is more UI than this needs.
enum DictationShortcut: String, CaseIterable, Identifiable, Codable {
    case disabled
    case controlOptionCommandD
    case controlOptionCommandSpace
    case controlOptionCommandR
    case functionF13

    var id: String { rawValue }

    var title: String {
        switch self {
        case .disabled: "사용 안 함"
        case .controlOptionCommandD: "⌃⌥⌘D"
        case .controlOptionCommandSpace: "⌃⌥⌘Space"
        case .controlOptionCommandR: "⌃⌥⌘R"
        case .functionF13: "F13"
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .disabled: nil
        case .controlOptionCommandD: UInt32(kVK_ANSI_D)
        case .controlOptionCommandSpace: UInt32(kVK_Space)
        case .controlOptionCommandR: UInt32(kVK_ANSI_R)
        case .functionF13: UInt32(kVK_F13)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .disabled, .functionF13: 0
        case .controlOptionCommandD, .controlOptionCommandSpace, .controlOptionCommandR:
            UInt32(controlKey | optionKey | cmdKey)
        }
    }
}

private final class HotKeyAction: @unchecked Sendable {
    static let shared = HotKeyAction()
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func set(_ action: (@Sendable () -> Void)?) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func fire() {
        lock.lock()
        let action = self.action
        lock.unlock()
        action?()
    }
}

private func dictationHotKeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    HotKeyAction.shared.fire()
    return noErr
}

/// Carbon's hot key API is still the only way to claim a system-wide shortcut
/// without asking for Accessibility or Input Monitoring access, and it also stops
/// the keystroke from reaching the focused app.
enum GlobalHotKey {
    private nonisolated(unsafe) static var hotKeyRef: EventHotKeyRef?
    private nonisolated(unsafe) static var handlerRef: EventHandlerRef?

    @discardableResult
    static func register(_ shortcut: DictationShortcut, action: @escaping @Sendable () -> Void) -> Bool {
        unregister()
        guard let keyCode = shortcut.keyCode else { return false }
        HotKeyAction.shared.set(action)
        if handlerRef == nil {
            var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), dictationHotKeyHandler, 1, &specification, nil, &handlerRef)
        }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x534C4144), id: 1)
        let status = RegisterEventHotKey(keyCode, shortcut.carbonModifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { return false }
        hotKeyRef = reference
        return true
    }

    static func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        HotKeyAction.shared.set(nil)
    }
}

/// Push-to-talk dictation: press the shortcut to record, press it again to stop.
/// The clip is transcribed by the same local ASR runner the app already uses, put
/// on the clipboard, and optionally pasted at the cursor.
@MainActor
final class DictationController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var status = "단축키를 누르면 받아쓰기를 시작합니다."
    @Published private(set) var lastText = ""
    @Published var errorMessage: String?
    @Published var shortcut: DictationShortcut {
        didSet {
            UserDefaults.standard.set(shortcut.rawValue, forKey: "dictationShortcut")
            applyShortcut()
        }
    }
    @Published var asrModel: ASRModelChoice {
        didSet { UserDefaults.standard.set(asrModel.rawValue, forKey: "dictationASRModel") }
    }
    @Published var language: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "dictationLanguage") }
    }
    @Published var pastesAutomatically: Bool {
        didSet { UserDefaults.standard.set(pastesAutomatically, forKey: "dictationAutoPaste") }
    }
    @Published private(set) var shortcutRegistered = false

    /// Only one local model job runs at a time, so dictation defers to whatever
    /// the transcription queue is already doing rather than competing with it.
    var isOtherWorkRunning: @MainActor () -> Bool = { false }

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt: Date?
    private var currentFile: URL?
    private var task: Task<Void, Never>?

    override init() {
        shortcut = UserDefaults.standard.string(forKey: "dictationShortcut").flatMap(DictationShortcut.init(rawValue:)) ?? .controlOptionCommandD
        asrModel = UserDefaults.standard.string(forKey: "dictationASRModel").flatMap(ASRModelChoice.init(rawValue:)) ?? .qwen06B8Bit
        language = UserDefaults.standard.string(forKey: "dictationLanguage").flatMap(TranscriptionLanguage.init(rawValue:)) ?? .korean
        pastesAutomatically = UserDefaults.standard.object(forKey: "dictationAutoPaste") as? Bool ?? false
        super.init()
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    func activate() { applyShortcut() }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func applyShortcut() {
        guard shortcut != .disabled else {
            GlobalHotKey.unregister()
            shortcutRegistered = false
            status = "받아쓰기 단축키가 꺼져 있습니다."
            return
        }
        shortcutRegistered = GlobalHotKey.register(shortcut) { [weak self] in
            Task { @MainActor in self?.toggle() }
        }
        status = shortcutRegistered
            ? "\(shortcut.title)를 누르면 받아쓰기를 시작합니다."
            : "\(shortcut.title)를 다른 앱이 이미 사용 중입니다. 다른 단축키를 선택해 주세요."
    }

    func toggle() {
        if isRecording {
            stopAndTranscribe()
        } else {
            start()
        }
    }

    func start() {
        guard !isRecording, !isTranscribing else { return }
        guard !isOtherWorkRunning() else {
            errorMessage = "전사 또는 AI 정리가 실행 중입니다. 끝난 뒤에 받아쓰기를 사용해 주세요."
            return
        }
        errorMessage = nil
        Task { [weak self] in
            guard let self else { return }
            guard await AVAudioApplication.requestRecordPermission() else {
                self.errorMessage = "마이크 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 마이크에서 허용해 주세요."
                return
            }
            do {
                let url = FileManager.default.temporaryDirectory
                    .appending(path: "SeoulLocalAgent-Dictation-\(UUID().uuidString).m4a")
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000,
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                recorder.delegate = self
                guard recorder.record() else {
                    throw AgentError.processFailed("마이크 녹음을 시작하지 못했습니다.")
                }
                self.recorder = recorder
                self.currentFile = url
                self.startedAt = Date()
                self.elapsed = 0
                self.isRecording = true
                self.status = "받아쓰는 중 · \(self.shortcut.title)로 종료"
                NSSound(named: "Tink")?.play()
                let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, let startedAt = self.startedAt else { return }
                        self.elapsed = Date().timeIntervalSince(startedAt)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func stopAndTranscribe() {
        guard isRecording, let recorder, let url = currentFile else { return }
        recorder.stop()
        finishRecording()
        NSSound(named: "Pop")?.play()
        let duration = elapsed
        guard duration >= 0.4 else {
            try? FileManager.default.removeItem(at: url)
            status = "너무 짧아 취소했습니다."
            return
        }
        isTranscribing = true
        status = "받아쓴 내용을 변환하는 중"
        task = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let result = try await TranscriptionService().transcribe(
                    url, asrModel: asrModel, diarization: .disabled,
                    timestampMode: .none, language: language
                ) { _ in }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.status = "인식된 말이 없습니다."
                    self.isTranscribing = false
                    return
                }
                self.lastText = text
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                if self.pastesAutomatically, self.accessibilityGranted {
                    Self.pasteAtCursor()
                    self.status = "붙여넣었습니다 · \(text.count)자"
                } else if self.pastesAutomatically {
                    self.status = "클립보드에 복사했습니다. 자동 붙여넣기는 손쉬운 사용 권한이 필요합니다."
                } else {
                    self.status = "클립보드에 복사했습니다 · \(text.count)자"
                }
            } catch is CancellationError {
                self.status = "받아쓰기를 취소했습니다."
            } catch {
                self.errorMessage = error.localizedDescription
                self.status = "받아쓰기에 실패했습니다."
            }
            self.isTranscribing = false
            self.task = nil
        }
    }

    func cancel() {
        if isRecording, let url = currentFile {
            recorder?.stop()
            finishRecording()
            try? FileManager.default.removeItem(at: url)
            status = "받아쓰기를 취소했습니다."
        }
        task?.cancel()
        ActiveProcessRegistry.shared.terminateProcesses(containing: "scripts/transcribe_runner.py")
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor [weak self] in
            self?.errorMessage = error?.localizedDescription ?? "받아쓰기 녹음을 저장하지 못했습니다."
            self?.finishRecording()
        }
    }

    private func finishRecording() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        startedAt = nil
        isRecording = false
    }

    private static func pasteAtCursor() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
