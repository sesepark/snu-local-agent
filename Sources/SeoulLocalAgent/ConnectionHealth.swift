import Foundation
import EventKit
import SQLite3

/// 설정 › 연결 상태 — what the app can actually reach right now.
///
/// This exists because of a real, sixteen-day failure. The Gmail refresh token
/// expired on a Monday; every run after that collected zero mail, recorded the
/// reason in a caption at the bottom of the archive, and otherwise reported
/// success. The settings pane meanwhile printed the fixed string "두 계정 ·
/// 읽기 전용" whether the tokens worked, had expired, or had never existed.
///
/// So none of these rows are labels. Every one of them performs the same read
/// the briefing performs, and reports what came back.
struct ConnectionCheck: Identifiable, Sendable {
    enum State: String, Sendable {
        case checking, ok, warning, failed

        var symbol: String {
            switch self {
            case .checking: "circle.dotted"
            case .ok: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failed: "xmark.circle.fill"
            }
        }
    }

    /// What the row offers to do about a problem. Deliberately narrow: opening a
    /// settings pane, revealing a file, or copying a command the user runs
    /// themselves. Nothing here re-authenticates on its own — that flow opens a
    /// browser and must stay something the user starts knowingly.
    enum Remedy: Equatable, Sendable {
        case openPrivacySettings(String)
        case revealFile(URL)
        case copyCommand(String)
        case requestCalendarAccess
        case requestReminderAccess

        var title: String {
            switch self {
            case .openPrivacySettings: "시스템 설정 열기"
            case .revealFile: "파일 위치 열기"
            case .copyCommand: "명령 복사"
            case .requestCalendarAccess, .requestReminderAccess: "권한 허용"
            }
        }

        /// Editing the notice-board list is a normal thing to want even when
        /// every board answered, so that one button stays. The rest are repairs
        /// and only appear when something is actually wrong.
        var isAlwaysOffered: Bool {
            if case .revealFile = self { return true }
            return false
        }
    }

    let id: String
    let title: String
    let symbol: String
    var state: State
    var summary: String
    var detail: String?
    var remedy: Remedy?

    static func checking(id: String, title: String, symbol: String) -> ConnectionCheck {
        ConnectionCheck(id: id, title: title, symbol: symbol, state: .checking, summary: "확인 중…")
    }
}

/// Runs every probe. Each one is independent and answers on its own, so a slow
/// site or an unreachable model never keeps the rest of the pane blank.
enum ConnectionProbe {
    static let gmailID = "gmail"
    static let slackID = "slack"
    static let messagesID = "messages"
    static let calendarID = "calendar"
    static let remindersID = "reminders"
    static let modelID = "model"
    static let webID = "web"
    static let etlID = "etl"

    static func placeholders() -> [ConnectionCheck] {
        [
            .checking(id: gmailID, title: "Gmail", symbol: "envelope"),
            .checking(id: slackID, title: "Slack", symbol: "bubble.left.and.bubble.right"),
            .checking(id: messagesID, title: "메시지", symbol: "message"),
            .checking(id: calendarID, title: "캘린더", symbol: "calendar"),
            .checking(id: remindersID, title: "미리 알림", symbol: "checklist"),
            .checking(id: modelID, title: "로컬 모델", symbol: "cpu"),
            .checking(id: webID, title: "웹 공지", symbol: "globe"),
            .checking(id: etlID, title: "eTL", symbol: "graduationcap"),
        ]
    }

    // MARK: - Gmail

    /// Asks `gog` for one message per account. A refresh token that has expired
    /// fails here exactly as it fails inside a run, with the same message.
    static func gmail() async -> ConnectionCheck {
        let accounts = GmailAccountStore().load()
        guard !accounts.isEmpty else {
            return ConnectionCheck(
                id: gmailID, title: "Gmail", symbol: "envelope", state: .warning,
                summary: "설정된 계정이 없습니다.",
                detail: "gmail-accounts.json에 계정을 넣기 전까지 브리핑에서 Gmail은 0건으로 조용히 빠집니다.",
                remedy: .revealFile(GmailAccountStore().debugURL)
            )
        }
        let runner = ProcessRunner()
        var working: [String] = []
        var broken: [(String, String)] = []
        for account in accounts {
            do {
                _ = try await runner.run("/opt/homebrew/bin/gog", [
                    "--readonly", "--account", account.address, "--json", "--results-only",
                    "gmail", "search", "newer_than:2d", "--max", "1",
                ])
                working.append(account.address)
            } catch {
                broken.append((account.address, Self.firstLine(of: error.localizedDescription)))
            }
        }
        guard !broken.isEmpty else {
            return ConnectionCheck(
                id: gmailID, title: "Gmail", symbol: "envelope", state: .ok,
                summary: "\(working.count)개 계정 · 읽기 전용으로 응답합니다.",
                detail: working.joined(separator: ", ")
            )
        }
        let names = broken.map(\.0)
        return ConnectionCheck(
            id: gmailID, title: "Gmail", symbol: "envelope",
            state: working.isEmpty ? .failed : .warning,
            summary: working.isEmpty
                ? "\(broken.count)개 계정 모두 읽지 못했습니다."
                : "\(broken.count)개 계정을 읽지 못했습니다. \(working.count)개는 정상입니다.",
            detail: broken.map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
            // Testing 상태의 OAuth 클라이언트는 리프레시 토큰이 7일이면 만료된다.
            // 그때 필요한 것은 정확히 이 한 줄이고, 범위를 좁혀 두는 것이 중요하다.
            remedy: .copyCommand("gog --readonly auth add \(names.joined(separator: " ")) --services gmail --timeout 15m")
        )
    }

    // MARK: - Slack

    static func slack() async -> ConnectionCheck {
        let token: String
        do {
            token = try Keychain.string(service: SlackCredential.service, account: SlackCredential.account)
        } catch {
            return ConnectionCheck(
                id: slackID, title: "Slack", symbol: "bubble.left.and.bubble.right", state: .warning,
                summary: "Keychain에 토큰이 없습니다.",
                detail: "토큰이 없으면 브리핑에서 Slack은 실패로 기록되고 다른 소스만 수집됩니다.",
                remedy: .copyCommand(SlackCredential.registerCommand)
            )
        }
        var request = URLRequest(url: URL(string: "https://slack.com/api/auth.test")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if root?["ok"] as? Bool == true {
                let team = root?["team"] as? String ?? "워크스페이스"
                let user = root?["user"] as? String ?? ""
                return ConnectionCheck(
                    id: slackID, title: "Slack", symbol: "bubble.left.and.bubble.right", state: .ok,
                    summary: "\(team)에 \(user.isEmpty ? "연결됨" : user + "(으)로 연결됨") · 읽기 전용.",
                    detail: AppConfig.slackMentionUserID == nil
                        ? "채널 멘션 수집용 Member ID가 비어 있어 DM만 읽습니다."
                        : nil
                )
            }
            let reason = root?["error"] as? String ?? "알 수 없는 오류"
            return ConnectionCheck(
                id: slackID, title: "Slack", symbol: "bubble.left.and.bubble.right", state: .failed,
                summary: "토큰이 거부되었습니다: \(reason)",
                detail: reason == "invalid_auth" || reason == "token_revoked"
                    ? "토큰이 만료되었거나 취소되었습니다. Slack 앱 설정에서 새로 발급해 Keychain에 다시 넣어 주세요."
                    : nil
            )
        } catch {
            return ConnectionCheck(
                id: slackID, title: "Slack", symbol: "bubble.left.and.bubble.right", state: .failed,
                summary: "Slack에 연결하지 못했습니다.", detail: error.localizedDescription
            )
        }
    }

    // MARK: - 메시지

    /// Opens the same database the collector opens. Without Full Disk Access the
    /// open fails here just as it does there, which is the whole point: the pane
    /// used to print "Full Disk Access 필요" as a permanent label whether the
    /// permission was granted or not.
    static func messages() -> ConnectionCheck {
        let path = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Messages/chat.db").path
        guard FileManager.default.fileExists(atPath: path) else {
            return ConnectionCheck(
                id: messagesID, title: "메시지", symbol: "message", state: .warning,
                summary: "chat.db가 없습니다.", detail: "이 Mac에서 메시지 앱을 쓴 적이 없다면 정상입니다."
            )
        }
        var database: OpaquePointer?
        defer { if database != nil { sqlite3_close(database) } }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            return ConnectionCheck(
                id: messagesID, title: "메시지", symbol: "message", state: .failed,
                summary: "데이터베이스를 열 수 없습니다.",
                detail: "개인정보 보호 및 보안 › 전체 디스크 접근 권한에서 이 앱을 허용해 주세요.",
                remedy: .openPrivacySettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
            )
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM message;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            return ConnectionCheck(
                id: messagesID, title: "메시지", symbol: "message", state: .failed,
                summary: "데이터베이스를 읽을 수 없습니다.",
                detail: "파일은 열렸지만 조회가 거부되었습니다. 전체 디스크 접근 권한을 확인해 주세요.",
                remedy: .openPrivacySettings("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
            )
        }
        return ConnectionCheck(
            id: messagesID, title: "메시지", symbol: "message", state: .ok,
            summary: "읽기 전용으로 열립니다 · 보관된 메시지 \(sqlite3_column_int64(statement, 0))건.",
            detail: "iMessage · SMS · RCS 수신 메시지만 읽고, 보내거나 지우는 기능은 없습니다."
        )
    }

    // MARK: - 캘린더 · 미리 알림

    static func calendar() -> ConnectionCheck {
        state(
            id: calendarID, title: "캘린더", symbol: "calendar",
            status: EKEventStore.authorizationStatus(for: .event),
            granted: "앞으로 14일 일정을 읽고 '\(AgentCalendar.title)' 캘린더에만 씁니다.",
            remedy: .requestCalendarAccess
        )
    }

    static func reminders() -> ConnectionCheck {
        state(
            id: remindersID, title: "미리 알림", symbol: "checklist",
            status: EKEventStore.authorizationStatus(for: .reminder),
            granted: "'\(AgentCalendar.title)' 목록에만 씁니다.",
            remedy: .requestReminderAccess
        )
    }

    private static func state(
        id: String, title: String, symbol: String,
        status: EKAuthorizationStatus, granted: String, remedy: ConnectionCheck.Remedy
    ) -> ConnectionCheck {
        switch status {
        case .fullAccess:
            return ConnectionCheck(id: id, title: title, symbol: symbol, state: .ok, summary: "허용됨", detail: granted)
        case .writeOnly:
            return ConnectionCheck(id: id, title: title, symbol: symbol, state: .warning,
                                   summary: "쓰기 전용 · 읽기 권한이 필요합니다.", detail: granted, remedy: remedy)
        case .notDetermined:
            return ConnectionCheck(id: id, title: title, symbol: symbol, state: .warning,
                                   summary: "아직 권한을 요청하지 않았습니다.", detail: granted, remedy: remedy)
        default:
            return ConnectionCheck(id: id, title: title, symbol: symbol, state: .failed,
                                   summary: "거부됨 · 시스템 설정에서 허용해야 합니다.", detail: granted,
                                   remedy: .openPrivacySettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"))
        }
    }

    // MARK: - API 모델

    /// 주소·키·모델 이름 중 무엇이 빠졌는지를 먼저 말하고, 다 있으면 실제로 한 번
    /// 물어본다. `/models`를 내지 않는 게이트웨이도 있으므로 그 실패는 경고까지만이다 —
    /// 분류는 `/chat/completions`로 하고, 그쪽이 되는지는 여기서 알 수 없다.
    static func remoteModel() async -> ConnectionCheck {
        let title = "판단 모델 (API)"
        if let problem = InferenceSettings.remoteConfigurationProblem() {
            return ConnectionCheck(
                id: modelID, title: title, symbol: "cloud", state: .failed,
                summary: "API 설정이 아직 끝나지 않았습니다.", detail: problem
            )
        }
        guard let base = URL(string: InferenceSettings.baseURL) else {
            return ConnectionCheck(id: modelID, title: title, symbol: "cloud", state: .failed,
                                   summary: "API 주소 형식이 올바르지 않습니다.",
                                   detail: InferenceSettings.baseURL)
        }
        var request = URLRequest(url: base.appending(path: "models"))
        request.timeoutInterval = 15
        request.setValue("Bearer \(InferenceSettings.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard 200..<300 ~= status else {
                let state: ConnectionCheck.State = (status == 401 || status == 403) ? .failed : .warning
                return ConnectionCheck(
                    id: modelID, title: title, symbol: "cloud", state: state,
                    summary: state == .failed ? "API 키가 거부되었습니다." : "모델 목록을 읽지 못했습니다 (HTTP \(status)).",
                    detail: StructuredInference.remoteFailure(status: status, body: data)
                )
            }
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let names = ((root?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
            let wanted = InferenceSettings.remoteModel
            if !names.isEmpty, !names.contains(wanted) {
                return ConnectionCheck(
                    id: modelID, title: title, symbol: "cloud", state: .warning,
                    summary: "\(wanted)이 목록에 없습니다.",
                    detail: "이 키로 쓸 수 있는 모델: \(names.prefix(6).joined(separator: ", "))"
                )
            }
            return ConnectionCheck(
                id: modelID, title: title, symbol: "cloud", state: .ok,
                summary: "\(wanted) 준비됨.",
                detail: "분류는 \(InferenceSettings.baseURL)로 전송됩니다. 파일 변환·전사·문서 인식은 계속 이 Mac 안에서만 처리됩니다."
            )
        } catch {
            return ConnectionCheck(
                id: modelID, title: title, symbol: "cloud", state: .failed,
                summary: "API에 연결하지 못했습니다.",
                detail: "\(InferenceSettings.baseURL) — \(error.localizedDescription)"
            )
        }
    }

    // MARK: - 로컬 모델

    /// Both halves matter and they fail differently: Ollama not running is a
    /// connection error, while a model that was never pulled is a 404 that used
    /// to reach the user as the bare words "로컬 모델 HTTP 오류".
    static func model() async -> ConnectionCheck {
        if InferenceSettings.backend == .remote { return await remoteModel() }
        let machine = MachineCapability.current
        // Said before Ollama is even contacted, because on such a machine a green
        // "준비됨" would be the wrong answer even if the model were installed: the
        // weights would not fit beside the OS and the run would swap rather than fail.
        if !machine.canRunLocalModel, AppConfig.preferredModelOverride == nil {
            let budget = String(format: "%.0f", machine.modelBudgetGigabytes)
            let smallest = LocalModelCatalog.smallest
            return ConnectionCheck(
                id: modelID, title: "로컬 모델", symbol: "cpu", state: .warning,
                summary: "이 맥에서는 로컬 모델이 버겁습니다.",
                detail: "\(machine.summary) 가장 작은 \(smallest.tag)도 \(String(format: "%.1f", smallest.gigabytes))GB여서 절반인 \(budget)GB를 넘습니다. "
                    + "그래도 시도하려면 설정에서 모델을 직접 지정할 수 있습니다."
            )
        }
        var request = URLRequest(url: AppConfig.ollamaURL.appending(path: "api/tags"))
        request.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let names = (root?["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            guard names.contains(AppConfig.model) else {
                return ConnectionCheck(
                    id: modelID, title: "로컬 모델", symbol: "cpu", state: .failed,
                    summary: "Ollama는 켜져 있지만 \(AppConfig.model)이 없습니다.",
                    detail: names.isEmpty ? "받은 모델이 하나도 없습니다." : "받은 모델: \(names.prefix(6).joined(separator: ", "))",
                    remedy: .copyCommand("ollama pull \(AppConfig.model)")
                )
            }
            return ConnectionCheck(
                id: modelID, title: "로컬 모델", symbol: "cpu", state: .ok,
                summary: "\(AppConfig.model) 준비됨.",
                detail: "분류는 전부 이 Mac 안에서 실행되고 끝나면 5분 뒤 메모리에서 내려갑니다."
            )
        } catch {
            return ConnectionCheck(
                id: modelID, title: "로컬 모델", symbol: "cpu", state: .failed,
                summary: "Ollama에 연결하지 못했습니다 (\(AppConfig.ollamaURL.absoluteString)).",
                detail: error.localizedDescription,
                remedy: .copyCommand("ollama serve")
            )
        }
    }

    // MARK: - 웹 공지

    static func web() async -> ConnectionCheck {
        let results = await WebNoticeSource().inspect()
        guard !results.isEmpty else {
            return ConnectionCheck(
                id: webID, title: "웹 공지", symbol: "globe", state: .warning,
                summary: "사용 중인 게시판이 없습니다.",
                remedy: .revealFile(WebNoticeConfiguration.url)
            )
        }
        var failed: [String] = []
        var empty: [String] = []
        for (site, result) in results {
            switch result {
            case .success(let entries): if entries.isEmpty { empty.append(site.name) }
            case .failure(let error): failed.append("\(site.name): \(Self.firstLine(of: error.localizedDescription))")
            }
        }
        let healthy = results.count - failed.count - empty.count
        guard failed.isEmpty && empty.isEmpty else {
            return ConnectionCheck(
                id: webID, title: "웹 공지", symbol: "globe", state: healthy == 0 ? .failed : .warning,
                summary: "\(results.count)곳 중 \(healthy)곳만 읽었습니다.",
                detail: (failed + empty.map { "\($0): 목록에서 글을 찾지 못했습니다. 사이트 구조가 바뀌었을 수 있습니다." })
                    .joined(separator: "\n"),
                remedy: .revealFile(WebNoticeConfiguration.url)
            )
        }
        return ConnectionCheck(
            id: webID, title: "웹 공지", symbol: "globe", state: .ok,
            summary: "\(results.count)곳 모두 응답합니다 · 공개 페이지만 읽습니다.",
            remedy: .revealFile(WebNoticeConfiguration.url)
        )
    }

    /// Connector errors arrive as several lines of stderr; a row shows one.
    static func firstLine(of message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}

// MARK: - eTL

extension ConnectionProbe {
    /// Asks eTL for the same course list a run asks for. A token that has been
    /// revoked fails here with the same 401 the briefing would hit, and a term
    /// that resolved to the wrong semester shows up as the wrong course count —
    /// which is the failure this row exists to make visible.
    static func etl() async -> ConnectionCheck {
        guard let token = try? ETLConfiguration.token() else {
            return ConnectionCheck(
                id: etlID, title: "eTL", symbol: "graduationcap", state: .warning,
                summary: "Keychain에 토큰이 없습니다.",
                detail: "토큰이 없으면 브리핑에서 eTL은 0건으로 빠지고 다른 소스만 수집됩니다. myetl.snu.ac.kr › 계정 › 설정에서 «+ 새 액세스 토큰»으로 발급한 뒤 아래 명령에 붙여 넣으세요. 값은 화면에 보이지 않습니다.",
                remedy: .copyCommand(ETLConfiguration.tokenCommand)
            )
        }
        do {
            let courses = try await ETLSource.courses(token: token)
            guard !courses.isEmpty else {
                return ConnectionCheck(
                    id: etlID, title: "eTL", symbol: "graduationcap", state: .warning,
                    summary: "수강 중인 과목을 찾지 못했습니다.",
                    detail: "학기 사이라 아직 과목이 열리지 않았을 수 있습니다. 학기 중인데도 비어 있다면 토큰이 다른 계정의 것입니다."
                )
            }
            var lines = [courses.map(\.shortName).joined(separator: ", ")]
            let snapshot = ETLDeadlineSnapshot.load()
            if snapshot.updatedAt > .distantPast {
                let open = snapshot.entries.filter { $0.kind == .assignment && !$0.isSettled && $0.dueAt != nil }
                let missing = open.filter(\.isMissing).count
                let events = snapshot.entries.filter { $0.kind == .event }.count
                let when = snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened)
                var counted = "마지막 수집(\(when)) 기준 · 남은 과제 \(open.count)건"
                if missing > 0 { counted += " · 미제출 \(missing)건" }
                if events > 0 { counted += " · 수업 일정 \(events)건" }
                lines.append(counted)
            }
            return ConnectionCheck(
                id: etlID, title: "eTL", symbol: "graduationcap", state: .ok,
                summary: "\(ETLSemester.name(of: courses)) · \(courses.count)과목 · 읽기 전용으로 응답합니다.",
                detail: lines.joined(separator: "\n")
            )
        } catch {
            let message = Self.firstLine(of: error.localizedDescription)
            let rejected = message.contains("거부")
            return ConnectionCheck(
                id: etlID, title: "eTL", symbol: "graduationcap", state: .failed,
                summary: rejected ? "토큰이 거부되었습니다." : "eTL에 연결하지 못했습니다.",
                detail: rejected ? "\(message) myetl.snu.ac.kr에서 토큰을 새로 발급해 다시 넣어 주세요." : message,
                remedy: rejected ? .copyCommand(ETLConfiguration.tokenCommand) : nil
            )
        }
    }
}

/// The one list of probes, in the one order.
///
/// Both callers — 설정 › 연결 상태 and `--connection-check` — read it from here,
/// so the window and the terminal cannot come to describe the same machine
/// differently. The split is only about *when* each answer is shown: the pane
/// fills rows in as they land, the terminal waits and prints.
enum ConnectionHealthReport {
    /// The synchronous probes answer with no I/O worth waiting on, so they are
    /// separated: the pane shows them before the network ones have started.
    static let immediate: [@Sendable () -> ConnectionCheck] = [
        ConnectionProbe.messages, ConnectionProbe.calendar, ConnectionProbe.reminders,
    ]

    static let awaited: [@Sendable () async -> ConnectionCheck] = [
        ConnectionProbe.gmail, ConnectionProbe.slack, ConnectionProbe.model, ConnectionProbe.web,
        ConnectionProbe.etl,
    ]

    /// Every probe, run once, ordered as `ConnectionProbe.placeholders()` lists them.
    static func run() async -> [ConnectionCheck] {
        var found = immediate.map { $0() }
        await withTaskGroup(of: ConnectionCheck.self) { group in
            for probe in awaited { group.addTask { await probe() } }
            for await result in group { found.append(result) }
        }
        let order = ConnectionProbe.placeholders().map(\.id)
        return found.sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
    }
}

/// Drives 설정 › 연결 상태.
///
/// Every probe runs on its own and reports as soon as it lands, so the pane
/// fills in rather than blocking on the slowest one — the fifteen notice boards
/// take several seconds and the Gmail check spawns a subprocess per account.
@MainActor
final class ConnectionHealthModel: ObservableObject {
    @Published private(set) var checks: [ConnectionCheck] = ConnectionProbe.placeholders()
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?
    @Published var briefing = BriefingHealth.load()
    @Published var status = ""

    private var task: Task<Void, Never>?
    private var lastAutomaticCheckStartedAt: Date?

    static let automaticCheckCooldown: TimeInterval = 5 * 60

    var problemCount: Int { checks.filter { $0.state == .failed || $0.state == .warning }.count }

    /// A manual refresh bypasses the automatic pane-entry cooldown.
    func check() {
        guard !isChecking else { return }
        isChecking = true
        status = ""
        checks = ConnectionProbe.placeholders()
        briefing = BriefingHealth.load()
        task = Task { [weak self] in
            // The synchronous ones answer immediately; no reason to make them
            // wait behind a network probe.
            for probe in ConnectionHealthReport.immediate { self?.replace(probe()) }
            await withTaskGroup(of: ConnectionCheck.self) { group in
                for probe in ConnectionHealthReport.awaited { group.addTask { await probe() } }
                for await result in group { self?.replace(result) }
            }
            self?.finish()
        }
    }

    func checkOnPaneEntry(now: Date = Date()) {
        guard !isChecking else { return }
        let mostRecent = [lastAutomaticCheckStartedAt, lastCheckedAt].compactMap { $0 }.max()
        guard mostRecent.map({ now.timeIntervalSince($0) >= Self.automaticCheckCooldown }) ?? true else { return }
        lastAutomaticCheckStartedAt = now
        check()
    }

    /// Re-reads only what the operating system can answer without any I/O, for
    /// use right after a permission prompt is granted.
    func refreshPermissions() {
        for probe in ConnectionHealthReport.immediate { replace(probe()) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isChecking = false
    }

    private func replace(_ check: ConnectionCheck) {
        guard let index = checks.firstIndex(where: { $0.id == check.id }) else { return }
        checks[index] = check
    }

    private func finish() {
        isChecking = false
        lastCheckedAt = Date()
        task = nil
    }
}

/// What the last run actually did, read back out of the checkpoint.
///
/// `lastSuccessAt` and `lastError` were written on every run from the beginning
/// and read by nothing. That is why a briefing could sit seventeen days stale
/// with both screens reporting 대기 중.
struct BriefingHealth: Equatable, Sendable {
    var lastSuccessAt: Date?
    var lastError: String?
    var newestDateKey: String?
    var failures: [String] = []

    static func load(store: StateStore = StateStore()) -> BriefingHealth {
        let state = store.load()
        let newest = state.dailyBriefings.values.sorted { $0.updatedAt > $1.updatedAt }.first
        return BriefingHealth(
            lastSuccessAt: state.lastSuccessAt,
            lastError: state.lastError,
            newestDateKey: newest?.dateKey,
            failures: newest?.failures ?? []
        )
    }

    /// Whole days between the last success and now, in Seoul.
    func daysSinceSuccess(now: Date = Date()) -> Int? {
        guard let lastSuccessAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = KoreanDeadline.timeZone
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: lastSuccessAt), to: calendar.startOfDay(for: now)).day
    }

    /// A briefing older than this is stale enough to say so on screen. Two days
    /// rather than one: running it every single morning is not the expectation,
    /// and a Monday-morning reader should not be nagged about Sunday.
    static let staleAfterDays = 2

    func isStale(now: Date = Date()) -> Bool {
        guard let days = daysSinceSuccess(now: now) else { return true }
        return days >= Self.staleAfterDays
    }

    /// When the run being reported on happened, for headings that would
    /// otherwise say "마지막" about something two weeks old.
    func when(now: Date = Date()) -> String {
        guard let lastSuccessAt else { return "마지막" }
        switch daysSinceSuccess(now: now) {
        case 0: return "오늘"
        case 1: return "어제"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.timeZone = KoreanDeadline.timeZone
            formatter.dateFormat = "M월 d일"
            return formatter.string(from: lastSuccessAt)
        }
    }

    /// "마지막 성공 8월 13일 · 17일 전" — the sentence that was missing.
    func summary(now: Date = Date()) -> String {
        guard let lastSuccessAt, let days = daysSinceSuccess(now: now) else {
            return "아직 한 번도 성공하지 않았습니다."
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = KoreanDeadline.timeZone
        formatter.dateFormat = "M월 d일 HH:mm"
        let when = formatter.string(from: lastSuccessAt)
        switch days {
        case 0: return "마지막 성공 오늘 \(when)"
        case 1: return "마지막 성공 어제 \(when)"
        default: return "마지막 성공 \(when) · \(days)일 전"
        }
    }
}
