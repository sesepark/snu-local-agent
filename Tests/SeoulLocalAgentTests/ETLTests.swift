import Foundation
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

@Suite("eTL 수집")
struct ETLTests {
    private static func course(_ id: Int, _ name: String, term: Int, termName: String? = nil) -> ETLCourse {
        let json = """
        {"id": \(id), "name": "\(name)", "enrollment_term_id": \(term),
         "term": {"id": \(term), "name": \(termName.map { "\"\($0)\"" } ?? "null")}}
        """
        return try! ETLSource.decoder.decode(ETLCourse.self, from: Data(json.utf8))
    }

    private static func assignment(id: Int, due: Date?, submitted: Bool = false) -> ETLAssignment {
        let dueText = due.map { "\"\(ISO8601DateFormatter().string(from: $0))\"" } ?? "null"
        let json = """
        {"id": \(id), "name": "Lab 1 보고서", "due_at": \(dueText),
         "html_url": "https://myetl.snu.ac.kr/courses/305638/assignments/\(id)",
         "description": "<p>보고서를 <b>PDF</b>로 제출하세요.&nbsp;</p>", "points_possible": 100,
         "submission": {"submitted_at": \(submitted ? "\"2026-09-08T10:00:00Z\"" : "null"), "workflow_state": "unsubmitted"}}
        """
        return try! ETLSource.decoder.decode(ETLAssignment.self, from: Data(json.utf8))
    }

    /// 계절학기와 SNUON이 같은 목록에 섞여 오고, `start_at`은 비어 있는 것이 있으며 `end_at`은
    /// 전부 비어 있다. 날짜로 학기를 계산하면 어느 쪽으로든 틀린다.
    @Test("가장 최근 학기의 과목만 남는다")
    func picksTheNewestTerm() {
        let courses = [
            Self.course(1, "2025-1 수학 1 (006)", term: 122, termName: "2025년 1학기"),
            Self.course(2, "2022년 SNUON 강좌", term: 57, termName: "2022년(SNUON)"),
            Self.course(3, "2026-하계 자유주제 (001)", term: 163, termName: "2026년 하계계절학기"),
            Self.course(4, "2026-2 로봇인공지능만들기 (001)", term: 164, termName: "2026년 2학기"),
            Self.course(5, "2026-2 자료구조의 기초 (001)", term: 164, termName: "2026년 2학기"),
        ]
        let current = ETLSemester.courses(of: courses)
        #expect(current.map(\.id) == [4, 5])
        #expect(ETLSemester.name(of: courses) == "2026년 2학기")
        // 과목이 하나도 없으면 학기도 없다. 연결 상태가 그렇게 말해야 한다.
        #expect(ETLSemester.courses(of: []).isEmpty)
        #expect(ETLSemester.name(of: []) == "학기 미상")
    }

    @Test("과목 이름에서 학기와 분반을 뗀다")
    func shortensCourseNames() {
        #expect(Self.course(1, "2026-2 로봇인공지능만들기 (001)", term: 164).shortName == "로봇인공지능만들기")
        #expect(Self.course(2, "2026-2 (공유)기계학습 (001)", term: 164).shortName == "(공유)기계학습")
        // 떼어 낼 것이 없으면 원래 이름 그대로. 빈 문자열을 화면에 올리는 편이 훨씬 나쁘다.
        #expect(Self.course(3, "특별 세미나", term: 164).shortName == "특별 세미나")
    }

    @Test("과제는 처음 한 번, 그리고 D-3·D-1에 다시 올라온다")
    func remindsAtThreeAndOneDay() {
        var store = ETLDigestStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = now.addingTimeInterval(10 * 86_400)
        let task = Self.assignment(id: 42, due: due)

        // 처음 볼 때 한 번.
        #expect(store.stage(for: task, now: now) == .first)
        store.record(.first, for: task)
        #expect(store.stage(for: task, now: now) == nil)
        // 아직 이레가 남았으면 조용하다.
        #expect(store.stage(for: task, now: due.addingTimeInterval(-7 * 86_400)) == nil)

        // 사흘 전에 한 번.
        let threeDaysBefore = due.addingTimeInterval(-3 * 86_400)
        #expect(store.stage(for: task, now: threeDaysBefore) == .threeDays)
        store.record(.threeDays, for: task)
        #expect(store.stage(for: task, now: threeDaysBefore) == nil)

        // 하루 전에 한 번 더, 그리고 그것으로 끝이다.
        let oneDayBefore = due.addingTimeInterval(-86_400)
        #expect(store.stage(for: task, now: oneDayBefore) == .oneDay)
        store.record(.oneDay, for: task)
        #expect(store.stage(for: task, now: oneDayBefore) == nil)
        #expect(store.stage(for: task, now: due.addingTimeInterval(-3_600)) == nil)
    }

    /// 마감이 코앞일 때 처음 본 과제가 "새 과제"부터 시작해 사흘에 걸쳐 세 번 올라오면 안 된다.
    @Test("늦게 발견한 과제는 가장 급한 단계 하나로만 올라온다")
    func lateDiscoveryReportsOnlyTheUrgentStage() {
        var store = ETLDigestStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = Self.assignment(id: 7, due: now.addingTimeInterval(20 * 3_600))

        #expect(store.stage(for: task, now: now) == .oneDay)
        store.record(.oneDay, for: task)
        // 지나간 단계도 함께 기록되므로 뒤늦게 "새 과제"가 따라오지 않는다.
        #expect(store.stage(for: task, now: now) == nil)
    }

    @Test("마감이 지난 과제와 마감이 없는 과제")
    func handlesMissingAndPastDeadlines() {
        var store = ETLDigestStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 지난 마감은 다시 올리지 않는다. 이월 항목이 그 몫을 한다.
        #expect(store.stage(for: Self.assignment(id: 1, due: now.addingTimeInterval(-3_600)), now: now) == nil)
        // 마감이 없는 과제는 처음 한 번만. 다시 올릴 근거가 되는 날짜가 없다.
        let undated = Self.assignment(id: 2, due: nil)
        #expect(store.stage(for: undated, now: now) == .first)
        store.record(.first, for: undated)
        #expect(store.stage(for: undated, now: now.addingTimeInterval(30 * 86_400)) == nil)
    }

    @Test("공지는 주소를 처음 볼 때만 새 항목이 된다")
    func announcementsAreReportedOnce() {
        var store = ETLDigestStore()
        #expect(!store.hasSeen(announcement: "etl:announcement:1"))
        store.record(announcement: "etl:announcement:1")
        #expect(store.hasSeen(announcement: "etl:announcement:1"))
        // 같은 공지를 두 번 적어도 목록이 불어나지 않는다.
        store.record(announcement: "etl:announcement:1")
        #expect(store.seenAnnouncements.count == 1)
    }

    @Test("과제는 정확한 마감을 지닌 수집 항목이 된다")
    func assignmentBecomesSourceItem() throws {
        let course = Self.course(305_638, "2026-2 로봇인공지능만들기 (001)", term: 164)
        let due = ISO8601DateFormatter().date(from: "2026-09-09T13:00:00Z")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let item = ETLSource.item(for: Self.assignment(id: 42, due: due), course: course, stage: .oneDay, now: now)

        #expect(item.source == SourceName.etl)
        // 달력 한 줄이 "eTL · 로봇인공지능만들기"로 읽혀야 한다.
        #expect(item.account == "로봇인공지능만들기")
        #expect(item.subject == "[마감 D-1] Lab 1 보고서")
        // 단계마다 다른 id, 그러나 추적은 과제 하나로 묶인다.
        #expect(item.id == "etl:assignment:42:oneDay")
        #expect(item.stableID == "etl:assignment:42")
        // 본문은 사람이 읽을 수 있어야 하고, HTML이 그대로 새어 나오면 안 된다.
        #expect(item.body.contains("마감: 2026년 9월 9일 22시 00분"))
        #expect(item.body.contains("아직 제출하지 않았습니다"))
        #expect(item.body.contains("PDF"))
        #expect(!item.body.contains("<b>"))
        #expect(!item.body.contains("&nbsp;"))

        // 마감은 추정이 아니라 API가 준 값이고, 달력이 읽는 그 형식이어야 한다.
        let deadline = try #require(item.knownDeadline)
        let parsed = try #require(KoreanDeadline.parse(deadline, now: now))
        #expect(parsed.date == due)
        #expect(parsed.includesTime)
        #expect(parsed.isConfident)
    }

    @Test("제출을 마친 과제도 마감까지 그대로 보인다")
    func submittedWorkIsStillShown() {
        let course = Self.course(1, "2026-2 자료구조의 기초 (001)", term: 164)
        let due = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(2 * 86_400)
        let item = ETLSource.item(for: Self.assignment(id: 9, due: due, submitted: true),
                                  course: course, stage: .first, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(item.body.contains("제출했습니다"))
        #expect(item.subject == "Lab 1 보고서")
    }

    @Test("공지는 과목 이름을 달고 항목이 된다")
    func announcementBecomesSourceItem() throws {
        let json = """
        [{"id": 377524, "title": "[Lab 1] Preparation for Lab 1",
          "message": "<p>준비물을 확인하세요.</p>",
          "html_url": "https://myetl.snu.ac.kr/courses/306075/discussion_topics/377524",
          "posted_at": "2026-09-04T02:01:47Z", "context_code": "course_306075"}]
        """
        let announcements = try ETLSource.decoder.decode([ETLAnnouncement].self, from: Data(json.utf8))
        let course = Self.course(306_075, "2026-2 Creative Engineering Design (002)", term: 164)
        let item = ETLSource.item(for: announcements[0], course: course, id: "etl:announcement:377524")

        #expect(item.source == SourceName.etl)
        #expect(item.account == "Creative Engineering Design")
        #expect(item.subject == "[Lab 1] Preparation for Lab 1")
        #expect(item.body.contains("준비물을 확인하세요."))
        #expect(item.link.absoluteString.hasSuffix("377524"))
        // 공지에는 마감이 없다. 없는 것을 있다고 말하지 않는다.
        #expect(item.knownDeadline == nil)
        #expect(item.timestamp == ISO8601DateFormatter().date(from: "2026-09-04T02:01:47Z"))
    }

    /// 모델은 본문을 읽어 마감을 적는데, eTL은 시각을 이미 알고 있다. 아는 값을 다시 추측하게
    /// 두면 틀릴 기회만 생긴다.
    @Test("정확한 마감이 모델이 읽은 마감을 대체한다")
    func exactDeadlineWins() {
        let course = Self.course(1, "2026-2 프로그래밍방법론 (001)", term: 164)
        let due = ISO8601DateFormatter().date(from: "2026-09-09T13:00:00Z")!
        let source = ETLSource.item(for: Self.assignment(id: 42, due: due), course: course, stage: .first, now: Date())
        let guessed = ClassifiedItem(
            sourceItem: source, facts: "과제", category: .action, summary: "보고서를 제출해야 합니다.",
            reason: "본인 과제", importance: 5, nextAction: "PDF 제출", deadline: "9월 10일"
        )
        let corrected = ExactDeadlines.applied(to: [guessed])
        #expect(corrected[0].deadline == source.knownDeadline)

        // 정확한 마감이 없는 항목은 그대로 둔다. 게시판 공지는 여전히 모델이 읽는다.
        let notice = SourceItem(id: "web:1", source: SourceName.web, account: "학부대학", author: "학부대학",
                                timestamp: Date(), subject: "장학금", body: "9월 10일까지",
                                link: URL(string: "https://snuc.snu.ac.kr/a/1")!)
        let untouched = ClassifiedItem(
            sourceItem: notice, facts: "공지", category: .action, summary: "신청하세요.",
            reason: "지원 가능", importance: 4, nextAction: "신청", deadline: "9월 10일"
        )
        #expect(ExactDeadlines.applied(to: [untouched])[0].deadline == "9월 10일")
    }

    /// 첫 페이지만 읽는 구현은 과제가 많은 학기에 뒤쪽을 조용히 흘린다.
    @Test("Link 헤더의 다음 페이지를 찾는다")
    func followsPagination() throws {
        let url = URL(string: "https://myetl.snu.ac.kr/api/v1/courses")!
        let header = "<https://myetl.snu.ac.kr/api/v1/courses?page=2&per_page=100>; rel=\"next\","
            + "<https://myetl.snu.ac.kr/api/v1/courses?page=5&per_page=100>; rel=\"last\""
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Link": header])!
        #expect(ETLSource.nextPage(in: response)?.absoluteString.contains("page=2") == true)

        let last = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                   headerFields: ["Link": "<https://myetl.snu.ac.kr/api/v1/courses?page=1>; rel=\"first\""])!
        #expect(ETLSource.nextPage(in: last) == nil)
        #expect(ETLSource.nextPage(in: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!) == nil)
    }

    @Test("eTL은 브리핑에서 자기 출처로 묶인다")
    func etlIsItsOwnSource() {
        #expect(SourceName.ordered.contains(SourceName.etl))
        // 게시판 공지와 같은 칸에 섞이면 과목 일이 학교 공지에 묻힌다.
        #expect(SourceName.etl != SourceName.web)
    }

    /// 첫 수집이 과제까지 숨기면, 연동한 날 브리핑에 eTL이 한 줄도 없다. 기준선은 학기 내내
    /// 쌓인 공지를 막으려는 것이지 아직 해야 할 일을 감추려는 것이 아니다.
    @Test("기준선은 공지에만 걸리고 과제는 첫 수집부터 올라온다")
    func baselineSilencesAnnouncementsOnly() {
        var store = ETLDigestStore()
        #expect(!store.hasBaseline)
        // 첫 수집에서도 마감이 남은 과제는 올릴 단계를 받는다.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let task = Self.assignment(id: 5, due: now.addingTimeInterval(5 * 86_400))
        #expect(store.stage(for: task, now: now) == .first)
        // 공지는 기준선이 잡히기 전이라도 "본 것"으로 기록되어 다음 실행에서 새 글이 아니다.
        store.record(announcement: "etl:announcement:1")
        #expect(store.hasSeen(announcement: "etl:announcement:1"))
    }

    @Test("토큰이 없으면 다른 소스를 막지 않고 경고만 남긴다")
    func missingTokenDoesNotFailTheRun() async {
        // 존재하지 않는 Keychain 항목을 가리키게 할 수는 없으므로, 토큰이 없는 기계에서만
        // 의미가 있는 검사다. 있으면 네트워크를 타지 않도록 건너뛴다.
        guard (try? ETLConfiguration.token()) == nil else { return }
        let harvest = await ETLSource().collect(persists: false)
        #expect(harvest.items.isEmpty)
        #expect(harvest.warnings.contains { $0.contains("토큰") })
    }
}
#endif
