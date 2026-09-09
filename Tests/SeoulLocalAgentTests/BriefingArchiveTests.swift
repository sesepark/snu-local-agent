#if canImport(Testing)
import Testing
import Foundation
@testable import SeoulLocalAgent

/// The briefing's move out of Notion and into the app.
///
/// Two things carry real risk here and are covered accordingly: the archive file
/// is now the only record of what the reader finished, so losing or misreading
/// it silently resurrects completed work; and the deadline parser decides what
/// date gets written into somebody's calendar, where a wrong answer is worse
/// than no answer.
@Suite("Briefing archive")
struct BriefingArchiveTests {

    // MARK: - 도우미

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "briefing-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(
        id: String, category: BriefCategory = .action, importance: Int = 4,
        title: String = "서류 제출", deadline: String = "", source: String = SourceName.gmail,
        at timestamp: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> ClassifiedItem {
        let source = SourceItem(
            id: id, source: source, account: "a@b.c", author: "학사행정",
            timestamp: timestamp, subject: title,
            body: "제출 서류를 금요일까지 학사행정실로 보내 주시기 바랍니다. 확인 후 회신드리겠습니다.",
            link: URL(string: "https://example.invalid/\(id)")!, stableID: id
        )
        var value = ClassifiedItem(
            sourceItem: source, facts: "f", category: category, summary: "요약입니다.",
            reason: "r", importance: importance, nextAction: "서류 제출", deadline: deadline
        )
        value.displayTitle = title
        value.displaySummary = "요약입니다."
        return value
    }

    private func briefing(_ dateKey: String, _ items: [ClassifiedItem], updatedAt: Date) -> DailyBriefing {
        DailyBriefing(dateKey: dateKey, items: items, sourceCounts: ["Gmail": items.count], failures: [], notionURL: nil, updatedAt: updatedAt)
    }

    // MARK: - 저장

    @Test("Marks survive a round trip and the file stays private")
    func storeRoundTrip() throws {
        let directory = temporaryDirectory()
        let store = BriefingArchiveStore(directory: directory)
        #expect(store.load().marks.isEmpty)

        var state = BriefingArchiveState()
        var mark = BriefingMark()
        mark.isDone = true
        mark.note = "조교에게 확인함"
        mark.calendarEventID = "EVENT-1"
        state.marks["gmail:1"] = mark
        try store.save(state)

        let reloaded = store.load()
        #expect(reloaded.marks["gmail:1"]?.isDone == true)
        #expect(reloaded.marks["gmail:1"]?.note == "조교에게 확인함")
        #expect(reloaded.completedIDs == ["gmail:1"])

        // Everything this app writes holds personal data and is owner-only.
        let attributes = try FileManager.default.attributesOfItem(atPath: store.debugPath)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    }

    @Test("A mark with nothing in it is not kept")
    func blankMarksArePruned() throws {
        let store = BriefingArchiveStore(directory: temporaryDirectory())
        var state = BriefingArchiveState()
        state.marks["gmail:blank"] = BriefingMark()
        var real = BriefingMark()
        real.isDone = true
        state.marks["gmail:real"] = real
        try store.save(state)
        #expect(Set(store.load().marks.keys) == ["gmail:real"])
    }

    @Test("An archive written by an older version still loads")
    func decodingToleratesMissingKeys() throws {
        let directory = temporaryDirectory()
        let store = BriefingArchiveStore(directory: directory)
        let json = #"{"marks":{"gmail:1":{"isDone":true}}}"#
        try Data(json.utf8).write(to: directory.appending(path: "briefing-archive.json"))
        let state = store.load()
        #expect(state.marks["gmail:1"]?.isDone == true)
        #expect(state.marks["gmail:1"]?.note == "")
    }

    // MARK: - 이월

    @Test("Carry-forward no longer depends on what a page rendered")
    func carryForwardCoversItemsBeyondTheReportCap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Twenty actions is more than any report ever printed as checkboxes. The
        // Notion-driven version could only carry the ones it had written, so the
        // rest disappeared the next morning without ever being finished.
        let items = (0..<20).map { item(id: "gmail:\($0)", title: "제출 \($0)") }
        let outcome = CarryForwardPolicy.evaluate(previousItems: items, completedIDs: ["gmail:3"], now: now)
        #expect(outcome.carried.count == 19)
        #expect(!outcome.carried.contains { $0.trackingID == "gmail:3" })
    }

    @Test("Identity survives a reworded title")
    func carryForwardTracksIDsNotTitles() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var renamed = item(id: "gmail:1", title: "완전히 다른 제목으로 다시 쓰인 항목")
        renamed.displayTitle = "완전히 다른 제목으로 다시 쓰인 항목"
        let outcome = CarryForwardPolicy.evaluate(previousItems: [renamed], completedIDs: ["gmail:1"], now: now)
        #expect(outcome.carried.isEmpty)
    }

    @Test("보관함에서 옮긴 분류가 다음 실행의 이월을 정한다")
    func carryForwardHonoursTheReadersReclassification() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let demoted = item(id: "gmail:demoted", title: "홍보 메일")
        let stillAction = item(id: "gmail:open", title: "서류 제출")
        // 모델이 확인 항목으로 둔 것을 사람이 할 일로 올린 경우. 올린 것도 같은 무게로
        // 지켜져야 한다 — 한쪽만 반영하면 옮기기는 반쪽짜리 기능이 된다.
        let promoted = item(id: "gmail:promoted", category: .reference, title: "면담 신청")

        let outcome = CarryForwardPolicy.evaluate(
            previousItems: [demoted, stillAction, promoted],
            completedIDs: [],
            overrides: [demoted.trackingID: .excluded, promoted.trackingID: .action],
            now: now
        )
        // `기타`로 내린 것은 다음 날 `오늘 꼭 할 일`에 다시 서지 않는다. 이것이 없던
        // 동안에는 같은 항목을 며칠이고 다시 내려야 했다.
        #expect(!outcome.carried.contains { $0.trackingID == demoted.trackingID })
        #expect(outcome.carried.contains { $0.trackingID == stillAction.trackingID })
        #expect(outcome.carried.contains { $0.trackingID == promoted.trackingID })
    }

    @Test("옮긴 적 없는 항목은 모델의 분류대로 이월된다")
    func carryForwardKeepsModelCategoryWithoutAnOverride() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let action = item(id: "gmail:a")
        let reference = item(id: "gmail:r", category: .reference)
        let outcome = CarryForwardPolicy.evaluate(previousItems: [action, reference], completedIDs: [], now: now)
        #expect(outcome.carried.map(\.trackingID) == [action.trackingID])
    }

    @Test("마감 없이 오래된 할 일은 이월을 그만둔다")
    func staleUndatedActionsStopBeingCarried() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 마감이 적힌 항목에는 빠질 날이 있지만, 마감이 없는 항목에는 없다. 그래서
        // 체크할 때까지 영원히 따라오고, `오늘 꼭 할 일`이 그만큼 못 읽는 자리가 된다.
        let fresh = item(id: "gmail:fresh", title: "이번 주 요청", at: now.addingTimeInterval(-3 * 86_400))
        let old = item(id: "gmail:old", title: "3주 전 요청", at: now.addingTimeInterval(-21 * 86_400))

        let outcome = CarryForwardPolicy.evaluate(previousItems: [fresh, old], completedIDs: [], now: now)
        #expect(outcome.carried.map(\.trackingID) == [fresh.trackingID])
        // 조용히 사라지지 않는다. 세어서 화면에 적고, 그날을 펼치면 그대로 있다.
        #expect(outcome.stale.map(\.trackingID) == [old.trackingID])
        #expect(outcome.expired.isEmpty)
    }

    @Test("마감이 남아 있으면 오래된 항목도 계속 이월한다")
    func aLiveDeadlineOutranksAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        // 한 달 전에 온 메일이지만 마감은 다음 주다. 나이로 끊으면 정작 아직 해야 하는
        // 일이 사라진다 — 나이는 마감이 **없을 때만** 보는 자다.
        let old = item(
            id: "gmail:longlead", title: "장학금 신청",
            deadline: iso.string(from: now.addingTimeInterval(7 * 86_400)),
            at: now.addingTimeInterval(-30 * 86_400)
        )
        let outcome = CarryForwardPolicy.evaluate(previousItems: [old], completedIDs: [], now: now)
        #expect(outcome.carried.map(\.trackingID) == [old.trackingID])
        #expect(outcome.stale.isEmpty)
    }

    // MARK: - 화면

    @MainActor
    @Test("The archive buckets a day the way the report used to")
    func modelGroupsAndSorts() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        var state = PersistentState()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [
            item(id: "gmail:low", importance: 2, title: "덜 급한 일"),
            item(id: "gmail:high", importance: 5, title: "급한 일"),
            item(id: "web:ref", category: .reference, title: "공지 확인", source: SourceName.web),
            item(id: "gmail:out", category: .excluded, title: "홍보 메일"),
        ], updatedAt: now)
        state.dailyBriefings["26/08/29"] = briefing("26/08/29", [item(id: "gmail:old", title: "어제 일")], updatedAt: now.addingTimeInterval(-86_400))
        try stateStore.save(state)

        let model = BriefingArchiveModel(stateStore: stateStore, archiveStore: BriefingArchiveStore(directory: directory), preferences: .defaults)
        #expect(model.selectedDateKey == "26/08/30")
        #expect(model.entries(.action).map(\.id) == ["gmail:high", "gmail:low"])
        #expect(model.entries(.reference).map(\.id) == ["web:ref"])
        #expect(model.entries(.other).map(\.id) == ["gmail:out"])
        #expect(model.openActionCount == 2)

        // Ticking one off sinks it and takes it out of the outstanding count.
        let top = try #require(model.entries(.action).first)
        model.toggleDone(top)
        #expect(model.entries(.action).map(\.id) == ["gmail:low", "gmail:high"])
        #expect(model.openActionCount == 1)
        // And it is what tomorrow's carry-forward reads.
        #expect(BriefingArchiveStore(directory: directory).load().completedIDs == ["gmail:high"])

        // Day navigation walks backwards through the days that exist.
        #expect(model.canStepBack)
        model.step(1)
        #expect(model.selectedDateKey == "26/08/29")
        #expect(model.entries(.action).map(\.id) == ["gmail:old"])
    }

    @Test("A link is only forgotten when it could actually be looked up")
    func reconciliationNeedsAccessBeforeForgetting() {
        let event = CalendarPlacement(identifier: "EVENT", date: Date(), isReminder: false)
        let reminder = CalendarPlacement(identifier: "REMINDER", date: Date(), isReminder: true)
        let both = [event, reminder]

        // Permission revoked: every EventKit lookup comes back empty. Concluding
        // the user deleted everything would wipe the archive's calendar links in
        // one pass, which is the bug this rule exists to prevent.
        #expect(PlacementReconciliation.lost(both, hasEventAccess: false, hasReminderAccess: false) { _ in false }.isEmpty)
        // Half revoked: only the half that could be checked may be forgotten.
        #expect(PlacementReconciliation.lost(both, hasEventAccess: true, hasReminderAccess: false) { _ in false } == ["EVENT"])
        // Permission held and the event really is gone.
        #expect(PlacementReconciliation.lost(both, hasEventAccess: true, hasReminderAccess: true) { _ in false } == ["EVENT", "REMINDER"])
        // Permission held and both still exist.
        #expect(PlacementReconciliation.lost(both, hasEventAccess: true, hasReminderAccess: true) { _ in true }.isEmpty)
    }

    @MainActor
    @Test("Search reaches every retained day, day view does not")
    func searchWidensTheScope() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        var state = PersistentState()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [item(id: "gmail:today", title: "오늘 항목")], updatedAt: now)
        state.dailyBriefings["26/08/20"] = briefing("26/08/20", [item(id: "gmail:old", title: "장학금 서류")], updatedAt: now.addingTimeInterval(-864_000))
        try stateStore.save(state)

        let model = BriefingArchiveModel(stateStore: stateStore, archiveStore: BriefingArchiveStore(directory: directory), preferences: .defaults)
        #expect(model.entries(.action).map(\.id) == ["gmail:today"])
        model.search = "장학금"
        #expect(model.isSearching)
        #expect(model.entries(.action).map(\.id) == ["gmail:old"])
    }

    @MainActor
    @Test("개요 lists what is due today and nothing else")
    func dueTodayCoversOnlyOpenActions() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = KoreanDeadline.calendar.startOfDay(for: now)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [
            item(id: "gmail:due", deadline: iso.string(from: today.addingTimeInterval(3_600))),
            item(id: "gmail:later", deadline: iso.string(from: today.addingTimeInterval(864_000))),
            item(id: "gmail:none", deadline: ""),
            item(id: "web:ref", category: .reference, deadline: iso.string(from: today.addingTimeInterval(3_600)), source: SourceName.web),
        ], updatedAt: now)
        try stateStore.save(state)

        let model = BriefingArchiveModel(stateStore: stateStore, archiveStore: BriefingArchiveStore(directory: directory), preferences: .defaults)
        #expect(model.dueToday(now: now).map(\.id) == ["gmail:due"])

        // Finishing it takes it off the front page.
        let due = try #require(model.dueToday(now: now).first)
        model.toggleDone(due)
        #expect(model.dueToday(now: now).isEmpty)
    }

    // MARK: - 일정 달력

    @MainActor
    @Test("달력은 마감과 넘긴 일정을 날짜별로 모은다")
    func calendarGroupsDeadlinesAndPlacements() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = KoreanDeadline.calendar.startOfDay(for: now)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [
            item(id: "gmail:soon", title: "장학금 서류", deadline: iso.string(from: today.addingTimeInterval(90_000))),
            // 날짜가 아닌 말. 달력에 놓을 수 없고, 그래서 따로 세어야 한다.
            item(id: "gmail:vague", title: "회신 요청", deadline: "가급적 빠른 시일 내"),
            item(id: "gmail:none", title: "그냥 공지", deadline: ""),
        ], updatedAt: now)
        try stateStore.save(state)

        let model = BriefingArchiveModel(stateStore: stateStore, archiveStore: BriefingArchiveStore(directory: directory), preferences: .defaults)

        // 달력은 고른 날짜와 검색에 매이지 않는다. 보관함이 하루만 보여 주고 있어도
        // 다음 주 마감은 달력에 있어야 한다.
        let dated = model.datedEntries(now: now)
        #expect(dated.map(\.entry.id) == ["gmail:soon"])
        #expect(dated.first?.kind == .deadline)

        // 날짜가 없는 것은 조용히 빠지는 대신 세어 둔다.
        #expect(model.undatedDeadlineEntries(now: now).map(\.id) == ["gmail:vague"])

        // 하루 단위로 묶이고, 그 열쇠는 그날 0시다 — 달력 칸 하나가 그 열쇠 하나다.
        let byDay = model.datedEntriesByDay(now: now)
        let expectedDay = KoreanDeadline.calendar.startOfDay(for: today.addingTimeInterval(90_000))
        #expect(byDay[expectedDay]?.map(\.entry.id) == ["gmail:soon"])
    }

    @MainActor
    @Test("사람이 정한 일정이 같은 날의 마감을 대신한다")
    func placementReplacesTheDeadlineOnTheSameDay() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = KoreanDeadline.calendar.startOfDay(for: now)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [
            item(id: "gmail:placed", title: "면담 신청", deadline: iso.string(from: today.addingTimeInterval(50_000))),
        ], updatedAt: now)
        try stateStore.save(state)

        var mark = BriefingMark()
        mark.calendarEventID = "event-1"
        mark.scheduledAt = today.addingTimeInterval(46_800)
        try BriefingArchiveStore(directory: directory).save(BriefingArchiveState(marks: ["gmail:placed": mark]))

        let model = BriefingArchiveModel(stateStore: stateStore, archiveStore: BriefingArchiveStore(directory: directory), preferences: .defaults)
        let dated = model.datedEntries(now: now)
        // 한 줄만 남는다. 사람이 확인해 넣은 시각이 본문에서 읽어 낸 것보다 정확하고,
        // 같은 제목이 한 칸에 두 번 서면 달력이 그만큼 읽기 어려워진다.
        #expect(dated.count == 1)
        #expect(dated.first?.kind == .scheduled)
        #expect(dated.first?.date == mark.scheduledAt)
    }

    @MainActor
    @Test("지난 마감은 끝내기 전까지만 지난 것이다")
    func lateOnlyCountsWhileTheWorkIsOpen() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [
            item(id: "gmail:late", title: "지난 과제", deadline: iso.string(from: now.addingTimeInterval(-86_400))),
        ], updatedAt: now)
        try stateStore.save(state)

        let model = BriefingArchiveModel(stateStore: stateStore, archiveStore: BriefingArchiveStore(directory: directory), preferences: .defaults)
        let late = try #require(model.datedEntries(now: now).first)
        #expect(late.isLate(now: now))

        // 끝낸 일을 계속 붉게 세워 두면 달력은 매일 같은 경고를 반복한다.
        model.toggleDone(late.entry)
        let after = try #require(model.datedEntries(now: now).first)
        #expect(!after.isLate(now: now))
    }

    @MainActor
    @Test("`기타`로 내린 항목은 지났어도 재촉하지 않는다")
    func demotedItemsStopNagging() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [
            item(id: "gmail:mine", title: "내 과제", deadline: iso.string(from: now.addingTimeInterval(-86_400))),
            item(id: "gmail:junk", title: "홍보 메일", deadline: iso.string(from: now.addingTimeInterval(-86_400))),
        ], updatedAt: now)
        try stateStore.save(state)

        var mark = BriefingMark()
        mark.categoryOverride = .excluded
        let junkID = item(id: "gmail:junk").trackingID
        try BriefingArchiveStore(directory: directory).save(BriefingArchiveState(marks: [junkID: mark]))

        let model = BriefingArchiveModel(stateStore: stateStore, archiveStore: BriefingArchiveStore(directory: directory), preferences: .defaults)
        let dated = model.datedEntries(now: now)
        let mine = try #require(dated.first { $0.entry.id.contains("mine") })
        let junk = try #require(dated.first { $0.entry.id.contains("junk") })

        // 둘 다 마감은 지났다.
        #expect(mine.isLate(now: now))
        #expect(junk.isLate(now: now))
        // 그러나 사람이 내린 쪽은 화면이 붉게 세우지 않는다. 이미 "상관없다"고 말한
        // 항목을 매일 다시 내리라고 조르는 화면이 되지 않게 하는 것이 요점이다.
        #expect(mine.nags(now: now))
        #expect(!junk.nags(now: now))
    }

    // MARK: - 읽고 가져가기

    /// The state file drops `sourceItem.body` on every save, so an archive that
    /// read the body straight off the source item showed nothing at all from the
    /// second run onwards — which is how the reader found it.
    @Test("The archive shows the excerpt that survives being saved")
    func bodyComesFromTheStoredExcerpt() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        var stored = item(id: "gmail:body")
        stored.bodyExcerpt = ClassifiedItem.excerpt(of: stored.sourceItem.body)
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [stored], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try stateStore.save(state)

        let reloaded = try #require(stateStore.load().dailyBriefings["26/08/30"]?.items.first)
        #expect(reloaded.sourceItem.body.isEmpty)
        #expect(reloaded.bodyExcerpt?.contains("학사행정실") == true)
    }

    @Test("An excerpt is bounded, and absent when there is nothing to show")
    func excerptsAreBounded() {
        #expect(ClassifiedItem.excerpt(of: "") == nil)
        #expect(ClassifiedItem.excerpt(of: "google_api") == nil)
        let long = String(repeating: "가", count: 2_000)
        let excerpt = ClassifiedItem.excerpt(of: long) ?? ""
        #expect(!excerpt.isEmpty)
        #expect(excerpt.count <= ClassifiedItem.bodyExcerptLimit + 1)
    }

    /// SwiftUI carries a selection inside one `Text` and no further, so dragging
    /// across a row can never produce the whole item. Copy has to build it.
    @MainActor
    @Test("Copying an item gives back everything the row shows")
    func copyingAnItemKeepsItsSubstance() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        var stored = item(id: "gmail:copy", title: "국가장학금 2차 신청", deadline: "2026-09-09T18:00:00+09:00")
        stored.bodyExcerpt = "신청 기간은 9월 9일 18시까지입니다."
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [
            stored,
            item(id: "web:ref", category: .reference, title: "공지 확인", source: SourceName.web),
        ], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try stateStore.save(state)

        let model = BriefingArchiveModel(stateStore: stateStore, archiveStore: BriefingArchiveStore(directory: directory), preferences: .defaults)
        let entry = try #require(model.entries(.action).first)
        let text = entry.plainText
        #expect(text.hasPrefix("국가장학금 2차 신청"))
        #expect(text.contains("마감 9월 9일 18시 00분"))
        #expect(text.contains("신청 기간은 9월 9일 18시까지입니다."))
        #expect(text.contains("https://example.invalid/gmail:copy"))

        // The whole day keeps the reader's headings and their ticks.
        model.toggleDone(entry)
        let day = model.plainText()
        #expect(day.contains(BriefingArchiveModel.Bucket.action.rawValue))
        #expect(day.contains(BriefingArchiveModel.Bucket.reference.rawValue))
        #expect(day.contains("[x] 국가장학금 2차 신청"))
        #expect(day.contains("[ ] 공지 확인"))
    }
}

/// The deadline strings that actually turn up, and what each one has to mean.
@Suite("Korean deadlines")
struct KoreanDeadlineTests {

    /// A Sunday, so "이번 주 금요일" and "다음 주 금요일" are five and twelve days
    /// out and the two readings cannot be confused.
    private let now: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 30
        components.hour = 15
        components.minute = 33
        return KoreanDeadline.calendar.date(from: components)!
    }()

    /// One comparable string rather than a tuple, so a failure prints the whole
    /// reading — including the year, which is where a bare "15일" rolling to the
    /// wrong place would otherwise hide.
    private func read(_ text: String) -> String? {
        guard let value = KoreanDeadline.parse(text, now: now) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = KoreanDeadline.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: value.date)) \(value.includesTime ? "시각" : "날짜") \(value.isConfident ? "확실" : "확인필요")"
    }

    @Test("Dates written the way a Korean message writes them")
    func absoluteDates() {
        #expect(read("9월 15일까지") == "2026-09-15 00:00 날짜 확실")
        #expect(read("2026년 9월 15일 오후 6시") == "2026-09-15 18:00 시각 확실")
        #expect(read("9/15") == "2026-09-15 00:00 날짜 확실")
        #expect(read("9월말") == "2026-09-30 00:00 날짜 확실")
        // A bare day already past rolls to the next month, not the next year.
        #expect(read("15일까지 제출") == "2026-09-15 00:00 날짜 확실")
        // The machine-readable shape the classifier is actually asked for.
        #expect(read("2026-09-15T18:00:00+09:00") == "2026-09-15 18:00 시각 확실")
        #expect(read("2026-09-15") == "2026-09-15 00:00 날짜 확실")
    }

    @Test("Days named relative to today")
    func relativeDays() {
        #expect(read("오늘") == "2026-08-30 00:00 날짜 확실")
        #expect(read("내일 오전 10시") == "2026-08-31 10:00 시각 확실")
        #expect(read("모레까지") == "2026-09-01 00:00 날짜 확실")
        #expect(read("3일 뒤") == "2026-09-02 00:00 날짜 확실")
        #expect(read("2주 후") == "2026-09-13 00:00 날짜 확실")
        #expect(read("이번 주 금요일") == "2026-09-04 00:00 날짜 확실")
        #expect(read("다음 주 금요일") == "2026-09-11 00:00 날짜 확실")
    }

    @Test("A time in the afternoon is a time in the afternoon")
    func afternoonTimes() {
        #expect(read("내일 오후 6시 30분") == "2026-08-31 18:30 시각 확실")
        #expect(read("내일 18:00") == "2026-08-31 18:00 시각 확실")
        #expect(read("내일 자정") == "2026-08-31 00:00 시각 확실")
        #expect(read("내일 정오") == "2026-08-31 12:00 시각 확실")
    }

    @Test("A bare time means today and is offered for confirmation")
    func bareTimeIsNotConfident() {
        // Not confident, so the UI opens the picker instead of writing it
        // straight into the calendar.
        #expect(read("18시까지") == "2026-08-30 18:00 시각 확인필요")
    }

    @Test("A date with no year rolls forward across the new year")
    func yearlessDatesRollForward() {
        // Read at the end of August, "1월 5일" is next January, not eight
        // months ago.
        #expect(read("1월 5일") == "2027-01-05 00:00 날짜 확실")
        // A deadline that only just passed is left where it is, so the report
        // can still say it was missed.
        #expect(read("8월 28일") == "2026-08-28 00:00 날짜 확실")
    }

    @Test("Urgency is not a date")
    func vaguePhrasesAreRefused() {
        #expect(KoreanDeadline.parse("", now: now) == nil)
        #expect(KoreanDeadline.parse("가급적 빨리", now: now) == nil)
        #expect(KoreanDeadline.parse("추후 공지", now: now) == nil)
        #expect(KoreanDeadline.parse("없음", now: now) == nil)
        // …but an urgent phrase that also names a day still yields the day.
        #expect(read("가급적 빨리, 늦어도 9월 15일") == "2026-09-15 00:00 날짜 확실")
    }
}
#endif
