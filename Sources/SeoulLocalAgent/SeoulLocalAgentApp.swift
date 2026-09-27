import SwiftUI
import AppKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import Combine

@main
struct SeoulLocalAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AutomationController()

    init() {
        // A board that quietly changes its markup would otherwise show up as a
        // silent zero inside a briefing. This reports each site on its own.
        if CommandLine.arguments.contains("--web-notices-check") {
            Task {
                for (site, result) in await WebNoticeSource().inspect() {
                    switch result {
                    case .success(let entries):
                        let sample = entries.first.map { " · 예: \($0.title.prefix(40))" } ?? ""
                        print("\(entries.isEmpty ? "⚠️" : "✅") \(site.name) \(entries.count)건\(sample)")
                    case .failure(let error):
                        print("❌ \(site.name) 실패: \(error.localizedDescription)")
                    }
                }
                exit(EXIT_SUCCESS)
            }
        }
        // eTL도 게시판과 같은 이유로 따로 확인할 수 있어야 한다. 수집을 진짜로 돌리면
        // 기준선과 알림 단계를 써 버려서, 확인이 다음 브리핑의 내용을 바꾼다.
        if CommandLine.arguments.contains("--etl-check") {
            Task {
                do {
                    let found = try await ETLSource().inspect()
                    guard !found.courses.isEmpty else {
                        print("⚠️ eTL: 수강 중인 과목을 찾지 못했습니다.")
                        exit(EXIT_SUCCESS)
                    }
                    print("✅ eTL \(found.semester) · \(found.courses.count)과목")
                    print("   \(found.courses.map(\.shortName).joined(separator: ", "))")
                    let announcementSample = found.announcements.first.map { " · 예: \($0.title.prefix(40))" } ?? ""
                    print("   공지(최근 14일) \(found.announcements.count)건\(announcementSample)")
                    print("   마감 남은 과제 \(found.upcoming.count)건")
                    for row in found.upcoming.prefix(8) {
                        let due = row.assignment.dueAt.map(ETLSource.dueText) ?? "마감 미정"
                        let days = row.assignment.dueAt.map { "D-\(ETLDigestStore.daysUntil($0, from: Date()))" } ?? ""
                        let late = row.assignment.lateWindow.map { " (지각 제출 \(ETLSource.dueText($0))까지)" } ?? ""
                        print("     · [\(row.course.shortName)] \(row.assignment.name) — \(due) \(days)\(late)")
                    }
                    print("   마감 지난 미제출 \(found.missing.count)건")
                    for row in found.missing.prefix(5) {
                        let due = row.dueAt.map(ETLSource.dueText) ?? "마감 미정"
                        print("     · \(row.name) — \(due)")
                    }
                    let unread = found.conversations.filter(\.isUnread).count
                    print("   쪽지(최근 14일) \(found.conversations.count)건, 안 읽음 \(unread)건")
                    for row in found.conversations.prefix(5) {
                        print("     · [\(row.contextName ?? "쪽지")] \(row.shortSubject.prefix(50))")
                    }
                    print("   앞으로의 수업 일정 \(found.events.count)건")
                    for row in found.events.prefix(5) {
                        let start = row.startAt.map(ETLSource.dueText) ?? "시각 미정"
                        print("     · [\(row.contextName ?? "eTL")] \(row.title.prefix(40)) — \(start)")
                    }
                    // 실제로 수집하면 무엇이 브리핑에 올라가고 달력에 무엇이 놓이는지까지
                    // 보여 준다. 기억과 스냅샷을 임시 폴더로 돌려 두었으므로 진짜 수집 경로를
                    // 그대로 타면서도 기준선·알림 단계·달력 파일 어느 것도 건드리지 않는다 —
                    // 확인했다는 이유로 다음 브리핑이 달라지지 않아야 한다.
                    let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                        .appending(path: "etl-check-\(UUID().uuidString)", directoryHint: .isDirectory)
                    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                    var probe = ETLSource()
                    probe.storeURL = scratch.appending(path: "etl-seen.json")
                    probe.snapshotURL = scratch.appending(path: "etl-deadlines.json")
                    // 진짜 기억을 **복사해서** 쓴다. 빈 폴더로 두면 이 실행이 첫 수집이 되어
                    // 공지도 쪽지도 기준선에 걸려 하나도 안 올라오고, 확인 화면이 "0건"이라고
                    // 거짓말을 한다. 사본이므로 진짜 파일은 그대로다.
                    try? FileManager.default.copyItem(at: ETLDigestStore.url, to: probe.storeURL)
                    let harvest = await probe.collect(persists: true)
                    print("   지금 수집하면 올라갈 항목 \(harvest.items.count)건")
                    for item in harvest.items.prefix(8) {
                        print("     · [\(item.account)] \(item.subject)")
                    }
                    let snapshot = ETLDeadlineSnapshot.load(url: probe.snapshotURL)
                    let open = snapshot.entries.filter { $0.kind == .assignment && !$0.isSettled }
                    let settled = snapshot.entries.filter(\.isSettled).count
                    print("   달력이 그릴 것 \(snapshot.dated.count)건 (남은 과제 \(open.count) · 제출·면제로 접힐 것 \(settled) · 수업 일정 \(snapshot.entries.filter { $0.kind == .event }.count))")
                    for row in snapshot.dated.prefix(6) {
                        let when = row.date.map(ETLSource.dueText) ?? "날짜 미정"
                        print("     · [\(row.courseName)] \(row.title.prefix(36)) — \(when)\(row.isSettled ? " · 접힘" : "")")
                    }
                    for warning in harvest.warnings { print("   ⚠︎ \(warning)") }
                    // `defer`로 지울 수 없다. 이 블록은 `exit`로 끝나고, `exit`는 defer를
                    // 돌리지 않은 채 프로세스를 세운다 — 그러면 확인할 때마다 임시 폴더가 쌓인다.
                    try? FileManager.default.removeItem(at: scratch)
                } catch {
                    print("❌ eTL 실패: \(error.localizedDescription)")
                }
                exit(EXIT_SUCCESS)
            }
        }
        // The same probes 설정 › 연결 상태 runs, on the terminal. Worth having
        // separately: this is the check you want when the app will not start, or
        // when you want to see the answer without a window in the way.
        if CommandLine.arguments.contains("--connection-check") {
            Task {
                var failed = false
                for check in await ConnectionHealthReport.run() {
                    let mark = switch check.state {
                    case .ok: "✅"
                    case .warning: "⚠️"
                    case .failed: "❌"
                    case .checking: "…"
                    }
                    if check.state == .failed { failed = true }
                    print("\(mark) \(check.title): \(check.summary)")
                    if let detail = check.detail, !detail.isEmpty {
                        detail.split(separator: "\n").forEach { print("     \($0)") }
                    }
                }
                print("• \(BriefingHealth.load().summary())")
                exit(failed ? EXIT_FAILURE : EXIT_SUCCESS)
            }
        }
        // The same idea as `--connection-check`, for the robot: open the tunnel,
        // read the console's status, pull one frame from each camera and report
        // whether anything was left running. Useful when the arms will not start
        // and the question is whether this Mac can reach the server at all.
        // 분류 프롬프트에 실려 가는 교정 예시를 파일로 꺼낸다. 창을 열지 않는다.
        //
        // `scripts/eval/briefing-eval.py`가 이것을 읽어 **넣은 쪽과 뺀 쪽을 나란히**
        // 재기 위한 것이다. 예시를 파이썬에서 다시 만들면 앱이 실제로 보내는 것과
        // 조용히 달라지므로, 만드는 곳은 이 한 군데로 둔다.
        if let index = CommandLine.arguments.firstIndex(of: "--export-corrections"),
           index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            Task { @MainActor in
                let model = BriefingArchiveModel()
                let corrections = model.corrections
                let block = ClassificationLearning.promptBlock(from: corrections) ?? ""
                do {
                    try block.write(toFile: path, atomically: true, encoding: .utf8)
                    let lines = block.isEmpty ? 0 : block.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
                    print("✅ 교정 \(corrections.count)건 중 \(lines)줄을 \(path)에 적었습니다 (\(block.count)자)")
                    exit(EXIT_SUCCESS)
                } catch {
                    print("❌ 쓰지 못했습니다: \(error.localizedDescription)")
                    exit(EXIT_FAILURE)
                }
            }
        }
        // 음악 탭이 닿는 곳을 한 번씩 두드려 본다. 창을 열지 않고도 무엇이 되고
        // 무엇이 안 되는지 알 수 있어야 한다.
        if CommandLine.arguments.contains("--music-check") {
            Task { @MainActor in
                exit(await MusicConnectionCheck.run() ? EXIT_SUCCESS : EXIT_FAILURE)
            }
        }
        // 프린터까지 가는 길을 창 없이 확인한다. 집 주소와 밖에서 쓸 주소를 따로 두드리므로,
        // "지금 있는 곳에서만 되는" 상태를 여기서 잡을 수 있다.
        if CommandLine.arguments.contains("--printer-check") {
            Task { @MainActor in
                exit(await PrintConnectionCheck.run() ? EXIT_SUCCESS : EXIT_FAILURE)
            }
        }
        // 터미널에서 바로 인쇄한다. 화면이 쓰는 것과 **같은** 준비·조판·명령·지켜보기를
        // 그대로 쓴다. `--print-hold`를 함께 주면 큐에 잡아 둔 채 넣어, 종이를 쓰지 않고
        // 이 길 전체를 확인할 수 있다.
        // 화면을 열지 않고 미리보기를 파일로 꺼낸다. 미리보기와 실제가 같은지 대조하는
        // 자리이기도 하다 — 함께 남기는 PDF가 서버로 갈 바로 그 파일이다.
        if let index = CommandLine.arguments.firstIndex(of: "--print-preview"), index + 2 < CommandLine.arguments.count {
            let input = CommandLine.arguments[index + 1]
            let output = CommandLine.arguments[index + 2]
            let sheet = CommandLine.arguments.count > index + 3
                ? (Int(CommandLine.arguments[index + 3]) ?? 1) - 1 : 0
            Task { @MainActor in
                exit(await PrintPreviewCommandLine.run(input: input, output: output, sheet: max(0, sheet)) ? EXIT_SUCCESS : EXIT_FAILURE)
            }
        } else if let index = CommandLine.arguments.firstIndex(of: "--print") {
            let paths = CommandLine.arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }
            let holding = CommandLine.arguments.contains("--print-hold")
            // 종이 위의 길이가 파일의 길이와 같아야 하는 인쇄물(캘리브레이션 표적 같은 것).
            // 저장해 둔 설정을 읽지도 덮어쓰지도 않고, 배율을 건드리는 항목을 모두 끈다.
            let exact = CommandLine.arguments.contains("--print-exact")
            Task { @MainActor in
                exit(await PrintCommandLine.run(paths: Array(paths), holding: holding, exact: exact) ? EXIT_SUCCESS : EXIT_FAILURE)
            }
        }
        // `--briefing-shadow` runs the whole pipeline and prints the report
        // without touching stored state; `--briefing-write` also saves it and
        // exports it to Notion, which is now an explicit extra step rather than
        // the last phase of every run.
        let shadow = CommandLine.arguments.contains("--briefing-shadow")
        let write = CommandLine.arguments.contains("--briefing-write")
        if shadow || write {
            Task {
                do {
                    let service = BriefingService()
                    var briefing = try await service.run(range: .day3, persists: write) { _, message, _ in
                        FileHandle.standardError.write(Data((message + "\n").utf8))
                    }
                    if write { briefing.notionURL = try await service.exportToNotion(briefing) }
                    if shadow { FileHandle.standardOutput.write(Data(service.markdownPreview(briefing).utf8)) }
                    if write { FileHandle.standardOutput.write(Data((briefing.notionURL?.absoluteString ?? "") .utf8)) }
                    exit(EXIT_SUCCESS)
                } catch {
                    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                    exit(EXIT_FAILURE)
                }
            }
        }
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: there is one workspace and no reason for
        // a second copy of it. A `WindowGroup` hands out a new window on every
        // ⌘N and on every `openWindow`, so 앱 열기 kept stacking duplicates;
        // a `Window` is unique, and opening it again just brings it forward.
        //
        // It also comes first on purpose. While `MenuBarExtra` was the leading
        // scene, SwiftUI treated *it* as the app's primary scene and launching
        // the app opened nothing at all — the only way in was the menu bar's own
        // 앱 열기 button, which is why that button existed.
        Window("서울대 로컬 에이전트", id: "main") {
            MainWorkspaceView(controller: controller)
        }
        .defaultSize(width: 1120, height: 780)
        .windowResizability(.contentMinSize)
        .commands { AppCommands(controller: controller) }

        MenuBarExtra {
            MenuContentView(controller: controller)
        } label: {
            // 창을 닫아도 앱은 여기 남는다. 그때 마이크가 열려 있는지 알 수 있는 곳은
            // 이 아이콘뿐이므로, 받아쓰기뿐 아니라 강의 녹음도 함께 비춘다.
            Label("서울대 로컬 에이전트", systemImage: controller.audioRecorder.isRecording || controller.dictation.isRecording ? "mic.circle.fill" : (controller.isRunning ? "graduationcap.circle.fill" : "graduationcap.circle"))
        }
        .menuBarExtraStyle(.window)

        // ⌘, — the only place settings live now. They used to be an eighth
        // sidebar row holding nine sections in one endless scroll.
        Settings {
            SettingsWindow(controller: controller)
        }
    }
}

/// The menu bar. The app had no `commands` block at all, so it shipped without
/// ⌘, , without a way to start a run from the keyboard, and without section
/// switching — every action needed the mouse.
private struct AppCommands: Commands {
    @ObservedObject var controller: AutomationController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("인박스 정리 시작") { controller.startBriefing() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(controller.isRunning)
            Button("실행 중지") { controller.stopBriefing() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!controller.isRunning)
        }
        CommandGroup(before: .toolbar) {
            // Divided the way the sidebar is: eleven screens in one undivided
            // run is a menu nobody reads to the bottom of.
            ForEach(AppSection.Group.allCases) { group in
                ForEach(group.members) { item in
                    Button(item.title) { controller.section = item }
                        .keyboardShortcut(item.shortcut, modifiers: item.shortcutModifiers)
                }
                Divider()
            }
        }
        CommandGroup(replacing: .help) {
            Button("서울대 로컬 에이전트 창 열기") {
                openWindow(id: "main")
                NSApp.activate()
            }
        }
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Checking the dark palette used to mean flipping the whole system's
        // appearance; this darkens only this app so the two schemes can be
        // compared without disturbing anything else.
        if CommandLine.arguments.contains("--force-dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if CommandLine.arguments.contains("--force-light") {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
        // Same purpose as `--section`: reaching a screen without a keystroke, so
        // the app can be looked at while it runs without taking the machine away
        // from whoever is using it.
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { Self.openSettingsWindow() }
            }
        }
        // 화면을 찍어 확인하는 법. **한때 이 자리에 되지 않는 방법이 적혀 있었다.**
        //
        // "뒤에서 띄운 창을 맨 뒤로 보내면 포커스를 빼앗지 않고 찍을 수 있다"는 설명만 남고
        // 코드는 없었는데, 실제로 해 보면 되지 않는다(2026-09-07 확인). `open -g`로 띄운
        // SwiftUI 창은 `NSWindow`로는 1510×1067라고 답하지만 한 번도 화면에 올라간 적이 없어
        // 표면이 없고, `CGWindowList`에는 143×184의 껍데기로 잡힌다.
        // `orderBack`·`orderFrontRegardless`·`setIsVisible(true)`·`makeKeyAndOrderFront`
        // 어느 것도 그 표면을 만들지 못했다. 창이 그려지려면 **앞으로 나와야 한다.**
        //
        //     open -a dist/SeoulLocalAgent.app --args --section print
        //     screencapture -x -o -l <창 번호>   # CGWindowListCopyWindowInfo로 얻는다
        //
        // 찍히지 않으면 먼저 **화면 잠금**을 본다. 잠겨 있으면 어떤 앱도 앞으로 나오지 못하고
        // 창은 그려지지 않는다 — 그때 `NSApp.activate(ignoringOtherApps:)`도 소용없다.
        //
        //     ioreg -n Root -d1 -a   # CGSSessionScreenIsLocked 를 본다
        //
        // Process discovery performs blocking system I/O and must never hold
        // SwiftUI's main thread during launch.
        DispatchQueue.global(qos: .utility).async {
            ActiveProcessRegistry.shared.terminateOrphanedRunners()
        }
    }

    /// 설정 창을 연다. **판올림을 타지 않게 세 갈래로 시도한다.**
    ///
    /// `showSettingsWindow:` 하나만 부르고 있었는데 macOS 26에서는 아무 일도 일어나지
    /// 않았다 — 오류도 없이 조용히. 그래서 `--settings`로 띄워 두고 화면을 확인하려던
    /// 것이 되지 않았고, 그 사실조차 창이 안 뜨는 것으로만 보였다. 점검용 인자는 조용히
    /// 실패하면 없는 것만 못하다.
    ///
    /// 마지막 갈래가 메뉴 항목이다. 이름이 무엇이든 `설정`을 여는 항목은 앱 메뉴에 반드시
    /// 있고, 그것을 눌러 주는 것은 사람이 ⌘,를 치는 것과 같은 길이다.
    @MainActor
    private static func openSettingsWindow() {
        for name in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if NSApp.sendAction(Selector((name)), to: nil, from: nil) { return }
        }
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        for item in appMenu.items where item.title.contains("설정") || item.title.contains("Settings") {
            guard let action = item.action else { continue }
            NSApp.sendAction(action, to: item.target, from: item)
            return
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 순서가 뜻을 갖는다. **사람이 만든 것을 먼저 지키고, 자원 반납은 그 다음이다.**
        //
        // 아래의 반납들은 하나하나가 최대 몇 초씩 기다린다(카메라 2대에 4초, 터널에 3.5초,
        // 자식 프로세스 하나에 2초). 다 합치면 십수 초인데, 로그아웃·재시동으로 끝날 때
        // macOS는 그만큼 기다려 주지 않고 앱을 끊어 버린다. 저장이 뒤에 있으면 바로 그때
        // 사라진다 — 마지막으로 듣던 자리와 방금 고친 서버 주소가 실제로 그랬다.
        //
        // 녹음이 맨 앞인 이유는 따로 있다. `AVAudioRecorder`는 `stop()`을 불러야 색인을
        // 쓰므로, 여기서 닫지 않으면 그 강의는 어떤 재생기도 열지 못하는 파일이 된다.
        AudioRecorder.current?.stopNow()
        // 저장은 400ms 뒤로 미뤄져 있어서, 그 사이에 끝나면 마지막 몇 초의 변경이 사라진다.
        MusicPlayerModel.current?.saveNow()

        // 여기서부터는 이 앱이 가져간 자원을 돌려주는 일이다.
        // The 누끼 runner stays resident between photos, so it gets an explicit
        // close-then-terminate-then-kill pass that returns only once it is gone.
        // Everything else is a short-lived child that `terminateAll` covers.
        MattingDaemon.shared.shutdownNow()
        // Same for the 소리 다듬기 · 화질 올리기 runner, which also keeps a torch
        // model warm between files.
        MediaDaemon.shared.shutdownNow()
        // 프린트 탭이 만든 임시 PDF. 보낸 뒤에도 목록에 남아 있으므로 앱이 끝날 때 치운다 —
        // 원본은 여기서 지우는 대상이 아니고, 지워지지도 않는다.
        PrintModel.cleanUpOnQuit()
        // Tree, not just the direct child: the 정밀 문서 인식 helper starts a
        // local service of its own that would otherwise be left behind.
        ActiveProcessRegistry.shared.terminateAllTrees()
    }
}

@MainActor
final class AutomationController: ObservableObject {
    let connectionHealth = ConnectionHealthModel()
    /// Lives here rather than in the split view so the ⌘1…⌘6 menu commands can
    /// move the selection; menu commands are outside the window's view tree.
    ///
    /// `--section <name>` picks the starting screen, which lets a screen be
    /// looked at in a background launch instead of by typing ⌘-number into a
    /// window that has to be frontmost to receive it.
    @Published var section: AppSection = {
        guard let index = CommandLine.arguments.firstIndex(of: "--section"),
              index + 1 < CommandLine.arguments.count,
              let requested = AppSection(rawValue: CommandLine.arguments[index + 1])
        else { return .overview }
        return requested
    }()
    @Published var phase: RunPhase = .idle
    @Published var detail = "명시적 실행을 기다리고 있습니다."
    @Published var selectedRange: CollectionRange {
        didSet { UserDefaults.standard.set(selectedRange.rawValue, forKey: "briefingRange") }
    }
    @Published var briefingQualityMode: BriefingQualityMode {
        didSet { UserDefaults.standard.set(briefingQualityMode.rawValue, forKey: "briefingQualityMode") }
    }
    @Published var briefingMaxActions: Int {
        didSet { UserDefaults.standard.set(briefingMaxActions, forKey: "briefingMaxActions") }
    }
    @Published var briefingMaxReferences: Int {
        didSet { UserDefaults.standard.set(briefingMaxReferences, forKey: "briefingMaxReferences") }
    }
    @Published var briefingETA: TimeInterval?
    @Published var briefingUserInstructions: String
    @Published var briefingAcademicInstructions: String
    @Published var briefingIgnoredPatternsText: String
    @Published var briefingImportantPatternsText: String
    @Published var briefingInterestPatternsText: String
    @Published var briefingPreferencesStatus = ""
    @Published var calendarAuthorizationStatus = CalendarIntegration.authorizationDescription
    @Published var reminderAuthorizationStatus = CalendarIntegration.reminderAuthorizationDescription
    @Published var lastBriefing: DailyBriefing?
    /// The briefings themselves, and what the reader has done with them.
    let briefingArchive = BriefingArchiveModel()
    /// Names and tags for the recording library, which had neither.
    let recordingOrganizer = RecordingOrganizer()
    /// 음악 탭. 재생·대기열·플레이리스트를 모두 쥐고 있고, 화면을 떠나도 소리가
    /// 이어져야 하므로 화면이 아니라 여기 산다.
    let music = MusicPlayerModel()
    /// 프린트 탭. 프린터는 집 서버에 USB로 붙어 있고, 이 Mac은 SSH 너머로 문서만 흘려보낸다.
    /// 프린터가 붙어 있는 집 서버 하나. 주소는 설정 › 프린터가 소유한다.
    let printing = PrintModel()
    /// Today's schedule for the 개요 screen. Read on demand rather than kept in
    /// sync: EventKit is the source of truth and the screen is not always up.
    @Published var todayEvents: [CalendarGlance] = []
    @Published var errorMessage: String?
    /// What the last run managed, read back out of the checkpoint the pipeline
    /// already writes. `lastSuccessAt` and `lastError` were recorded from the
    /// first version and displayed by nothing, which is how a briefing went
    /// seventeen days stale while both screens said 대기 중.
    @Published var briefingHealth = BriefingHealth.load()
    /// Which pane ⌘, lands on. Lives here because the buttons that need to steer
    /// it — 연결 상태 점검 on 개요, 설정에서 변경 on 자동 브리핑 — are outside the
    /// settings window's own view tree.
    ///
    /// `--settings <이름>`으로 어느 탭을 열지 고를 수 있다. `--section`과 같은 이유로, 창을
    /// 눌러 보지 않고도 특정 화면을 확인할 수 있어야 하기 때문이다.
    @Published var settingsTab: SettingsTab = {
        guard let index = CommandLine.arguments.firstIndex(of: "--settings"),
              index + 1 < CommandLine.arguments.count,
              let requested = SettingsTab(rawValue: CommandLine.arguments[index + 1])
        else { return .briefing }
        return requested
    }()
    @Published var isRunning = false
    @Published var isTranscribing = false
    @Published var asrModel: ASRModelChoice {
        didSet { UserDefaults.standard.set(asrModel.rawValue, forKey: "asrModelChoice") }
    }
    @Published var diarization: DiarizationChoice {
        didSet { UserDefaults.standard.set(diarization.rawValue, forKey: "diarizationChoice") }
    }
    @Published var transcriptionTimestampMode: TranscriptionTimestampMode {
        didSet { UserDefaults.standard.set(transcriptionTimestampMode.rawValue, forKey: "transcriptionTimestampMode") }
    }
    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet { UserDefaults.standard.set(transcriptionLanguage.rawValue, forKey: "transcriptionLanguage") }
    }
    @Published var transcriptionDetail = "녹음 파일을 선택하면 설정한 음성 인식과 화자 구분을 시작합니다."
    /// 녹음이 어떻게 끝났는지. **전사 진행 줄과 따로 있어야 한다.**
    ///
    /// 예전에는 이 말도 `transcriptionDetail`에 적었는데, 그 줄은 전사가 도는 동안에만
    /// 화면에 나오고 그때는 진행률에 밀리지 않으려고 적기를 건너뛰었다. 그래서 녹음을
    /// 멈춰도 어디에도 아무 말이 나오지 않았다 — 전사 중이든 아니든. 녹음과 전사는 같이
    /// 도는 일이므로 말할 자리도 둘이어야 한다.
    @Published var recordingStatus: String?
    @Published var transcriptionStep = 0
    @Published var transcriptionETA: TimeInterval?
    @Published var transcriptionText = ""
    @Published var transcriptionError: String?
    @Published var mostRecentRecording: URL?
    @Published var recordings: [RecordingItem] = []
    @Published var recordingLibraryStatus = "녹음 보관함을 불러오는 중"
    @Published var downloadingRecordingIDs: Set<RecordingItem.ID> = []
    @Published var selectedRecordingID: RecordingItem.ID?
    @Published var selectedTranscriptRunID: UUID?
    @Published var selectedOrganizationRunID: UUID?
    @Published var transcribingRecordingID: RecordingItem.ID?
    @Published var isOrganizingTranscript = false
    @Published var organizationDetail = ""
    @Published var organizationError: String?
    @Published var organizationETA: TimeInterval?
    @Published var automaticallyOrganizeTranscripts: Bool
    @Published var organizationKind: TranscriptOrganizationKind
    @Published var organizationDetailLevel: TranscriptOrganizationDetail
    @Published var lectureOrganizationPrompt: String
    @Published var meetingOrganizationPrompt: String
    @Published var generalOrganizationPrompt: String
    @Published var summaryModel: String
    @Published var organizationPreferencesStatus = ""
    @Published private(set) var processingQueue: [ProcessingQueueItem] = []
    @Published private(set) var activeProcessingItemID: UUID?
    @Published var mediaURLText = ""
    @Published private(set) var isImportingMedia = false
    @Published private(set) var mediaImportStatus = ""
    @Published var mediaImportError: String?
    @Published private(set) var isRecognizingDocument = false
    @Published private(set) var recognizedText = ""
    @Published private(set) var recognizedSourceName = ""
    @Published private(set) var recognitionStatus = "이미지나 PDF를 넣으면 글자를 뽑습니다."
    @Published var recognitionError: String?
    @Published private(set) var recognizedNoteText = ""
    /// Drives the save panel's file type and the hint under the result.
    @Published private(set) var recognizedTextIsMarkdown = false
    @Published var documentMode: DocumentRecognitionMode {
        didSet { UserDefaults.standard.set(documentMode.rawValue, forKey: "documentRecognitionMode") }
    }
    @Published var mattingModel: MattingModelChoice {
        didSet { UserDefaults.standard.set(mattingModel.rawValue, forKey: "mattingModel") }
    }
    @Published var cutoutBackground: CutoutBackground {
        didSet { UserDefaults.standard.set(cutoutBackground.rawValue, forKey: "cutoutBackground") }
    }
    @Published var cutoutCustomColor: Color {
        didSet { UserDefaults.standard.set(Self.hex(from: cutoutCustomColor), forKey: "cutoutCustomColor") }
    }
    @Published private(set) var cutoutItems: [CutoutItem] = []
    @Published var selectedCutoutIDs: Set<CutoutItem.ID> = []
    @Published private(set) var isRemovingBackground = false
    @Published private(set) var cutoutStatus = "사진을 넣으면 배경을 지웁니다."
    @Published var cutoutError: String?
    @Published var compressionMode: CompressionMode {
        didSet { UserDefaults.standard.set(compressionMode.rawValue, forKey: "compressionMode") }
    }
    @Published var compressionLevel: CompressionLevel {
        didSet { UserDefaults.standard.set(compressionLevel.rawValue, forKey: "compressionLevel") }
    }
    @Published var compressionImageFormat: ImageOutputFormat {
        didSet { UserDefaults.standard.set(compressionImageFormat.rawValue, forKey: "compressionImageFormat") }
    }
    @Published var compressionVideoCodec: VideoOutputCodec {
        didSet { UserDefaults.standard.set(compressionVideoCodec.rawValue, forKey: "compressionVideoCodec") }
    }
    @Published var compressionTargetBytes: Int {
        didSet { UserDefaults.standard.set(compressionTargetBytes, forKey: "compressionTargetBytes") }
    }
    @Published private(set) var compressionItems: [CompressionItem] = []
    @Published var selectedCompressionIDs: Set<CompressionItem.ID> = []
    @Published private(set) var isCompressing = false
    @Published private(set) var compressionStatus = "파일을 넣고 방식과 정도를 고르세요."
    @Published private(set) var compressionETA: TimeInterval?
    @Published var compressionError: String?
    private var compressionHistorySettings = ""

    // MARK: 소리 다듬기 · 화질 올리기 · 스캔 보정 · 형식 변환 · PDF 편집

    /// Each new tool owns its own queue instead of adding another forty
    /// published properties to this class; the screens observe these directly,
    /// which also keeps a progress tick from redrawing every other screen.
    let audioCleanup = BatchToolModel(name: "AudioCleanup", idleStatus: "녹음이나 영상을 넣으면 잡음을 걷어냅니다.")
    let upscale = BatchToolModel(name: "Upscale", idleStatus: "사진을 넣으면 크고 또렷하게 만듭니다.")
    let scan = BatchToolModel(name: "Scan", idleStatus: "찍은 유인물을 넣으면 반듯한 스캔으로 만듭니다.")
    let convert = BatchToolModel(name: "Convert", idleStatus: "파일을 넣고 바꿀 형식을 고르세요.")
    let pdfEditor = PDFEditorModel()

    @Published var audioCleanupMethod: AudioCleanupMethod {
        didSet { UserDefaults.standard.set(audioCleanupMethod.rawValue, forKey: "audioCleanupMethod") }
    }
    @Published var audioCleanupStrength: AudioCleanupStrength {
        didSet { UserDefaults.standard.set(audioCleanupStrength.rawValue, forKey: "audioCleanupStrength") }
    }
    @Published var audioCleanupNormalises: Bool {
        didSet { UserDefaults.standard.set(audioCleanupNormalises, forKey: "audioCleanupNormalises") }
    }
    @Published var audioCleanupFormat: AudioOutputFormat {
        didSet { UserDefaults.standard.set(audioCleanupFormat.rawValue, forKey: "audioCleanupFormat") }
    }
    @Published var upscaleModel: UpscaleModel {
        didSet { UserDefaults.standard.set(upscaleModel.rawValue, forKey: "upscaleModel") }
    }
    @Published var upscaleFormat: UpscaleFormat {
        didSet { UserDefaults.standard.set(upscaleFormat.rawValue, forKey: "upscaleFormat") }
    }
    @Published var scanFinish: ScanFinish {
        didSet { UserDefaults.standard.set(scanFinish.rawValue, forKey: "scanFinish") }
    }
    @Published var scanResolution: ScanResolution {
        didSet { UserDefaults.standard.set(scanResolution.rawValue, forKey: "scanResolution") }
    }
    @Published var scanFormat: ScanOutputFormat {
        didSet { UserDefaults.standard.set(scanFormat.rawValue, forKey: "scanFormat") }
    }
    @Published var scanDetectsEdges: Bool {
        didSet { UserDefaults.standard.set(scanDetectsEdges, forKey: "scanDetectsEdges") }
    }
    /// Changing the family has to move the format with it: `MP3` is not a thing
    /// a picture can become, and leaving it selected would queue every file
    /// against a conversion that refuses all of them.
    @Published var conversionFamily: ConversionFamily {
        didSet {
            UserDefaults.standard.set(conversionFamily.rawValue, forKey: "conversionFamily")
            if conversionTarget.family != conversionFamily, let first = conversionFamily.targets.first {
                conversionTarget = first
            }
        }
    }
    @Published var conversionTarget: ConversionTarget {
        didSet { UserDefaults.standard.set(conversionTarget.rawValue, forKey: "conversionTarget") }
    }
    @Published var conversionQuality: Double {
        didSet { UserDefaults.standard.set(conversionQuality, forKey: "conversionQuality") }
    }

    // MARK: 자동 브리핑

    /// 밤에 스스로 한 번 돌릴 것인가. 기본은 **꺼짐** — 사람이 켜지 않은 자동 실행은
    /// 자동화가 아니라 놀라운 일이다.
    @Published var autoBriefingEnabled: Bool {
        didSet { UserDefaults.standard.set(autoBriefingEnabled, forKey: "autoBriefingEnabled") }
    }
    /// 시간대의 시작. 끝은 여기서 `autoBriefingWindowHours` 뒤다.
    @Published var autoBriefingStartHour: Int {
        didSet { UserDefaults.standard.set(autoBriefingStartHour, forKey: "autoBriefingStartHour") }
    }
    /// 왜 지금 돌지 않는지, 또는 마지막으로 언제 돌았는지. 화면이 그대로 적는다.
    @Published private(set) var autoBriefingStatus = ""
    /// 자동으로 돌린 마지막 시각. 사람이 직접 누른 실행은 여기에 적히지 않는다 —
    /// 아침에 답해야 하는 질문은 "어젯밤 자동으로 돌았나"이기 때문이다.
    @Published private(set) var lastAutoBriefingAt: Date? {
        didSet { UserDefaults.standard.set(lastAutoBriefingAt?.timeIntervalSince1970 ?? 0, forKey: "lastAutoBriefingAt") }
    }
    private var autoBriefingFailures = 0
    private var autopilotTimer: Timer?
    private let sleepGuard = SleepGuard()
    /// 자동 실행이 걸어 둔 절전 방지를 이 실행이 잡고 있는가.
    private var isAutoBriefing = false

    /// 시간대의 길이. 세 시간인 이유는 사용자가 그렇게 정했기 때문이고(3시–6시), 그
    /// 길이면 조건이 맞는 밤에는 넉넉히 걸리면서 아침에 사람이 돌아오기 전에 끝난다.
    static let autoBriefingWindowHours = 3

    let audioRecorder = AudioRecorder()
    let recordingPlayer = RecordingPlayer()
    let dictation = DictationController()
    private var task: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var organizationTask: Task<Void, Never>?
    private var processingQueueState = ProcessingQueueState()
    private var mediaImportTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var cutoutTask: Task<Void, Never>?
    private var compressionTask: Task<Void, Never>?
    private var compressionEstimator = CompressionProgressEstimator()
    private var compressionETAUpdatedAt = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []
    private let store = StateStore()
    private let briefingPreferencesStore = BriefingPreferencesStore()
    private let organizationPreferencesStore = TranscriptOrganizationPreferencesStore()
    private var transcriptArchive = TranscriptArchive.load()
    private var briefingStartedAt: Date?
    private var transcriptionStartedAt: Date?
    private var organizationStartedAt: Date?

    var selectedRecording: RecordingItem? { recordings.first { $0.id == selectedRecordingID } }
    var selectedTranscriptRun: TranscriptRun? {
        guard let recording = selectedRecording else { return nil }
        let runs = transcriptRuns(for: recording)
        return runs.first(where: { $0.id == selectedTranscriptRunID }) ?? runs.first
    }
    var selectedTranscript: String { selectedTranscriptRun?.text ?? "" }
    var selectedOrganizationRun: TranscriptOrganizationRun? {
        guard let transcript = selectedTranscriptRun else { return nil }
        let runs = transcriptArchive.organizations(for: transcript.id)
        return runs.first(where: { $0.id == selectedOrganizationRunID }) ?? runs.first
    }

    var activeProcessingItem: ProcessingQueueItem? {
        guard let activeProcessingItemID else { return nil }
        return processingQueue.first { $0.id == activeProcessingItemID }
    }

    var waitingProcessingItems: [ProcessingQueueItem] {
        processingQueue.filter { $0.id != activeProcessingItemID }
    }

    var progressValue: Double {
        switch phase {
        case .idle, .failed, .cancelled: return 0
        case .collecting: return 0.15
        case .classifying: return 0.45
        case .writing: return 0.75
        case .completed: return 1
        }
    }

    init() {
        let briefingPreferences = BriefingPreferencesStore().load()
        autoBriefingEnabled = UserDefaults.standard.bool(forKey: "autoBriefingEnabled")
        autoBriefingStartHour = UserDefaults.standard.object(forKey: "autoBriefingStartHour") as? Int ?? 3
        let storedAuto = UserDefaults.standard.double(forKey: "lastAutoBriefingAt")
        lastAutoBriefingAt = storedAuto > 0 ? Date(timeIntervalSince1970: storedAuto) : nil
        briefingUserInstructions = briefingPreferences.userInstructions
        briefingAcademicInstructions = briefingPreferences.academicInstructions
        briefingIgnoredPatternsText = briefingPreferences.ignoredPatterns.joined(separator: "\n")
        briefingImportantPatternsText = briefingPreferences.importantPatterns.joined(separator: "\n")
        briefingInterestPatternsText = briefingPreferences.interestPatterns.joined(separator: "\n")
        // Incremental by default: earlier items that are still open are carried
        // forward rather than collected and analysed again.
        selectedRange = CollectionRange(rawValue: UserDefaults.standard.string(forKey: "briefingRange") ?? "") ?? .sinceLastSuccess
        briefingQualityMode = BriefingQualityMode(rawValue: UserDefaults.standard.string(forKey: "briefingQualityMode") ?? "") ?? .thorough
        briefingMaxActions = max(3, UserDefaults.standard.integer(forKey: "briefingMaxActions").nonZero(or: 10))
        briefingMaxReferences = max(3, UserDefaults.standard.integer(forKey: "briefingMaxReferences").nonZero(or: 8))
        // Vision stays the default: it is instant and needs no download, and
        // most captures are plain text. 정밀 is opted into per document.
        documentMode = DocumentRecognitionMode(rawValue: UserDefaults.standard.string(forKey: "documentRecognitionMode") ?? "") ?? .vision
        // Quality is the point of the 누끼 tab, so the 2048 checkpoint is the
        // default even though it costs a one-time download.
        mattingModel = MattingModelChoice(rawValue: UserDefaults.standard.string(forKey: "mattingModel") ?? "") ?? .highResolution
        cutoutBackground = CutoutBackground(rawValue: UserDefaults.standard.string(forKey: "cutoutBackground") ?? "") ?? .transparent
        cutoutCustomColor = Self.color(fromHex: UserDefaults.standard.string(forKey: "cutoutCustomColor")) ?? .white
        compressionMode = CompressionMode(rawValue: UserDefaults.standard.string(forKey: "compressionMode") ?? "") ?? .level
        compressionLevel = CompressionLevel(rawValue: UserDefaults.standard.string(forKey: "compressionLevel") ?? "") ?? .standard
        // JPEG rather than 원본 유지: someone opening this tab wants a smaller
        // file, and keeping a PNG as a PNG barely delivers one.
        compressionImageFormat = ImageOutputFormat(rawValue: UserDefaults.standard.string(forKey: "compressionImageFormat") ?? "") ?? .jpeg
        compressionVideoCodec = VideoOutputCodec(rawValue: UserDefaults.standard.string(forKey: "compressionVideoCodec") ?? "") ?? .h264
        let savedTarget = UserDefaults.standard.integer(forKey: "compressionTargetBytes")
        compressionTargetBytes = savedTarget > 0 ? savedTarget : 1_048_576
        // The gate is the default because it needs no download and is fast
        // enough to feel free; the model is opted into per batch.
        audioCleanupMethod = AudioCleanupMethod(rawValue: UserDefaults.standard.string(forKey: "audioCleanupMethod") ?? "") ?? .gate
        audioCleanupStrength = AudioCleanupStrength(rawValue: UserDefaults.standard.string(forKey: "audioCleanupStrength") ?? "") ?? .standard
        audioCleanupNormalises = UserDefaults.standard.object(forKey: "audioCleanupNormalises") as? Bool ?? true
        audioCleanupFormat = AudioOutputFormat(rawValue: UserDefaults.standard.string(forKey: "audioCleanupFormat") ?? "") ?? .m4a
        // Two times over rather than four: it is several times faster and the
        // result looks more natural on the blurry slide photos this is for.
        upscaleModel = UpscaleModel(rawValue: UserDefaults.standard.string(forKey: "upscaleModel") ?? "") ?? .realESRGANx2
        upscaleFormat = UpscaleFormat(rawValue: UserDefaults.standard.string(forKey: "upscaleFormat") ?? "") ?? .png
        scanFinish = ScanFinish(rawValue: UserDefaults.standard.string(forKey: "scanFinish") ?? "") ?? .bright
        scanResolution = ScanResolution(rawValue: UserDefaults.standard.string(forKey: "scanResolution") ?? "") ?? .standard
        scanFormat = ScanOutputFormat(rawValue: UserDefaults.standard.string(forKey: "scanFormat") ?? "") ?? .pdf
        scanDetectsEdges = UserDefaults.standard.object(forKey: "scanDetectsEdges") as? Bool ?? true
        let savedFamily = ConversionFamily(rawValue: UserDefaults.standard.string(forKey: "conversionFamily") ?? "") ?? .image
        conversionFamily = savedFamily
        let savedConversion = ConversionTarget(rawValue: UserDefaults.standard.string(forKey: "conversionTarget") ?? "")
        conversionTarget = savedConversion?.family == savedFamily ? savedConversion! : (savedFamily.targets.first ?? .jpeg)
        let savedQuality = UserDefaults.standard.double(forKey: "conversionQuality")
        conversionQuality = savedQuality > 0 ? savedQuality : 0.9
        let savedASR = UserDefaults.standard.string(forKey: "asrModelChoice")
        asrModel = savedASR.flatMap(ASRModelChoice.init(rawValue:)) ?? .qwen06B8Bit
        let savedDiarization = UserDefaults.standard.string(forKey: "diarizationChoice")
        diarization = savedDiarization.flatMap(DiarizationChoice.init(rawValue:)) ?? .disabled
        transcriptionTimestampMode = UserDefaults.standard.string(forKey: "transcriptionTimestampMode").flatMap(TranscriptionTimestampMode.init(rawValue:)) ?? .none
        transcriptionLanguage = UserDefaults.standard.string(forKey: "transcriptionLanguage").flatMap(TranscriptionLanguage.init(rawValue:)) ?? .korean
        let organizationPreferences = TranscriptOrganizationPreferencesStore().load()
        automaticallyOrganizeTranscripts = organizationPreferences.automaticallyOrganize
        organizationKind = organizationPreferences.defaultKind
        organizationDetailLevel = organizationPreferences.detail
        lectureOrganizationPrompt = organizationPreferences.lecturePrompt
        meetingOrganizationPrompt = organizationPreferences.meetingPrompt
        generalOrganizationPrompt = organizationPreferences.generalPrompt
        summaryModel = organizationPreferences.model
        // The most recent briefing is whatever the archive holds, which is now
        // the real thing rather than a stub built around a Notion link.
        lastBriefing = briefingArchive.days.first
        refreshRecordings()
        dictation.isOtherWorkRunning = { [weak self] in
            guard let self else { return false }
            return self.isTranscribing || self.isOrganizingTranscript
        }
        dictation.activate()
        // Dictation is its own observable object; forward its changes so the menu
        // bar icon and overview reflect it without duplicating the state here.
        dictation.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // And the archive: 보관함 and 개요 both read it through the controller, so
        // without this a ticked checkbox would not re-sort its own list until
        // something else happened to redraw the screen.
        briefingArchive.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 보관함에서 규칙 제안을 받아들이면 분류 기준 파일이 바뀐다. 설정 창이 들고 있는
        // 사본을 다시 읽지 않으면, 거기서 다음에 `저장`을 누르는 순간 방금 굳힌 규칙이
        // 낡은 사본에 덮여 사라진다.
        briefingArchive.didChangePreferences = { [weak self] in self?.reloadBriefingPreferences() }
        startAutopilot()
        // 뚜껑을 닫거나 마이크가 사라져서 녹음이 스스로 끝났을 때. 녹음기는 파일을 닫는
        // 데까지가 자기 일이고, 보관함에 넣고 화면에 적는 것은 이쪽 일이다.
        audioRecorder.onUnattendedStop = { [weak self] url, message in
            self?.recordingEndedOnItsOwn(url, message)
        }
        // Same for the recorder: without this the elapsed time published every
        // quarter second never reaches the views, so the counter sits at 0:00.
        audioRecorder.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 음악도 같은 이유로 이어 붙인다. 개요 타일과 메뉴 막대가 컨트롤러를 통해
        // 이 상태를 읽는다.
        music.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 설정 창의 탭 선택은 컨트롤러가 쥐고 있고 그 창은 음악 화면의 뷰 트리 밖에
        // 있다. 화면이 `설정 열기`를 누르면 정확히 음악 탭으로 가야 한다.
        music.requestSettingsTab = { [weak self] in self?.settingsTab = .music }
    }

    // MARK: - 자동 브리핑

    /// 1분에 한 번, 지금 돌아도 되는지 본다.
    ///
    /// 1분인 이유는 이 검사가 거의 공짜이기 때문이다 — 전원 상태와 유휴 시간을 읽는 것이
    /// 전부다. 더 드물게 보면 조건이 맞는 짧은 창을 놓치고, 더 자주 볼 이유는 없다.
    private func startAutopilot() {
        updateAutoBriefingStatus()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.autopilotTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autopilotTimer = timer
    }

    private func autopilotConditions(now: Date = Date()) -> BriefingAutopilot.Conditions {
        BriefingAutopilot.Conditions(
            isEnabled: autoBriefingEnabled,
            now: now,
            startHour: autoBriefingStartHour,
            windowHours: Self.autoBriefingWindowHours,
            isOnPower: BriefingAutopilot.isOnPower,
            isLidClosed: LidState.isClosed,
            idleSeconds: BriefingAutopilot.idleSeconds,
            busyWith: currentWorkName,
            isHot: BriefingAutopilot.isHot,
            lastAttemptAt: lastAutoBriefingAt,
            consecutiveFailures: autoBriefingFailures
        )
    }

    /// 지금 이 Mac이 하고 있는 무거운 일. 자동 실행은 그 위에 얹지 않는다.
    ///
    /// 녹음과 받아쓰기까지 세는 이유는, 로컬 모델이 GPU를 통째로 쓰는 동안 마이크가
    /// 도는 것을 굳이 겹치게 할 이유가 없기 때문이다.
    private var currentWorkName: String? {
        if isRunning { return "브리핑" }
        if isTranscribing { return "전사" }
        if isOrganizingTranscript { return "AI 정리" }
        if audioRecorder.isRecording { return "녹음" }
        if dictation.isRecording || dictation.isTranscribing { return "받아쓰기" }
        if isRecognizingDocument { return "문서 인식" }
        return nil
    }

    private func autopilotTick() {
        guard !isAutoBriefing else { return }
        let conditions = autopilotConditions()
        guard BriefingAutopilot.blocker(conditions) == nil else {
            updateAutoBriefingStatus(conditions)
            return
        }
        runBriefingAutomatically()
    }

    private func updateAutoBriefingStatus(_ conditions: BriefingAutopilot.Conditions? = nil) {
        let conditions = conditions ?? autopilotConditions()
        guard let blocker = BriefingAutopilot.blocker(conditions) else {
            autoBriefingStatus = "조건이 맞습니다 · 곧 시작합니다"
            return
        }
        // 마지막으로 자동 실행한 시각은 막힌 이유와 함께 남긴다. "왜 지금 안 도는가"와
        // "마지막으로 언제 돌았는가"는 아침에 둘 다 궁금한 것이다.
        var line = blocker.reason
        if case .disabled = blocker {} else if let last = lastAutoBriefingAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "M월 d일 HH:mm"
            line += " · 마지막 자동 실행 \(formatter.string(from: last))"
        }
        autoBriefingStatus = line
    }

    /// 사람이 없는 동안 도는 실행. 도는 내내 유휴 절전을 막아 두고, 끝나면 놓는다.
    private func runBriefingAutomatically() {
        isAutoBriefing = true
        lastAutoBriefingAt = Date()
        sleepGuard.hold("서울대 로컬 에이전트 · 자동 브리핑")
        autoBriefingStatus = "자동 실행 중입니다"
        startBriefing()
        // `startBriefing`이 만든 작업이 끝나는 것을 기다린다. 브리핑 모델이 상태를
        // 직접 알려 주지 않으므로 `isRunning`이 내려가는 것을 본다.
        Task { [weak self] in
            while let self, self.isRunning {
                try? await Task.sleep(for: .seconds(2))
            }
            guard let self else { return }
            self.sleepGuard.release()
            self.isAutoBriefing = false
            // 실패가 이어지면 그만둔다. 밤새 같은 실패를 반복하는 것은 고치는 데 도움이
            // 되지 않고 배터리와 열만 쓴다.
            if self.phase == .failed {
                self.autoBriefingFailures += 1
            } else {
                self.autoBriefingFailures = 0
            }
            self.updateAutoBriefingStatus()
        }
    }

    /// 파일에 있는 분류 기준을 화면의 사본으로 다시 읽는다.
    func reloadBriefingPreferences() {
        let preferences = briefingPreferencesStore.load()
        briefingUserInstructions = preferences.userInstructions
        briefingAcademicInstructions = preferences.academicInstructions
        briefingIgnoredPatternsText = preferences.ignoredPatterns.joined(separator: "\n")
        briefingImportantPatternsText = preferences.importantPatterns.joined(separator: "\n")
        briefingInterestPatternsText = preferences.interestPatterns.joined(separator: "\n")
    }

    func saveBriefingPreferences() {
        do {
            try briefingPreferencesStore.save(BriefingPreferences(
                userInstructions: briefingUserInstructions,
                academicInstructions: briefingAcademicInstructions,
                ignoredPatterns: .preferenceLines(briefingIgnoredPatternsText),
                importantPatterns: .preferenceLines(briefingImportantPatternsText),
                interestPatterns: .preferenceLines(briefingInterestPatternsText)
            ))
            // Some of these rules are applied when a briefing is shown, not when
            // it is written, so the archive can answer to the new ones at once.
            briefingArchive.reload()
            briefingPreferencesStatus = "저장했습니다. 보관함에 바로 반영되고, 나머지는 다음 실행부터 적용됩니다."
        } catch { briefingPreferencesStatus = error.localizedDescription }
    }

    func resetBriefingPreferences() {
        briefingUserInstructions = BriefingPreferences.defaultInstructions
        briefingAcademicInstructions = BriefingPreferences.defaultAcademicInstructions
        briefingIgnoredPatternsText = ""
        briefingImportantPatternsText = ""
        briefingInterestPatternsText = BriefingPreferences.defaultInterests.joined(separator: "\n")
        saveBriefingPreferences()
    }

    /// Full access now, not read-only: the 보관함 turns an item into an event.
    /// Everything written goes into the app's own 서울대 로컬 에이전트 calendar,
    /// so granting this cannot change an appointment the user already had.
    func requestCalendarAccess() {
        Task { [weak self] in
            do {
                try await CalendarWriter.requestEventAccess()
                await MainActor.run {
                    self?.calendarAuthorizationStatus = CalendarIntegration.authorizationDescription
                    self?.briefingPreferencesStatus = "캘린더 권한을 허용했습니다. 앞으로 14일 일정을 읽고, 보관함에서 고른 항목만 '\(AgentCalendar.title)' 캘린더에 넣습니다."
                    self?.refreshToday()
                }
            } catch {
                await MainActor.run {
                    self?.calendarAuthorizationStatus = CalendarIntegration.authorizationDescription
                    self?.briefingPreferencesStatus = error.localizedDescription
                }
            }
        }
    }

    func requestReminderAccess() {
        Task { [weak self] in
            do {
                try await CalendarWriter.requestReminderAccess()
                await MainActor.run {
                    self?.reminderAuthorizationStatus = CalendarIntegration.reminderAuthorizationDescription
                    self?.briefingPreferencesStatus = "미리 알림 권한을 허용했습니다. 보관함에서 고른 항목을 '\(AgentCalendar.title)' 목록에 넣습니다."
                }
            } catch {
                await MainActor.run {
                    self?.reminderAuthorizationStatus = CalendarIntegration.reminderAuthorizationDescription
                    self?.briefingPreferencesStatus = error.localizedDescription
                }
            }
        }
    }

    func saveOrganizationPreferences() {
        do {
            try organizationPreferencesStore.save(.init(
                automaticallyOrganize: automaticallyOrganizeTranscripts,
                defaultKind: organizationKind,
                detail: organizationDetailLevel,
                lecturePrompt: lectureOrganizationPrompt,
                meetingPrompt: meetingOrganizationPrompt,
                generalPrompt: generalOrganizationPrompt,
                model: summaryModel
            ))
            organizationPreferencesStatus = "저장했습니다. 다음 AI 정리부터 적용됩니다."
        } catch { organizationPreferencesStatus = error.localizedDescription }
    }

    func resetOrganizationPrompts() {
        lectureOrganizationPrompt = TranscriptOrganizationPreferences.defaultLecturePrompt
        meetingOrganizationPrompt = TranscriptOrganizationPreferences.defaultMeetingPrompt
        generalOrganizationPrompt = TranscriptOrganizationPreferences.defaultGeneralPrompt
        saveOrganizationPreferences()
    }

    func startBriefing() {
        guard !isRunning else { return }
        isRunning = true
        briefingStartedAt = Date()
        briefingETA = selectedRange.days.map { TimeInterval(max(300, $0 * 150)) } ?? 600
        phase = .collecting
        errorMessage = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let briefing = try await BriefingService().run(range: selectedRange) { [weak self] phase, detail, pendingItemCount in
                    await MainActor.run {
                        self?.phase = phase
                        self?.detail = detail
                        self?.updateBriefingETA(phase: phase, detail: detail, pendingItemCount: pendingItemCount)
                    }
                }
                phase = .completed
                // A run where Gmail failed and iMessage answered used to end on
                // the word 완료 and nothing else, with the reason buried in a
                // caption below thirty rows in another screen. Partial success is
                // still success, but it has to say what it missed.
                detail = briefing.failures.isEmpty
                    ? "브리핑 보관함에 저장했고 모델을 언로드했습니다."
                    : "브리핑 보관함에 저장했지만 \(briefing.failures.count)개 소스에 문제가 있었습니다. 아래를 확인해 주세요."
                lastBriefing = briefing
                briefingArchive.reload()
                briefingHealth = BriefingHealth.load()
                briefingETA = 0
            } catch AgentError.cancelled {
                phase = .cancelled
                detail = "작업을 중지하고 로컬 모델을 해제했습니다."
                briefingHealth = BriefingHealth.load()
            } catch {
                phase = .failed
                errorMessage = error.localizedDescription
                detail = "원본 서비스는 변경하지 않았습니다."
                briefingHealth = BriefingHealth.load()
            }
            isRunning = false
            task = nil
        }
    }

    private func updateBriefingETA(phase: RunPhase, detail: String, pendingItemCount: Int?) {
        let elapsed = Date().timeIntervalSince(briefingStartedAt ?? Date())
        switch phase {
        case .collecting:
            // The service reports the real number of items it is about to classify,
            // so the estimate no longer depends on the wording of a progress line.
            if let count = pendingItemCount {
                // Measured end to end (분류 + 한국어 편집) on the MoE model: 3.5s and
                // 3.8s per item on short items. Doubled for real message bodies,
                // which are up to 1,200 characters and cost more prefill.
                let perItem = briefingQualityMode == .thorough ? 6.0 : 6.5
                briefingETA = count == 0 ? 30 : max(60, Double(count) * perItem - elapsed)
            }
        case .classifying:
            briefingETA = max(45, (briefingETA ?? 300) - 15)
        case .writing:
            briefingETA = detail.contains("4/4") ? 10 : 45
        case .completed: briefingETA = 0
        default: break
        }
    }

    var briefingETAString: String {
        guard let eta = briefingETA, isRunning else { return "" }
        let minutes = max(1, Int(ceil(eta / 60)))
        return "예상 남은 시간 약 \(minutes)분"
    }

    func stopBriefing() {
        guard isRunning else { return }
        detail = "중단 요청 중 · 로컬 모델을 안전하게 해제하고 있습니다."
        task?.cancel()
    }

    func stopTranscription() {
        guard isTranscribing else { return }
        transcriptionDetail = "전사 중단 요청 중 · 음성 인식 프로세스를 종료하고 있습니다."
        transcriptionTask?.cancel()
        ActiveProcessRegistry.shared.terminateProcesses(containing: "scripts/transcribe_runner.py")
    }

    func stopTranscriptOrganization() {
        guard isOrganizingTranscript else { return }
        organizationDetail = "AI 정리 중단 요청 중 · 로컬 모델을 안전하게 해제하고 있습니다."
        organizationTask?.cancel()
    }

    func refreshToday() {
        todayEvents = CalendarSource().today()
        briefingArchive.reload()
    }

    /// Used to open the Notion page in a browser. The result lives in the app
    /// now, so this goes to the screen that shows it.
    func openLatestResult() {
        briefingArchive.reload()
        if let latest = briefingArchive.days.first { briefingArchive.selectedDateKey = latest.dateKey }
        section = .archive
    }

    func cancelProcessingItem(_ id: UUID) {
        if id == activeProcessingItemID {
            switch activeProcessingItem?.kind {
            case .transcription: stopTranscription()
            case .organization: stopTranscriptOrganization()
            case nil: break
            }
            return
        }
        processingQueueState.remove(id)
        processingQueue = processingQueueState.items
    }

    func clearWaitingProcessingItems() {
        let activeID = activeProcessingItemID
        processingQueueState.clearWaiting(activeID: activeID)
        processingQueue = processingQueueState.items
    }

    private func startNextProcessingItemIfNeeded() {
        // Only one local model job runs at a time. Anything queued while a job is
        // still finishing stays queued and is picked up by the next completion,
        // instead of being discarded to make room.
        guard !isTranscribing, !isOrganizingTranscript else { return }
        guard let work = processingQueueState.next(activeID: activeProcessingItemID) else { return }
        activeProcessingItemID = work.id
        switch work.payload {
        case .transcription(let payload): startTranscription(payload)
        case .organization(let payload): startOrganization(payload)
        }
    }

    private func finishActiveProcessingItem() {
        if let id = activeProcessingItemID {
            processingQueueState.remove(id)
            processingQueue = processingQueueState.items
            activeProcessingItemID = nil
        }
        startNextProcessingItemIfNeeded()
    }

    func transcribe(fileURL: URL) {
        // Capturing audio and running the ASR model are independent — the mic feeds
        // AVFoundation while the model runs in its own process — so the two overlap
        // freely. The one file that cannot be queued is the take still being written.
        guard fileURL.standardizedFileURL.path != audioRecorder.currentFileURL?.standardizedFileURL.path else {
            transcriptionError = "지금 녹음 중인 파일입니다. 녹음을 중지한 뒤 전사해 주세요."
            return
        }
        if MediaImporter.isVideo(fileURL) {
            importLocalVideo(fileURL)
            return
        }
        enqueueTranscription(ensureRecording(for: fileURL))
    }

    // MARK: - 영상 가져오기

    func importMediaFromURL() {
        let address = mediaURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !isImportingMedia else { return }
        guard MediaImporter.looksLikeMediaURL(address) else {
            mediaImportError = "http 또는 https로 시작하는 영상 주소를 입력해 주세요."
            return
        }
        runMediaImport(startingWith: "1/3 · 영상 정보를 확인하고 있습니다.") { importer, progress in
            try await importer.importRemoteVideo(address, progress: progress)
        } onSuccess: { [weak self] in
            self?.mediaURLText = ""
        }
    }

    private func importLocalVideo(_ url: URL) {
        runMediaImport(startingWith: "영상에서 오디오를 추출하고 있습니다.") { importer, progress in
            try await importer.importLocalVideo(url, progress: progress)
        } onSuccess: { }
    }

    private func runMediaImport(
        startingWith status: String,
        operation: @escaping @Sendable (MediaImporter, @escaping @Sendable (String) async -> Void) async throws -> MediaImporter.ImportedMedia,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard !isImportingMedia else {
            mediaImportError = "이미 영상을 가져오는 중입니다. 끝난 뒤에 다시 시도해 주세요."
            return
        }
        isImportingMedia = true
        mediaImportError = nil
        mediaImportStatus = status
        mediaImportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let media = try await operation(MediaImporter()) { [weak self] detail in
                    await MainActor.run { self?.mediaImportStatus = detail }
                }
                onSuccess()
                self.registerImportedMedia(media)
            } catch is CancellationError {
                self.mediaImportStatus = "영상 가져오기를 중단했습니다."
            } catch {
                self.mediaImportError = error.localizedDescription
                self.mediaImportStatus = ""
            }
            self.isImportingMedia = false
            self.mediaImportTask = nil
        }
    }

    /// The extracted audio lands in the app's own recordings folder, so it becomes
    /// an ordinary library item rather than a separately tracked external file.
    private func registerImportedMedia(_ media: MediaImporter.ImportedMedia) {
        let item = RecordingItem(
            id: "app:\(media.url.path)", source: .app,
            title: media.url.deletingPathExtension().lastPathComponent, url: media.url,
            date: Date(), duration: (try? AVAudioPlayer(contentsOf: media.url).duration) ?? 0,
            isLocallyAvailable: true
        )
        recordings.removeAll { $0.id == item.id }
        recordings.insert(item, at: 0)
        selectedRecordingID = item.id
        mediaImportStatus = "‘\(item.title)’을 보관함에 추가하고 전사 대기열에 넣었습니다."
        enqueueTranscription(item)
        refreshRecordings()
    }

    func stopMediaImport() {
        guard isImportingMedia else { return }
        mediaImportStatus = "영상 가져오기를 중단하는 중"
        mediaImportTask?.cancel()
    }

    // MARK: - 문서 인식

    func recognizeDocument(fileURL: URL, removingSourceAfterwards removeSource: Bool = false) {
        guard !isRecognizingDocument else {
            recognitionError = "문서를 인식하는 중입니다. 끝난 뒤에 넣어 주세요."
            return
        }
        guard DocumentRecognizer.isSupported(fileURL) else {
            recognitionError = "이미지 또는 PDF 파일만 인식할 수 있습니다."
            return
        }
        isRecognizingDocument = true
        recognitionError = nil
        recognizedNoteText = ""
        recognizedText = ""
        recognizedSourceName = fileURL.lastPathComponent
        let mode = documentMode
        recognizedTextIsMarkdown = mode.producesMarkdown
        recognitionStatus = mode == .precise ? "정밀 인식을 시작합니다." : "글자를 인식하고 있습니다."
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            defer { if removeSource { try? FileManager.default.removeItem(at: fileURL) } }
            do {
                if mode == .precise {
                    let result = try await DocumentParsingService().parse(fileURL: fileURL) { detail in
                        await MainActor.run { self.recognitionStatus = detail }
                    }
                    self.recognizedText = result.markdown
                    self.recognitionStatus = "수식·표 정밀 인식 완료 · \(result.pageCount)쪽 · \(result.markdown.count)자"
                } else {
                    // Vision recognition is synchronous CPU work; keep it off the main actor.
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await DocumentRecognizer().recognize(fileURL: fileURL) { detail in
                            await MainActor.run { self.recognitionStatus = detail }
                        }
                    }.value
                    self.recognizedText = result.text
                    let method = result.usedOpticalRecognition ? "글자 인식" : "PDF 내장 텍스트"
                    self.recognitionStatus = "\(method) 완료 · \(result.pageCount)쪽 · \(result.text.count)자"
                }
            } catch is CancellationError {
                self.recognitionStatus = "문서 인식을 중단했습니다."
            } catch {
                self.recognitionError = error.localizedDescription
                self.recognitionStatus = ""
            }
            self.isRecognizingDocument = false
            self.recognitionTask = nil
        }
    }

    func captureScreenAndRecognize() {
        guard !isRecognizingDocument else { return }
        recognitionError = nil
        recognitionStatus = "인식할 화면 영역을 드래그해 주세요."
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let url = try await DocumentRecognizer.captureScreenRegion() else {
                    self.recognitionStatus = "화면 캡처를 취소했습니다."
                    return
                }
                self.recognizeDocument(fileURL: url, removingSourceAfterwards: true)
            } catch {
                self.recognitionError = "화면을 캡처하지 못했습니다: \(error.localizedDescription)"
                self.recognitionStatus = ""
            }
        }
    }

    func stopDocumentRecognition() {
        guard isRecognizingDocument else { return }
        recognitionTask?.cancel()
    }

    func copyRecognizedText() {
        guard !recognizedText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recognizedText, forType: .string)
        recognitionStatus = "인식한 텍스트를 복사했습니다."
    }

    func copyRecognizedNote() {
        guard !recognizedNoteText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recognizedNoteText, forType: .string)
    }

    func saveRecognizedText() {
        guard !recognizedText.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "인식한 텍스트 저장"
        let stem = URL(fileURLWithPath: recognizedSourceName).deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = recognizedTextIsMarkdown ? "\(stem).md" : "\(stem).txt"
        panel.allowedContentTypes = recognizedTextIsMarkdown ? [.init(filenameExtension: "md") ?? .plainText] : [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(recognizedText.utf8).write(to: url, options: .atomic)
            recognitionStatus = "저장했습니다: \(url.lastPathComponent)"
        } catch {
            recognitionError = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    // MARK: - 누끼 따기

    /// Photos are processed one after another rather than concurrently: a single
    /// resident model is the whole point, and running two 2048² passes at once
    /// would only make both slower.
    func removeBackground(fileURLs: [URL]) {
        // Dropping onto a busy tab used to do nothing at all, with the drop well
        // still lighting up as though it had been accepted.
        guard !isRemovingBackground else {
            cutoutError = "누끼를 따는 중입니다. 끝나거나 중단한 뒤에 넣어 주세요."
            return
        }
        let (sources, truncated) = ToolWorkspace.expand(fileURLs, accepting: BackgroundRemovalService.supportedExtensions)
        guard !sources.isEmpty else {
            cutoutError = "이미지 파일만 누끼를 딸 수 있습니다."
            return
        }
        cutoutError = truncated ? "한 번에 500개까지만 처리합니다. 나머지는 다시 넣어 주세요." : ToolWorkspace.rejectionMessage(fileURLs, accepting: BackgroundRemovalService.supportedExtensions)
        // A new batch replaces the old one, so say what was thrown away. Losing a
        // dozen finished cutouts to a stray drop, silently, is the worst case here.
        cutoutItems = sources.map { CutoutItem(source: $0) }
        selectedCutoutIDs.removeAll()
        isRemovingBackground = true
        let model = mattingModel
        let opening = sources.count == 1 ? "배경을 지우고 있습니다." : "\(sources.count)장을 순서대로 처리하고 있습니다."
        cutoutStatus = opening + " 이전 결과는 지난 내역에서 볼 수 있습니다."
        cutoutTask = Task { [weak self] in
            guard let self else { return }
            let service = BackgroundRemovalService()
            var succeeded = 0
            var cancelled = false
            for (index, source) in sources.enumerated() {
                if Task.isCancelled { cancelled = true; break }
                let identifier = self.cutoutItems[index].id
                self.updateCutout(at: index) { $0.state = .working("준비 중") }
                let started = Date()
                do {
                    let output = try await service.removeBackground(from: source, model: model) { detail in
                        Task { @MainActor [weak self] in
                            guard let self, self.cutoutItems.indices.contains(index), self.cutoutItems[index].id == identifier else { return }
                            self.updateCutout(at: index) {
                                if case .working = $0.state { $0.state = .working(detail) }
                            }
                        }
                    }
                    self.updateCutout(at: index) {
                        $0.output = output
                        $0.state = .done(milliseconds: Int(Date().timeIntervalSince(started) * 1000))
                    }
                    succeeded += 1
                } catch is CancellationError {
                    self.updateCutout(at: index) { $0.state = .failed("중단했습니다.") }
                    cancelled = true
                    break
                } catch {
                    self.updateCutout(at: index) { $0.state = .failed(error.localizedDescription) }
                }
            }
            if cancelled {
                self.cutoutStatus = "누끼 따기를 중단했습니다."
            } else if succeeded == sources.count {
                self.cutoutStatus = "\(succeeded)장 완료했습니다."
            } else {
                self.cutoutStatus = "\(succeeded)/\(sources.count)장 완료했습니다."
            }
            self.isRemovingBackground = false
            self.cutoutTask = nil
            for index in self.cutoutItems.indices {
                if !self.cutoutItems[index].isFinished, self.cutoutItems[index].output == nil {
                    if cancelled { self.updateCutout(at: index) { if case .waiting = $0.state { $0.state = .failed("중단했습니다.") } } }
                }
                let item = self.cutoutItems[index]
                ToolHistory.shared.record(.init(id: item.id, tool: "Cutout", source: item.source, output: item.output,
                    saveName: Self.cutoutFileName(for: item), settings: model.title + " · 투명 PNG",
                    detail: item.isFinished ? "배경 제거 완료 · 투명 원본" : String(describing: item.state), succeeded: item.isFinished))
            }
        }
    }

    /// The 용량 줄이기 tab has had this since it shipped; the 누끼 tab was the odd
    /// one out, with no way to put the grid back to empty.
    func clearCutouts() {
        guard !isRemovingBackground else { return }
        cutoutItems = []
        selectedCutoutIDs.removeAll()
        cutoutError = nil
        cutoutStatus = "사진을 드롭하면 배경을 지운 PNG를 만듭니다."
    }

    func stopBackgroundRemoval() {
        guard isRemovingBackground else { return }
        cutoutStatus = "누끼 따기를 중단하는 중"
        cutoutTask?.cancel()
    }

    private func updateCutout(at index: Int, _ change: (inout CutoutItem) -> Void) {
        guard cutoutItems.indices.contains(index) else { return }
        change(&cutoutItems[index])
    }

    /// The background colour is applied here, not in the runner, so switching
    /// between 투명/흰색/직접 선택 is instant and never re-runs the model.
    func cutoutPNG(_ item: CutoutItem) -> Data? {
        guard let output = item.output, let image = CutoutComposer.load(output) else { return nil }
        // Full resolution: the card and the editor both work on a downscaled copy,
        // but what leaves the app is the original with the same crop applied.
        return CutoutComposer.pngData(from: item.edit.apply(to: image), background: cutoutBackgroundColor)
    }

    /// The editor hands its result back here so every export path — copy, save,
    /// save-all — picks it up from the one place the item lives.
    func updateCutoutEdit(_ id: CutoutItem.ID, to edit: PhotoEdit) {
        guard let index = cutoutItems.firstIndex(where: { $0.id == id }) else { return }
        cutoutItems[index].edit = edit
        cutoutStatus = edit.isIdentity
            ? "편집을 되돌렸습니다: \(cutoutItems[index].source.lastPathComponent)"
            : "편집을 적용했습니다: \(edit.summary ?? "")"
    }

    func updateCompressionEdit(_ id: CompressionItem.ID, to edit: PhotoEdit) {
        guard let index = compressionItems.firstIndex(where: { $0.id == id }) else { return }
        guard compressionItems[index].edit != edit else { return }
        compressionItems[index].edit = edit
        // A finished card would otherwise keep showing the result of the previous
        // framing while claiming the edit was applied. Back to waiting says plainly
        // that this one is going to be made again.
        if compressionItems[index].isFinished {
            compressionItems[index].state = .waiting
            compressionItems[index].output = nil
            compressionItems[index].compressedBytes = nil
            compressionItems[index].outputDetail = nil
        }
        compressionStatus = edit.isIdentity
            ? "편집을 되돌렸습니다. 줄이기를 다시 실행하면 반영됩니다."
            : "편집을 적용했습니다: \(edit.summary ?? "") · 줄이기를 다시 실행하면 반영됩니다"
    }

    var cutoutBackgroundColor: CGColor? {
        cutoutBackground.color(custom: cutoutCustomColorComponents)
    }

    /// Plain values rather than a `CGColor`, so a background thread can build
    /// the colour itself instead of having one handed across.
    var cutoutCustomColorComponents: CutoutBackground.Color? {
        Self.components(of: cutoutCustomColor)
    }

    func copyCutout(_ item: CutoutItem) {
        guard let data = cutoutPNG(item) else {
            cutoutError = "결과 이미지를 읽지 못했습니다."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        cutoutStatus = "클립보드에 복사했습니다: \(item.source.lastPathComponent)"
    }

    func saveCutout(_ item: CutoutItem) {
        guard let data = cutoutPNG(item) else {
            cutoutError = "결과 이미지를 읽지 못했습니다."
            return
        }
        let panel = NSSavePanel()
        panel.title = "누끼 이미지 저장"
        panel.nameFieldStringValue = Self.cutoutFileName(for: item)
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            ToolHistory.shared.markSaved(id: item.id, at: url)
            cutoutStatus = "저장했습니다: \(url.lastPathComponent)"
        } catch {
            cutoutError = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func saveAllCutouts() {
        saveCutouts(cutoutItems.filter(\.isFinished), title: "누끼 이미지를 저장할 폴더 선택")
    }

    func saveSelectedCutouts() {
        saveCutouts(cutoutItems.filter { selectedCutoutIDs.contains($0.id) && $0.isFinished }, title: "선택한 누끼 이미지를 저장할 폴더 선택")
    }

    private func saveCutouts(_ finished: [CutoutItem], title: String) {
        guard !finished.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "저장"
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        var saved = 0
        for item in finished {
            guard let data = cutoutPNG(item) else { continue }
            // Two photos from different folders can share a name, and writing
            // straight to it silently replaced the first cutout with the second.
            let target = CompressionWorkspace.uniqueURL(in: directory, name: Self.cutoutFileName(for: item))
            do {
                try data.write(to: target, options: .atomic)
                ToolHistory.shared.markSaved(id: item.id, at: target)
                saved += 1
            } catch {
                cutoutError = "저장하지 못했습니다: \(error.localizedDescription)"
            }
        }
        cutoutStatus = "\(saved)장을 저장했습니다: \(directory.lastPathComponent)"
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func toggleCutoutSelection(_ id: CutoutItem.ID) {
        if selectedCutoutIDs.contains(id) { selectedCutoutIDs.remove(id) } else { selectedCutoutIDs.insert(id) }
    }

    func selectAllCutouts() { selectedCutoutIDs = Set(cutoutItems.filter(\.isFinished).map(\.id)) }

    func deleteSelectedCutouts() {
        guard !isRemovingBackground, !selectedCutoutIDs.isEmpty else { return }
        let removing = cutoutItems.filter { selectedCutoutIDs.contains($0.id) }
        for output in removing.compactMap(\.output) { try? FileManager.default.removeItem(at: output) }
        cutoutItems.removeAll { selectedCutoutIDs.contains($0.id) }
        let count = removing.count
        selectedCutoutIDs.removeAll()
        cutoutStatus = "선택한 \(count)개 결과를 삭제했습니다. 원본은 그대로입니다."
    }

    private static func cutoutFileName(for item: CutoutItem) -> String {
        "\(item.source.deletingPathExtension().lastPathComponent)-누끼.png"
    }

    // MARK: - 용량 줄이기

    var compressionRequest: CompressionRequest {
        CompressionRequest(
            mode: compressionMode,
            level: compressionLevel,
            targetBytes: compressionTargetBytes,
            imageFormat: compressionImageFormat,
            videoCodec: compressionVideoCodec
        )
    }

    var compressionETAString: String {
        guard isCompressing, let compressionETA else { return "" }
        return CompressionProgressEstimator.text(compressionETA)
    }

    var compressionProgressValue: Double {
        guard !compressionItems.isEmpty else { return 0 }
        let settled = compressionItems.filter { $0.isFinished || $0.isFailed }.count
        let running = compressionItems.reduce(0.0) { total, item in
            if case .working(let fraction) = item.state { return total + fraction }
            return total
        }
        return min(1, (Double(settled) + running) / Double(compressionItems.count))
    }

    var compressionCountText: String {
        let settled = compressionItems.filter { $0.isFinished || $0.isFailed }.count
        return "\(settled)/\(compressionItems.count)개"
    }

    /// The running tally that makes the tab worth opening: what went in against
    /// what came out, over everything finished so far.
    var compressionSavingsText: String {
        let finished = compressionItems.filter(\.isFinished)
        guard !finished.isEmpty else { return "" }
        let before = finished.reduce(0) { $0 + $1.originalBytes }
        let after = finished.reduce(0) { $0 + ($1.compressedBytes ?? $1.originalBytes) }
        guard before > 0 else { return "" }
        let saved = Int(((1 - Double(after) / Double(before)) * 100).rounded())
        return "총 \(CompressionFormat.bytes(before)) → \(CompressionFormat.bytes(after)) (−\(saved)%)"
    }

    var lastCompressionSaveFolder: URL? {
        get {
            UserDefaults.standard.string(forKey: "compressionSaveFolder").map { URL(fileURLWithPath: $0) }
        }
        set {
            UserDefaults.standard.set(newValue?.path, forKey: "compressionSaveFolder")
        }
    }

    static func compressor(for kind: CompressionKind) -> any FileCompressor {
        switch kind {
        case .image: ImageCompressor()
        case .pdf: PDFCompressor()
        case .video: VideoCompressor()
        }
    }

    private static func outputExtension(for item: CompressionItem, request: CompressionRequest) -> String {
        switch item.kind {
        case .image: ImageOutputFormat.resolved(request.imageFormat, for: item.source).fileExtension
        case .pdf: "pdf"
        case .video: "mp4"
        }
    }

    // MARK: 배치 실행

    func compress(fileURLs: [URL]) {
        guard !isCompressing else {
            compressionError = "용량을 줄이는 중입니다. 끝나거나 중단한 뒤에 넣어 주세요."
            return
        }
        let (files, truncated) = CompressionWorkspace.expand(fileURLs)
        guard !files.isEmpty else {
            compressionError = "사진·PDF·영상 파일만 압축할 수 있습니다."
            return
        }
        compressionError = truncated ? "한 번에 500개까지만 처리합니다. 나머지는 다시 넣어 주세요." : ToolWorkspace.rejectionMessage(fileURLs, accepting: CompressionKind.imageExtensions.union(["pdf"]).union(MediaImporter.videoExtensions))
        compressionItems = files.map {
            CompressionItem(
                source: $0,
                kind: CompressionKind.of($0) ?? .image,
                originalBytes: CompressionWorkspace.fileSize(of: $0),
                originalDetail: ""
            )
        }
        selectedCompressionIDs.removeAll()
        startCompressionRun()
    }

    /// Runs whatever is already on screen again.
    ///
    /// Editing a photo puts its card back to 대기 중, because showing the previous
    /// framing while claiming the edit was applied would be a lie. Without this
    /// there would be no way to then produce the new version, and the card would
    /// sit at 대기 중 forever.
    func recompress() {
        guard !isCompressing, !compressionItems.isEmpty else { return }
        selectedCompressionIDs.removeAll()
        for index in compressionItems.indices {
            compressionItems[index].id = UUID()
            compressionItems[index].state = .waiting
            compressionItems[index].output = nil
            compressionItems[index].compressedBytes = nil
            compressionItems[index].outputDetail = nil
            compressionItems[index].note = nil
        }
        compressionError = nil
        startCompressionRun()
    }

    private func startCompressionRun() {
        let request = compressionRequest
        compressionHistorySettings = "\(compressionMode.title) · \(compressionLevel.title) · \(compressionImageFormat.title) · \(compressionVideoCodec.title) · 목표 \(CompressionFormat.bytes(compressionTargetBytes))"
        let total = compressionItems.count
        compressionEstimator = CompressionProgressEstimator()
        compressionETA = nil
        isCompressing = true
        compressionStatus = "\(total)개를 확인하고 있습니다."

        compressionTask = Task { [weak self] in
            guard let self else { return }
            let directory: URL
            do {
                directory = try CompressionWorkspace.directory()
            } catch {
                self.compressionError = "작업 폴더를 만들지 못했습니다: \(error.localizedDescription)"
                self.isCompressing = false
                self.compressionTask = nil
                return
            }
            await self.inspectAll(request: request)
            await self.runCompression(request: request, directory: directory)
            self.finishCompression(total: total)
        }
    }

    /// True while a card is waiting for a run that has to be asked for — after an
    /// edit, or after the settings changed since the last pass.
    var hasPendingCompression: Bool {
        !isCompressing && compressionItems.contains { if case .waiting = $0.state { true } else { false } }
    }

    /// Headers only, before any encoding starts: this is what makes the estimate
    /// size-aware, and it is also where a PDF's annotations get flagged while the
    /// user can still change their mind.
    private func inspectAll(request: CompressionRequest) async {
        for index in compressionItems.indices {
            if Task.isCancelled { return }
            let item = compressionItems[index]
            do {
                let info = try await Self.compressor(for: item.kind).inspect(item.source, request: request)
                updateCompression(at: index) {
                    $0.originalBytes = info.bytes
                    $0.originalDetail = info.detail
                }
                compressionEstimator.add(id: item.id, kind: item.kind, estimate: info.estimatedSeconds)
            } catch {
                updateCompression(at: index) { $0.state = .failed(error.localizedDescription) }
                continue
            }
            if item.kind == .pdf, let warning = PDFCompressor.annotationWarning(for: item.source) {
                updateCompression(at: index) { $0.note = warning }
            }
        }
        refreshCompressionETA(force: true)
        compressionStatus = "\(compressionItems.count)개를 압축하고 있습니다."
    }

    /// Photos and PDFs run several at a time because they are pure CPU work and
    /// this Mac has cores to spare — unlike the 누끼 tab, there is no single
    /// resident model to serialise around. Videos still go one at a time: there
    /// is one hardware encoder, and queueing two only makes both slower.
    private func runCompression(request: CompressionRequest, directory: URL) async {
        let pending = compressionItems.indices.filter { !compressionItems[$0].isFailed }
        let videos = pending.filter { compressionItems[$0].kind == .video }
        let rest = pending.filter { compressionItems[$0].kind != .video }
        let limit = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

        await withTaskGroup(of: Void.self) { lanes in
            lanes.addTask { [weak self] in
                guard let self else { return }
                for index in videos {
                    if Task.isCancelled { return }
                    await self.compressOne(at: index, request: request, directory: directory)
                }
            }
            lanes.addTask { [weak self] in
                guard let self else { return }
                await withTaskGroup(of: Void.self) { group in
                    var next = 0
                    while next < min(limit, rest.count) {
                        let index = rest[next]
                        next += 1
                        group.addTask { await self.compressOne(at: index, request: request, directory: directory) }
                    }
                    while await group.next() != nil {
                        guard !Task.isCancelled, next < rest.count else { continue }
                        let index = rest[next]
                        next += 1
                        group.addTask { await self.compressOne(at: index, request: request, directory: directory) }
                    }
                }
            }
        }
    }

    private func compressOne(at index: Int, request: CompressionRequest, directory: URL) async {
        guard compressionItems.indices.contains(index) else { return }
        let item = compressionItems[index]
        let identifier = item.id
        let warning = item.note
        let destination = CompressionWorkspace.outputURL(
            for: item.source, extension: Self.outputExtension(for: item, request: request), in: directory
        )
        let started = Date()
        updateCompression(at: index) { $0.state = .working(0) }
        // Per item: the crop belongs to this photo, not to the run.
        var itemRequest = request
        itemRequest.edit = item.edit
        do {
            let outcome = try await Self.compressor(for: item.kind).compress(
                item.source, to: destination, request: itemRequest
            ) { fraction, remaining in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // These hops are unstructured, so one can land after the
                    // file has already finished; without the guard a late report
                    // would flip a completed card back to "처리 중".
                    guard self.compressionItems.indices.contains(index), self.compressionItems[index].id == identifier else { return }
                    self.updateCompression(at: index) {
                        if case .working = $0.state { $0.state = .working(fraction) }
                    }
                    if let remaining { self.compressionEstimator.note(id: identifier, remaining: remaining) }
                    self.refreshCompressionETA()
                }
            }
            updateCompression(at: index) {
                $0.output = outcome.output
                $0.compressedBytes = outcome.bytes
                $0.outputDetail = outcome.detail
                // A warning raised while reading the file still matters once it
                // is done — the annotations really are gone from the result.
                $0.note = outcome.note ?? warning
                $0.state = .done
            }
            compressionEstimator.finish(id: identifier, actual: Date().timeIntervalSince(started))
        } catch is CancellationError {
            updateCompression(at: index) { $0.state = .skipped("중단했습니다.") }
            compressionEstimator.drop(id: identifier)
        } catch {
            updateCompression(at: index) { $0.state = .failed(error.localizedDescription) }
            compressionEstimator.drop(id: identifier)
        }
        let completed = compressionItems[index]
        ToolHistory.shared.record(.init(id: completed.id, tool: "Compress", source: completed.source, output: completed.output,
            saveName: CompressionWorkspace.saveName(for: completed), settings: compressionHistorySettings,
            detail: "\(completed.specText) · \(completed.statusText)", succeeded: completed.isFinished))
        refreshCompressionETA(force: true)
    }

    private func finishCompression(total: Int) {
        for index in compressionItems.indices {
            if case .waiting = compressionItems[index].state { compressionItems[index].state = .skipped("중단했습니다.") }
        }
        ToolHistory.shared.record(compressionItems.map { item in
            .init(id: item.id, tool: "Compress", source: item.source, output: item.output,
                saveName: CompressionWorkspace.saveName(for: item), settings: compressionHistorySettings,
                detail: "\(item.specText) · \(item.statusText)", succeeded: item.isFinished)
        })
        let succeeded = compressionItems.filter(\.isFinished).count
        if Task.isCancelled {
            compressionStatus = "용량 줄이기를 중단했습니다."
        } else if succeeded == total {
            compressionStatus = "\(succeeded)개를 마쳤습니다. \(compressionSavingsText)"
        } else {
            compressionStatus = "\(succeeded)/\(total)개를 마쳤습니다."
        }
        isCompressing = false
        compressionETA = nil
        compressionTask = nil
    }

    func stopCompression() {
        guard isCompressing else { return }
        compressionStatus = "중단하는 중"
        compressionTask?.cancel()
        // ffmpeg is the only helper here that runs long enough to need chasing.
        // FFmpegHandle's cancellation handler terminates only this encode.
    }

    private func updateCompression(at index: Int, _ change: (inout CompressionItem) -> Void) {
        guard compressionItems.indices.contains(index) else { return }
        change(&compressionItems[index])
    }

    /// Throttled: ffmpeg reports twice a second and four photos can finish at
    /// once, and republishing the estimate on every one of those makes the whole
    /// tab flicker.
    private func refreshCompressionETA(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(compressionETAUpdatedAt) >= 0.25 else { return }
        compressionETAUpdatedAt = now
        compressionETA = compressionEstimator.isEmpty ? nil : compressionEstimator.remainingSeconds
    }

    // MARK: 저장

    func saveCompressed(_ item: CompressionItem) {
        guard let output = item.output else {
            compressionError = "결과 파일을 찾지 못했습니다."
            return
        }
        let panel = NSSavePanel()
        panel.title = "압축한 파일 저장"
        panel.nameFieldStringValue = CompressionWorkspace.saveName(for: item)
        if let folder = lastCompressionSaveFolder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LocalFileStorage.copyPreservingDestination(output, to: url)
            ToolHistory.shared.markSaved(id: item.id, at: url)
            lastCompressionSaveFolder = url.deletingLastPathComponent()
            compressionStatus = "저장했습니다: \(url.lastPathComponent)"
        } catch {
            compressionError = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func saveAllCompressed() {
        saveCompressed(compressionItems.filter(\.isFinished), title: "압축한 파일을 저장할 폴더 선택")
    }

    func saveSelectedCompressed() {
        saveCompressed(compressionItems.filter { selectedCompressionIDs.contains($0.id) && $0.isFinished }, title: "선택한 파일을 저장할 폴더 선택")
    }

    private func saveCompressed(_ finished: [CompressionItem], title: String) {
        guard !finished.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "저장"
        if let folder = lastCompressionSaveFolder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        var saved = 0
        for item in finished {
            guard let output = item.output else { continue }
            let target = CompressionWorkspace.uniqueURL(in: directory, name: CompressionWorkspace.saveName(for: item))
            do {
                try FileManager.default.copyItem(at: output, to: target)
                ToolHistory.shared.markSaved(id: item.id, at: target)
                saved += 1
            } catch {
                compressionError = "저장하지 못했습니다: \(error.localizedDescription)"
            }
        }
        lastCompressionSaveFolder = directory
        compressionStatus = "\(saved)개를 저장했습니다: \(directory.lastPathComponent)"
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func toggleCompressionSelection(_ id: CompressionItem.ID) {
        if selectedCompressionIDs.contains(id) { selectedCompressionIDs.remove(id) } else { selectedCompressionIDs.insert(id) }
    }

    func selectAllCompressed() { selectedCompressionIDs = Set(compressionItems.filter(\.isFinished).map(\.id)) }

    func deleteSelectedCompressed() {
        guard !isCompressing, !selectedCompressionIDs.isEmpty else { return }
        let removing = compressionItems.filter { selectedCompressionIDs.contains($0.id) }
        for output in removing.compactMap(\.output) { try? FileManager.default.removeItem(at: output) }
        compressionItems.removeAll { selectedCompressionIDs.contains($0.id) }
        let count = removing.count
        selectedCompressionIDs.removeAll()
        compressionStatus = "선택한 \(count)개 결과를 삭제했습니다. 원본은 그대로입니다."
    }

    /// Two photos from different folders can share a name, and a batch save must
    /// not have the second silently replace the first.
    func copyCompressed(_ item: CompressionItem) {
        guard let output = item.output else {
            compressionError = "결과 파일을 찾지 못했습니다."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([output as NSURL])
        compressionStatus = "클립보드에 복사했습니다: \(item.source.lastPathComponent)"
    }

    /// The Photos import runs in the view (that is where the picker lives) but
    /// the status line belongs to the controller, so it gets one way in.
    func reportCompressionStatus(_ text: String) {
        compressionStatus = text
    }

    func clearCompression() {
        guard !isCompressing else { return }
        compressionItems = []
        selectedCompressionIDs.removeAll()
        compressionError = nil
        compressionStatus = "사진·PDF·영상을 넣으면 이 Mac에서 용량을 줄입니다."
    }

    // MARK: 색 저장

    private static func components(of color: Color) -> CutoutBackground.Color? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return CutoutBackground.Color(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    fileprivate static func hex(from color: Color) -> String {
        guard let parts = components(of: color) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(parts.red * 255), Int(parts.green * 255), Int(parts.blue * 255))
    }

    fileprivate static func color(fromHex hex: String?) -> Color? {
        guard var value = hex?.trimmingCharacters(in: .whitespaces), value.hasPrefix("#") else { return nil }
        value.removeFirst()
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    /// Reuses the same one-at-a-time queue and Korean note prompts the transcript
    /// organiser uses, so recognised slides become notes in the same house style.
    func organizeRecognizedText() {
        guard !recognizedText.isEmpty, !isRecognizingDocument else { return }
        let run = TranscriptRun(
            id: UUID(), recordingID: "ocr:\(UUID().uuidString)", createdAt: .now, completedAt: .now,
            duration: 0, settings: .init(), backend: nil, text: recognizedText, segments: [],
            engineVersion: "vision-ocr", isLegacy: false
        )
        recognizedNoteText = ""
        enqueueOrganization(run, titleOverride: recognizedSourceName.isEmpty ? "인식한 문서" : recognizedSourceName)
    }

    private func enqueueTranscription(_ recording: RecordingItem) {
        let item = ProcessingQueueItem(
            id: UUID(),
            kind: .transcription,
            title: recording.title,
            detail: "\(asrModel.title) · \(transcriptionLanguage.title)",
            enqueuedAt: Date()
        )
        let payload = TranscriptionQueuePayload(
            recording: recording,
            asrModel: asrModel,
            diarization: diarization,
            timestampMode: transcriptionTimestampMode,
            language: transcriptionLanguage
        )
        processingQueueState.enqueue(.init(item: item, payload: .transcription(payload)))
        processingQueue = processingQueueState.items
        startNextProcessingItemIfNeeded()
    }

    private func startTranscription(_ payload: TranscriptionQueuePayload) {
        guard !isTranscribing, !isOrganizingTranscript else {
            // Leave the work queued; the running job's completion restarts it.
            activeProcessingItemID = nil
            return
        }
        let recording = payload.recording
        let fileURL = recording.url
        isTranscribing = true
        transcriptionError = nil
        transcriptionText = ""
        transcriptionStep = 1
        transcriptionStartedAt = Date()
        transcriptionETA = nil
        transcribingRecordingID = recording.id
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let startedAt = Date()
                let settings = TranscriptionSettingsSnapshot(asrModel: payload.asrModel, diarization: payload.diarization, timestampMode: payload.timestampMode, language: payload.language)
                let result = try await TranscriptionService().transcribe(fileURL, asrModel: payload.asrModel, diarization: payload.diarization, timestampMode: payload.timestampMode, language: payload.language) { [weak self] detail in
                    await MainActor.run {
                        self?.transcriptionDetail = detail
                        if let prefix = detail.split(separator: " ").first, let step = Int(prefix.split(separator: "/").first ?? "") {
                            self?.transcriptionStep = max(self?.transcriptionStep ?? 0, step)
                            self?.updateETA(recordingDuration: recording.duration, asrModel: payload.asrModel, diarization: payload.diarization)
                        }
                    }
                }
                let completedAt = Date()
                let run = TranscriptRun(
                    id: UUID(), recordingID: recording.id, createdAt: startedAt, completedAt: completedAt,
                    duration: completedAt.timeIntervalSince(startedAt), settings: settings, backend: result.backend,
                    text: result.text, segments: result.segments, engineVersion: "mlx-qwen3-asr-v2", isLegacy: false
                )
                transcriptArchive.runsByRecording[recording.id, default: []].append(run)
                // A save failure here would silently lose a transcript that took minutes.
                if let failure = transcriptArchive.saveReportingFailure() {
                    transcriptionError = failure
                }
                selectedTranscriptRunID = run.id
                transcriptionText = run.text
                if automaticallyOrganizeTranscripts { enqueueOrganization(run) }
                transcriptionStep = 4
                transcriptionDetail = "전사 완료. 모델 프로세스가 종료되어 메모리를 반환했습니다."
            } catch is CancellationError {
                transcriptionError = nil
                transcriptionDetail = "전사를 중단했고 음성 인식 프로세스를 종료했습니다. 기존 전사 결과는 유지됩니다."
            } catch {
                transcriptionError = error.localizedDescription
                transcriptionDetail = "전사에 실패했습니다. 파일과 화자 분리 설정을 확인해 주세요."
            }
            isTranscribing = false
            transcribingRecordingID = nil
                transcriptionETA = nil
                transcriptionTask = nil
                finishActiveProcessingItem()
            }
        }

    private func updateETA(recordingDuration duration: TimeInterval, asrModel: ASRModelChoice, diarization: DiarizationChoice) {
        guard let startedAt = transcriptionStartedAt, transcriptionStep >= 2, duration > 0 else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        // Conservative local-MLX estimate, refined as each stage finishes.
        let asrFactor: Double = switch asrModel {
        case .qwen06B8Bit: 0.05
        case .qwen06B: 0.10
        case .qwen17B: 0.09
        case .qwen17BSpeculative: 0.50
        }
        let expected = duration * (asrFactor + (diarization.isEnabled ? 0.25 : 0)) + 8
        transcriptionETA = max(0, expected - elapsed)
    }

    func transcribe(recording: RecordingItem) {
        selectedRecordingID = recording.id
        selectLatestTranscript(for: recording)
        guard recording.isLocallyAvailable else {
            transcriptionError = "이 녹음은 iCloud에만 있습니다. 음성 메모 앱에서 먼저 재생해 원본을 다운로드한 뒤 새로고침해 주세요."
            return
        }
        transcribe(fileURL: recording.url)
    }

    func selectedTranscriptFor(_ recording: RecordingItem) -> String? {
        if let current = transcriptArchive.runs(for: recording.id).first { return current.text }
        let legacyID = "voice:file:\(recording.url.path)"
        guard let legacy = transcriptArchive.runs(for: legacyID).first else { return nil }
        var migrated = legacy
        migrated.recordingID = recording.id
        transcriptArchive.runsByRecording[recording.id, default: []].append(migrated)
        transcriptArchive.save()
        return migrated.text
    }

    func transcriptRuns(for recording: RecordingItem) -> [TranscriptRun] {
        _ = selectedTranscriptFor(recording)
        return transcriptArchive.runs(for: recording.id)
    }

    func selectRecording(_ recording: RecordingItem) {
        // Playback belongs to the take on screen: moving the selection must not
        // leave the previous recording playing behind the new one.
        recordingPlayer.stopUnless(recording)
        selectedRecordingID = recording.id
        selectLatestTranscript(for: recording)
    }

    func selectTranscript(_ id: UUID) {
        selectedTranscriptRunID = id
        selectedOrganizationRunID = nil
        transcriptionText = selectedTranscriptRun?.text ?? ""
    }

    private func selectLatestTranscript(for recording: RecordingItem) {
        let run = transcriptRuns(for: recording).first
        selectedTranscriptRunID = run?.id
        selectedOrganizationRunID = nil
        transcriptionText = run?.text ?? ""
    }

    func organizationRuns(for transcript: TranscriptRun) -> [TranscriptOrganizationRun] {
        transcriptArchive.organizations(for: transcript.id)
    }

    func organizationPrompt(for kind: TranscriptOrganizationKind) -> String {
        switch kind {
        case .automatic: lectureOrganizationPrompt
        case .lecture: lectureOrganizationPrompt + "\n사용자가 강의로 지정했다. 강의 출력 형식을 사용한다."
        case .meeting: meetingOrganizationPrompt + "\n사용자가 회의로 지정했다. 회의 출력 형식을 사용한다."
        case .seminar: generalOrganizationPrompt + "\n사용자가 세미나로 지정했다. 세미나 출력 형식을 사용한다."
        case .general: generalOrganizationPrompt
        }
    }

    func organizeSelectedTranscript() {
        guard let run = selectedTranscriptRun else { return }
        enqueueOrganization(run)
    }

    private func enqueueOrganization(_ run: TranscriptRun, titleOverride: String? = nil) {
        // The reader's own name for the take, so an exported transcript is
        // filed as 회로이론 3주차 rather than as 녹음 2026-08-25 154002.
        let recordingTitle = titleOverride
            ?? recordings.first { $0.id == run.recordingID }.map { recordingOrganizer.displayTitle(for: $0) }
            ?? "저장된 전사"
        let item = ProcessingQueueItem(
            id: UUID(),
            kind: .organization,
            title: recordingTitle,
            detail: "\(organizationKind.title) · \(organizationDetailLevel.title) · \(summaryModel)",
            enqueuedAt: Date()
        )
        let payload = OrganizationQueuePayload(
            transcript: run,
            recordingTitle: recordingTitle,
            kind: organizationKind,
            detail: organizationDetailLevel,
            prompt: organizationPrompt(for: organizationKind),
            model: summaryModel
        )
        processingQueueState.enqueue(.init(item: item, payload: .organization(payload)))
        processingQueue = processingQueueState.items
        startNextProcessingItemIfNeeded()
    }

    private func startOrganization(_ payload: OrganizationQueuePayload) {
        guard !isTranscribing, !isOrganizingTranscript else {
            activeProcessingItemID = nil
            return
        }
        organizationTask = Task { [weak self] in
            await self?.organizeTranscript(payload)
            self?.finishActiveProcessingItem()
        }
    }

    private func organizeTranscript(_ payload: OrganizationQueuePayload) async {
        let run = payload.transcript
        isOrganizingTranscript = true
        organizationError = nil
        organizationStartedAt = Date()
        organizationETA = TranscriptOrganizer.estimatedDuration(for: run)
        let kind = payload.kind
        let detailLevel = payload.detail
        let prompt = payload.prompt
        let organizer = TranscriptOrganizer(model: payload.model)
        defer {
            isOrganizingTranscript = false
            organizationETA = nil
        }
        do {
            let startedAt = Date()
            let text = try await organizer.organize(transcript: run, detail: detailLevel, prompt: prompt) { [weak self] detail in
                await MainActor.run {
                    self?.organizationDetail = detail
                    if let started = self?.organizationStartedAt, let eta = self?.organizationETA {
                        self?.organizationETA = max(10, eta - Date().timeIntervalSince(started))
                        self?.organizationStartedAt = Date()
                    }
                }
            }
            let completedAt = Date()
            let organization = TranscriptOrganizationRun(
                id: UUID(), transcriptRunID: run.id, createdAt: startedAt, completedAt: completedAt,
                duration: completedAt.timeIntervalSince(startedAt), kind: kind, detail: detailLevel,
                model: payload.model, promptSnapshot: prompt, text: text
            )
            if run.recordingID.hasPrefix("ocr:") {
                // Recognised text is not a recording, so it gets no archive entry;
                // the result belongs to the document panel that asked for it.
                recognizedNoteText = text
            } else {
                transcriptArchive.organizationsByTranscript[run.id.uuidString, default: []].append(organization)
                if let failure = transcriptArchive.saveReportingFailure() { organizationError = failure }
                selectedOrganizationRunID = organization.id
            }
            organizationDetail = "AI 정리 완료. 로컬 모델을 언로드하고 있습니다."
        } catch is CancellationError {
            organizationError = nil
            organizationDetail = "AI 정리를 중단했고 로컬 모델을 해제했습니다. 전사 원문과 기존 정리는 유지됩니다."
        } catch {
            organizationError = error.localizedDescription
            organizationDetail = "AI 정리에 실패했습니다. 전사 원문은 그대로 보존되어 있습니다."
        }
        await organizer.unload()
        organizationTask = nil
    }

    func copyTranscription() {
        guard !selectedTranscript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedTranscript, forType: .string)
    }

    func copySelectedOrganization() {
        guard let text = selectedOrganizationRun?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func toggleRecording() {
        if audioRecorder.isRecording {
            mostRecentRecording = audioRecorder.stop()
            refreshRecordings(selecting: mostRecentRecording)
            reportRecordingStatus(mostRecentRecording == nil ? "녹음을 저장하지 못했습니다." : "녹음이 저장되었습니다. 전사 버튼으로 바로 전사할 수 있습니다.")
            return
        }
        // 앞 녹음이 어떻게 끝났다는 말은 새 녹음이 시작되는 순간 사실이 아니게 된다.
        reportRecordingStatus(nil)
        Task {
            if await audioRecorder.start() {
                reportRecordingStatus("녹음 중입니다. 전사는 녹음과 같이 돌릴 수 있습니다.")
            }
        }
    }

    /// 사람이 누르지 않았는데 녹음이 끝났다 — 뚜껑을 닫았거나, Mac이 잠들었거나, 마이크가
    /// 사라졌거나. 끝난 자리에 사람이 없었을 수 있으므로, 보관함에 넣어 고르고 왜 끝났는지
    /// 화면에 남긴다.
    private func recordingEndedOnItsOwn(_ url: URL?, _ message: String) {
        mostRecentRecording = url
        refreshRecordings(selecting: url)
        reportRecordingStatus(message)
    }

    /// 녹음에 대한 말은 녹음의 줄에 적는다. 전사가 도는 중에도 지워지지 않고, 전사가
    /// 돌지 않을 때에도 보인다.
    private func reportRecordingStatus(_ status: String?) {
        recordingStatus = status
    }

    /// Scanning the Voice Memos database and probing durations is file I/O, so it
    /// runs off the main actor; blocking here froze app launch and every rename,
    /// delete, or refresh once the library grew.
    func refreshRecordings(selecting url: URL? = nil) {
        recordingLibraryStatus = "녹음 보관함을 불러오는 중"
        // A take still being written has no finalised MPEG-4 container, so it would
        // sit in the library as a recording that can only fail — and the repair pass
        // inside `load` must not touch a file the recorder still has open, which is
        // why this is read before the scan starts rather than after it.
        let recording = audioRecorder.currentFileURL
        let report: @Sendable (String) -> Void = { [weak self] status in
            Task { @MainActor [weak self] in self?.recordingLibraryStatus = status }
        }
        Task { [weak self] in
            let library = await Task.detached(priority: .utility) {
                RecordingLibrary.load(skipping: recording, status: report)
            }.value
            guard let self else { return }
            let external = self.transcriptArchive.externalRecordings.values.compactMap(\.item)
            let inProgress = recording?.standardizedFileURL.path
            self.recordings = Dictionary((library + external).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                .values.filter { $0.url.standardizedFileURL.path != inProgress }
                .sorted { $0.date > $1.date }
            self.recordingLibraryStatus = self.recordings.isEmpty
                ? "녹음 파일을 찾지 못했습니다. Voice Memos 접근 권한을 확인해 주세요."
                : "\(self.recordings.count)개 녹음"
            if let url, let match = self.recordings.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                self.selectedRecordingID = match.id
            }
            // A take that left the library — deleted elsewhere, or on a volume that
            // went away — must not keep playing behind a window that no longer
            // shows it, where nothing can stop it.
            if let playing = self.recordingPlayer.recordingID, !self.recordings.contains(where: { $0.id == playing }) {
                self.recordingPlayer.stop()
            }
        }
    }

    private func ensureRecording(for url: URL) -> RecordingItem {
        if let existing = recordings.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { return existing }
        let standardized = url.standardizedFileURL
        let id = "file:\(standardized.path)"
        let date = (try? standardized.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        let duration = (try? AVAudioPlayer(contentsOf: standardized).duration) ?? 0
        let metadata = ArchivedRecordingMetadata(
            id: id, title: standardized.deletingPathExtension().lastPathComponent,
            path: standardized.path, date: date, duration: duration
        )
        transcriptArchive.externalRecordings[id] = metadata
        transcriptArchive.save()
        let item = metadata.item ?? RecordingItem(id: id, source: .file, title: metadata.title, url: standardized, date: date, duration: duration, isLocallyAvailable: true)
        recordings.append(item)
        recordings.sort { $0.date > $1.date }
        selectedRecordingID = id
        return item
    }

    func requestVoiceMemoDownload(_ recording: RecordingItem) {
        guard recording.source == .voiceMemos, !recording.isLocallyAvailable,
              !downloadingRecordingIDs.contains(recording.id) else { return }
        downloadingRecordingIDs.insert(recording.id)
        selectedRecordingID = recording.id
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recording.title, forType: .string)
        recordingLibraryStatus = "음성 메모에서 ‘\(recording.title)’을 눌러 주세요 · 완료는 자동 확인합니다"
        let applicationURL = URL(fileURLWithPath: "/System/Applications/VoiceMemos.app")
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init()) { _, error in
            if let error {
                Task { @MainActor in
                    self.downloadingRecordingIDs.remove(recording.id)
                    self.transcriptionError = "음성 메모 앱을 열지 못했습니다: \(error.localizedDescription)"
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<90 {
                try? await Task.sleep(for: .seconds(2))
                let size = (try? recording.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > 0 {
                    self.refreshRecordings()
                    self.downloadingRecordingIDs.remove(recording.id)
                    self.recordingLibraryStatus = "다운로드 완료 · \(self.recordings.count)개 녹음"
                    return
                }
            }
            self.downloadingRecordingIDs.remove(recording.id)
            self.recordingLibraryStatus = "다운로드 대기 시간이 지났습니다 · 음성 메모에서 항목 상태를 확인해 주세요"
        }
    }

    func rename(_ recording: RecordingItem, to proposedName: String) {
        guard recording.source == .app else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let destination = recording.url.deletingLastPathComponent().appendingPathComponent(safeName).appendingPathExtension(recording.url.pathExtension)
        do {
            try FileManager.default.moveItem(at: recording.url, to: destination)
            if let runs = transcriptArchive.runsByRecording.removeValue(forKey: recording.id) {
                let destinationID = "app:\(destination.path)"
                transcriptArchive.runsByRecording[destinationID] = runs.map {
                    var value = $0; value.recordingID = destinationID; return value
                }
                if let failure = transcriptArchive.saveReportingFailure() { transcriptionError = failure }
            }
            refreshRecordings(selecting: destination)
        } catch { transcriptionError = "이름을 변경하지 못했습니다: \(error.localizedDescription)" }
    }

    func delete(_ recording: RecordingItem) {
        guard recording.source == .app else { return }
        do {
            recordingPlayer.stop(ifPlaying: recording)
            try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
            transcriptArchive.runsByRecording.removeValue(forKey: recording.id)
            transcriptArchive.save()
            if selectedRecordingID == recording.id { selectedRecordingID = nil; transcriptionText = "" }
            refreshRecordings()
        } catch { transcriptionError = "녹음을 휴지통으로 옮기지 못했습니다: \(error.localizedDescription)" }
    }

    func chooseVoiceMemosFolder() {
        let panel = NSOpenPanel()
        panel.title = "Voice Memos의 Recordings 폴더 선택"
        panel.message = "Voice Memos 녹음을 읽기 전용으로 표시하기 위해 Recordings 폴더를 선택하세요."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = RecordingLibrary.voiceMemosDirectory()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        RecordingLibrary.saveVoiceMemosDirectory(url)
        refreshRecordings()
    }

}

struct MenuContentView: View {
    @ObservedObject var controller: AutomationController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                Image(systemName: controller.isRunning ? "arrow.triangle.2.circlepath.circle.fill" : "graduationcap.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.snuBlueLabel)
                    .symbolEffect(.rotate, options: .repeating, isActive: controller.isRunning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("서울대 로컬 에이전트").font(.headline)
                    Text(controller.phase.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: Spacing.s) {
                ProgressView(value: controller.progressValue).tint(.snuBlue)
                VStack(alignment: .leading, spacing: 5) {
                    ProgressStep(title: "새 항목 수집", isCurrent: controller.phase == .collecting, isDone: controller.phase == .classifying || controller.phase == .writing || controller.phase == .completed)
                    ProgressStep(title: "로컬 모델 로드 · 분류", isCurrent: controller.phase == .classifying, isDone: controller.phase == .writing || controller.phase == .completed)
                    ProgressStep(title: "보관함에 저장", isCurrent: controller.phase == .writing, isDone: controller.phase == .completed)
                    ProgressStep(title: "모델 언로드", isCurrent: controller.phase == .completed, isDone: controller.phase == .completed)
                }
                Text(controller.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = controller.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
                Button(controller.isRunning ? "중지" : "인박스 정리 시작",
                       systemImage: controller.isRunning ? "stop.fill" : "tray.full.fill") {
                    controller.isRunning ? controller.stopBriefing() : controller.startBriefing()
                }
                .buttonStyle(.bordered)
                .tint(controller.isRunning ? .red : .snuBlue)
                .controlSize(.small)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(Radius.card)

            // 창을 닫아도 녹음은 계속 돈다 — 이 앱은 메뉴 막대에 남는 앱이니 그것이 맞다.
            // 다만 창이 없으면 멈출 방법도, 돌고 있다는 표시도 없었다. 강의 하나가 통째로
            // 마이크를 열어 둔 채 남는 길이라 여기에 둔다. 녹음 중이 아니면 나오지 않는다.
            if controller.audioRecorder.isRecording {
                HStack(spacing: Spacing.m) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(Color.red)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("녹음 중").font(.subheadline)
                        Text(controller.audioRecorder.elapsed.playbackTimeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("중지") { controller.toggleRecording() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassPanel(Radius.card)
            }

            HStack(spacing: Spacing.m) {
                Image(systemName: controller.dictation.isRecording ? "mic.fill" : "mic")
                    .foregroundStyle(controller.dictation.isRecording ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.snuBlueLabel))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("받아쓰기").font(.subheadline)
                    Text(controller.dictation.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if controller.dictation.isTranscribing {
                    ProgressView().controlSize(.small)
                } else {
                    Button(controller.dictation.isRecording ? "중지" : "시작") { controller.dictation.toggle() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(controller.dictation.isRecording ? .red : nil)
                }
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(Radius.card)

            if let error = controller.dictation.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }

            Divider()

            HStack(spacing: Spacing.s) {
                Button("앱 열기", systemImage: "macwindow") {
                    dismiss()
                    DispatchQueue.main.async {
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.snuBlue)
                Button("설정…", systemImage: "gearshape") {
                    dismiss()
                    DispatchQueue.main.async { openSettings() }
                }
                .buttonStyle(.bordered)
                .help("⌘, 로도 열 수 있습니다")
                // 코드를 고쳐 번들을 다시 만든 뒤 끄고 켜는 일이 잦다. 끄는 것은 정상 종료
                // 경로 그대로이고, 다시 켜는 것은 떼어 놓은 셸이 한다. 보던 화면으로 돌아온다.
                Button("앱 재시작", systemImage: "arrow.clockwise") {
                    let section = controller.section.rawValue
                    dismiss()
                    DispatchQueue.main.async { AppRelauncher.relaunch(section: section) }
                }
                .buttonStyle(.bordered)
                .help("앱을 끄고 같은 번들을 다시 켭니다. 번들을 다시 만들었으면 새 코드로 뜹니다")
                Spacer()
                Button("종료", role: .destructive) { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(Spacing.l)
        .frame(width: 380)
        .animation(.appControl, value: controller.phase)
        .animation(.appControl, value: controller.dictation.isRecording)
        .animation(.appControl, value: controller.audioRecorder.isRecording)
    }
}


private struct MainWorkspaceView: View {
    @ObservedObject var controller: AutomationController
    @ObservedObject private var appearance = AppearanceModel.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { controller.section }, set: { controller.section = $0 ?? .overview })) {
                // Grouped rather than a flat pile: 개요, four tools and the
                // automation are not peers of one another.
                ForEach(AppSection.Group.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(group.members) { item in
                            Label {
                                Text(item.title)
                            } icon: {
                                Image(systemName: item.symbol).foregroundStyle(appearance.accent.label)
                            }
                            .tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            Group {
                switch controller.section {
                case .overview: OverviewView(controller: controller)
                case .documents: DocumentRecognitionView(controller: controller)
                case .scan: ScanCorrectionView(controller: controller)
                case .pdf: PDFEditorView(controller: controller)
                case .print: PrintView(controller: controller)
                case .transcription: TranscriptionView(controller: controller)
                case .audioCleanup: AudioCleanupView(controller: controller)
                case .cutout: CutoutView(controller: controller)
                case .upscale: UpscaleView(controller: controller)
                case .music: MusicView(controller: controller)
                case .compression: FileCompressionView(controller: controller)
                case .convert: FileConversionView(controller: controller)
                case .briefing: BriefingStatusWorkspaceView(controller: controller)
                case .archive: BriefingArchiveView(controller: controller)
                case .briefingCalendar: BriefingCalendarView(controller: controller)
                }
            }
            // Screens now carry their own name into the title bar, so switching
            // sections crossfades the body rather than swapping it instantly.
            .animation(.appContent, value: controller.section)
            // 어느 화면에서 나온 결과든 프린터로 넘길 수 있게 하는 한 줄. 결과 카드는
            // 자기 도구의 모델만 알고 컨트롤러를 모르므로, 길을 환경으로 내려 준다.
            .environment(\.sendToPrinter) { controller.sendToPrinter($0) }
        }
        .task { controller.openLaunchFiles() }
        .navigationSplitViewStyle(.balanced)
        // The window's minimum belongs to the window, not to whichever screen
        // happens to be showing. It used to be a `minWidth: 760` buried inside
        // 녹음·전사 alone, so picking that one tab raised the whole window's
        // minimum while every other tab had none at all.
        .frame(minWidth: 940, minHeight: 620)
        .tint(appearance.accent.color)
    }
}

private struct OverviewView: View {
    @ObservedObject var controller: AutomationController
    @Environment(\.openSettings) private var openSettings

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: Spacing.l)]

    var body: some View {
        WorkspaceScreen(title: AppSection.overview.title, subtitle: AppSection.overview.subtitle) {
            LazyVGrid(columns: columns, spacing: Spacing.l) {
                StatusTile(
                    title: "자동 브리핑",
                    value: controller.phase.rawValue,
                    // When it is not running, the useful number is not the
                    // collection range — that is a setting, and it never changes
                    // on its own. It is when this last worked.
                    detail: controller.isRunning ? controller.briefingETAString : controller.briefingHealth.summary(),
                    symbol: "tray.full",
                    isBusy: controller.isRunning,
                    isAlarming: !controller.isRunning && controller.briefingHealth.isStale()
                ) { controller.section = .briefing }

                StatusTile(
                    title: "녹음 보관함",
                    value: "\(controller.recordings.count)개",
                    detail: controller.recordings.first.map { controller.recordingOrganizer.displayTitle(for: $0) } ?? "아직 녹음이 없습니다",
                    symbol: "waveform",
                    isBusy: controller.isTranscribing || controller.audioRecorder.isRecording
                ) { controller.section = .transcription }

                StatusTile(
                    title: "받아쓰기 단축키",
                    value: controller.dictation.shortcut == .disabled ? "꺼짐" : controller.dictation.shortcut.title,
                    detail: controller.dictation.status,
                    symbol: controller.dictation.isRecording ? "mic.fill" : "mic",
                    isBusy: controller.dictation.isRecording || controller.dictation.isTranscribing
                ) { openSettings() }

                MusicOverviewTile(model: controller.music) { controller.section = .music }

                PrintOverviewTile(model: controller.printing) { controller.section = .print }
            }

            runProblems

            today

            overdue

            if !controller.processingQueue.isEmpty {
                ProcessingQueueCard(controller: controller)
                    .transition(.appCard)
            }

            recentRecordings

            tools

            GroupBox {
                HStack(spacing: Spacing.s) {
                    Button(controller.isRunning ? "브리핑 중지" : "인박스 정리 시작",
                           systemImage: controller.isRunning ? "stop.fill" : "tray.full.fill") {
                        controller.isRunning ? controller.stopBriefing() : controller.startBriefing()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(controller.isRunning ? .red : .snuBlue)
                    .help(controller.isRunning ? "실행을 중지합니다 (⌘.)" : "지금 수집하고 정리합니다 (⌘R)")

                    Button(controller.audioRecorder.isRecording ? "녹음 중지" : "녹음 시작",
                           systemImage: controller.audioRecorder.isRecording ? "stop.circle.fill" : "record.circle") {
                        controller.toggleRecording()
                        controller.section = .transcription
                    }
                    .buttonStyle(.bordered)
                    .tint(controller.audioRecorder.isRecording ? .red : .primary)
                    .help("녹음·전사 화면으로 이동하며 녹음을 시작합니다")

                    Button("화면 영역 캡처", systemImage: "camera.viewfinder") {
                        controller.section = .documents
                        controller.captureScreenAndRecognize()
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.isRecognizingDocument)
                    .help("화면 일부를 골라 바로 텍스트로 인식합니다")

                    Spacer()

                    if !controller.briefingArchive.days.isEmpty {
                        Button("최근 브리핑", systemImage: "checklist", action: controller.openLatestResult)
                            .buttonStyle(.link)
                            .font(.callout)
                            .help("가장 최근 브리핑을 보관함에서 엽니다 (⇧⌘B)")
                    }
                }
            } label: {
                Label("지금 할 수 있는 것", systemImage: "bolt").font(.headline)
            }
        }
        .animation(.appContent, value: controller.processingQueue.map(\.id))
        .animation(.appContent, value: controller.isRunning)
        .task {
            controller.refreshToday()
            // Re-read rather than trust what was loaded at launch: a run started
            // from the menu bar, or the date rolling over, both change the answer.
            controller.briefingHealth = BriefingHealth.load()
        }
    }

    /// What the last run could not reach.
    ///
    /// This is the surface the sixteen-day Gmail outage needed and did not have.
    /// A source that failed is named here, on the first screen, until a run
    /// succeeds without it — not in a caption at the foot of another screen.
    @ViewBuilder
    private var runProblems: some View {
        let health = controller.briefingHealth
        if let error = health.lastError, !error.isEmpty {
            problemBox(symbol: "xmark.octagon.fill", tint: .red,
                       title: "\(health.when())의 실행이 실패했습니다", lines: [error])
        } else if !health.failures.isEmpty {
            // Dated, not just "마지막". A seventeen-day-old failure written as
            // "마지막 브리핑에서" reads as a problem happening now — and the one
            // this actually showed, a missing Slack token, had been fixed days
            // before. The reader has to be able to tell those apart.
            problemBox(symbol: "exclamationmark.triangle.fill", tint: .orange,
                       title: "\(health.when()) 브리핑에서 \(health.failures.count)개 소스에 문제가 있었습니다",
                       lines: health.failures)
        }
    }

    private func problemBox(symbol: String, tint: Color, title: String, lines: [String]) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(lines.prefix(4), id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: Spacing.s) {
                    Button("연결 상태 점검", systemImage: "stethoscope") {
                        controller.settingsTab = .connections
                        openSettings()
                    }
                    .buttonStyle(.bordered)
                    Button("다시 정리", systemImage: "arrow.clockwise") { controller.startBriefing() }
                        .buttonStyle(.bordered)
                        .disabled(controller.isRunning)
                    Spacer()
                }
                .padding(.top, Spacing.xs)
            }
        } label: {
            Label(title, systemImage: symbol).font(.headline).foregroundStyle(tint)
        }
        .transition(.appCard)
    }

    /// What is actually happening today: the Mac's own calendar, and whatever
    /// the briefing says is due before the day is out.
    ///
    /// Both halves are already on this machine — the calendar is read for the
    /// briefing anyway and the deadlines are in the archive — so this costs one
    /// EventKit query and no network at all. It stays hidden on a day with
    /// nothing in it rather than showing an empty box.
    ///
    /// Deadlines that have already passed are *not* here; they have their own
    /// heading below. A box called 오늘 that fills up with a fortnight-old
    /// deadline and never empties stops being read.
    @ViewBuilder
    private var today: some View {
        let due = controller.briefingArchive.dueToday()
        if !controller.todayEvents.isEmpty || !due.isEmpty {
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(controller.todayEvents.enumerated()), id: \.element.id) { index, event in
                        if index > 0 { Divider() }
                        row(symbol: "calendar", tint: .snuBlueLabel, lead: event.timeText, title: event.title, trailing: event.calendarTitle) {
                            NSWorkspace.shared.open(URL(string: "ical://")!)
                        }
                    }
                    ForEach(Array(due.prefix(BriefingArchiveModel.dueTodayLimit).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 || !controller.todayEvents.isEmpty { Divider() }
                        row(
                            symbol: entry.isOverdue() ? "exclamationmark.triangle.fill" : "circle.badge.exclamationmark",
                            tint: entry.isOverdue() ? .red : .orange,
                            // A two-week-old deadline under a heading that says
                            // 오늘 reads as a bug unless it says it is late.
                            lead: entry.isOverdue() ? "지남 · \(entry.deadlineText ?? "")" : (entry.deadlineText ?? "오늘"),
                            title: entry.title,
                            trailing: entry.source
                        ) {
                            controller.briefingArchive.selectedDateKey = entry.dateKey
                            controller.section = .archive
                        }
                    }
                }
            } label: {
                HStack(spacing: Spacing.s) {
                    Label("오늘", systemImage: "calendar.day.timeline.left").font(.headline)
                    if !due.isEmpty {
                        Text("마감 \(due.count)개")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .transition(.appCard)
        }
    }

    /// Deadlines already gone. Separated from 오늘 on purpose and capped
    /// separately, so a backlog cannot squeeze out the day's actual work; the
    /// full list is in the archive.
    @ViewBuilder
    private var overdue: some View {
        let late = controller.briefingArchive.overdue()
        if !late.isEmpty {
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(late.prefix(BriefingArchiveModel.overdueLimit).enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider() }
                        row(
                            symbol: "exclamationmark.triangle.fill", tint: .red,
                            lead: "지남 · \(entry.deadlineText ?? "")",
                            title: entry.title, trailing: entry.source
                        ) {
                            controller.briefingArchive.selectedDateKey = entry.dateKey
                            controller.section = .archive
                        }
                    }
                    if late.count > BriefingArchiveModel.overdueLimit {
                        Divider()
                        Button("보관함에서 \(late.count)개 모두 보기") { controller.section = .archive }
                            .buttonStyle(.link)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Spacing.s)
                    }
                }
            } label: {
                HStack(spacing: Spacing.s) {
                    Label("밀린 것", systemImage: "clock.badge.exclamationmark").font(.headline)
                    Text("\(late.count)개")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            .transition(.appCard)
        }
    }

    private func row(symbol: String, tint: Color, lead: String, title: String, trailing: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
                Text(lead)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                Text(title).font(.callout).lineLimit(1)
                Spacer(minLength: Spacing.s)
                Text(trailing).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Every file tool, with a few words about what it is for.
    ///
    /// The sidebar lists the same names, but nine of them is past what anyone
    /// holds in their head, and the sidebar has no room to say what any of them
    /// does. This is the screen where the answer to "어디서 하지?" lives.
    ///
    /// 자동 브리핑 and 브리핑 보관함 are deliberately not here. They already have
    /// a status tile at the top of this screen and a button in 지금 할 수 있는 것,
    /// so a third copy was duplication for its own sake.
    private var tools: some View {
        GroupBox {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: Spacing.m)], spacing: Spacing.m) {
                ForEach(AppSection.allCases.filter { $0 != .overview && $0 != .briefing && $0 != .archive && $0 != .briefingCalendar }) { section in
                    ToolShortcut(section: section) { controller.section = section }
                }
            }
            .padding(.top, Spacing.xs)
        } label: {
            Label("도구", systemImage: "square.grid.2x2").font(.headline)
        }
    }

    /// The five most recent takes, so the first screen is a place to resume work
    /// rather than a place to read three numbers and leave.
    @ViewBuilder
    private var recentRecordings: some View {
        if !controller.recordings.isEmpty {
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(controller.recordings.prefix(5).enumerated()), id: \.element.id) { index, recording in
                        if index > 0 { Divider() }
                        Button {
                            controller.selectRecording(recording)
                            controller.section = .transcription
                        } label: {
                            HStack(spacing: Spacing.m) {
                                Image(systemName: recording.source == .app ? "mic.fill" : "waveform")
                                    .foregroundStyle(Color.snuBlueLabel)
                                    .frame(width: 18)
                                Text(controller.recordingOrganizer.displayTitle(for: recording)).lineLimit(1)
                                ForEach(controller.recordingOrganizer.tags(for: recording.id).prefix(2), id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Color.snuBlue.opacity(0.16), in: Capsule())
                                }
                                Spacer(minLength: Spacing.s)
                                let runs = controller.transcriptRuns(for: recording).count
                                if runs > 0 {
                                    Label("\(runs)", systemImage: "doc.on.doc.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                        .help("전사본 \(runs)개")
                                }
                                Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, Spacing.s)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("녹음·전사에서 이 녹음을 엽니다")
                    }
                }
            } label: {
                Label("최근 녹음", systemImage: "clock.arrow.circlepath").font(.headline)
            }
        }
    }
}

/// One tool on the 개요 launcher: its symbol, its name, and what it is for.
private struct ToolShortcut: View {
    let section: AppSection
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Spacing.m) {
                Image(systemName: section.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.snuBlueLabel)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title).font(.callout.weight(.medium))
                    Text(section.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.appControl, value: isHovering)
        .help(section.subtitle)
        .accessibilityLabel("\(section.title) 화면으로 이동")
    }
}

/// A tile that is also the way into the screen it summarises. Fixed 180-point
/// tiles used to sit in a row that could not reflow, and clicking one did
/// nothing.
struct StatusTile: View {
    let title: String
    let value: String
    var detail: String = ""
    let symbol: String
    var isBusy = false
    /// Draws attention to the tile's own detail line. Used when the number on it
    /// is the problem — a briefing that has not succeeded in days.
    var isAlarming = false
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(isAlarming ? Color.orange : Color.snuBlueLabel)
                    Spacer()
                    if isBusy { ProgressView().controlSize(.small) }
                }
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title3.weight(.semibold)).lineLimit(1)
                if !detail.isEmpty {
                    Label {
                        Text(detail)
                    } icon: {
                        if isAlarming { Image(systemName: "exclamationmark.triangle.fill") }
                    }
                    .font(.caption2)
                    .foregroundStyle(isAlarming ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .padding(Spacing.l)
            .glassPanel()
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.appControl, value: isHovering)
        .accessibilityLabel("\(title), \(value)")
        .accessibilityHint("열려면 클릭하세요")
    }
}


private struct BriefingStatusWorkspaceView: View {
    @ObservedObject var controller: AutomationController
    @Environment(\.openSettings) private var openSettings

    private var isDone: Bool { controller.phase == .completed }

    /// 자동 실행이 켜져 있으면 **왜 지금 돌지 않는지**를 적는다.
    ///
    /// 자동화는 안 돌았을 때 이유를 말해 주지 않으면 고장과 구별되지 않는다. 아침에
    /// 사람이 던지는 질문은 "어젯밤에 돌았나"이고, 답이 "아니오"라면 곧바로 "왜"가
    /// 따라온다. 꺼져 있을 때는 아무것도 그리지 않는다 — 쓰지 않는 기능이 자리를
    /// 차지할 이유가 없다.
    @ViewBuilder
    private var autoRun: some View {
        if controller.autoBriefingEnabled {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: "moon.zzz")
                    .foregroundStyle(Color.snuBlueLabel)
                VStack(alignment: .leading, spacing: 1) {
                    Text("밤 자동 실행 켜짐 · \(controller.autoBriefingStartHour)시–\((controller.autoBriefingStartHour + AutomationController.autoBriefingWindowHours) % 24)시")
                        .font(.callout.weight(.medium))
                    Text(controller.autoBriefingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("설정") { openSettings() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(Radius.card)
            .transition(.appCard)
        }
    }

    var body: some View {
        WorkspaceScreen(title: AppSection.briefing.title, subtitle: AppSection.briefing.subtitle) {
            autoRun
            conditions
            progressPanel
            if let error = controller.errorMessage {
                DismissibleError(message: error) { controller.errorMessage = nil }
            }
        }
        .animation(.appContent, value: controller.phase)
        .animation(.appContent, value: controller.errorMessage)
        .animation(.appContent, value: controller.autoBriefingEnabled)
        .toolbar {
            ToolbarItem {
                Button("보관함 열기", systemImage: "checklist", action: controller.openLatestResult)
                    .disabled(controller.briefingArchive.days.isEmpty)
                    .help("정리된 결과를 브리핑 보관함에서 봅니다 (⇧⌘B)")
            }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                if controller.isRunning {
                    Button("중지", systemImage: "stop.fill") { controller.stopBriefing() }
                        .tint(.red)
                        .toolbarKeepsTitle()
                        .help("모델을 안전하게 해제하고 멈춥니다 (⌘.)")
                } else {
                    Button("인박스 정리 시작", systemImage: "tray.full.fill") { controller.startBriefing() }
                        .buttonStyle(.glassProminent)
                        .tint(.snuBlue)
                        .toolbarKeepsTitle()
                        .help("지금 수집하고 분류해 보관함에 저장합니다 (⌘R)")
                }
            }
        }
    }

    /// The run's conditions, and — new — when it last worked.
    ///
    /// This screen's own subtitle promises "수집부터 저장까지의 상태", and it used
    /// to show two settings and a progress bar: nothing about whether any source
    /// could be reached, and nothing about when a run last succeeded.
    private var conditions: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Label(controller.selectedRange.rawValue, systemImage: "calendar.badge.clock")
                    .font(.callout)
                Text("·").foregroundStyle(.tertiary)
                Text(controller.briefingQualityMode.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("설정에서 변경") {
                    controller.settingsTab = .briefing
                    openSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("수집 범위와 분석 품질을 바꿉니다 (⌘,)")
            }
            Divider()
            HStack(spacing: Spacing.s) {
                let stale = controller.briefingHealth.isStale()
                Image(systemName: stale ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(stale ? Color.orange : Color.green)
                    .font(.caption)
                Text(controller.briefingHealth.summary())
                    .font(.callout)
                    .foregroundStyle(stale ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                Spacer()
                Button("연결 상태 점검") {
                    controller.settingsTab = .connections
                    openSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("각 소스에 실제로 닿는지 지금 확인합니다")
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .glassPanel(Radius.card)
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Label(controller.phase.rawValue, systemImage: controller.isRunning ? "arrow.triangle.2.circlepath" : (isDone ? "checkmark.circle.fill" : "circle.dashed"))
                    .font(.headline)
                    .foregroundStyle(isDone ? Color.green : Color.snuBlueLabel)
                    .symbolEffect(.rotate, options: .repeating, isActive: controller.isRunning)
                Spacer()
                Text(controller.isRunning ? "실행 중" : "대기")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: controller.progressValue).tint(.snuBlue)
            if !controller.briefingETAString.isEmpty {
                Label(controller.briefingETAString, systemImage: "clock.arrow.circlepath")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .transition(.appBanner)
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                BriefingStatusRow(title: "새 항목 수집", active: controller.phase == .collecting, done: controller.phase == .classifying || controller.phase == .writing || isDone)
                BriefingStatusRow(title: "로컬 모델 분류", active: controller.phase == .classifying, done: controller.phase == .writing || isDone)
                BriefingStatusRow(title: "보관함에 저장", active: controller.phase == .writing, done: isDone)
                BriefingStatusRow(title: "모델 언로드", active: isDone, done: isDone)
            }
            Text(controller.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
    }
}


private struct BriefingStatusRow: View {
    let title: String
    let active: Bool
    let done: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.inset.filled" : "circle"))
                .foregroundStyle(done ? .green : (active ? Color.snuBlueLabel : .secondary))
                .symbolEffect(.pulse, options: .repeating, isActive: active)
            Text(title)
                .font(.callout)
                .foregroundStyle(active ? .primary : .secondary)
            Spacer()
        }
        .animation(.appControl, value: done)
        .animation(.appControl, value: active)
    }
}

/// Which pane ⌘, opens on, so a button elsewhere can send the reader somewhere
/// specific rather than to wherever they were last.
enum SettingsTab: String, Hashable, CaseIterable {
    case briefing, connections, classification, transcription, dictation, tools, music, printer, appearance

    var title: String {
        switch self {
        case .briefing: "브리핑"
        case .connections: "연결 상태"
        case .classification: "분류 기준"
        case .transcription: "전사 / AI 요약"
        case .dictation: "받아쓰기"
        case .tools: "도구"
        case .music: "음악"
        case .printer: "프린터"
        case .appearance: "모양"
        }
    }

    var symbol: String {
        switch self {
        case .briefing: "tray.full"
        case .connections: "stethoscope"
        case .classification: "line.3.horizontal.decrease.circle"
        case .transcription: "waveform"
        case .dictation: "mic"
        case .tools: "wand.and.stars"
        case .music: "music.note"
        case .printer: "printer"
        case .appearance: "paintpalette"
        }
    }
}

/// The ⌘, window. These nine sections used to be one `Form` inside a sidebar
/// row, with six `TextEditor`s in a single scroll that ran several screens long.
/// Splitting them by subject is the difference between finding a setting and
/// hunting for it.
private struct SettingsWindow: View {
    @ObservedObject var controller: AutomationController
    @ObservedObject private var appearance = AppearanceModel.shared

    var body: some View {
        // Bound, not free: a button that says 연결 상태 점검 has to land on that
        // tab. `openSettings()` alone reopens whichever tab was left showing, so
        // the promise the button makes was one it could not keep.
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $controller.settingsTab) { tab in
                Label {
                    Text(tab.title)
                } icon: {
                    Image(systemName: tab.symbol).foregroundStyle(appearance.accent.label)
                }
                .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            Group {
                switch controller.settingsTab {
                case .briefing: BriefingSettingsTab(controller: controller)
                case .connections: ConnectionSettingsTab(controller: controller, model: controller.connectionHealth)
                case .classification: ClassificationSettingsTab(controller: controller)
                case .transcription: TranscriptionSettingsTab(controller: controller)
                case .dictation: Form { DictationSettingsSection(dictation: controller.dictation) }.formStyle(.grouped)
                case .tools: ToolSettingsTab(controller: controller)
                case .music: MusicSettingsTab(model: controller.music)
                case .printer: PrintSettingsTab(model: controller.printing)
                case .appearance: AppearanceSettingsView()
                }
            }.navigationTitle(controller.settingsTab.title)
        }
        .frame(minWidth: 780, idealWidth: 850, minHeight: 580, idealHeight: 640)
        .tint(appearance.accent.color)
    }
}

private struct BriefingSettingsTab: View {
    @ObservedObject var controller: AutomationController
    @AppStorage("slackMentionUserID") private var slackMentionUserID = ""
    @State private var webNoticeSites = WebNoticeConfiguration.load()
    @State private var showsWebNoticeEditor = false

    var body: some View {
        Form {
            Section("수집") {
                Picker("수집 범위", selection: $controller.selectedRange) {
                    ForEach(CollectionRange.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("분석 품질", selection: $controller.briefingQualityMode) {
                    ForEach(BriefingQualityMode.allCases) { Text($0.title).tag($0) }
                }
                Text(controller.briefingQualityMode.explanation).font(.caption).foregroundStyle(.secondary)
                Stepper("TODO 최대 \(controller.briefingMaxActions)개", value: $controller.briefingMaxActions, in: 3...20)
                Stepper("확인 항목 최대 \(controller.briefingMaxReferences)개", value: $controller.briefingMaxReferences, in: 3...20)
                TextField("내 Slack Member ID (채널 멘션용)", text: $slackMentionUserID)
                Text("Slack DM은 Member ID 없이 수집하며, 채널은 이 ID의 멘션만 수집합니다. `마지막 성공 이후`는 직전 실행이 수동 재검토였어도 그 시점부터 이어서 수집하고, 기록이 없으면 최대 30일까지 거슬러 봅니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("밤에 스스로 실행") {
                // 확인은 체크박스 하나. 위험한 동작이 아니고, 끄는 것도 같은 한 번이다.
                Toggle("조건이 맞으면 밤에 한 번 자동으로 정리", isOn: $controller.autoBriefingEnabled)
                Picker("시작 시각", selection: $controller.autoBriefingStartHour) {
                    ForEach([0, 1, 2, 3, 4], id: \.self) { hour in
                        Text("\(hour)시–\((hour + AutomationController.autoBriefingWindowHours) % 24)시").tag(hour)
                    }
                }
                .disabled(!controller.autoBriefingEnabled)
                Text("**전원이 꽂혀 있고, 노트북이 열려 있고, \(Int(BriefingAutopilot.idleThreshold) / 60)분 넘게 아무것도 누르지 않았고, 다른 작업이 돌고 있지 않을 때** 하루 한 번 실행합니다. 도는 동안에는 이 Mac이 유휴로 잠들지 않게 잡아 두고 끝나면 놓습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("**노트북을 닫으면 이 Mac은 잠들고, 잠든 동안에는 돌지 않습니다.** 뚜껑을 닫아 둔 밤에도 돌게 하려면 예약 기상(`pmset repeat`)이나 launch agent가 필요하고, 둘 다 이 앱이 설치하지 않습니다. 로그인·화면 열기·잠자기 해제로 시작하는 일은 여전히 없습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.autoBriefingEnabled {
                    LabeledContent("지금 상태", value: controller.autoBriefingStatus)
                        .font(.caption)
                }
            }
            Section("무엇을 읽는가") {
                // These rows say what each source is *for*. What each source can
                // actually reach right now is a live question with a live answer,
                // and it belongs in 연결 상태 — printing a fixed "읽기 전용" here
                // and calling it a status is exactly what hid a dead Gmail token
                // for sixteen days.
                IntegrationStatusRow(symbol: "envelope", title: "Gmail", detail: "설정한 계정의 새 메일 · 읽기 전용", status: "")
                IntegrationStatusRow(symbol: "bubble.left.and.bubble.right", title: "Slack", detail: "DM 및 내 멘션 · 읽기 전용", status: "")
                IntegrationStatusRow(symbol: "message", title: "메시지", detail: "iMessage · SMS · RCS 수신 · 읽기 전용", status: "")
                IntegrationStatusRow(
                    symbol: "globe",
                    title: "웹 공지",
                    detail: "학교 공지 게시판 \(webNoticeSites.filter(\.enabled).count)곳 · 공개 페이지만 읽음",
                    status: ""
                ) {
                    Button("목록 관리") { showsWebNoticeEditor = true }
                    .buttonStyle(.borderless)
                    .help("앱 안에서 웹 공지 게시판을 추가하거나 끕니다")
                }
                IntegrationStatusRow(
                    symbol: "graduationcap",
                    title: "eTL",
                    detail: "이번 학기 과목의 공지 · 과제 마감 · 미제출 · 쪽지 · 수업 일정 · 읽기 전용",
                    status: ""
                ) {
                    Button("토큰 넣기") {
                        // 토큰은 화면에서 받지 않는다. 값이 셸 기록에도 남지 않는 명령을
                        // 복사해 주고, 실제로 넣는 일은 연결 상태 탭이 안내한다.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ETLConfiguration.tokenCommand, forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .help("Keychain에 토큰을 넣는 명령을 복사합니다. 붙여 넣고 실행하면 토큰을 화면에 보이지 않게 입력받습니다.")
                }
                IntegrationStatusRow(symbol: "calendar", title: "캘린더 · 미리 알림", detail: "앞으로 14일 일정 읽기 · 전용 캘린더와 목록에만 쓰기", status: "")
                Text("캘린더 일정은 인박스 정리에 일정 맥락으로 포함됩니다. 앱이 만드는 일정과 미리 알림은 전부 '\(AgentCalendar.title)' 이름의 전용 캘린더·목록에만 들어가며, 원래 쓰던 캘린더의 일정은 만들거나 고치거나 지우지 않습니다. 지금 각 소스에 실제로 닿는지는 **연결 상태** 탭에서 점검합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { webNoticeSites = WebNoticeConfiguration.load() }
        .sheet(isPresented: $showsWebNoticeEditor) {
            WebNoticeSettingsSheet(sites: webNoticeSites) { saved in
                webNoticeSites = saved
            }
        }
    }
}

/// The public-board list used by automatic briefings. It used to be reachable
/// only as a JSON file in Finder, which made adding one require knowing the file
/// shape and hand-writing an encoded URL. This sheet keeps that file as the
/// storage format while making the ordinary path entirely in-app.
private struct WebNoticeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sites: [WebNoticeSite]
    @State private var showsAddSite = false
    @State private var errorMessage: String?
    let onSave: ([WebNoticeSite]) -> Void

    init(sites: [WebNoticeSite], onSave: @escaping ([WebNoticeSite]) -> Void) {
        _sites = State(initialValue: sites)
        self.onSave = onSave
    }

    private var builtInIDs: Set<String> { Set(WebNoticeCatalog.defaults.map(\.id)) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($sites) { $site in
                        HStack(alignment: .top, spacing: Spacing.m) {
                            Toggle("", isOn: $site.enabled)
                                .labelsHidden()
                                .help(site.enabled ? "이 게시판을 브리핑에서 제외" : "이 게시판을 브리핑에 포함")
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(site.name)
                                Text(site.url.absoluteString.removingPercentEncoding ?? site.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(site.interest == .direct ? "모든 새 공지" : "지원 가능한 프로그램 위주")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: Spacing.s)
                            if !builtInIDs.contains(site.id) {
                                Button(role: .destructive) {
                                    sites.removeAll { $0.id == site.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("이 게시판 삭제")
                            }
                        }
                        .padding(.vertical, Spacing.xs)
                    }
                } header: {
                    Text("\(sites.filter(\.enabled).count)곳 사용 중")
                } footer: {
                    Text("새 게시판은 다음 브리핑에서 현재 목록을 기준선으로 저장하고, 그다음 실행부터 새 글만 보고합니다. 기본 게시판은 끌 수 있고, 직접 추가한 게시판은 삭제할 수 있습니다.")
                }
            }
            .navigationTitle("웹 공지 목록")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsAddSite = true
                    } label: {
                        Label("게시판 추가", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                }
            }
        }
        .frame(width: 660, height: 520)
        .sheet(isPresented: $showsAddSite) {
            AddWebNoticeSiteSheet(existingIDs: Set(sites.map(\.id))) { site in
                sites.append(site)
            }
        }
        .alert("웹 공지 목록을 저장하지 못했습니다", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "알 수 없는 오류입니다.")
        }
    }

    private func save() {
        do {
            try WebNoticeConfiguration.save(sites)
            onSave(sites)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AddWebNoticeSiteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pageAddress = ""
    @State private var feedAddress = ""
    @State private var interest: WebNoticeInterest = .direct
    @State private var errorMessage: String?
    let existingIDs: Set<String>
    let onAdd: (WebNoticeSite) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("게시판") {
                    TextField("이름", text: $name, prompt: Text("예: 전기·정보공학부"))
                    TextField("목록 페이지 주소", text: $pageAddress, prompt: Text("https://example.edu/notices"))
                    TextField("RSS 또는 Atom 주소 (선택)", text: $feedAddress, prompt: Text("https://example.edu/feed"))
                    Text("RSS/Atom 주소가 있으면 더 빠르고 안정적으로 읽고, 없으면 목록 페이지에서 공지 링크를 찾습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("포함할 공지") {
                    Picker("대상", selection: $interest) {
                        Text("모든 새 공지").tag(WebNoticeInterest.direct)
                        Text("지원 가능한 프로그램 위주").tag(WebNoticeInterest.programsOnly)
                    }
                    Text(interest == .direct
                         ? "내 소속 게시판이나 학교 전체 기관처럼 모든 글을 분류 모델에 보냅니다."
                         : "다른 단과대 게시판처럼 내부 행정 공지는 줄이고, 모집·신청·장학 등 참여할 수 있는 글을 중심으로 보냅니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("웹 게시판 추가")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("추가") { add() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || pageAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(width: 520, height: 390)
    }

    private func add() {
        do {
            let site = try WebNoticeConfiguration.site(
                name: name,
                pageAddress: pageAddress,
                feedAddress: feedAddress,
                interest: interest
            )
            guard !existingIDs.contains(site.id) else {
                throw WebNoticeConfigurationError.duplicateAddress
            }
            onAdd(site)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 설정 › 연결 상태.
///
/// Every row here performs the read the briefing performs and reports what came
/// back, because the pane this replaces printed fixed strings. The check is
/// manual: it spawns `gog` per account and fetches fifteen notice boards, and
/// neither should happen merely because a settings window was opened.
private struct ConnectionSettingsTab: View {
    @ObservedObject var controller: AutomationController
    @ObservedObject var model: ConnectionHealthModel

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Image(systemName: model.briefing.isStale() ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(model.briefing.isStale() ? Color.orange : Color.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.briefing.summary()).font(.callout.weight(.medium))
                        if let error = model.briefing.lastError, !error.isEmpty {
                            Text("마지막 오류: \(error)").font(.caption).foregroundStyle(.red)
                        } else if !model.briefing.failures.isEmpty {
                            Text(model.briefing.failures.joined(separator: "\n"))
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                }
            } header: {
                Text("마지막 인박스 정리")
            }

            Section {
                ForEach(model.checks) { check in
                    ConnectionCheckRow(check: check) { remedy in apply(remedy) }
                }
            } header: {
                HStack {
                    Text("소스")
                    Spacer()
                    if let checkedAt = model.lastCheckedAt {
                        Text("점검 \(checkedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("점검은 각 소스에 실제로 한 번씩 읽기를 시도합니다. Gmail은 계정마다 `gog`를 한 번 실행하고, 웹 공지는 등록한 게시판을 모두 받아 봅니다. 여기서 보내는 것은 없습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: Spacing.s) {
                    Button(model.isChecking ? "점검 중…" : "지금 점검", systemImage: "stethoscope") { model.check() }
                        .buttonStyle(.borderedProminent).tint(.snuBlue)
                        .disabled(model.isChecking)
                    if model.isChecking {
                        ProgressView().controlSize(.small)
                        Button("중지") { model.cancel() }.buttonStyle(.bordered)
                    }
                    Spacer()
                    if !model.status.isEmpty {
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                    } else if !model.isChecking, model.lastCheckedAt != nil {
                        Text(model.problemCount == 0 ? "모든 소스 정상" : "문제 \(model.problemCount)건")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(model.problemCount == 0 ? .green : .orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(.appContent, value: model.checks.map(\.state.rawValue))
        .onAppear { model.checkOnPaneEntry() }
    }

    private func apply(_ remedy: ConnectionCheck.Remedy) {
        switch remedy {
        case .openPrivacySettings(let url):
            if let target = URL(string: url) { NSWorkspace.shared.open(target) }
        case .revealFile(let url):
            // Reveal rather than open: the parent folder is what the user needs
            // when the file does not exist yet.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .copyCommand(let command):
            ArchiveClipboard.put(command)
            model.status = "터미널에 붙여넣어 실행해 주세요."
        case .requestCalendarAccess:
            controller.requestCalendarAccess()
            Task { try? await Task.sleep(for: .seconds(1)); model.refreshPermissions() }
        case .requestReminderAccess:
            controller.requestReminderAccess()
            Task { try? await Task.sleep(for: .seconds(1)); model.refreshPermissions() }
        }
    }
}

private struct ConnectionCheckRow: View {
    let check: ConnectionCheck
    let apply: (ConnectionCheck.Remedy) -> Void

    private var tint: Color {
        switch check.state {
        case .checking: .secondary
        case .ok: .green
        case .warning: .orange
        case .failed: .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: check.state.symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
                .symbolEffect(.pulse, options: .repeating, isActive: check.state == .checking)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: check.symbol).foregroundStyle(.secondary).font(.caption)
                    Text(check.title).font(.callout.weight(.medium))
                }
                Text(check.summary)
                    .font(.caption)
                    .foregroundStyle(check.state == .ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = check.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: Spacing.s)
            if let remedy = check.remedy, check.state != .ok || remedy.isAlwaysOffered {
                Button(remedy.title) { apply(remedy) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ClassificationSettingsTab: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        Form {
            Section("직접 확인하고 수정") {
                Text("아래 내용만 개인 맞춤 분류에 사용합니다. 앱 내부에 숨은 중요/무시 발신자 목록을 두지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $controller.briefingUserInstructions)
                    .font(.body.monospaced()).frame(minHeight: 130)
            }
            Section("항상 중요") {
                TextEditor(text: $controller.briefingImportantPatternsText)
                    .font(.body.monospaced()).frame(minHeight: 80)
                Text("발신자·도메인·제목·본문에 포함될 문자열을 한 줄에 하나씩 입력합니다. 중요 규칙은 무시 규칙보다 우선합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("학업 · 과제") {
                TextEditor(text: $controller.briefingAcademicInstructions)
                    .font(.body.monospaced()).frame(minHeight: 140)
                Text("과목 맥락과 실제 성적·출석 영향을 판단해 보관함의 과제 항목으로 분류합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("관심 분야") {
                TextEditor(text: $controller.briefingInterestPatternsText)
                    .font(.body.monospaced()).frame(minHeight: 80)
                Text("여기 적힌 분야의 포럼·특강·모집 공지는 한 단계 위로 올라갑니다. 참가 신청이 열려 있으면 할 일, 정보뿐이면 확인 항목이 됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("항상 무시") {
                TextEditor(text: $controller.briefingIgnoredPatternsText)
                    .font(.body.monospaced()).frame(minHeight: 80)
                Text("무시 규칙과 일치한 항목은 본문 요약과 모델 분석에서 제외되고 건수만 기록됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("저장", action: controller.saveBriefingPreferences)
                        .buttonStyle(.borderedProminent).tint(.snuBlue)
                    Button("기본값 복원", action: controller.resetBriefingPreferences)
                    Spacer()
                    if !controller.briefingPreferencesStatus.isEmpty {
                        Text(controller.briefingPreferencesStatus)
                            .font(.caption).foregroundStyle(.secondary)
                            .transition(.appBanner)
                    }
                }
                .animation(.appContent, value: controller.briefingPreferencesStatus)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranscriptionSettingsTab: View {
    @ObservedObject var controller: AutomationController
    @StateObject private var catalog = SummaryModelCatalog()
    @State private var diarizationToken = ""
    @State private var diarizationTokenStatus = ""

    var body: some View {
        Form {
            Section("기본값") {
                Picker("언어", selection: $controller.transcriptionLanguage) { ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0) } }
                Picker("인식 모델", selection: $controller.asrModel) { ForEach(ASRModelChoice.allCases) { Text($0.title).tag($0) } }
                Text(controller.asrModel.explanation).font(.caption).foregroundStyle(.secondary)
                Picker("시간 표시", selection: $controller.transcriptionTimestampMode) { ForEach(TranscriptionTimestampMode.allCases) { Text($0.title).tag($0) } }
                Text("녹음·전사 화면에서 이번 전사만 다르게 지정할 수도 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("화자 구분") {
                Picker("분리 모델", selection: $controller.diarization) { ForEach(DiarizationChoice.allCases) { Text($0.title).tag($0) } }
                Text(controller.diarization.explanation).font(.caption).foregroundStyle(.secondary)
                SecureField("Hugging Face pyannote 토큰 (hf_…)", text: $diarizationToken)
                HStack {
                    Button("Keychain에 저장") {
                        do {
                            try TranscriptionService.saveDiarizationToken(diarizationToken)
                            diarizationToken = ""
                            diarizationTokenStatus = "Keychain에 저장했습니다."
                        } catch {
                            diarizationTokenStatus = error.localizedDescription
                        }
                    }
                    .disabled(diarizationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !diarizationTokenStatus.isEmpty {
                        Text(diarizationTokenStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Community-1 또는 Legacy 3.1을 쓰려면 해당 Hugging Face 모델 약관을 승인한 토큰이 필요합니다. 토큰은 저장소가 아닌 macOS Keychain에만 저장됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI 정리") {
                Picker("자동요약 모델", selection: $controller.summaryModel) {
                    if !catalog.models.contains(controller.summaryModel) {
                        Text("\(controller.summaryModel) · 설치 확인 필요").tag(controller.summaryModel)
                    }
                    ForEach(catalog.models, id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Button(catalog.isLoading ? "확인 중…" : "모델 목록 새로고침") { catalog.refresh() }
                        .disabled(catalog.isLoading)
                    if let error = catalog.error { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                Toggle("전사 완료 후 자동으로 AI 정리", isOn: $controller.automaticallyOrganizeTranscripts)
                Picker("기본 정리 유형", selection: $controller.organizationKind) {
                    ForEach(TranscriptOrganizationKind.allCases) { Text($0.title).tag($0) }
                }
                Picker("상세도", selection: $controller.organizationDetailLevel) {
                    ForEach(TranscriptOrganizationDetail.allCases) { Text($0.title).tag($0) }
                }
                Text("설치된 로컬 모델을 선택합니다. 다음에 대기열에 넣는 작업부터 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("자동 판단 / 수업 정리 프롬프트") {
                    TextEditor(text: $controller.lectureOrganizationPrompt).font(.body.monospaced()).frame(minHeight: 130)
                }
                DisclosureGroup("회의 정리 프롬프트") {
                    TextEditor(text: $controller.meetingOrganizationPrompt).font(.body.monospaced()).frame(minHeight: 130)
                }
                DisclosureGroup("세미나 / 일반 정리 프롬프트") {
                    TextEditor(text: $controller.generalOrganizationPrompt).font(.body.monospaced()).frame(minHeight: 130)
                }
                HStack {
                    Button("저장") { controller.saveOrganizationPreferences() }
                        .buttonStyle(.borderedProminent).tint(.snuBlue)
                    Button("기본 프롬프트로 복원") { controller.resetOrganizationPrompts() }
                    Spacer()
                    if !controller.organizationPreferencesStatus.isEmpty {
                        Text(controller.organizationPreferencesStatus)
                            .font(.caption).foregroundStyle(.secondary)
                            .transition(.appBanner)
                    }
                }
                .animation(.appContent, value: controller.organizationPreferencesStatus)
            }
        }
        .onAppear { catalog.refresh() }
        .onChange(of: controller.summaryModel) { controller.saveOrganizationPreferences() }
        .onChange(of: controller.automaticallyOrganizeTranscripts) { controller.saveOrganizationPreferences() }
        .onChange(of: controller.organizationKind) { controller.saveOrganizationPreferences() }
        .onChange(of: controller.organizationDetailLevel) { controller.saveOrganizationPreferences() }
        .formStyle(.grouped)
    }
}

private struct ToolSettingsTab: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        Form {
            Section("문서 인식") {
                Picker("인식 방식", selection: $controller.documentMode) { ForEach(DocumentRecognitionMode.allCases) { Text($0.title).tag($0) } }
                Text(controller.documentMode.detail).font(.caption).foregroundStyle(.secondary)
            }
            Section("누끼 따기") {
                Picker("누끼 모델", selection: $controller.mattingModel) { ForEach(MattingModelChoice.allCases) { Text($0.title).tag($0) } }
                Text(controller.mattingModel.detail).font(.caption).foregroundStyle(.secondary)
                Text("모델은 마지막 사진 이후 5분이 지나면 스스로 메모리에서 내려가고, 앱을 끄면 함께 종료됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct IntegrationStatusRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let status: String
    @ViewBuilder let trailing: () -> Trailing

    init(symbol: String, title: String, detail: String, status: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.status = status
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(Color.snuBlueLabel)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                // Empty on purpose for the rows that describe scope rather than
                // state: a row with nothing live to report should print nothing,
                // not a reassuring constant.
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status == "허용됨" ? .green : .secondary)
                }
                trailing()
            }
        }
    }
}

private extension IntegrationStatusRow where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String, status: String) {
        self.init(symbol: symbol, title: title, detail: detail, status: status) { EmptyView() }
    }
}

/// 녹음·전사.
///
/// This used to exist twice: once as a sidebar screen and once as a separate
/// `Window` scene that nothing in the app could open, and the two showed
/// *different* controls — the unreachable window had the four transcription
/// pickers, the sidebar one had none, so the only way to change the model from
/// the main window was to go to 설정. There is now one screen, and it has them.
private struct TranscriptionView: View {
    @ObservedObject var controller: AutomationController
    @State private var isDropTarget = false
    @State private var showsAllRecordings = false
    @State private var showsConditions = false

    /// How many take cards to show before the list is folded. The grid used to
    /// live inside its own `ScrollView` nested in the page's — the wheel then
    /// scrolled whichever one the pointer happened to be over.
    private static let collapsedRecordingCount = 8

    /// Filtering is an explicit request for what matches, so it is never folded:
    /// hiding half of a five-result search behind 전체 보기 would be a second
    /// filter the reader did not ask for.
    private var matchingRecordings: [RecordingItem] {
        controller.recordingOrganizer.filtered(controller.recordings)
    }

    private var visibleRecordings: [RecordingItem] {
        let matching = matchingRecordings
        guard !showsAllRecordings, !controller.recordingOrganizer.isFiltering else { return matching }
        return Array(matching.prefix(Self.collapsedRecordingCount))
    }

    var body: some View {
        WorkspaceScreen(title: AppSection.transcription.title, subtitle: AppSection.transcription.subtitle) {
            if controller.audioRecorder.isRecording { recordingBanner }
            if let error = controller.audioRecorder.errorMessage {
                DismissibleError(message: error) { controller.audioRecorder.dismissError() }
            }
            // 녹음이 어떻게 끝났는지. 전사가 도는 중에도 이 자리는 전사 카드와 겹치지
            // 않으므로, 강의 중에 뚜껑을 닫아 끝난 녹음도 돌아와서 읽을 수 있다.
            if let status = controller.recordingStatus, !controller.audioRecorder.isRecording {
                DismissibleNote(message: status, symbol: "waveform.circle.fill") { controller.recordingStatus = nil }
            }

            dropWell

            if !controller.processingQueue.isEmpty {
                ProcessingQueueCard(controller: controller)
                    .transition(.appCard)
            }
            if controller.isTranscribing {
                TranscriptionProgressCard(
                    step: controller.transcriptionStep,
                    detail: controller.transcriptionDetail,
                    timestamps: controller.transcriptionTimestampMode.includesTimestamps,
                    diarizing: controller.diarization.isEnabled,
                    eta: controller.transcriptionETA
                )
                .transition(.appCard)
            }

            conditions
            MediaImportCard(controller: controller)
            library

            if let recording = controller.selectedRecording {
                selectedRecordingPanel(recording)
            }

            if let error = controller.transcriptionError {
                DismissibleError(message: error) { controller.transcriptionError = nil }
            }

            if controller.selectedTranscript.isEmpty {
                EmptyResults(symbol: "text.quote", message: controller.recordings.isEmpty
                             ? "아직 녹음이 없습니다.\n툴바에서 녹음을 시작하거나 파일을 드롭하세요."
                             : "보관함에서 녹음을 고르고 전사 대기열에 추가하세요.")
            } else {
                results
            }
        }
        .animation(.appContent, value: controller.selectedRecordingID)
        .animation(.appContent, value: controller.isTranscribing)
        .animation(.appContent, value: controller.processingQueue.map(\.id))
        .animation(.appContent, value: controller.audioRecorder.isRecording)
        .animation(.appContent, value: controller.recordingStatus)
        .animation(.appContent, value: controller.transcriptionError)
        .toolbar {
            ToolbarItem {
                Menu("보관함", systemImage: "ellipsis") {
                    Button("Finder에서 파일 선택해 전사…", systemImage: "folder") { chooseFilesForTranscription() }
                    Divider()
                    Button("새로 고침", systemImage: "arrow.clockwise") { controller.refreshRecordings() }
                    Button("Voice Memos 폴더 연결…", systemImage: "folder.badge.plus") { controller.chooseVoiceMemosFolder() }
                } 
                .help("녹음 보관함을 다시 읽거나 Voice Memos 폴더를 연결합니다")
            }
            ToolbarItem {
                if controller.isTranscribing {
                    Button("전사 중단", systemImage: "stop.fill") { controller.stopTranscription() }
                        .tint(.red)
                        .toolbarKeepsTitle()
                        .help("실행 중인 음성 인식을 중단합니다")
                }
            }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button(controller.audioRecorder.isRecording ? "녹음 중지" : "녹음 시작",
                       systemImage: controller.audioRecorder.isRecording ? "stop.circle.fill" : "record.circle") {
                    controller.toggleRecording()
                }
                .buttonStyle(.glassProminent)
                .tint(controller.audioRecorder.isRecording ? .red : .snuBlue)
                .toolbarKeepsTitle()
                .help(controller.audioRecorder.isRecording ? "녹음을 끝내고 보관함에 넣습니다" : "이 Mac의 마이크로 바로 녹음합니다")
            }
        }
    }

    // MARK: 녹음 중

    private var recordingBanner: some View {
        HStack(spacing: Spacing.l) {
            Image(systemName: "waveform")
                .font(.system(size: 30, weight: .medium))
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("녹음 중").font(.headline).foregroundStyle(.red)
                }
                Text(Self.durationString(controller.audioRecorder.elapsed))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            Button("녹음 중지", systemImage: "stop.circle.fill") { controller.toggleRecording() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(Color.red.opacity(0.25))
        )
        .transition(.appCard)
    }

    // MARK: 넣기

    private func chooseFilesForTranscription() {
        let panel = NSOpenPanel()
        panel.title = "전사할 오디오 또는 영상 선택"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { controller.transcribe(fileURL: url) }
    }

    private var dropWell: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(isDropTarget ? AnyShapeStyle(Color.snuBlueLabel) : AnyShapeStyle(.tertiary))
            // Kept live during a recording too: dropping a file only adds to the
            // queue, which runs alongside the mic.
            Text("오디오 또는 영상 파일을 드롭하세요 · 여러 개도 됩니다")
                .font(.callout)
            Text("영상은 오디오만 추출해 전사합니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .multilineTextAlignment(.center)
        .padding(Spacing.l)
        .dropWell(isTargeted: isDropTarget)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            // Every file, not just the first: this tab has a real queue, and
            // dropping five recordings used to silently transcribe one.
            guard !providers.isEmpty else { return false }
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in controller.transcribe(fileURL: url) }
                }
            }
            return true
        }
    }

    // MARK: 이번 전사 조건

    private var conditions: some View {
        DisclosureGroup(isExpanded: $showsConditions) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                LabeledContent("음성 인식") {
                    Picker("음성 인식", selection: $controller.asrModel) {
                        ForEach(ASRModelChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                Text(controller.asrModel.explanation).font(.caption).foregroundStyle(.secondary)
                LabeledContent("화자 구분") {
                    Picker("화자 구분", selection: $controller.diarization) {
                        ForEach(DiarizationChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                Text(controller.diarization.explanation).font(.caption).foregroundStyle(.secondary)
                LabeledContent("시간 표시") {
                    Picker("시간 표시", selection: $controller.transcriptionTimestampMode) {
                        ForEach(TranscriptionTimestampMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                LabeledContent("언어") {
                    Picker("언어", selection: $controller.transcriptionLanguage) {
                        ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
                Text("여기서 바꾼 값은 설정의 기본값과 같은 값입니다.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .disabled(controller.isTranscribing)
            .padding(.top, Spacing.s)
        } label: {
            HStack(spacing: Spacing.s) {
                Label("전사 조건", systemImage: "slider.horizontal.3").font(.headline)
                Spacer()
                Text("\(controller.asrModel.title)  /  \(controller.diarization.title)  /  \(controller.transcriptionLanguage.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(Spacing.l)
        .glassPanel()
        .animation(.appControl, value: showsConditions)
    }

    // MARK: 보관함

    private var library: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Label("녹음 보관함", systemImage: "tray.2").font(.headline)
                Text(controller.recordingOrganizer.isFiltering
                     ? "\(matchingRecordings.count) / \(controller.recordings.count)개"
                     : controller.recordingLibraryStatus)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !controller.recordingOrganizer.isFiltering, controller.recordings.count > Self.collapsedRecordingCount {
                    Button(showsAllRecordings ? "접기" : "전체 \(controller.recordings.count)개 보기") {
                        showsAllRecordings.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if !controller.recordings.isEmpty { RecordingFilterBar(organizer: controller.recordingOrganizer) }
            if controller.recordings.isEmpty {
                EmptyResults(symbol: "waveform", message: "보관함이 비어 있습니다.\n녹음을 시작하거나 Voice Memos 폴더를 연결하세요.")
            } else if visibleRecordings.isEmpty {
                EmptyResults(symbol: "magnifyingglass", message: "조건에 맞는 녹음이 없습니다.")
            } else if controller.recordingOrganizer.groupsByTag {
                ForEach(controller.recordingOrganizer.grouped(visibleRecordings), id: \.tag) { group in
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: group.tag == RecordingOrganizer.untaggedGroup ? "tray" : "tag.fill")
                                .imageScale(.small)
                                .foregroundStyle(group.tag == RecordingOrganizer.untaggedGroup ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.snuBlueLabel))
                            Text(group.tag).font(.callout.weight(.semibold))
                            Text("\(group.recordings.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        grid(group.recordings)
                    }
                }
            } else {
                grid(visibleRecordings)
            }
        }
        .animation(.appContent, value: showsAllRecordings)
        .animation(.appContent, value: controller.recordings.map(\.id))
        .animation(.appContent, value: controller.recordingOrganizer.selectedTags)
        .animation(.appContent, value: controller.recordingOrganizer.groupsByTag)
    }

    private func grid(_ recordings: [RecordingItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Spacing.m)], spacing: Spacing.m) {
            ForEach(recordings) { recording in
                RecordingCard(controller: controller, recording: recording)
            }
        }
    }

    @ViewBuilder
    private func selectedRecordingPanel(_ recording: RecordingItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Label(controller.recordingOrganizer.displayTitle(for: recording), systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.snuBlueLabel)
                    .lineLimit(1)
                Spacer()
                if !recording.isLocallyAvailable {
                    Button(controller.downloadingRecordingIDs.contains(recording.id) ? "다운로드 확인 중" : "iCloud 녹음 받기", systemImage: "icloud.and.arrow.down") {
                        controller.requestVoiceMemoDownload(recording)
                    }
                    .buttonStyle(.bordered)
                    .disabled(controller.downloadingRecordingIDs.contains(recording.id))
                    .help("iCloud에만 있는 녹음을 이 Mac으로 내려받습니다")
                }
                Button("전사 대기열 추가", systemImage: "text.badge.plus") { controller.transcribe(recording: recording) }
                    .buttonStyle(.borderedProminent)
                    .tint(.snuBlue)
                    .disabled(!recording.isLocallyAvailable)
                    .help("현재 전사 조건으로 이 녹음을 대기열에 넣습니다")
            }
            RecordingPlaybackBar(player: controller.recordingPlayer, recording: recording)
            Divider()
            RecordingLabelEditor(organizer: controller.recordingOrganizer, recording: recording)
        }
        .padding(Spacing.l)
        .glassPanel()
        .transition(.appCard)
    }

    // MARK: 결과

    @ViewBuilder
    private var results: some View {
        if let transcript = controller.selectedTranscriptRun, let recording = controller.selectedRecording {
            HStack {
                Picker("전사 버전", selection: Binding(
                    get: { controller.selectedTranscriptRunID ?? transcript.id },
                    set: { controller.selectTranscript($0) }
                )) {
                    ForEach(controller.transcriptRuns(for: recording)) { run in
                        Text(Self.transcriptVersionLabel(run)).tag(run.id)
                    }
                }
                .frame(maxWidth: 520)
                Spacer()
                Text(transcript.settings.displayName).font(.caption).foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(spacing: Spacing.s) {
                        Label("\(controller.organizationKind.title) · \(controller.organizationDetailLevel.title)", systemImage: "slider.horizontal.3")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let eta = controller.organizationETA {
                            Text("약 \(Self.durationString(eta)) 남음").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if controller.isOrganizingTranscript { ProgressView().controlSize(.small) }
                        Button("AI 자동요약", systemImage: "sparkles") {
                            controller.organizeSelectedTranscript()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.snuBlue)
                        .help("이 전사를 로컬 모델로 정리해 대기열에 넣습니다")
                    }
                    if controller.isOrganizingTranscript || !controller.organizationDetail.isEmpty {
                        Text(controller.organizationDetail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = controller.organizationError {
                        DismissibleError(message: error) { controller.organizationError = nil }
                    }
                }
            } label: {
                Label("AI 정리", systemImage: "sparkles").font(.headline).foregroundStyle(Color.snuBlueLabel)
            }

            if let selected = controller.selectedOrganizationRun {
                GroupBox {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        HStack {
                            Picker("정리 버전", selection: Binding(
                                get: { controller.selectedOrganizationRunID ?? selected.id },
                                set: { controller.selectedOrganizationRunID = $0 }
                            )) {
                                ForEach(controller.organizationRuns(for: transcript)) { run in
                                    Text("\(run.kind.title) · \(run.completedAt.formatted(date: .abbreviated, time: .shortened))").tag(run.id)
                                }
                            }
                            .labelsHidden().frame(maxWidth: 320)
                            Spacer()
                            Button("복사", systemImage: "doc.on.doc", action: controller.copySelectedOrganization)
                                .buttonStyle(.bordered)
                        }
                        Text(selected.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Spacing.xs)
                    }
                } label: {
                    Label("AI 정리 결과", systemImage: "text.document.fill").font(.headline)
                }
                .transition(.appCard)
            }
        }

        GroupBox {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack {
                    Text("선택한 전사 버전").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("복사", systemImage: "doc.on.doc", action: controller.copyTranscription)
                        .buttonStyle(.bordered)
                }
                Text(controller.selectedTranscript)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.xs)
            }
        } label: {
            Label("전사 원문", systemImage: "quote.bubble").font(.headline)
        }
    }

    static func durationString(_ seconds: TimeInterval) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private static func transcriptVersionLabel(_ run: TranscriptRun) -> String {
        if run.isLegacy { return "이전 전사 · 조건 미상" }
        return "\(run.completedAt.formatted(date: .abbreviated, time: .shortened)) · \(run.settings.asrModel?.title ?? "모델 미상") · \(Int(run.duration))초"
    }
}

/// One take in the 녹음 보관함 grid.
/// Search, tag chips and grouping for 녹음 보관함.
///
/// Fifty recordings sorted only by date is a pile; this is what turns it into a
/// library. The chips are the tags actually in use, so the bar stays empty until
/// there is something to filter by rather than presenting an empty apparatus.
private struct RecordingFilterBar: View {
    @ObservedObject var organizer: RecordingOrganizer
    @State private var showsTagManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("이름·태그로 찾기", text: $organizer.search)
                    .textFieldStyle(.plain)
                if !organizer.search.isEmpty {
                    Button("지우기", systemImage: "xmark.circle.fill") { organizer.search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                Divider().frame(height: 16)
                Toggle("태그별로 묶기", isOn: $organizer.groupsByTag)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                    .disabled(organizer.allTags.isEmpty)
                if !organizer.allTags.isEmpty {
                    Button("태그 정리", systemImage: "tag") { showsTagManager = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("태그 이름을 바꾸거나 지웁니다")
                }
            }
            // Before the first tag exists this bar is a search box and a disabled
            // checkbox, with the only way in — select a take, scroll to the panel
            // — nowhere on screen. One line fixes that.
            if organizer.allTags.isEmpty {
                Text("녹음을 하나 고르면 아래에서 이름을 붙이고 과목·주제 태그를 달 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(organizer.allTags, id: \.self) { tag in
                            let isOn = organizer.selectedTags.contains(tag)
                            Button {
                                organizer.toggleFilter(tag)
                            } label: {
                                HStack(spacing: 4) {
                                    Text(tag).font(.caption.weight(.medium))
                                    Text("\(organizer.count(of: tag))").font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isOn ? AnyShapeStyle(Color.snuBlue.opacity(0.18)) : AnyShapeStyle(.quaternary), in: Capsule())
                                .overlay(Capsule().strokeBorder(isOn ? Color.snuBlue : .clear))
                            }
                            .buttonStyle(.plain)
                        }
                        if organizer.isFiltering {
                            Button("초기화") { organizer.clearFilter() }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .glassPanel(Radius.card)
        .sheet(isPresented: $showsTagManager) { RecordingTagManager(organizer: organizer) }
    }
}

/// Renaming a tag in one place rather than on every recording that carries it.
private struct RecordingTagManager: View {
    @ObservedObject var organizer: RecordingOrganizer
    @Environment(\.dismiss) private var dismiss
    @State private var editing: String?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("태그 정리").font(.headline)
            Text("이름을 바꾸면 이 태그를 쓰는 녹음 전체에 반영됩니다. 녹음 파일 자체는 건드리지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(organizer.allTags, id: \.self) { tag in
                        HStack(spacing: Spacing.s) {
                            if editing == tag {
                                TextField("태그 이름", text: $draft)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { commit(tag) }
                                Button("확인") { commit(tag) }.buttonStyle(.borderedProminent).tint(.snuBlue)
                                Button("취소") { editing = nil }
                            } else {
                                Text(tag).font(.callout)
                                Text("녹음 \(organizer.count(of: tag))개").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("이름 바꾸기") { editing = tag; draft = tag }.buttonStyle(.borderless)
                                Button("지우기", role: .destructive) { organizer.deleteTag(tag) }.buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, Spacing.xs)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 260)
            HStack {
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.l)
        .frame(width: 420)
    }

    private func commit(_ tag: String) {
        organizer.renameTag(tag, to: draft)
        editing = nil
    }
}

/// The name-and-tags editor for one recording.
private struct RecordingLabelEditor: View {
    @ObservedObject var organizer: RecordingOrganizer
    let recording: RecordingItem

    @State private var name = ""
    @State private var newTag = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Text("이름").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                TextField(recording.title, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit { organizer.rename(recording, to: name) }
                if organizer.hasCustomTitle(recording) {
                    Button("원래 이름", systemImage: "arrow.uturn.backward") {
                        name = ""
                        organizer.rename(recording, to: "")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("파일 이름인 \(recording.title)(으)로 되돌립니다")
                }
            }
            HStack(alignment: .top, spacing: Spacing.s) {
                Text("태그").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    let tags = organizer.tags(for: recording.id)
                    if !tags.isEmpty {
                        HStack(spacing: Spacing.xs) {
                            ForEach(tags, id: \.self) { tag in
                                HStack(spacing: 3) {
                                    Text(tag).font(.caption.weight(.medium))
                                    Button("지우기", systemImage: "xmark") { organizer.removeTag(tag, from: recording.id) }
                                        .labelStyle(.iconOnly).buttonStyle(.plain)
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.snuBlue.opacity(0.16), in: Capsule())
                            }
                        }
                    }
                    HStack(spacing: Spacing.s) {
                        TextField("과목이나 주제 (쉼표로 여러 개)", text: $newTag)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
                            .onSubmit { commitTags() }
                        Button("추가") { commitTags() }
                            .buttonStyle(.bordered)
                            .disabled(RecordingTag.parse(newTag).isEmpty || tags.count >= RecordingTag.maxPerRecording)
                        // Reusing a tag already in the library beats retyping it
                        // and beats creating a near-duplicate by accident.
                        let unused = organizer.allTags.filter { existing in
                            !tags.contains { RecordingTag.key($0) == RecordingTag.key(existing) }
                        }
                        if !unused.isEmpty {
                            Menu {
                                ForEach(unused.prefix(20), id: \.self) { tag in
                                    Button(tag) { organizer.addTag(tag, to: recording.id) }
                                }
                            } label: {
                                Label("기존 태그", systemImage: "tag")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
        }
        .onAppear { name = organizer.labels(for: recording.id).title }
        .onChange(of: recording.id) { _, _ in name = organizer.labels(for: recording.id).title }
        // The field is torn down when the panel closes or the selection moves,
        // and neither of those ever moves focus, so committing on focus loss
        // alone would throw the typed name away.
        .onChange(of: nameFocused) { _, focused in if !focused { organizer.rename(recording, to: name) } }
        .onDisappear { organizer.rename(recording, to: name) }
    }

    private func commitTags() {
        for tag in RecordingTag.parse(newTag) { organizer.addTag(tag, to: recording.id) }
        newTag = ""
    }
}

private struct RecordingCard: View {
    @ObservedObject var controller: AutomationController
    let recording: RecordingItem
    @State private var isHovering = false

    private var isSelected: Bool { controller.selectedRecordingID == recording.id }

    var body: some View {
        Button {
            controller.selectRecording(recording)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: recording.source == .app ? "mic.fill" : "waveform")
                        .foregroundStyle(recording.source == .app ? AnyShapeStyle(Color.snuBlueLabel) : AnyShapeStyle(.secondary))
                    Text(recording.source.rawValue).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if !recording.isLocallyAvailable {
                        Label(controller.downloadingRecordingIDs.contains(recording.id) ? "확인 중" : "iCloud",
                              systemImage: "icloud.and.arrow.down")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if controller.transcribingRecordingID == recording.id {
                        ProgressView().controlSize(.small).tint(.snuBlue)
                    }
                    let runCount = controller.transcriptRuns(for: recording).count
                    if runCount > 0 {
                        Label("\(runCount)", systemImage: "doc.on.doc.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help("이 녹음의 전사본 \(runCount)개")
                    }
                }
                Text(controller.recordingOrganizer.displayTitle(for: recording))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                let tags = controller.recordingOrganizer.tags(for: recording.id)
                if !tags.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(tags.prefix(3), id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.snuBlue.opacity(0.16), in: Capsule())
                        }
                        if tags.count > 3 {
                            Text("+\(tags.count - 3)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "calendar").imageScale(.small)
                    Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Image(systemName: "clock").imageScale(.small)
                    Text(TranscriptionView.durationString(recording.duration)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .contentCard(Radius.card, selected: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering ? 1.012 : 1)
        .animation(.appControl, value: isHovering)
        .animation(.appControl, value: isSelected)
        .accessibilityLabel("\(recording.title), \(recording.source.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            if !recording.isLocallyAvailable {
                Button("iCloud 녹음 받기", systemImage: "icloud.and.arrow.down") { controller.requestVoiceMemoDownload(recording) }
                    .disabled(controller.downloadingRecordingIDs.contains(recording.id))
                Divider()
            }
            Button("전사 대기열 추가", systemImage: "text.badge.plus") { controller.transcribe(recording: recording) }
                .disabled(!recording.isLocallyAvailable)
            Divider()
            // Tagging from the grid, so filing a run of takes does not mean
            // selecting each one and scrolling down to the panel.
            let tags = controller.recordingOrganizer.tags(for: recording.id)
            Menu("태그") {
                ForEach(controller.recordingOrganizer.allTags, id: \.self) { tag in
                    let isOn = tags.contains { RecordingTag.key($0) == RecordingTag.key(tag) }
                    Button(isOn ? "✓ \(tag)" : tag) {
                        if isOn {
                            controller.recordingOrganizer.removeTag(tag, from: recording.id)
                        } else {
                            controller.recordingOrganizer.addTag(tag, to: recording.id)
                        }
                    }
                }
                if controller.recordingOrganizer.allTags.isEmpty {
                    Text("아직 만든 태그가 없습니다. 녹음을 고르면 아래에서 붙일 수 있습니다.")
                }
            }
            Button("이 녹음 열기", systemImage: "arrow.right.circle") { controller.selectRecording(recording) }
            if recording.source == .app {
                Divider()
                Button("파일 이름 변경…", systemImage: "pencil") { RenameRecordingPanel.present(recording: recording, controller: controller) }
                Button("휴지통으로 이동", systemImage: "trash", role: .destructive) { controller.delete(recording) }
            }
        }
    }
}


/// The 재생바 for the selected take: play/pause, ±15초 이동 and a scrubber that
/// seeks inside the recording. It observes the player directly rather than going
/// through the controller, so the position update ten times a second repaints
/// this row alone instead of the whole 녹음 전사 window.
private struct RecordingPlaybackBar: View {
    @ObservedObject var player: RecordingPlayer
    let recording: RecordingItem
    /// Non-nil only while the thumb is held, so the running take cannot drag the
    /// slider out from under the pointer.
    @State private var scrubTime: TimeInterval?

    private var isPlaying: Bool { player.isPlaying(recording) }
    private var duration: TimeInterval { player.duration(of: recording) }
    private var position: TimeInterval { scrubTime ?? player.position(of: recording) }

    private var scrubBinding: Binding<Double> {
        Binding(get: { min(position, max(duration, 0.1)) }, set: { scrubTime = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button {
                    player.toggle(recording)
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 13, height: 13)
                }
                .buttonStyle(.bordered)
                .help(isPlaying ? "일시정지" : "재생")
                .accessibilityLabel(isPlaying ? "일시정지" : "재생")
                Button { player.skip(recording, by: -15) } label: { Image(systemName: "gobackward.15") }
                    .buttonStyle(.borderless)
                    .help("15초 뒤로")
                    .accessibilityLabel("15초 뒤로")
                Button { player.skip(recording, by: 15) } label: { Image(systemName: "goforward.15") }
                    .buttonStyle(.borderless)
                    .help("15초 앞으로")
                    .accessibilityLabel("15초 앞으로")
                Text(position.playbackTimeLabel)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 38, alignment: .trailing)
                Slider(value: scrubBinding, in: 0...max(duration, 0.1)) { isEditing in
                    if isEditing {
                        scrubTime = player.position(of: recording)
                    } else if let scrubTime {
                        player.seek(recording, to: scrubTime)
                        self.scrubTime = nil
                    }
                }
                .controlSize(.small)
                .accessibilityLabel("재생 위치")
                Text("-\(max(0, duration - position).playbackTimeLabel)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .leading)
            }
            .disabled(!recording.isLocallyAvailable)
            if let error = player.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}

private enum RenameRecordingPanel {
    @MainActor
    static func present(recording: RecordingItem, controller: AutomationController) {
        let alert = NSAlert()
        alert.messageText = "녹음 이름 변경"
        alert.informativeText = "이 앱에서 만든 녹음 파일의 이름을 변경합니다."
        let field = NSTextField(string: recording.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "변경")
        alert.addButton(withTitle: "취소")
        if alert.runModal() == .alertFirstButtonReturn { controller.rename(recording, to: field.stringValue) }
    }
}

private struct ProcessingQueueCard: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Label("작업 대기열", systemImage: "tray.full.fill")
                    .font(.headline)
                Spacer()
                Text("\(controller.processingQueue.count)개")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.snuBlueLabel)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xs)
                    .background(Color.snuBlue.opacity(0.12), in: Capsule())
                    .monospacedDigit()
                if !controller.waitingProcessingItems.isEmpty {
                    Button("대기 항목 지우기") { controller.clearWaitingProcessingItems() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("아직 시작하지 않은 항목을 모두 제거합니다")
                }
            }

            if let active = controller.activeProcessingItem {
                ProcessingQueueRow(item: active, status: "처리 중", isActive: true) {
                    controller.cancelProcessingItem(active.id)
                }
                .transition(.appCard)
            }

            ForEach(Array(controller.waitingProcessingItems.enumerated()), id: \.element.id) { index, item in
                ProcessingQueueRow(item: item, status: "대기 \(index + 1)번", isActive: false) {
                    controller.cancelProcessingItem(item.id)
                }
                .transition(.appCard)
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
        .animation(.appContent, value: controller.activeProcessingItemID)
        .animation(.appContent, value: controller.processingQueue.map(\.id))
    }
}

private struct ProcessingQueueRow: View {
    let item: ProcessingQueueItem
    let status: String
    let isActive: Bool
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            ZStack {
                Circle().fill(isActive ? AnyShapeStyle(Color.snuBlue.opacity(0.16)) : AnyShapeStyle(.quaternary))
                if isActive {
                    ProgressView().controlSize(.small).tint(.snuBlue)
                } else {
                    Image(systemName: item.kind.symbol).foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Spacing.xs) {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(item.kind.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.kind == .transcription ? Color.snuBlueLabel : Color.purple)
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Text(status)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.snuBlueLabel : .secondary)
            Button(action: cancel) {
                Image(systemName: isActive ? "stop.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isActive ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isActive ? "현재 작업 중단" : "대기열에서 제거")
            .accessibilityLabel(isActive ? "현재 작업 중단" : "대기열에서 제거")
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(
            isActive ? Color.snuBlue.opacity(0.08) : Color.clear,
            in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        )
    }
}

private struct TranscriptionProgressCard: View {
    let step: Int
    let detail: String
    let timestamps: Bool
    let diarizing: Bool
    let eta: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Label("전사 진행 중", systemImage: "waveform.badge.magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(Color.snuBlueLabel)
                Spacer()
                Text("\(min(step, 4)) / 4").font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            if let eta, step >= 2 {
                Label("약 \(Self.etaString(eta)) 남음", systemImage: "clock")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
            } else if step == 1 {
                Text("예상 시간 계산 중").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(step), total: 4).tint(.snuBlue)
            HStack(spacing: Spacing.s) {
                ProgressPill(title: "준비", isActive: step == 1, isDone: step > 1)
                ProgressPill(title: timestamps ? "음성·시간" : "음성 인식", isActive: step == 2, isDone: step > 2)
                ProgressPill(title: diarizing ? "화자 분리" : "화자 건너뜀", isActive: step == 3, isDone: step > 3)
                ProgressPill(title: "결과", isActive: step == 4, isDone: false)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
        .animation(.appControl, value: step)
    }

    private static func etaString(_ seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        return rounded >= 60 ? "\(rounded / 60)분 \(rounded % 60)초" : "\(rounded)초"
    }
}

private struct ProgressPill: View {
    let title: String
    let isActive: Bool
    let isDone: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: isDone ? "checkmark" : (isActive ? "circle.inset.filled" : "circle")).imageScale(.small)
            Text(title).lineLimit(1)
        }
        .font(.caption2.weight(isActive ? .semibold : .regular))
        .foregroundStyle(isDone ? .green : (isActive ? Color.snuBlueLabel : .secondary))
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xs + 2)
        .background(isActive ? Color.snuBlue.opacity(0.12) : .clear, in: Capsule())
    }
}

private struct ProgressStep: View {
    let title: String
    let isCurrent: Bool
    let isDone: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: isDone ? "checkmark.circle.fill" : (isCurrent ? "circle.inset.filled" : "circle"))
                .foregroundStyle(isDone ? Color.green : (isCurrent ? Color.snuBlueLabel : Color.secondary))
            Text(title).font(.caption).foregroundStyle(isCurrent ? .primary : .secondary)
        }
    }
}

private struct MediaImportCard: View {
    @ObservedObject var controller: AutomationController

    private var toolsMissing: Bool { MediaImporter.ytDLPPath == nil || MediaImporter.ffmpegPath == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label("영상에서 가져오기", systemImage: "play.rectangle.on.rectangle")
                .font(.headline)
            Text("강의 영상 주소를 붙여넣으면 오디오만 이 Mac으로 내려받아 전사 대기열에 넣습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: Spacing.s) {
                TextField("https://…", text: $controller.mediaURLText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.importMediaFromURL() }
                    .disabled(controller.isImportingMedia || toolsMissing)
                if controller.isImportingMedia {
                    Button("중단", systemImage: "stop.fill") { controller.stopMediaImport() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .help("내려받기를 중단합니다")
                } else {
                    Button("가져오기", systemImage: "arrow.down.circle") { controller.importMediaFromURL() }
                        .buttonStyle(.borderedProminent)
                        .tint(.snuBlue)
                        .disabled(toolsMissing || controller.mediaURLText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help("이 주소의 오디오만 내려받아 전사 대기열에 넣습니다")
                }
            }
            if controller.isImportingMedia || !controller.mediaImportStatus.isEmpty {
                HStack(spacing: Spacing.s) {
                    if controller.isImportingMedia { ProgressView().controlSize(.small) }
                    Text(controller.mediaImportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.appBanner)
            }
            if let error = controller.mediaImportError {
                DismissibleError(message: error) { controller.mediaImportError = nil }
            }
            if toolsMissing {
                Label("yt-dlp와 ffmpeg가 필요합니다 · 터미널에서 `brew install yt-dlp ffmpeg`", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel()
        .animation(.appContent, value: controller.isImportingMedia)
        .animation(.appContent, value: controller.mediaImportError)
    }
}


private struct DocumentRecognitionView: View {
    @ObservedObject var controller: AutomationController
    @State private var isDropTarget = false

    var body: some View {
        WorkspaceScreen(title: AppSection.documents.title, subtitle: AppSection.documents.subtitle) {
            dropWell

            HStack(spacing: Spacing.s) {
                if !controller.recognizedSourceName.isEmpty {
                    Text(controller.recognizedSourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text("·").font(.caption).foregroundStyle(.tertiary)
                }
                Text(controller.recognitionStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }

            if let error = controller.recognitionError {
                DismissibleError(message: error) { controller.recognitionError = nil }
            }

            if controller.recognizedText.isEmpty && controller.recognizedNoteText.isEmpty && !controller.isRecognizingDocument {
                EmptyResults(symbol: "text.viewfinder", message: "아직 인식한 문서가 없습니다.\n위에 파일을 드롭하거나 툴바에서 화면 영역을 캡처하세요.")
            }

            if !controller.recognizedText.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        HStack(spacing: Spacing.s) {
                            Button("AI로 정리", systemImage: "sparkles") { controller.organizeRecognizedText() }
                                .buttonStyle(.borderedProminent)
                                .tint(.snuBlue)
                                .disabled(controller.isOrganizingTranscript)
                                .help("인식한 텍스트를 로컬 모델로 정리해 대기열에 넣습니다")
                            Button("복사", systemImage: "doc.on.doc", action: controller.copyRecognizedText)
                                .buttonStyle(.bordered)
                            Button("텍스트로 저장…", systemImage: "square.and.arrow.down", action: controller.saveRecognizedText)
                                .buttonStyle(.bordered)
                            Spacer()
                            if controller.isOrganizingTranscript { ProgressView().controlSize(.small) }
                        }
                        if controller.isOrganizingTranscript || !controller.organizationDetail.isEmpty {
                            Text(controller.organizationDetail).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(controller.recognizedText)
                            .font(controller.recognizedTextIsMarkdown ? .body.monospaced() : .body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Spacing.xs)
                    }
                } label: {
                    Label(
                        controller.recognizedTextIsMarkdown ? "인식한 Markdown (수식은 LaTeX)" : "인식한 텍스트",
                        systemImage: controller.recognizedTextIsMarkdown ? "function" : "doc.plaintext"
                    ).font(.headline)
                }
                .transition(.appCard)
            }

            if !controller.recognizedNoteText.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        HStack {
                            Spacer()
                            Button("복사", systemImage: "doc.on.doc", action: controller.copyRecognizedNote)
                                .buttonStyle(.bordered)
                        }
                        Text(controller.recognizedNoteText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Spacing.xs)
                    }
                } label: {
                    Label("AI 정리 결과", systemImage: "sparkles").font(.headline).foregroundStyle(Color.snuBlueLabel)
                }
                .transition(.appCard)
            }
        }
        .animation(.appContent, value: controller.recognizedText)
        .animation(.appContent, value: controller.recognizedNoteText)
        .animation(.appContent, value: controller.recognitionError)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("인식 방식", selection: $controller.documentMode) {
                    ForEach(DocumentRecognitionMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(controller.isRecognizingDocument)
                .help(controller.documentMode.detail)
            }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button("파일 선택…", systemImage: "doc.badge.plus") { chooseFile() }
                    .disabled(controller.isRecognizingDocument)
                    .help("인식할 이미지 또는 PDF를 고릅니다")
            }
            ToolbarItem {
                if controller.isRecognizingDocument {
                    Button("중단", systemImage: "stop.fill") { controller.stopDocumentRecognition() }
                        .tint(.red)
                        .toolbarKeepsTitle()
                        .help("인식을 중단합니다")
                } else {
                    Button("화면 영역 캡처", systemImage: "camera.viewfinder") { controller.captureScreenAndRecognize() }
                        .buttonStyle(.glassProminent)
                        .tint(.snuBlue)
                        .toolbarKeepsTitle()
                        .help("화면의 일부를 끌어 선택해 바로 인식합니다")
                }
            }
        }
    }

    private var dropWell: some View {
        VStack(spacing: Spacing.s) {
            if controller.isRecognizingDocument {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(isDropTarget ? AnyShapeStyle(Color.snuBlueLabel) : AnyShapeStyle(.tertiary))
            }
            Text(controller.isRecognizingDocument
                 ? "문서를 인식하는 중입니다 · 끝난 뒤에 넣어 주세요"
                 : "여기로 이미지 또는 PDF를 드롭하세요 · 한 번에 한 개")
                .font(.callout)
                .foregroundStyle(controller.isRecognizingDocument ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .multilineTextAlignment(.center)
        .padding(Spacing.l)
        .dropWell(isTargeted: isDropTarget, enabled: !controller.isRecognizingDocument)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            guard let provider = providers.first else { return false }
            // The recogniser handles one document at a time, so the rest of a
            // multi-file drop is dropped — say so instead of leaving the user to
            // notice four missing results.
            let extras = providers.count - 1
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    controller.recognizeDocument(fileURL: url)
                    if extras > 0 {
                        controller.recognitionError = "문서 인식은 한 번에 한 개만 처리합니다. 첫 번째 파일만 인식했고 나머지 \(extras)개는 넣지 않았습니다."
                    }
                }
            }
            return true
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "인식할 이미지 또는 PDF 선택"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.recognizeDocument(fileURL: url)
    }
}

// MARK: - 누끼 따기

/// Built from the same pieces as every other tool screen: the name in the title
/// bar, the primary action in the toolbar, a drop well first in the body, a
/// caption status line, then results.
private struct CutoutView: View {
    @ObservedObject var controller: AutomationController
    @State private var isDropTarget = false

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: Spacing.l)]

    var body: some View {
        WorkspaceScreen(title: AppSection.cutout.title, subtitle: AppSection.cutout.subtitle) {
            dropWell
            backgroundPicker

            HStack(spacing: Spacing.s) {
                Text(controller.cutoutStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(controller.mattingModel.title).font(.caption).foregroundStyle(.tertiary)
            }

            if let error = controller.cutoutError {
                DismissibleError(message: error) { controller.cutoutError = nil }
            }

            if controller.cutoutItems.isEmpty {
                EmptyResults(symbol: "person.and.background.dotted", message: "아직 누끼를 딴 사진이 없습니다.\n위에 사진을 드롭하거나 툴바에서 골라 주세요.")
            } else {
                LazyVGrid(columns: columns, spacing: Spacing.l) {
                    ForEach(controller.cutoutItems) { item in
                        CutoutCard(controller: controller, item: item)
                            .transition(.appCard)
                    }
                }
            }
            ToolHistoryPanel(tool: "Cutout", isBusy: controller.isRemovingBackground) { controller.removeBackground(fileURLs: $0) }
        }
        .animation(.appContent, value: controller.cutoutItems.map(\.id))
        .animation(.appContent, value: controller.cutoutError)
        .toolbar {
            ToolbarItem {
                Menu("결과", systemImage: "ellipsis") {
                    if !controller.selectedCutoutIDs.isEmpty {
                        Button("선택한 결과 저장…", systemImage: "square.and.arrow.down.on.square") { controller.saveSelectedCutouts() }
                            .disabled(!controller.cutoutItems.contains { controller.selectedCutoutIDs.contains($0.id) && $0.isFinished })
                        Button("선택한 \(controller.selectedCutoutIDs.count)개 삭제", systemImage: "trash", role: .destructive) { controller.deleteSelectedCutouts() }
                            .disabled(controller.isRemovingBackground)
                        Button("선택 해제", systemImage: "xmark.circle") { controller.selectedCutoutIDs.removeAll() }
                        Divider()
                    }
                    Button("완료 결과 모두 선택", systemImage: "checkmark.circle") { controller.selectAllCutouts() }
                        .disabled(!controller.cutoutItems.contains(where: \.isFinished))
                    Button("모두 저장…", systemImage: "square.and.arrow.down.on.square") { controller.saveAllCutouts() }
                        .disabled(!controller.cutoutItems.contains(where: \.isFinished))
                    Button("목록 비우기", systemImage: "trash", role: .destructive) { controller.clearCutouts() }
                        .disabled(controller.cutoutItems.isEmpty || controller.isRemovingBackground)
                }
                .help("누끼 결과를 한꺼번에 저장하거나 목록을 비웁니다")
            }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                if controller.isRemovingBackground {
                    Button("중단", systemImage: "stop.fill") { controller.stopBackgroundRemoval() }
                        .tint(.red)
                        .toolbarKeepsTitle()
                        .help("남은 사진 처리를 중단합니다")
                } else {
                    Button("사진 선택…", systemImage: "photo.badge.plus") { choosePhotos() }
                        .buttonStyle(.glassProminent)
                        .tint(.snuBlue)
                        .toolbarKeepsTitle()
                        .help("누끼를 딸 사진을 고릅니다 · 여러 장 가능")
                }
            }
        }
    }

    private var dropWell: some View {
        VStack(spacing: Spacing.s) {
            if controller.isRemovingBackground {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(isDropTarget ? AnyShapeStyle(Color.snuBlueLabel) : AnyShapeStyle(.tertiary))
            }
            Text(controller.isRemovingBackground
                 ? "누끼를 따는 중입니다 · 끝나거나 중단한 뒤에 넣어 주세요"
                 : "여기로 사진을 드롭하세요 · 여러 장도 됩니다")
                .font(.callout)
                .foregroundStyle(controller.isRemovingBackground ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .multilineTextAlignment(.center)
        .padding(Spacing.l)
        .dropWell(isTargeted: isDropTarget, enabled: !controller.isRemovingBackground)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            load(providers)
            return true
        }
    }

    private var backgroundPicker: some View {
        HStack(spacing: Spacing.m) {
            Text("배경").font(.callout).foregroundStyle(.secondary)
            Picker("배경", selection: $controller.cutoutBackground) {
                ForEach(CutoutBackground.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
            .help("누끼 뒤에 깔 배경입니다. 저장할 때 함께 적용됩니다")
            if controller.cutoutBackground == .custom {
                ColorPicker("배경색", selection: $controller.cutoutCustomColor, supportsOpacity: false)
                    .labelsHidden()
                    .transition(.opacity)
            }
            Spacer()
        }
        .animation(.appControl, value: controller.cutoutBackground)
    }

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.title = "누끼를 딸 사진 선택"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        controller.removeBackground(fileURLs: panel.urls)
    }

    /// Every provider is collected before starting, so a multi-photo drop runs
    /// as one batch through the warm model instead of several rejected calls.
    private func load(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collected = DroppedURLs()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                collected.append(url)
            }
        }
        group.notify(queue: .main) {
            let urls = collected.all
            guard !urls.isEmpty else { return }
            Task { @MainActor in controller.removeBackground(fileURLs: urls) }
        }
    }
}


private struct CutoutCard: View {
    @ObservedObject var controller: AutomationController
    let item: CutoutItem
    @State private var preview: CGImage?
    @State private var showsEditor = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ZStack {
                CheckerboardBackground()
                if let image = preview {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else if case .failed = item.state {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if item.isFinished {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2.weight(.semibold))
                        .padding(5)
                        .background(.thinMaterial, in: Circle())
                        .padding(6)
                        .opacity(isHovering ? 1 : 0.55)
                }
            }
            // A 170-point card is too small to judge a cutout edge, so the picture
            // itself is the way into the large view.
            .onTapGesture { if item.isFinished { showsEditor = true } }
            .onHover { isHovering = $0 }
            .scaleEffect(isHovering && item.isFinished ? 1.012 : 1)
            .animation(.appControl, value: isHovering)
            .help(item.isFinished ? "클릭하면 크게 보고 자르기·뒤집기를 할 수 있습니다" : "")
            .accessibilityLabel("\(item.source.lastPathComponent) 누끼 결과")
            .accessibilityAddTraits(item.isFinished ? .isButton : [])

            HStack(spacing: Spacing.xs) {
                Text(item.source.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Spacing.xs)
                if let preview {
                    // The card shows a thumbnail, so the real size of what would be
                    // saved is otherwise invisible.
                    Text(pixelSizeText(preview)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let summary = item.edit.summary {
                Label(summary, systemImage: "crop").font(.caption2).foregroundStyle(Color.snuBlueLabel).lineLimit(1)
            }
            Text(item.statusText)
                .font(.caption2)
                .foregroundStyle(isFailed ? Color.red : .secondary)
                .lineLimit(2)
            if item.isFinished {
                // One primary action plus a menu, rather than three equal buttons
                // fighting for a 220-point row.
                HStack(spacing: Spacing.s) {
                    Button("크게 보기", systemImage: "arrow.up.left.and.arrow.down.right") { showsEditor = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("크게 보고 자르기·뒤집기")
                    Spacer(minLength: Spacing.xs)
                    Menu {
                        Button("복사", systemImage: "doc.on.doc") { controller.copyCutout(item) }
                        Button("저장…", systemImage: "square.and.arrow.down") { controller.saveCutout(item) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("복사하거나 파일로 저장합니다")
                    .accessibilityLabel("이 누끼의 추가 동작")
                }
            }
        }
        .padding(Spacing.m)
        .contentCard(Radius.card, selected: controller.selectedCutoutIDs.contains(item.id))
        .overlay(alignment: .topLeading) {
            Button { controller.toggleCutoutSelection(item.id) } label: {
                Image(systemName: controller.selectedCutoutIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(controller.selectedCutoutIDs.contains(item.id) ? Color.snuBlueLabel : .secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .help("한꺼번에 저장하거나 삭제하도록 선택")
        }
        .task(id: previewKey) { await loadPreview() }
        .sheet(isPresented: $showsEditor) {
            PhotoEditorSheet(
                title: item.source.lastPathComponent,
                subtitle: "누끼 결과",
                load: { [output = item.output, choice = controller.cutoutBackground, custom = controller.cutoutCustomColorComponents] in
                    guard let output else { return nil }
                    return CutoutComposer.preview(of: output, maxPixel: 1800, background: choice.color(custom: custom))
                },
                edit: Binding(
                    get: { item.edit },
                    set: { controller.updateCutoutEdit(item.id, to: $0) }
                ),
                showsCheckerboard: controller.cutoutBackground == .transparent
            )
        }
    }

    private var isFailed: Bool { if case .failed = item.state { true } else { false } }

    /// The thumbnail is downscaled, so its own size says nothing; this reports what
    /// the exported PNG will actually be.
    private func pixelSizeText(_ preview: CGImage) -> String {
        guard let output = item.output, let full = CutoutComposer.size(of: output) else {
            return "\(preview.width)×\(preview.height)"
        }
        let size = item.edit.resultSize(of: full)
        return "\(Int(size.width))×\(Int(size.height))"
    }

    /// Rebuilt only when the cutout or the chosen background actually changes,
    /// and always off the main thread: a phone photo is big enough that doing
    /// this per redraw would stutter the whole tab.
    private var previewKey: String {
        let colour = controller.cutoutBackground == .custom
            ? AutomationController.hex(from: controller.cutoutCustomColor)
            : ""
        return "\(item.output?.path ?? "")|\(controller.cutoutBackground.rawValue)|\(colour)|\(item.edit)"
    }

    private func loadPreview() async {
        guard let output = item.output else {
            preview = nil
            return
        }
        let choice = controller.cutoutBackground
        let custom = controller.cutoutCustomColorComponents
        let edit = item.edit
        preview = await Task.detached(priority: .userInitiated) {
            CutoutComposer.preview(of: output, maxPixel: 640, background: choice.color(custom: custom), edit: edit)
        }.value
    }
}


// MARK: - 용량 줄이기

/// Built from the same pieces as `CutoutView`: the name in the title bar, the
/// primary action in the toolbar, a drop well first in the body, a caption
/// status line and a card grid. What is different is where files come *from* —
/// the Photos library and the folders they actually live in — and the
/// before/after numbers.
private struct FileCompressionView: View {
    @ObservedObject var controller: AutomationController
    @State private var isDropTarget = false
    @State private var photoSelection: [PhotosPickerItem] = []

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: Spacing.l)]

    var body: some View {
        WorkspaceScreen(title: AppSection.compression.title, subtitle: AppSection.compression.subtitle) {
            dropWell
            quickFolders
            settings
            statusLine
            ToolHistoryPanel(tool: "Compress", isBusy: controller.isCompressing) { controller.compress(fileURLs: $0) }

            if controller.compressionItems.isEmpty {
                EmptyResults(symbol: "arrow.down.right.and.arrow.up.left", message: "아직 줄인 파일이 없습니다.\n위에 파일을 드롭하거나 툴바에서 사진 앱·파일을 고르세요.")
            } else {
                LazyVGrid(columns: columns, spacing: Spacing.l) {
                    ForEach(controller.compressionItems) { item in
                        CompressionCard(controller: controller, item: item)
                            .transition(.appCard)
                    }
                }
            }
        }
        .animation(.appContent, value: controller.compressionItems.map(\.id))
        .animation(.appContent, value: controller.compressionError)
        .onChange(of: photoSelection) { _, selection in
            guard !selection.isEmpty else { return }
            importFromPhotos(selection)
        }
        .toolbar {
            ToolbarItem {
                Menu("결과", systemImage: "ellipsis") {
                    if !controller.selectedCompressionIDs.isEmpty {
                        Button("선택한 결과 저장…", systemImage: "square.and.arrow.down.on.square") { controller.saveSelectedCompressed() }
                            .disabled(!controller.compressionItems.contains { controller.selectedCompressionIDs.contains($0.id) && $0.isFinished })
                        Button("선택한 \(controller.selectedCompressionIDs.count)개 삭제", systemImage: "trash", role: .destructive) { controller.deleteSelectedCompressed() }
                            .disabled(controller.isCompressing)
                        Button("선택 해제", systemImage: "xmark.circle") { controller.selectedCompressionIDs.removeAll() }
                        Divider()
                    }
                    Button("완료 결과 모두 선택", systemImage: "checkmark.circle") { controller.selectAllCompressed() }
                        .disabled(!controller.compressionItems.contains(where: \.isFinished))
                    Button("모두 저장…", systemImage: "square.and.arrow.down.on.square") { controller.saveAllCompressed() }
                        .disabled(!controller.compressionItems.contains(where: \.isFinished))
                    Button("목록 비우기", systemImage: "trash", role: .destructive) { controller.clearCompression() }
                        .disabled(controller.compressionItems.isEmpty || controller.isCompressing)
                }
                .help("줄인 파일을 한꺼번에 저장하거나 목록을 비웁니다")
            }
            ToolbarItem {
                // Editing a photo puts its card back to 대기 중; this is how the
                // new version actually gets made. Prominent only when something
                // is genuinely waiting for it.
                Button("다시 실행", systemImage: "arrow.clockwise") { controller.recompress() }
                    .disabled(controller.compressionItems.isEmpty || controller.isCompressing)
                    .tint(controller.hasPendingCompression ? Color.snuBlue : nil)
                    .help(controller.hasPendingCompression
                          ? "편집한 사진이 아직 반영되지 않았습니다 · 지금 다시 실행합니다"
                          : "목록의 파일을 현재 설정으로 다시 처리합니다")
            }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button("파일 선택…", systemImage: "folder") { choose(startingAt: nil) }
                    .disabled(controller.isCompressing)
                    .help("줄일 파일이나 폴더를 고릅니다")
            }
            ToolbarItem {
                if controller.isCompressing {
                    Button("중단", systemImage: "stop.fill") { controller.stopCompression() }
                        .tint(.red)
                        .toolbarKeepsTitle()
                        .help("남은 파일 처리를 중단합니다")
                } else {
                    PhotosPicker(selection: $photoSelection, matching: .any(of: [.images, .videos])) {
                        Label("사진 앱에서", systemImage: "photo.stack")
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.snuBlue)
                    .help("사진 보관함에서 직접 고릅니다 · 사진 권한 없이 동작합니다")
                    .toolbarKeepsTitle()
                }
            }
        }
    }

    private var dropWell: some View {
        VStack(spacing: Spacing.s) {
            if controller.isCompressing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(isDropTarget ? AnyShapeStyle(Color.snuBlueLabel) : AnyShapeStyle(.tertiary))
            }
            Text(controller.isCompressing
                 ? "용량을 줄이는 중입니다 · 끝나거나 중단한 뒤에 넣어 주세요"
                 : "여기로 파일이나 폴더를 드롭하세요 · 사진 · PDF · 영상")
                .font(.callout)
                .foregroundStyle(controller.isCompressing ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .multilineTextAlignment(.center)
        .padding(Spacing.l)
        .dropWell(isTargeted: isDropTarget, enabled: !controller.isCompressing)
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            load(providers)
            return true
        }
    }

    private var quickFolders: some View {
        HStack(spacing: Spacing.s) {
            Text("빠른 폴더").font(.caption).foregroundStyle(.secondary)
            ForEach(QuickFolder.available) { folder in
                Button(folder.title) { choose(startingAt: folder.url) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(controller.isCompressing)
                    .help("\(folder.title) 폴더에서 바로 고릅니다")
            }
            if let recent = controller.lastCompressionSaveFolder {
                Button("최근 저장 폴더") { choose(startingAt: recent) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(controller.isCompressing)
                    .help(recent.path)
            }
            Spacer()
        }
    }

    // MARK: 설정

    private var settings: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.l) {
                LabeledContent("방식") {
                    Picker("방식", selection: $controller.compressionMode) {
                        ForEach(CompressionMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                .fixedSize()

                if controller.compressionMode == .level {
                    LabeledContent("정도") {
                        Picker("정도", selection: $controller.compressionLevel) {
                            ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    .fixedSize()
                } else {
                    LabeledContent("목표") {
                        Picker("목표", selection: $controller.compressionTargetBytes) {
                            ForEach(Self.targetChoices, id: \.bytes) { Text($0.title).tag($0.bytes) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    .fixedSize()
                }
                Spacer()
            }
            .disabled(controller.isCompressing)
            .animation(.appControl, value: controller.compressionMode)

            HStack(spacing: Spacing.l) {
                Picker("사진 형식", selection: $controller.compressionImageFormat) {
                    ForEach(ImageOutputFormat.allCases) { format in
                        Text(format == .webp && !ImageOutputFormat.isWebPAvailable ? "WebP (brew install webp 필요)" : format.title)
                            .tag(format)
                    }
                }
                .frame(maxWidth: 260)

                Picker("영상 코덱", selection: $controller.compressionVideoCodec) {
                    ForEach(VideoOutputCodec.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 260)
                Spacer()
            }
            .disabled(controller.isCompressing)

            Text(InlineMarkup.attributed(explanation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.l)
        .glassPanel()
    }

    /// Says out loud what the current combination will actually do, including
    /// the two cases that would otherwise look like bugs: PNG ignoring the
    /// quality steps, and WebP needing a Homebrew package.
    private var explanation: String {
        var lines: [String] = []
        if controller.compressionMode == .level {
            lines.append(controller.compressionLevel.detail)
        } else {
            lines.append("각 파일을 목표 용량 아래로 맞춥니다. 사진은 품질을 자동으로 탐색하고 영상은 비트레이트를 계산합니다.")
        }
        if controller.compressionImageFormat == .png {
            lines.append("PNG는 무손실이라 단계는 해상도만 바꿉니다. 용량을 줄이려면 JPEG·HEIC·WebP·AVIF를 고르세요.")
        }
        if controller.compressionImageFormat == .webp, !ImageOutputFormat.isWebPAvailable {
            lines.append("WebP로 저장하려면 터미널에서 `brew install webp`를 실행해 주세요.")
        }
        if MediaImporter.ffmpegPath == nil {
            lines.append("영상을 압축하려면 `brew install ffmpeg`가 필요합니다.")
        }
        return lines.joined(separator: " ")
    }

    static let targetChoices: [(title: String, bytes: Int)] = [
        ("500 KB", 512_000), ("1 MB", 1_048_576), ("2 MB", 2_097_152),
        ("5 MB", 5_242_880), ("10 MB", 10_485_760), ("25 MB", 26_214_400),
    ]

    // MARK: 진행 상황

    @ViewBuilder
    private var statusLine: some View {
        if controller.isCompressing || !controller.compressionItems.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if controller.isCompressing {
                    ProgressView(value: controller.compressionProgressValue).tint(.snuBlue)
                }
                HStack(spacing: Spacing.m) {
                    Text(controller.compressionCountText)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                    if !controller.compressionETAString.isEmpty {
                        Label(controller.compressionETAString, systemImage: "clock.arrow.circlepath")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    if !controller.compressionSavingsText.isEmpty {
                        Text(controller.compressionSavingsText)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.snuBlueLabel)
                            .monospacedDigit()
                    }
                }
            }
            .padding(Spacing.m)
            .glassPanel(Radius.card)
            .transition(.appCard)
        }
        Text(controller.compressionStatus).font(.caption).foregroundStyle(.secondary)
        if let error = controller.compressionError {
            DismissibleError(message: error) { controller.compressionError = nil }
        }
    }

    // MARK: 입력 처리

    private func choose(startingAt directory: URL?) {
        let panel = NSOpenPanel()
        panel.title = "용량을 줄일 파일 선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = directory
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        controller.compress(fileURLs: panel.urls)
    }

    /// Every provider is collected before starting, so a multi-file drop runs as
    /// one batch with one estimate rather than several rejected calls.
    private func load(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let collected = DroppedURLs()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                collected.append(url)
            }
        }
        group.notify(queue: .main) {
            let urls = collected.all
            guard !urls.isEmpty else { return }
            Task { @MainActor in controller.compress(fileURLs: urls) }
        }
    }

    /// `PhotosPicker` runs out of process, so this reaches the library without
    /// asking for photo permission and without adding anything to Info.plist.
    /// Items arrive as files rather than as `Data` so a two-gigabyte recording
    /// never has to sit in memory.
    private func importFromPhotos(_ selection: [PhotosPickerItem]) {
        photoSelection = []
        Task { @MainActor in
            controller.reportCompressionStatus("사진 앱에서 \(selection.count)개를 가져오는 중")
            var urls: [URL] = []
            for item in selection {
                if let picked = try? await item.loadTransferable(type: PickedFile.self) {
                    urls.append(picked.url)
                }
            }
            guard !urls.isEmpty else {
                controller.compressionError = "사진 앱에서 파일을 가져오지 못했습니다."
                return
            }
            controller.compress(fileURLs: urls)
        }
    }
}


private struct CompressionCard: View {
    @ObservedObject var controller: AutomationController
    let item: CompressionItem
    @State private var preview: CGImage?
    @State private var showsEditor = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            thumbnail
            HStack(spacing: Spacing.xs) {
                Image(systemName: item.kind.symbol).font(.caption2).foregroundStyle(.secondary)
                Text(item.source.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            Text(item.sizeText)
                .font(.caption.weight(.medium))
                .foregroundStyle(item.isFinished ? Color.snuBlueLabel : .secondary)
                .monospacedDigit()
            if !item.specText.isEmpty {
                Text(item.specText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if let summary = item.edit.summary {
                Label(summary, systemImage: "crop").font(.caption2).foregroundStyle(Color.snuBlueLabel).lineLimit(1)
            }
            if item.isFailed || item.note != nil || !item.isFinished {
                Text(item.statusText)
                    .font(.caption2)
                    .foregroundStyle(item.isFailed ? Color.red : .secondary)
                    .lineLimit(2)
            }
            actions
        }
        .padding(Spacing.m)
        .contentCard(Radius.card, selected: controller.selectedCompressionIDs.contains(item.id))
        .overlay(alignment: .topLeading) {
            Button { controller.toggleCompressionSelection(item.id) } label: {
                Image(systemName: controller.selectedCompressionIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(controller.selectedCompressionIDs.contains(item.id) ? Color.snuBlueLabel : .secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .help("한꺼번에 저장하거나 삭제하도록 선택")
        }
        .task(id: previewKey) { await loadPreview() }
        .sheet(isPresented: $showsEditor) {
            PhotoEditorSheet(
                title: item.source.lastPathComponent,
                subtitle: item.originalDetail,
                // The source, not the result: the edit is applied while compressing,
                // so what the user frames here is what goes into that pass.
                load: { [source = item.source] in
                    try? ImageCompressor.decode(source, maxPixel: 1800).image
                },
                edit: Binding(
                    get: { item.edit },
                    set: { controller.updateCompressionEdit(item.id, to: $0) }
                )
            )
        }
    }

    /// One visible action at most, with the rest behind a menu: three equal
    /// buttons never fitted a 240-point card without wrapping.
    @ViewBuilder
    private var actions: some View {
        if item.kind == .image || item.isFinished {
            HStack(spacing: Spacing.s) {
                if item.kind == .image {
                    // Photos only: cropping a PDF or a video is a different job and
                    // this editor cannot show either of them.
                    Button("편집…", systemImage: "crop") { showsEditor = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(controller.isCompressing)
                        .help("자르기·뒤집기를 하고 다시 실행하면 반영됩니다")
                }
                Spacer(minLength: Spacing.xs)
                if item.isFinished {
                    Menu {
                        Button("저장…", systemImage: "square.and.arrow.down") { controller.saveCompressed(item) }
                        Button("복사", systemImage: "doc.on.doc") { controller.copyCompressed(item) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("결과를 저장하거나 복사합니다")
                    .accessibilityLabel("이 파일의 추가 동작")
                }
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(.quaternary.opacity(0.6))
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else if item.isFailed {
                Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.red)
            } else {
                Image(systemName: item.kind.symbol).font(.title).foregroundStyle(.tertiary)
            }
            if case .working(let fraction) = item.state {
                VStack {
                    Spacer()
                    ProgressView(value: fraction).tint(.snuBlue).padding(.horizontal, 10).padding(.bottom, 8)
                }
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .onTapGesture { if item.kind == .image && !controller.isCompressing { showsEditor = true } }
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering && item.kind == .image ? 1.012 : 1)
        .animation(.appControl, value: isHovering)
        .help(item.kind == .image ? "클릭하면 크게 보고 자르기·뒤집기를 할 수 있습니다" : "")
        .accessibilityLabel("\(item.source.lastPathComponent) 미리보기")
    }

    /// Rebuilt only when the result actually changes, and always off the main
    /// thread: these are full-size photos and video frames.
    private var previewKey: String { item.output?.path ?? item.source.path }

    private func loadPreview() async {
        preview = await CompressionThumbnail.image(for: item, maxPixel: 640)
    }
}


private struct DictationSettingsSection: View {
    @ObservedObject var dictation: DictationController

    var body: some View {
        Section("전역 받아쓰기") {
            Picker("단축키", selection: $dictation.shortcut) {
                ForEach(DictationShortcut.allCases) { Text($0.title).tag($0) }
            }
            Text(dictation.status)
                .font(.caption)
                .foregroundStyle(dictation.shortcutRegistered || dictation.shortcut == .disabled ? Color.secondary : Color.red)
            Picker("인식 모델", selection: $dictation.asrModel) {
                ForEach(ASRModelChoice.allCases) { Text($0.title).tag($0) }
            }
            Text("받아쓰기는 짧은 문장을 즉시 처리해야 하므로 가장 빠른 모델을 권장합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("언어", selection: $dictation.language) {
                ForEach(TranscriptionLanguage.allCases) { Text($0.title).tag($0) }
            }
            Toggle("변환 후 커서 위치에 자동으로 붙여넣기", isOn: $dictation.pastesAutomatically)
            if dictation.pastesAutomatically && !dictation.accessibilityGranted {
                HStack {
                    Text("자동 붙여넣기에는 손쉬운 사용 권한이 필요합니다. 허용 후 앱을 다시 실행해 주세요.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("설정 열기") { dictation.openAccessibilitySettings() }
                        .buttonStyle(.bordered)
                }
            }
            Text("단축키를 한 번 누르면 녹음, 다시 누르면 변환합니다. 결과는 항상 클립보드에 복사되며 녹음 파일은 변환 직후 삭제됩니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
