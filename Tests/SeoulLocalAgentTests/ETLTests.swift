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

    private static func assignment(id: Int, due: Date?, submitted: Bool = false,
                                   lock: Date? = nil, excused: Bool = false) -> ETLAssignment {
        let dueText = due.map { "\"\(ISO8601DateFormatter().string(from: $0))\"" } ?? "null"
        let lockText = lock.map { "\"\(ISO8601DateFormatter().string(from: $0))\"" } ?? "null"
        let json = """
        {"id": \(id), "name": "Lab 1 보고서", "due_at": \(dueText), "lock_at": \(lockText),
         "html_url": "https://myetl.snu.ac.kr/courses/305638/assignments/\(id)",
         "description": "<p>보고서를 <b>PDF</b>로 제출하세요.&nbsp;</p>", "points_possible": 100,
         "submission": {"submitted_at": \(submitted ? "\"2026-09-08T10:00:00Z\"" : "null"),
                        "workflow_state": "unsubmitted", "excused": \(excused ? "true" : "false")}}
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

    // MARK: - 마감이 지난 뒤

    /// 단계 사다리는 마감 시각에서 끝난다. 그것만 있으면 놓친 과제가 D-1 다음 날 목록에서
    /// 조용히 사라지고, 화면에서 "끝냈다"와 "놓쳤다"를 구별할 수 없다.
    @Test("마감이 지난 미제출은 사흘에 한 번만 다시 올라온다")
    func missingSubmissionRepeatsEveryThirdDay() {
        var store = ETLDigestStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let key = "etl:missing:99"
        #expect(store.shouldReport(missing: key, now: now))
        store.record(missing: key, now: now)
        // 같은 날, 그리고 이틀 뒤까지는 조용하다.
        #expect(!store.shouldReport(missing: key, now: now))
        #expect(!store.shouldReport(missing: key, now: now.addingTimeInterval(2 * 86_400)))
        // 사흘이 지나면 다시 한 번. 이월이 하루 만에 끊기므로 이레는 너무 길다.
        #expect(store.shouldReport(missing: key, now: now.addingTimeInterval(3 * 86_400)))
    }

    @Test("미제출 항목은 정확한 마감과 과목을 달고 올라온다")
    func missingSubmissionBecomesAnItem() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = now.addingTimeInterval(-3 * 86_400)
        let json = """
        {"id": 356074, "name": "8주차 질의", "due_at": "\(ISO8601DateFormatter().string(from: due))",
         "html_url": "https://myetl.snu.ac.kr/courses/296405/assignments/356074",
         "course_id": 296405, "points_possible": 10}
        """
        let missing = try! ETLSource.decoder.decode(ETLMissingAssignment.self, from: Data(json.utf8))
        let item = ETLSource.item(for: missing, courseName: "전기·정보세미나 1", now: now)
        #expect(item.source == SourceName.etl)
        #expect(item.subject.hasPrefix("[미제출]"))
        #expect(item.account == "전기·정보세미나 1")
        // 이월된 사본을 대체해야지 매주 새 줄로 늘어나면 안 된다. 추적 이름은 과제와 같아야
        // 달력에서 스냅샷의 줄과 하나로 합쳐진다.
        #expect(item.stableID == "etl:assignment:356074")
        #expect(item.knownDeadline == ISO8601DateFormatter().string(from: due))
        #expect(item.body.contains("아직 제출하지 않았습니다"))
    }

    // MARK: - 마감이 바뀌었을 때

    /// 마감이 옮겨졌다는 사실은 공지 본문에 적히지 않는 일이 더 많다. 과제라면 API가 두 시각을
    /// 그대로 주므로 추정할 이유가 없다.
    @Test("마감이 바뀌면 한 번 알리고 지나간 단계를 다시 연다")
    func reopensStagesWhenTheDueDateMoves() {
        var store = ETLDigestStore()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = now.addingTimeInterval(2 * 86_400)
        let task = Self.assignment(id: 7, due: due)

        // 처음 보고, D-3과 D-1까지 전부 올린 상태로 만든다.
        #expect(store.movedDue(for: task) == nil)
        store.record(due: task)
        store.record(.oneDay, for: task)
        #expect(store.stage(for: task, now: now) == nil)

        // 교수가 마감을 2주 뒤로 옮겼다.
        let moved = Self.assignment(id: 7, due: due.addingTimeInterval(14 * 86_400))
        #expect(store.movedDue(for: moved) == due)
        store.record(due: moved)
        // "새 과제"로 다시 뜨지는 않지만, 새 날짜의 D-3·D-1은 다시 온다.
        #expect(store.stage(for: moved, now: now) == nil)
        #expect(store.stage(for: moved, now: moved.dueAt!.addingTimeInterval(-2 * 86_400)) == .threeDays)
        // 적어 둔 뒤에는 같은 값으로 다시 물어도 바뀐 것이 없다.
        #expect(store.movedDue(for: moved) == nil)
    }

    @Test("마감 변경 항목은 두 시각을 모두 적는다")
    func dueChangeItemNamesBothTimes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = now.addingTimeInterval(86_400)
        let due = now.addingTimeInterval(8 * 86_400)
        let course = Self.course(1, "2026-2 자료구조의 기초 (002)", term: 164)
        let item = ETLSource.item(for: Self.assignment(id: 7, due: due), course: course, movedFrom: previous, to: due, now: now)
        #expect(item.subject.hasPrefix("[마감 변경]"))
        #expect(item.stableID == "etl:assignment:7")
        #expect(item.knownDeadline == ISO8601DateFormatter().string(from: due))
        #expect(item.body.contains(ETLSource.dueText(previous)))
        #expect(item.body.contains(ETLSource.dueText(due)))
        #expect(item.body.contains("미뤄졌습니다"))
    }

    /// 한 과제가 만들 수 있는 세 가지 줄은 전부 같은 이름으로 추적된다. 이월된 사본을
    /// 대체하라고 그렇게 두었는데, 그래서 **한 수집에 둘 이상을 실으면 안 된다** — 화면은
    /// `trackingID`마다 한 줄만 남기므로 나머지가 조용히 사라진다. 수집이 마감 변경을 올린
    /// 실행에서 단계 알림을 건너뛰는 이유가 이것이다.
    @Test("한 과제가 만드는 줄은 모두 같은 이름으로 추적된다")
    func everyShapeOfOneAssignmentSharesATrackingID() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = now.addingTimeInterval(4 * 86_400)
        let course = Self.course(1, "2026-2 자료구조의 기초 (002)", term: 164)
        let task = Self.assignment(id: 356_074, due: due)

        let staged = ETLSource.item(for: task, course: course, stage: .threeDays, now: now)
        let changed = ETLSource.item(for: task, course: course, movedFrom: now, to: due, now: now)
        let json = """
        {"id": 356074, "name": "8주차 질의", "due_at": null,
         "html_url": "https://myetl.snu.ac.kr/courses/296405/assignments/356074",
         "course_id": 296405, "points_possible": 10}
        """
        let missing = ETLSource.item(
            for: try! ETLSource.decoder.decode(ETLMissingAssignment.self, from: Data(json.utf8)),
            courseName: "자료구조의 기초", now: now)

        #expect(staged.stableID == "etl:assignment:356074")
        #expect(changed.stableID == staged.stableID)
        #expect(missing.stableID == staged.stableID)
        // 같은 수집 안에서 서로를 지우지 않도록 `id`는 서로 달라야 한다.
        #expect(Set([staged.id, changed.id, missing.id]).count == 3)
    }

    // MARK: - 제출 창

    /// `마감`과 `제출이 막히는 시각`은 사람이 지금 할 행동이 서로 다르다. 하루가 더 있는 것과
    /// 그 순간 끝나는 것을 같은 말로 적으면 그 하루가 없어진다.
    @Test("마감 뒤에도 받는 시간이 있으면 그렇게 적는다")
    func namesTheLateWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = now.addingTimeInterval(5 * 86_400)
        let late = Self.assignment(id: 8, due: due, lock: due.addingTimeInterval(86_400))
        #expect(late.lateWindow == due.addingTimeInterval(86_400))
        let lines = ETLSource.submissionLines(for: late, stage: .first)
        #expect(lines.contains { $0.contains("지각 제출") })

        // 마감과 같은 시각에 잠기면 지각 제출이 없다는 것을 D-3·D-1 줄에서 말한다.
        let hard = Self.assignment(id: 9, due: due, lock: due)
        #expect(hard.lateWindow == nil)
        #expect(ETLSource.submissionLines(for: hard, stage: .oneDay).contains { $0.contains("제출 자체가 막힙니다") })
        // 처음 보는 줄에서는 아직 재촉하지 않는다.
        #expect(!ETLSource.submissionLines(for: hard, stage: .first).contains { $0.contains("막힙니다") })
    }

    @Test("면제받은 과제는 미제출로 적지 않는다")
    func excusedIsNotMissing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let excused = Self.assignment(id: 10, due: now.addingTimeInterval(86_400), excused: true)
        #expect(excused.submission?.isSettled == true)
        let lines = ETLSource.submissionLines(for: excused, stage: .first)
        #expect(lines.contains { $0.contains("면제") })
        #expect(!lines.contains { $0.contains("아직 제출하지 않았습니다") })
    }

    /// 한 과목이 500으로 답한 날 스냅샷을 그대로 갈아 끼우면, 그 과목의 마감이 달력에서
    /// 통째로 사라지고 흔적은 브리핑 아래 경고 한 줄뿐이다.
    @Test("읽지 못한 과목의 마감은 지난 스냅샷에서 이어받는다")
    func keepsDeadlinesOfCoursesThatFailedToLoad() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = now.addingTimeInterval(4 * 86_400)
        let read = Self.course(1, "2026-2 자료구조의 기초 (002)", term: 164)
        let unread = Self.course(2, "2026-2 기초전자기학 및 연습 (001)", term: 164)
        let previous = ETLDeadlineSnapshot(updatedAt: now, entries: [
            ETLSource.snapshotEntry(for: Self.assignment(id: 7, due: due), course: read),
            ETLSource.snapshotEntry(for: Self.assignment(id: 8, due: due), course: unread),
        ])
        // 이번 실행은 과목 1만 읽었다.
        let fresh = [ETLSource.snapshotEntry(for: Self.assignment(id: 7, due: due), course: read)]
        let carried = ETLSource.carriedOver(from: previous, unreadCourseIDs: [2], eventsFailed: false,
                                            alreadyHave: Set(fresh.map(\.id)))
        #expect(carried.map(\.id) == ["etl:assignment:8"])
        // 잘 읽은 과목의 것을 두 번 싣지는 않는다. 그래야 eTL에서 지워진 과제가 사라진다.
        #expect(ETLSource.carriedOver(from: previous, unreadCourseIDs: [], eventsFailed: false,
                                      alreadyHave: Set(fresh.map(\.id))).isEmpty)
    }

    /// 자르지 않으면 학기 초의 선택 연습문제 하나가 학기 내내 주황색 "지났습니다"로 서 있고
    /// 연결 상태의 "남은 과제"에도 계속 잡힌다.
    @Test("달력 스냅샷은 지난 두 달까지만 담는다")
    func snapshotDropsLongPastDeadlines() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let course = Self.course(1, "2026-2 자료구조의 기초 (002)", term: 164)
        let recent = ETLSource.snapshotEntry(for: Self.assignment(id: 1, due: now.addingTimeInterval(-30 * 86_400)), course: course)
        let ancient = ETLSource.snapshotEntry(for: Self.assignment(id: 2, due: now.addingTimeInterval(-90 * 86_400)), course: course)
        let future = ETLSource.snapshotEntry(for: Self.assignment(id: 3, due: now.addingTimeInterval(5 * 86_400)), course: course)
        let undated = ETLSource.snapshotEntry(for: Self.assignment(id: 4, due: nil, submitted: true), course: course)

        let kept = ETLSource.withinCalendarWindow([recent, ancient, future, undated], now: now)
        // 날짜가 없는 것은 달력에 서지 않지만 제출 여부를 알려 주므로 남는다.
        #expect(kept.map(\.id) == ["etl:assignment:1", "etl:assignment:3", "etl:assignment:4"])
    }

    // MARK: - 쪽지함

    /// 수강이 끝난 과목 셸은 과목 목록에도 없고 그쪽 `/announcements`는 401로 막힌다.
    /// 학부 통합 게시판의 실험 공지가 오는 길은 쪽지함뿐이다.
    @Test("쪽지 제목에서 앞에 붙은 과목 이름을 뗀다")
    func conversationDropsTheRepeatedCourseName() {
        let json = """
        {"id": 2370143, "subject": "[기초회로이론 통합 게시판] 실험 공지 3주차 준비물",
         "context_name": "기초회로이론 통합 게시판", "context_code": "course_301810",
         "last_message": "3주차 실험 준비물을 확인하세요.", "last_message_at": "2026-09-10T10:43:49Z",
         "workflow_state": "unread"}
        """
        let conversation = try! ETLSource.decoder.decode(ETLConversation.self, from: Data(json.utf8))
        #expect(conversation.shortSubject == "실험 공지 3주차 준비물")
        #expect(conversation.isUnread)
        let item = ETLSource.item(for: conversation, id: "etl:conversation:2370143")
        #expect(item.source == SourceName.etl)
        #expect(item.account == "기초회로이론 통합 게시판")
        #expect(item.subject == "실험 공지 3주차 준비물")
    }

    @Test("쪽지는 공지와 따로 기억되고 기준선도 따로다")
    func conversationsKeepTheirOwnBaseline() {
        var store = ETLDigestStore()
        #expect(!store.hasConversationBaseline)
        store.record(conversation: "etl:conversation:1")
        #expect(store.hasSeen(conversation: "etl:conversation:1"))
        // 공지 쪽 기억과 섞이지 않는다.
        #expect(!store.hasSeen(announcement: "etl:conversation:1"))
    }

    // MARK: - 달력이 읽는 스냅샷

    /// 달력은 브리핑 이력이 아니라 이 파일을 그린다. 덧붙이지 않고 통째로 갈아 끼우는 것이
    /// 중요하다 — eTL에서 사라진 과제가 달력에 남으면 안 된다.
    @Test("스냅샷은 과제와 수업 일정을 그대로 싣고 돌아온다")
    func snapshotRoundTrips() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "etl-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "etl-deadlines.json")
        // 파일이 없으면 빈 것으로 돌아온다. eTL이 없어도 달력은 그려져야 한다.
        #expect(ETLDeadlineSnapshot.load(url: url).entries.isEmpty)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let due = now.addingTimeInterval(3 * 86_400)
        let course = Self.course(1, "2026-2 자료구조의 기초 (002)", term: 164)
        let open = ETLSource.snapshotEntry(for: Self.assignment(id: 7, due: due, lock: due.addingTimeInterval(86_400)), course: course)
        let done = ETLSource.snapshotEntry(for: Self.assignment(id: 8, due: due, submitted: true), course: course)
        let eventJSON = """
        {"id": 52184, "title": "특강", "start_at": "\(ISO8601DateFormatter().string(from: due))",
         "end_at": null, "html_url": "https://myetl.snu.ac.kr/calendar?event_id=52184",
         "context_code": "course_305925", "context_name": "2026-2 자료구조의 기초 (002)",
         "location_name": "화상 강의", "description": null}
        """
        let event = ETLSource.snapshotEntry(
            for: try ETLSource.decoder.decode(ETLCalendarEvent.self, from: Data(eventJSON.utf8)), course: course)

        ETLDeadlineSnapshot(updatedAt: now, entries: [open, done, event]).save(url: url)
        let loaded = ETLDeadlineSnapshot.load(url: url)
        #expect(loaded.updatedAt == now)
        #expect(loaded.dated.map(\.id) == ["etl:assignment:7", "etl:assignment:8", "etl:event:52184"])
        // 달력 줄의 id는 브리핑 항목의 `stableID`와 같아야 두 줄로 갈라지지 않는다.
        #expect(loaded.entry(id: "etl:assignment:7")?.isSettled == false)
        #expect(loaded.entry(id: "etl:assignment:8")?.isSettled == true)
        #expect(loaded.entry(id: "etl:assignment:7")?.lockAt == due.addingTimeInterval(86_400))
        #expect(loaded.entry(id: "etl:event:52184")?.kind == .event)
        #expect(loaded.entry(id: "etl:event:52184")?.locationName == "화상 강의")
        // 개인정보가 담긴 파일이라 주인만 읽을 수 있어야 한다.
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
    }

    /// 필드를 하나 늘릴 때마다 기존 `etl-seen.json`이 통째로 버려지면, 그 실행은 기준선을
    /// 다시 잡느라 eTL이 한 줄도 올리지 않는다.
    @Test("옛 etl-seen.json에 없는 필드가 있어도 기억을 잃지 않는다")
    func decodesOlderStoreFiles() throws {
        let legacy = """
        {"seenAnnouncements": ["etl:announcement:1"],
         "assignmentStages": {"assignment:42": ["first"]},
         "hasBaseline": true}
        """
        let store = try JSONDecoder().decode(ETLDigestStore.self, from: Data(legacy.utf8))
        #expect(store.hasBaseline)
        #expect(store.hasSeen(announcement: "etl:announcement:1"))
        #expect(store.assignmentStages["assignment:42"] == ["first"])
        // 새 칸은 비어 있을 뿐이다.
        #expect(store.seenConversations.isEmpty)
        #expect(!store.hasConversationBaseline)
        #expect(store.assignmentDue.isEmpty)
    }
}
#endif
