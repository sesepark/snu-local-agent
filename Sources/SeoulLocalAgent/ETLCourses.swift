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

    enum CodingKeys: String, CodingKey {
        case submittedAt = "submitted_at"
        case workflowState = "workflow_state"
    }

    var isSubmitted: Bool { submittedAt != nil }
}

struct ETLAssignment: Decodable, Hashable, Sendable {
    let id: Int
    let name: String
    let dueAt: Date?
    let htmlURL: URL
    let description: String?
    let pointsPossible: Double?
    let submission: ETLSubmission?

    enum CodingKeys: String, CodingKey {
        case id, name, description, submission
        case dueAt = "due_at"
        case htmlURL = "html_url"
        case pointsPossible = "points_possible"
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

    static let announcementLimit = 400

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SeoulLocalAgent/etl-seen.json")
    }

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
            var items: [SourceItem] = []
            var warnings: [String] = []

            let since = Calendar.current.date(byAdding: .day, value: -14, to: now) ?? now
            let byContext = Dictionary(uniqueKeysWithValues: courses.map { ($0.contextCode, $0) })
            for announcement in try await Self.announcements(for: courses, since: since, token: token) {
                let course = announcement.contextCode.flatMap { byContext[$0] }
                let id = "etl:announcement:\(announcement.id)"
                defer { store.record(announcement: id) }
                guard !baseline, !store.hasSeen(announcement: id) else { continue }
                items.append(Self.item(for: announcement, course: course, id: id))
            }

            for course in courses {
                let assignments: [ETLAssignment]
                do {
                    assignments = try await Self.assignments(in: course, token: token)
                } catch {
                    warnings.append("eTL: \(course.shortName)의 과제를 읽지 못했습니다 (\(error.localizedDescription)).")
                    continue
                }
                for assignment in assignments {
                    guard let stage = store.stage(for: assignment, now: now) else { continue }
                    // 기준선은 공지에만 적용한다. 학기 내내 쌓인 공지를 하루에 쏟으면 그 브리핑은
                    // 읽히지 않지만, 마감이 남은 과제는 몇 건뿐이고 전부 아직 해야 할 일이다.
                    // 그것을 첫 실행에서 숨기면 연동한 날 정작 볼 것이 없다.
                    store.record(stage, for: assignment)
                    items.append(Self.item(for: assignment, course: course, stage: stage, now: now))
                }
            }

            store.hasBaseline = true
            if persists { store.save(url: storeURL) }
            if baseline {
                warnings.append("eTL: 지금 올라와 있는 공지를 기준선으로 저장했습니다(첫 수집). 다음 실행부터 새 공지만 보고합니다. 마감이 남은 과제는 이번 실행부터 그대로 올라갑니다.")
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
        if let submission = assignment.submission {
            lines.append(submission.isSubmitted
                ? "제출: 제출했습니다\(submission.submittedAt.map { " (\(Self.dueText($0)))" } ?? "")."
                : "제출: 아직 제출하지 않았습니다.")
        }
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

    static func dueText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current
        formatter.dateFormat = "yyyy년 M월 d일 HH시 mm분"
        return formatter.string(from: date)
    }
}
