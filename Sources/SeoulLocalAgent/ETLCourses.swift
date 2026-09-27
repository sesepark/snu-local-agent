import Foundation

/// 서울대 eTL에서 이번 학기 과목의 공지와 과제 마감을 읽어 온다.
///
/// eTL은 두 시스템이다. `etl.snu.ac.kr`은 자이닉스가 만든 포털(강좌 카탈로그·SNUON·로그인
/// 게이트웨이)이고, 실제 수업이 도는 `myetl.snu.ac.kr`은 Canvas LMS다. Canvas이므로 문서화된
/// `/api/v1` REST API가 그대로 열려 있고, 이 파일은 그 API만 쓴다. 포털 화면을 긁지 않는 이유는
/// 명확하다 — 과제 마감이 문장이 아니라 `due_at` 필드로 오기 때문에, 날짜를 추정할 필요가 없다.
///
/// 온라인 강의 영상 진도와 출석은 일부러 다루지 않는다. 그쪽만 Canvas가 아니라 자이닉스가 얹은
/// `/learningx/api` 레이어에 있어서 문서가 없고, 학교가 갱신하면 조용히 깨진다. 과제와 공지는
/// 표준 API로 정확히 나오므로 여기서 멈추는 편이 오래 간다.
enum ETLConfiguration {
    static let baseURL = URL(string: "https://myetl.snu.ac.kr")!
    static let tokenService = "com.seoullocalagent.etl.token"
    static let tokenAccount = "myetl"

    /// 토큰은 계정 전체 권한을 가진 자격증명이라 저장소에도 `state.json`에도 두지 않고
    /// Keychain에만 있다. 이 파일의 어떤 호출도 GET이 아니다.
    static func token() throws -> String {
        try Keychain.string(service: tokenService, account: tokenAccount,
                            missing: "Keychain에 eTL 액세스 토큰이 없습니다.")
    }

    /// 토큰이 없거나 거부됐을 때 연결 상태가 그대로 복사해 주는 한 줄. 값을 인자로 받지 않아야
    /// 셸 기록에 토큰이 남지 않는다 — `-w`만 두면 화면에 보이지 않게 입력받는다.
    static let tokenCommand = "security add-generic-password -U -s \(tokenService) -a \(tokenAccount) -w"
}

// MARK: - API가 돌려주는 것

struct ETLTerm: Decodable, Hashable, Sendable {
    let id: Int
    let name: String?
}

struct ETLCourse: Decodable, Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
    let enrollmentTermID: Int
    let term: ETLTerm?

    enum CodingKeys: String, CodingKey {
        case id, name, term
        case enrollmentTermID = "enrollment_term_id"
    }

    var contextCode: String { "course_\(id)" }

    /// 달력 한 줄에 들어갈 이름. 과목명은 "2026-2 로봇인공지능만들기 (001)" 꼴이라 학기와 분반을
    /// 떼면 사람이 부르는 이름만 남는다. 떼어 낼 것이 없으면 원래 이름을 그대로 쓴다.
    var shortName: String {
        var value = name.replacingOccurrences(of: #"^\s*\d{4}-\S+\s+"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }
}

struct ETLAnnouncement: Decodable, Hashable, Sendable {
    let id: Int
    let title: String
    let message: String?
    let htmlURL: URL
    let postedAt: Date?
    let contextCode: String?

    enum CodingKeys: String, CodingKey {
        case id, title, message
        case htmlURL = "html_url"
        case postedAt = "posted_at"
        case contextCode = "context_code"
    }
}

struct ETLSubmission: Decodable, Hashable, Sendable {
    let submittedAt: Date?
    let workflowState: String?
    /// Canvas가 직접 매기는 표시들. `submitted_at`만 보면 "면제받았다"와 "안 냈다"를 구별하지
    /// 못하고, 지각 제출도 제때 낸 것과 같아 보인다.
    let missing: Bool?
    let late: Bool?
    let excused: Bool?
    let graded: Bool?

    enum CodingKeys: String, CodingKey {
        case submittedAt = "submitted_at"
        case workflowState = "workflow_state"
        case missing, late, excused, graded
    }

    var isSubmitted: Bool { submittedAt != nil }

    /// 더 할 일이 없는 상태인가. 제출했거나 면제받았으면 끝난 것이다.
    var isSettled: Bool { isSubmitted || excused == true }
}

struct ETLAssignment: Decodable, Hashable, Sendable {
    let id: Int
    let name: String
    let dueAt: Date?
    /// 제출 창이 닫히는 시각. 마감보다 늦으면 그 사이는 지각 제출을 받는다는 뜻이고, 마감과 같으면
    /// 그 시각을 넘기는 순간 제출 자체가 막힌다. 사람에게는 이 둘이 완전히 다른 이야기다.
    let lockAt: Date?
    let unlockAt: Date?
    let htmlURL: URL
    let description: String?
    let pointsPossible: Double?
    let submission: ETLSubmission?

    enum CodingKeys: String, CodingKey {
        case id, name, description, submission
        case dueAt = "due_at"
        case lockAt = "lock_at"
        case unlockAt = "unlock_at"
        case htmlURL = "html_url"
        case pointsPossible = "points_possible"
    }

    /// 마감 뒤에도 제출을 받는 시간이 있는가. 같은 시각이거나 `lock_at`이 없으면 없다.
    var lateWindow: Date? {
        guard let lock = lockAt, let due = dueAt, lock > due else { return nil }
        return lock
    }
}

/// `/users/self/missing_submissions`가 돌려주는 것. 과제와 같은 모양이지만 어느 과목인지가
/// 본문에 들어 있어서(`course_id`) 과목을 따로 짝지을 필요가 없다.
struct ETLMissingAssignment: Decodable, Hashable, Sendable {
    let id: Int
    let name: String
    let dueAt: Date?
    let htmlURL: URL
    let courseID: Int
    let pointsPossible: Double?

    enum CodingKeys: String, CodingKey {
        case id, name
        case dueAt = "due_at"
        case htmlURL = "html_url"
        case courseID = "course_id"
        case pointsPossible = "points_possible"
    }
}

/// Canvas 쪽지함의 한 대화.
///
/// 이것이 있어야 닿는 곳이 있다. 「[전기·정보공학부] … 통합 게시판」처럼 수강이 끝난 과목 셸은
/// `enrollment_state=active` 목록에 안 잡히고 그쪽 `/announcements`는 401로 막히는데, 실험 공지와
/// 준비물은 거기로 온다. 쪽지함은 그 대화를 그대로 돌려준다.
struct ETLConversation: Decodable, Hashable, Sendable {
    let id: Int
    let subject: String?
    let contextName: String?
    let contextCode: String?
    let lastMessage: String?
    let lastMessageAt: Date?
    let workflowState: String?

    enum CodingKeys: String, CodingKey {
        case id, subject
        case contextName = "context_name"
        case contextCode = "context_code"
        case lastMessage = "last_message"
        case lastMessageAt = "last_message_at"
        case workflowState = "workflow_state"
    }

    var isUnread: Bool { workflowState == "unread" }

    /// 쪽지 제목은 「[과목명] 진짜 제목」 꼴이라 과목명이 두 번 나온다. 앞의 대괄호를 뗀다.
    var shortSubject: String {
        let raw = (subject ?? lastMessage ?? "제목 없는 쪽지").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name = contextName, raw.hasPrefix("[\(name)]") else { return raw }
        return String(raw.dropFirst(name.count + 2)).trimmingCharacters(in: .whitespaces)
    }
}

/// 과목 달력에 걸린 수업 일정 — 특강, 보강, 시험, Zoom 세션.
///
/// `context_codes[]`로 과목을 명시해야만 나온다. 붙이지 않고 부르면 0건이 오므로, 과목 목록을
/// 먼저 읽은 뒤에만 물을 수 있다.
struct ETLCalendarEvent: Decodable, Hashable, Sendable {
    let id: Int
    let title: String
    let startAt: Date?
    let endAt: Date?
    let htmlURL: URL?
    let contextCode: String?
    let contextName: String?
    let locationName: String?
    let description: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description
        case startAt = "start_at"
        case endAt = "end_at"
        case htmlURL = "html_url"
        case contextCode = "context_code"
        case contextName = "context_name"
        case locationName = "location_name"
    }
}

// MARK: - 어느 학기가 이번 학기인가

/// Canvas는 학기를 `enrollment_term_id`로 매기고, 그 번호는 학기가 열릴 때마다 커진다.
///
/// 날짜로 학기를 계산하지 않는 이유가 있다. 이 계정의 term 목록에는 정규 학기뿐 아니라
/// 계절학기와 SNUON이 섞여 있고, `start_at`은 비어 있는 것이 있으며 `end_at`은 전부 비어 있다.
/// 그래서 달력 산수는 어느 쪽으로든 틀린다. 반면 "수강 중인 과목이 속한 term 중 가장 큰 번호"는
/// 계절학기까지 포함해 지금 듣고 있는 학기를 그대로 가리키고, 학기가 바뀌어도 손댈 것이 없다.
enum ETLSemester {
    static func current(in courses: [ETLCourse]) -> Int? {
        courses.map(\.enrollmentTermID).max()
    }

    static func courses(of courses: [ETLCourse]) -> [ETLCourse] {
        guard let term = current(in: courses) else { return [] }
        return courses.filter { $0.enrollmentTermID == term }
    }

    /// 연결 상태가 "2026년 2학기 · 7과목"이라고 말할 수 있도록. term 이름이 비어 있으면 번호라도
    /// 보여 준다 — 잘못된 학기를 골랐을 때 화면에서 바로 드러나야 한다.
    static func name(of courses: [ETLCourse]) -> String {
        guard let term = current(in: courses) else { return "학기 미상" }
        let named = courses.first { $0.enrollmentTermID == term }?.term?.name
        return named ?? "term \(term)"
    }
}

// MARK: - 무엇을 언제 다시 알릴 것인가

/// 과제 하나를 브리핑에 몇 번 올렸는지 기억한다.
///
/// 공지는 게시판과 같은 규칙이다 — 주소를 처음 보면 새 글. 과제는 다르다. 마감은 한 번 보고
/// 잊는 것이 아니라 다가올수록 다시 보여야 하므로, 처음 볼 때 한 번, 마감 사흘 전에 한 번,
/// 하루 전에 한 번까지 올린다. 어느 단계를 이미 올렸는지 여기 적어 두지 않으면 매일 같은 과제가
/// 브리핑을 채운다.
struct ETLDigestStore: Codable, Sendable {
    enum Stage: String, Codable, Sendable, CaseIterable {
        case first, threeDays, oneDay

        /// 브리핑 제목에 붙는 말. 왜 지금 다시 보이는지 한눈에 알려야 한다.
        var label: String {
            switch self {
            case .first: "새 과제"
            case .threeDays: "마감 D-3"
            case .oneDay: "마감 D-1"
            }
        }

        /// 급한 순서. 한 번의 수집에서 한 과제는 가장 급한 단계 하나만 올린다.
        var urgency: Int {
            switch self {
            case .first: 0
            case .threeDays: 1
            case .oneDay: 2
            }
        }
    }

    var seenAnnouncements: [String] = []
    var assignmentStages: [String: [String]] = [:]
    /// 첫 수집인가. 게시판과 같은 이유로 첫 방문은 기준선만 잡는다: 학기 내내 쌓인 공지와 과제를
    /// 하루치 브리핑에 쏟으면 그날 브리핑은 읽히지 않는다.
    var hasBaseline: Bool = false

    /// 과제마다 마지막으로 본 마감. 단계만 기억하면 교수가 마감을 옮겼을 때 아무 말도 못 한다.
    var assignmentDue: [String: Date] = [:]
    /// 미제출을 마지막으로 보고한 때. 마감이 지난 과제는 계속 미제출로 남으므로 매일 올리면
    /// 같은 줄이 브리핑을 채운다.
    var missingReported: [String: Date] = [:]
    /// 쪽지함은 공지와 따로 기억한다. 기준선도 따로다 — 쪽지를 나중에 켜도 그날 브리핑이
    /// 몇십 건으로 덮이지 않아야 한다.
    var seenConversations: [String] = []
    var hasConversationBaseline: Bool = false
    /// 수업 일정도 같은 이유로 따로.
    var seenEvents: [String] = []

    static let announcementLimit = 400
    /// 미제출 한 건을 다시 올리기까지 두는 간격.
    ///
    /// 사흘인 이유는 이월 규칙과 맞물린다. 미제출 항목은 마감이 이미 지난 채로 올라오므로
    /// `CarryForwardPolicy`가 다음 날 `expired`로 세고 이월하지 않는다 — 즉 올린 날 하루만
    /// `오늘 꼭 할 일`에 선다. 이레를 두면 엿새를 그 자리에서 못 본다. 사흘이면 주에 두 번
    /// 눈에 들어오고, 그 사이에도 일정 달력에는 지난 마감으로 계속 서 있다.
    static let missingRepeatInterval: TimeInterval = 3 * 24 * 60 * 60

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SeoulLocalAgent/etl-seen.json")
    }

    /// 손으로 쓴 디코더다. Swift가 만들어 주는 것은 키가 없으면 그냥 던지므로, 필드를 하나
    /// 늘릴 때마다 기존 `etl-seen.json`이 통째로 버려지고 기준선이 다시 잡힌다 — 그 실행의
    /// 브리핑에서 eTL이 조용히 비어 버린다. 없는 키는 기본값으로 채운다.
    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        seenAnnouncements = try box.decodeIfPresent([String].self, forKey: .seenAnnouncements) ?? []
        assignmentStages = try box.decodeIfPresent([String: [String]].self, forKey: .assignmentStages) ?? [:]
        hasBaseline = try box.decodeIfPresent(Bool.self, forKey: .hasBaseline) ?? false
        assignmentDue = try box.decodeIfPresent([String: Date].self, forKey: .assignmentDue) ?? [:]
        missingReported = try box.decodeIfPresent([String: Date].self, forKey: .missingReported) ?? [:]
        seenConversations = try box.decodeIfPresent([String].self, forKey: .seenConversations) ?? []
        hasConversationBaseline = try box.decodeIfPresent(Bool.self, forKey: .hasConversationBaseline) ?? false
        seenEvents = try box.decodeIfPresent([String].self, forKey: .seenEvents) ?? []
    }

    init() {}

    static func load(url: URL = ETLDigestStore.url) -> Self {
        guard let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return store
    }

    func save(url: URL = ETLDigestStore.url) {
        try? LocalFileStorage.write(try JSONEncoder().encode(self), to: url)
    }

    func hasSeen(announcement id: String) -> Bool { seenAnnouncements.contains(id) }

    mutating func record(announcement id: String) {
        guard !seenAnnouncements.contains(id) else { return }
        seenAnnouncements = Array(([id] + seenAnnouncements).prefix(Self.announcementLimit))
    }

    func hasSeen(conversation id: String) -> Bool { seenConversations.contains(id) }

    mutating func record(conversation id: String) {
        guard !seenConversations.contains(id) else { return }
        seenConversations = Array(([id] + seenConversations).prefix(Self.announcementLimit))
    }

    func hasSeen(event id: String) -> Bool { seenEvents.contains(id) }

    mutating func record(event id: String) {
        guard !seenEvents.contains(id) else { return }
        seenEvents = Array(([id] + seenEvents).prefix(Self.announcementLimit))
    }

    /// 마감이 옮겨졌는가. 처음 보는 과제는 "바뀌지 않았다"로 친다 — 새 과제는 `.first`가 맡는다.
    func movedDue(for assignment: ETLAssignment) -> Date? {
        guard let previous = assignmentDue[Self.key(assignment)] else { return nil }
        guard let now = assignment.dueAt else { return nil }
        return previous == now ? nil : previous
    }

    /// 마감을 적어 둔다. 마감이 바뀌었으면 지나간 단계를 새 날짜 기준으로 다시 연다 — 그러지
    /// 않으면 마감이 한 달 뒤로 밀린 과제의 D-3·D-1이 영영 오지 않는다.
    mutating func record(due assignment: ETLAssignment) {
        let key = Self.key(assignment)
        let moved = movedDue(for: assignment) != nil
        if let due = assignment.dueAt {
            assignmentDue[key] = due
        } else {
            assignmentDue.removeValue(forKey: key)
        }
        guard moved else { return }
        assignmentStages[key] = [Stage.first.rawValue]
    }

    /// 이 미제출을 지금 다시 올릴 때인가.
    func shouldReport(missing key: String, now: Date) -> Bool {
        guard let last = missingReported[key] else { return true }
        return now.timeIntervalSince(last) >= Self.missingRepeatInterval
    }

    mutating func record(missing key: String, now: Date) {
        missingReported[key] = now
    }

    /// 지금 올려야 할 단계. 아직 올리지 않은 것 중 가장 급한 하나이고, 마감이 지난 과제는 없다.
    func stage(for assignment: ETLAssignment, now: Date) -> Stage? {
        if let due = assignment.dueAt, due <= now { return nil }
        let sent = Set(assignmentStages[Self.key(assignment)] ?? [])
        var reached: [Stage] = [.first]
        if let due = assignment.dueAt {
            let days = Self.daysUntil(due, from: now)
            if days <= 3 { reached.append(.threeDays) }
            if days <= 1 { reached.append(.oneDay) }
        }
        return reached
            .filter { !sent.contains($0.rawValue) }
            .max { $0.urgency < $1.urgency }
    }

    /// 어떤 단계를 올리면 그보다 앞선 단계도 함께 지나간 것으로 적는다. 그러지 않으면 D-1을 올린
    /// 뒤에 "새 과제"가 뒤늦게 한 번 더 올라온다.
    mutating func record(_ stage: Stage, for assignment: ETLAssignment) {
        let key = Self.key(assignment)
        let passed = Stage.allCases.filter { $0.urgency <= stage.urgency }.map(\.rawValue)
        assignmentStages[key] = Array(Set(assignmentStages[key] ?? []).union(passed)).sorted()
    }

    static func key(_ assignment: ETLAssignment) -> String { "assignment:\(assignment.id)" }

    /// 서울 기준 날짜 차이. 시각까지 빼면 "23시간 뒤"가 D-0이 되어 D-1 알림을 건너뛴다.
    static func daysUntil(_ due: Date, from now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        let start = calendar.startOfDay(for: now)
        let target = calendar.startOfDay(for: due)
        return calendar.dateComponents([.day], from: start, to: target).day ?? 0
    }
}

// MARK: - 수집

struct ETLSource {
    /// 게시판과 같은 이유로 짧은 타임아웃과 자체 세션을 쓴다. eTL이 느린 날 브리핑 전체가 붙잡혀
    /// 있으면 안 된다.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    /// Canvas는 `2026-09-04T02:01:47Z`로 답하지만 소수점 초가 붙는 필드도 있다. 둘 다 읽는다.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            for options in [ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
                            ISO8601DateFormatter.Options([.withInternetDateTime])] {
                let parser = ISO8601DateFormatter()
                parser.formatOptions = options
                if let date = parser.date(from: text) { return date }
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "날짜를 읽지 못했습니다: \(text)"))
        }
        return decoder
    }()

    var storeURL: URL = ETLDigestStore.url
    var snapshotURL: URL = ETLDeadlineSnapshot.url
    var now: Date = Date()

    // MARK: 요청

    private static func request(_ path: String, query: [URLQueryItem], token: String) throws -> URLRequest {
        guard var components = URLComponents(url: ETLConfiguration.baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw AgentError.processFailed("eTL 주소를 만들지 못했습니다: \(path)")
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw AgentError.processFailed("eTL 주소를 만들지 못했습니다: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// 한 페이지씩 `Link` 헤더를 따라가며 모은다. 학기 하나의 과목·과제는 몇 페이지면 끝나지만,
    /// 첫 페이지만 읽고 마는 구현은 과제가 늘어난 학기에 조용히 뒤쪽을 흘린다.
    private static func fetch<T: Decodable>(_ path: String, query: [URLQueryItem], token: String, as type: T.Type) async throws -> [T] where T: Sendable {
        var next: URL? = try request(path, query: query, token: token).url
        var collected: [T] = []
        var pages = 0
        while let url = next, pages < 10 {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            try validate(response)
            collected += try decoder.decode([T].self, from: data)
            next = (response as? HTTPURLResponse).flatMap { nextPage(in: $0) }
            pages += 1
        }
        return collected
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw AgentError.missingCredential("eTL 토큰이 거부되었습니다(HTTP \(http.statusCode)). 토큰이 만료되었거나 취소되었습니다.")
        default:
            throw AgentError.processFailed("eTL이 HTTP \(http.statusCode)로 답했습니다.")
        }
    }

    /// `Link: <…>; rel="next", <…>; rel="last"` 중 next만.
    static func nextPage(in response: HTTPURLResponse) -> URL? {
        guard let header = response.value(forHTTPHeaderField: "Link") else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";")
            guard pieces.count >= 2, pieces.contains(where: { $0.contains("rel=\"next\"") }) else { continue }
            let raw = pieces[0].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: raw)
        }
        return nil
    }

    // MARK: 읽기

    static func courses(token: String) async throws -> [ETLCourse] {
        let all = try await fetch("/api/v1/courses", query: [
            URLQueryItem(name: "enrollment_state", value: "active"),
            URLQueryItem(name: "include[]", value: "term"),
            URLQueryItem(name: "per_page", value: "100"),
        ], token: token, as: ETLCourse.self)
        return ETLSemester.courses(of: all)
    }

    static func announcements(for courses: [ETLCourse], since: Date, token: String) async throws -> [ETLAnnouncement] {
        guard !courses.isEmpty else { return [] }
        let formatter = ISO8601DateFormatter()
        var collected: [ETLAnnouncement] = []
        // Canvas는 한 번에 받는 context_code 수를 제한한다. 열 과목씩 나눠 묻는다.
        for group in stride(from: 0, to: courses.count, by: 10).map({ Array(courses[$0..<min($0 + 10, courses.count)]) }) {
            var query = group.map { URLQueryItem(name: "context_codes[]", value: $0.contextCode) }
            query.append(URLQueryItem(name: "start_date", value: formatter.string(from: since)))
            query.append(URLQueryItem(name: "per_page", value: "50"))
            collected += try await fetch("/api/v1/announcements", query: query, token: token, as: ETLAnnouncement.self)
        }
        return collected
    }

    static func assignments(in course: ETLCourse, token: String) async throws -> [ETLAssignment] {
        try await fetch("/api/v1/courses/\(course.id)/assignments", query: [
            URLQueryItem(name: "include[]", value: "submission"),
            URLQueryItem(name: "order_by", value: "due_at"),
            URLQueryItem(name: "per_page", value: "100"),
        ], token: token, as: ETLAssignment.self)
    }

    /// 마감이 지났는데 아직 안 낸 것.
    ///
    /// `course_ids[]`를 붙여도 이 서버는 무시하고 계정 전체를 돌려준다(실측: 26건, 2025-1까지
    /// 거슬러 올라간다). 그래서 학기를 자르는 일은 부른 쪽이 해야 한다.
    /// `filter[]=submittable`은 지금도 낼 수 있는 것만 남긴다 — 이미 닫힌 과제를 "해야 할 일"로
    /// 올리면 할 수 있는 것이 없다.
    static func missingSubmissions(token: String) async throws -> [ETLMissingAssignment] {
        try await fetch("/api/v1/users/self/missing_submissions", query: [
            URLQueryItem(name: "filter[]", value: "submittable"),
            URLQueryItem(name: "per_page", value: "100"),
        ], token: token, as: ETLMissingAssignment.self)
    }

    /// Canvas 쪽지함. 과목으로 거르지 않는다 — 거르는 순간 수강이 끝난 과목 셸의 실험 공지가
    /// 사라지고, 그게 바로 이 엔드포인트를 부르는 이유다.
    static func conversations(token: String) async throws -> [ETLConversation] {
        try await fetch("/api/v1/conversations", query: [
            URLQueryItem(name: "per_page", value: "50"),
        ], token: token, as: ETLConversation.self)
    }

    /// 과목 달력의 수업 일정. 공지와 같은 이유로 열 과목씩 나눠 묻는다.
    static func calendarEvents(for courses: [ETLCourse], from: Date, to end: Date, token: String) async throws -> [ETLCalendarEvent] {
        guard !courses.isEmpty else { return [] }
        let formatter = ISO8601DateFormatter()
        var collected: [ETLCalendarEvent] = []
        for group in stride(from: 0, to: courses.count, by: 10).map({ Array(courses[$0..<min($0 + 10, courses.count)]) }) {
            var query = group.map { URLQueryItem(name: "context_codes[]", value: $0.contextCode) }
            query.append(URLQueryItem(name: "type", value: "event"))
            query.append(URLQueryItem(name: "start_date", value: formatter.string(from: from)))
            query.append(URLQueryItem(name: "end_date", value: formatter.string(from: end)))
            query.append(URLQueryItem(name: "per_page", value: "100"))
            collected += try await fetch("/api/v1/calendar_events", query: query, token: token, as: ETLCalendarEvent.self)
        }
        return collected
    }

    /// 기억한 것을 건드리지 않고 지금 eTL에 무엇이 있는지만 읽는다.
    ///
    /// 게시판의 `inspect()`와 같은 이유로 있다. 수집이 제대로 도는지 확인하려고 진짜 실행을
    /// 시키면 기준선이나 알림 단계를 써 버려서, 확인하는 행위 자체가 다음 브리핑의 내용을
    /// 바꾼다. 이쪽은 아무것도 쓰지 않는다.
    struct Inspection: Sendable {
        var courses: [ETLCourse] = []
        var announcements: [ETLAnnouncement] = []
        /// 아직 마감이 남은 과제만, 급한 순서로.
        var upcoming: [(course: ETLCourse, assignment: ETLAssignment)] = []
        /// 마감이 지났는데 아직 낼 수 있는 것. 이번 학기 과목만 남긴다.
        var missing: [ETLMissingAssignment] = []
        /// 최근 2주 안에 온 쪽지.
        var conversations: [ETLConversation] = []
        /// 앞으로 있을 수업 일정.
        var events: [ETLCalendarEvent] = []
        var semester: String { ETLSemester.name(of: courses) }
    }

    func inspect() async throws -> Inspection {
        let token = try ETLConfiguration.token()
        var found = Inspection()
        found.courses = try await Self.courses(token: token)
        guard !found.courses.isEmpty else { return found }
        let since = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
        found.announcements = try await Self.announcements(for: found.courses, since: since, token: token)
        for course in found.courses {
            for assignment in try await Self.assignments(in: course, token: token) {
                guard let due = assignment.dueAt, due > now else { continue }
                found.upcoming.append((course, assignment))
            }
        }
        found.upcoming.sort { ($0.assignment.dueAt ?? .distantFuture) < ($1.assignment.dueAt ?? .distantFuture) }

        let currentCourseIDs = Set(found.courses.map(\.id))
        found.missing = try await Self.missingSubmissions(token: token)
            .filter { currentCourseIDs.contains($0.courseID) }
            .sorted { ($0.dueAt ?? .distantPast) > ($1.dueAt ?? .distantPast) }
        found.conversations = try await Self.conversations(token: token)
            .filter { ($0.lastMessageAt ?? .distantPast) >= since }
        let until = Calendar.current.date(byAdding: .day, value: 120, to: now) ?? now
        found.events = try await Self.calendarEvents(for: found.courses, from: since, to: until, token: token)
            .filter { ($0.startAt ?? .distantPast) > now }
            .sorted { ($0.startAt ?? .distantFuture) < ($1.startAt ?? .distantFuture) }
        return found
    }

    /// `persists`는 게시판과 같은 뜻이다. 모의 실행이 기준선을 써 버리면 다음 진짜 실행이 "전부
    /// 이미 봤다"고 믿고 아무것도 보고하지 않는다.
    func collect(persists: Bool = true) async -> SourceHarvest {
        let token: String
        do {
            token = try ETLConfiguration.token()
        } catch {
            return SourceHarvest(items: [], warnings: [
                "eTL: Keychain에 토큰이 없어 과목을 전혀 읽지 않았습니다. 설정 › 연결 상태에서 확인해 주세요.",
            ])
        }
        do {
            let courses = try await Self.courses(token: token)
            guard !courses.isEmpty else {
                return SourceHarvest(items: [], warnings: ["eTL: 수강 중인 과목을 찾지 못했습니다."])
            }
            var store = ETLDigestStore.load(url: storeURL)
            let baseline = !store.hasBaseline
            let conversationBaseline = !store.hasConversationBaseline
            var items: [SourceItem] = []
            var warnings: [String] = []
            var snapshot = ETLDeadlineSnapshot(updatedAt: now, entries: [])

            let since = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
            let byContext = Dictionary(uniqueKeysWithValues: courses.map { ($0.contextCode, $0) })
            for announcement in try await Self.announcements(for: courses, since: since, token: token) {
                let course = announcement.contextCode.flatMap { byContext[$0] }
                let id = "etl:announcement:\(announcement.id)"
                defer { store.record(announcement: id) }
                guard !baseline, !store.hasSeen(announcement: id) else { continue }
                items.append(Self.item(for: announcement, course: course, id: id))
            }

            let currentCourseIDs = Set(courses.map(\.id))
            var courseNames: [Int: String] = [:]
            for course in courses { courseNames[course.id] = course.shortName }

            var unreadCourseIDs: Set<Int> = []
            var eventsFailed = false
            for course in courses {
                let assignments: [ETLAssignment]
                do {
                    assignments = try await Self.assignments(in: course, token: token)
                } catch {
                    warnings.append("eTL: \(course.shortName)의 과제를 읽지 못했습니다 (\(error.localizedDescription)).")
                    unreadCourseIDs.insert(course.id)
                    continue
                }
                for assignment in assignments {
                    snapshot.entries.append(Self.snapshotEntry(for: assignment, course: course))

                    // 마감이 옮겨졌으면 그 사실 자체가 할 일이다. 기준선 실행에서는 비교할 옛 값이
                    // 없으므로 자연히 걸리지 않는다.
                    let moved = store.movedDue(for: assignment)
                    // 마감을 적는 것이 단계를 다시 여는 일이므로 `stage(for:)`보다 먼저 와야 한다.
                    store.record(due: assignment)

                    if let previous = moved, let due = assignment.dueAt {
                        items.append(Self.item(for: assignment, course: course, movedFrom: previous, to: due, now: now))
                        // 이번 실행에서는 여기서 멈춘다. 두 항목은 같은 과제라 `stableID`가 같고,
                        // 같은 수집에 둘 다 실으면 뒤엣것이 화면에서 조용히 사라진다. 옮겨진
                        // 마감을 알리는 줄이 이미 새 시각을 싣고 있으므로, 새 날짜의 D-3·D-1은
                        // 다음 실행이 맡는다.
                        continue
                    }

                    guard let stage = store.stage(for: assignment, now: now) else { continue }
                    // 기준선은 공지에만 적용한다. 학기 내내 쌓인 공지를 하루에 쏟으면 그 브리핑은
                    // 읽히지 않지만, 마감이 남은 과제는 몇 건뿐이고 전부 아직 해야 할 일이다.
                    // 그것을 첫 실행에서 숨기면 연동한 날 정작 볼 것이 없다.
                    store.record(stage, for: assignment)
                    items.append(Self.item(for: assignment, course: course, stage: stage, now: now))
                }
            }

            // 마감이 지난 미제출. 단계 사다리는 `due <= now`에서 끝나므로 이것이 없으면 놓친
            // 과제가 D-1 다음 날 조용히 목록에서 사라진다.
            do {
                for missing in try await Self.missingSubmissions(token: token) {
                    guard currentCourseIDs.contains(missing.courseID) else { continue }
                    let key = "etl:missing:\(missing.id)"
                    guard store.shouldReport(missing: key, now: now) else { continue }
                    // 기준선을 걸지 않는다. 과제와 같은 이유다 — 이미 놓친 과제는 연동한 날에도
                    // 여전히 해야 할 일이고, 그것을 첫 실행에서 감추면 이레 가까이 아무도
                    // 말해 주지 않는다. 적는 것도 실제로 올린 뒤여야 한다.
                    store.record(missing: key, now: now)
                    items.append(Self.item(for: missing, courseName: courseNames[missing.courseID] ?? "eTL", now: now))
                }
            } catch {
                warnings.append("eTL: 미제출 과제를 읽지 못했습니다 (\(error.localizedDescription)).")
            }

            // 쪽지함. 수강이 끝난 과목 셸의 공지가 오는 유일한 길이라 과목으로 거르지 않는다.
            do {
                for conversation in try await Self.conversations(token: token) {
                    guard let at = conversation.lastMessageAt, at >= since else { continue }
                    let id = "etl:conversation:\(conversation.id)"
                    defer { store.record(conversation: id) }
                    guard !conversationBaseline, !store.hasSeen(conversation: id) else { continue }
                    items.append(Self.item(for: conversation, id: id))
                }
            } catch {
                warnings.append("eTL: 쪽지함을 읽지 못했습니다 (\(error.localizedDescription)).")
            }

            // 수업 일정(특강·보강·시험). 앞으로 넉 달치만 본다.
            do {
                let until = Calendar.current.date(byAdding: .day, value: 120, to: now) ?? now
                for event in try await Self.calendarEvents(for: courses, from: since, to: until, token: token) {
                    let course = event.contextCode.flatMap { byContext[$0] }
                    snapshot.entries.append(Self.snapshotEntry(for: event, course: course))
                    guard let start = event.startAt, start > now else { continue }
                    let id = "etl:event:\(event.id)"
                    defer { store.record(event: id) }
                    guard !store.hasSeen(event: id) else { continue }
                    items.append(Self.item(for: event, course: course, id: id))
                }
            } catch {
                warnings.append("eTL: 수업 일정을 읽지 못했습니다 (\(error.localizedDescription)).")
                eventsFailed = true
            }

            store.hasBaseline = true
            store.hasConversationBaseline = true
            if persists {
                store.save(url: storeURL)
                // 달력이 읽는 자리. 덧붙이지 않고 통째로 갈아 끼워야 eTL에서 없어진 과제가
                // 달력에 남지 않는다. 다만 **이번에 읽지 못한 것까지 지워서는 안 된다** —
                // 한 과목이 500으로 답한 날 그 과목의 마감이 달력에서 통째로 사라지고, 사람은
                // 경고 한 줄로 그것을 알아채야 한다.
                snapshot.entries += Self.carriedOver(
                    from: ETLDeadlineSnapshot.load(url: snapshotURL),
                    unreadCourseIDs: unreadCourseIDs, eventsFailed: eventsFailed,
                    alreadyHave: Set(snapshot.entries.map(\.id)))
                snapshot.entries = Self.withinCalendarWindow(snapshot.entries, now: now)
                snapshot.save(url: snapshotURL)
            }
            if baseline {
                warnings.append("eTL: 지금 올라와 있는 공지를 기준선으로 저장했습니다(첫 수집). 다음 실행부터 새 공지만 보고합니다. 마감이 남은 과제는 이번 실행부터 그대로 올라갑니다.")
            } else if conversationBaseline {
                warnings.append("eTL: 쪽지함을 처음 읽어 지금 있는 쪽지를 기준선으로 저장했습니다. 다음 실행부터 새 쪽지만 보고합니다.")
            }
            return SourceHarvest(items: items, warnings: warnings)
        } catch {
            return SourceHarvest(items: [], warnings: ["eTL: \(error.localizedDescription)"])
        }
    }

    // MARK: 브리핑 항목으로

    static func item(for announcement: ETLAnnouncement, course: ETLCourse?, id: String) -> SourceItem {
        let name = course?.shortName ?? "eTL"
        let body = [
            "과목: \(course?.name ?? "확인 필요")",
            "공지: \(announcement.title)",
            InboxTextSanitizer.clean((announcement.message ?? "").strippingTags().decodingHTMLEntities()),
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        return SourceItem(
            id: id,
            source: SourceName.etl,
            account: name,
            author: name,
            timestamp: announcement.postedAt ?? Date(),
            subject: InboxTextSanitizer.clean(announcement.title),
            body: String(body.prefix(2000)),
            link: announcement.htmlURL,
            stableID: id
        )
    }

    static func item(for assignment: ETLAssignment, course: ETLCourse, stage: ETLDigestStore.Stage, now: Date) -> SourceItem {
        let due = assignment.dueAt
        var lines = [
            "과목: \(course.name)",
            "과제: \(assignment.name)",
            "마감: \(due.map(Self.dueText) ?? "마감 시각이 지정되지 않았습니다.")",
        ]
        lines += Self.submissionLines(for: assignment, stage: stage)
        if let points = assignment.pointsPossible, points > 0 {
            lines.append("배점: \(points.formatted(.number.precision(.fractionLength(0...1))))점")
        }
        lines.append("알림: \(stage.label)")
        let description = InboxTextSanitizer.clean((assignment.description ?? "").strippingTags().decodingHTMLEntities())
        if !description.isEmpty { lines.append(description) }

        return SourceItem(
            // 단계마다 다른 id를 써야 같은 수집 안에서 서로를 지우지 않는다.
            id: "etl:assignment:\(assignment.id):\(stage.rawValue)",
            source: SourceName.etl,
            account: course.shortName,
            author: course.shortName,
            timestamp: now,
            subject: stage == .first
                ? InboxTextSanitizer.clean(assignment.name)
                : "[\(stage.label)] \(InboxTextSanitizer.clean(assignment.name))",
            body: String(lines.joined(separator: "\n").prefix(2000)),
            link: assignment.htmlURL,
            // 추적은 과제 단위다. D-1 알림은 새로운 할 일이 아니라 같은 과제가 다시 온 것이므로,
            // 이월된 사본을 대체해야지 두 줄로 늘어나면 안 된다.
            stableID: "etl:assignment:\(assignment.id)",
            // 모델이 본문에서 마감을 추정할 필요가 없다. API가 시각을 그대로 주므로 분류가 끝난
            // 뒤 이 값이 마감 칸을 차지한다.
            knownDeadline: due.map { ISO8601DateFormatter().string(from: $0) }
        )
    }

    /// 제출 상태와 제출 창을 사람이 읽는 말로.
    ///
    /// `submitted_at`만 보던 때는 세 가지를 구별하지 못했다. 면제받은 과제가 "아직 안 냈습니다"로
    /// 나왔고, 지각 제출이 제때 낸 것과 같아 보였고, 마감 뒤에도 하루 더 받는 과제와 마감 순간
    /// 잠기는 과제가 똑같이 "마감 …"이라고만 적혔다. 이 셋은 사람이 지금 할 행동이 서로 다르다.
    static func submissionLines(for assignment: ETLAssignment, stage: ETLDigestStore.Stage?) -> [String] {
        var lines: [String] = []
        if let submission = assignment.submission {
            if submission.excused == true {
                lines.append("제출: 면제 처리된 과제입니다.")
            } else if submission.isSubmitted {
                let when = submission.submittedAt.map { " (\(Self.dueText($0)))" } ?? ""
                let late = submission.late == true ? ", 지각 제출로 기록되었습니다" : ""
                let graded = submission.graded == true ? ", 채점 완료" : ""
                lines.append("제출: 제출했습니다\(when)\(late)\(graded).")
            } else if submission.missing == true {
                lines.append("제출: 마감이 지났고 아직 제출하지 않았습니다.")
            } else {
                lines.append("제출: 아직 제출하지 않았습니다.")
            }
        }
        let settled = assignment.submission?.isSettled ?? false
        if !settled {
            if let window = assignment.lateWindow {
                lines.append("지각 제출: \(Self.dueText(window))까지는 늦게라도 낼 수 있습니다.")
            } else if let lock = assignment.lockAt, let due = assignment.dueAt, lock <= due, stage != .first {
                lines.append("주의: 이 시각을 넘기면 제출 자체가 막힙니다(지각 제출 없음).")
            }
        }
        return lines
    }

    /// 마감이 옮겨졌다.
    ///
    /// 공지 본문에 "9/3 → 9/10"이라고 적히는 일도 있지만 안 적히는 일이 더 많고, 적혀 있어도
    /// 모델이 읽어 내야 한다. 과제 마감이라면 API가 두 시각을 그대로 주므로 추정할 이유가 없다.
    static func item(for assignment: ETLAssignment, course: ETLCourse, movedFrom previous: Date, to due: Date, now: Date) -> SourceItem {
        let direction = due > previous ? "미뤄졌습니다" : "당겨졌습니다"
        var lines = [
            "과목: \(course.name)",
            "과제: \(assignment.name)",
            "이전 마감: \(Self.dueText(previous))",
            "새 마감: \(Self.dueText(due))",
            "마감이 \(direction).",
        ]
        lines += Self.submissionLines(for: assignment, stage: nil)
        return SourceItem(
            id: "etl:assignment:\(assignment.id):due:\(Int(due.timeIntervalSince1970))",
            source: SourceName.etl,
            account: course.shortName,
            author: course.shortName,
            timestamp: now,
            subject: "[마감 변경] \(InboxTextSanitizer.clean(assignment.name))",
            body: String(lines.joined(separator: "\n").prefix(2000)),
            link: assignment.htmlURL,
            stableID: "etl:assignment:\(assignment.id)",
            knownDeadline: ISO8601DateFormatter().string(from: due)
        )
    }

    /// 마감이 지났는데 아직 안 낸 과제.
    ///
    /// 단계 사다리는 마감 시각에서 끝난다(`stage(for:)`). 그래서 이 항목이 없으면 D-1 다음 날
    /// 과제가 목록에서 사라지고, 사라진 것과 끝낸 것을 화면에서 구별할 수 없다.
    static func item(for missing: ETLMissingAssignment, courseName: String, now: Date) -> SourceItem {
        var lines = [
            "과목: \(courseName)",
            "과제: \(missing.name)",
            "마감: \(missing.dueAt.map(Self.dueText) ?? "마감 시각이 지정되지 않았습니다.")",
            "제출: 마감이 지났고 아직 제출하지 않았습니다. eTL은 아직 제출을 받고 있습니다.",
        ]
        if let points = missing.pointsPossible, points > 0 {
            lines.append("배점: \(points.formatted(.number.precision(.fractionLength(0...1))))점")
        }
        return SourceItem(
            id: "etl:missing:\(missing.id):\(Int(now.timeIntervalSince1970))",
            source: SourceName.etl,
            account: courseName,
            author: courseName,
            timestamp: now,
            subject: "[미제출] \(InboxTextSanitizer.clean(missing.name))",
            body: String(lines.joined(separator: "\n").prefix(2000)),
            link: missing.htmlURL,
            // 추적은 과제 단위다. `etl:missing:…`을 따로 두면 같은 과제가 달력에 두 줄로
            // 서고(하나는 스냅샷에서, 하나는 브리핑에서), 한쪽에 친 체크가 다른 쪽에 닿지
            // 않는다. 미제출은 새로운 일이 아니라 같은 과제의 나중 모습이다.
            stableID: "etl:assignment:\(missing.id)",
            knownDeadline: missing.dueAt.map { ISO8601DateFormatter().string(from: $0) }
        )
    }

    /// Canvas 쪽지 한 건.
    static func item(for conversation: ETLConversation, id: String) -> SourceItem {
        let name = conversation.contextName ?? "eTL 쪽지"
        let body = [
            "과목: \(name)",
            "쪽지: \(conversation.shortSubject)",
            InboxTextSanitizer.clean((conversation.lastMessage ?? "").strippingTags().decodingHTMLEntities()),
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        return SourceItem(
            id: id,
            source: SourceName.etl,
            account: name,
            author: name,
            timestamp: conversation.lastMessageAt ?? Date(),
            subject: InboxTextSanitizer.clean(conversation.shortSubject),
            body: String(body.prefix(2000)),
            link: URL(string: "https://myetl.snu.ac.kr/conversations/\(conversation.id)") ?? ETLConfiguration.baseURL,
            stableID: id
        )
    }

    /// 과목 달력에 걸린 수업 일정.
    static func item(for event: ETLCalendarEvent, course: ETLCourse?, id: String) -> SourceItem {
        let name = course?.shortName ?? event.contextName ?? "eTL"
        var lines = [
            "과목: \(course?.name ?? event.contextName ?? "확인 필요")",
            "일정: \(event.title)",
            "시각: \(event.startAt.map(Self.dueText) ?? "시각이 지정되지 않았습니다.")",
        ]
        if let place = event.locationName, !place.isEmpty { lines.append("장소: \(place)") }
        let description = InboxTextSanitizer.clean((event.description ?? "").strippingTags().decodingHTMLEntities())
        if !description.isEmpty { lines.append(description) }
        return SourceItem(
            id: id,
            source: SourceName.etl,
            account: name,
            author: name,
            timestamp: event.startAt ?? Date(),
            subject: InboxTextSanitizer.clean(event.title),
            body: String(lines.joined(separator: "\n").prefix(2000)),
            link: event.htmlURL ?? ETLConfiguration.baseURL,
            stableID: id,
            knownDeadline: event.startAt.map { ISO8601DateFormatter().string(from: $0) }
        )
    }

    // MARK: 달력이 읽는 스냅샷

    /// 이번 실행이 읽지 못한 것만 지난 스냅샷에서 그대로 가져온다.
    static func carriedOver(from previous: ETLDeadlineSnapshot, unreadCourseIDs: Set<Int>,
                            eventsFailed: Bool, alreadyHave: Set<String>) -> [ETLDeadlineEntry] {
        guard !unreadCourseIDs.isEmpty || eventsFailed else { return [] }
        return previous.entries.filter { entry in
            guard !alreadyHave.contains(entry.id) else { return false }
            switch entry.kind {
            case .assignment: return entry.courseID.map(unreadCourseIDs.contains) ?? false
            case .event: return eventsFailed
            }
        }
    }

    /// 달력이 아직 쓸모 있게 그릴 수 있는 범위. 앞으로의 것은 전부 남기고, 지난 것은 두 달치만
    /// 남긴다.
    ///
    /// 자르지 않으면 학기 초의 선택 연습문제 하나가 학기 내내 스냅샷에 남아, 지난 날 칸에
    /// 주황색 "지났습니다"로 서 있고 연결 상태의 "남은 과제"에도 계속 잡힌다. 날짜가 없는
    /// 항목은 달력에 서지 않지만 제출 여부를 알려 주므로 그대로 둔다.
    static func withinCalendarWindow(_ entries: [ETLDeadlineEntry], now: Date) -> [ETLDeadlineEntry] {
        let floor = Calendar.current.date(byAdding: .day, value: -60, to: now) ?? now
        return entries.filter { entry in
            guard let date = entry.date else { return true }
            return date >= floor
        }
    }

    static func snapshotEntry(for assignment: ETLAssignment, course: ETLCourse) -> ETLDeadlineEntry {
        ETLDeadlineEntry(
            id: "etl:assignment:\(assignment.id)",
            kind: .assignment,
            courseID: course.id,
            courseName: course.shortName,
            title: assignment.name,
            dueAt: assignment.dueAt,
            lockAt: assignment.lockAt,
            endAt: nil,
            submittedAt: assignment.submission?.submittedAt,
            isMissing: assignment.submission?.missing ?? false,
            isExcused: assignment.submission?.excused ?? false,
            link: assignment.htmlURL,
            locationName: nil
        )
    }

    static func snapshotEntry(for event: ETLCalendarEvent, course: ETLCourse?) -> ETLDeadlineEntry {
        ETLDeadlineEntry(
            id: "etl:event:\(event.id)",
            kind: .event,
            courseID: course?.id,
            courseName: course?.shortName ?? event.contextName ?? "eTL",
            title: event.title,
            dueAt: event.startAt,
            lockAt: nil,
            endAt: event.endAt,
            submittedAt: nil,
            isMissing: false,
            isExcused: false,
            link: event.htmlURL,
            locationName: event.locationName
        )
    }

    static func dueText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        formatter.dateFormat = "yyyy년 M월 d일 HH시 mm분"
        return formatter.string(from: date)
    }
}
