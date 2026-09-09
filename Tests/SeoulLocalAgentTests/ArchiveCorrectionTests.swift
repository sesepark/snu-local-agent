#if canImport(Testing)
import Testing
import Foundation
@testable import SeoulLocalAgent

/// What the user-flow review turned up, held in place.
///
/// Every case here corresponds to something the app did wrong when it was walked
/// the way a person walks it: a briefing that could not say it was stale, a
/// heading that ignored its own limit, an 오늘 box that never emptied, a
/// misfiled item with no way to move it, and marks that outlived their items.
@Suite("보관함 교정과 상태")
struct ArchiveCorrectionTests {

    // MARK: - 도우미

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "archive-correction-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(
        id: String, category: BriefCategory = .action, importance: Int = 3,
        title: String? = nil, deadline: String = ""
    ) -> ClassifiedItem {
        let source = SourceItem(
            id: id, source: SourceName.gmail, account: "a@b.c", author: "학사행정",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000), subject: title ?? id,
            body: "제출 서류를 금요일까지 학사행정실로 보내 주시기 바랍니다. 확인 후 회신드리겠습니다.",
            link: URL(string: "https://example.invalid/\(id)")!, stableID: id
        )
        var value = ClassifiedItem(
            sourceItem: source, facts: "f", category: category, summary: "요약입니다.",
            reason: "r", importance: importance, nextAction: "서류 제출", deadline: deadline
        )
        value.displayTitle = title ?? id
        value.displaySummary = "요약입니다. 충분히 긴 설명 문장이 여기에 들어갑니다."
        value.bodyExcerpt = ClassifiedItem.excerpt(of: source.body)
        return value
    }

    private func briefing(_ dateKey: String, _ items: [ClassifiedItem], updatedAt: Date) -> DailyBriefing {
        DailyBriefing(dateKey: dateKey, items: items, sourceCounts: ["Gmail": items.count], failures: [], notionURL: nil, updatedAt: updatedAt)
    }

    @MainActor
    private func model(_ directory: URL, _ stateStore: StateStore) -> BriefingArchiveModel {
        BriefingArchiveModel(stateStore: stateStore, archiveStore: BriefingArchiveStore(directory: directory), preferences: .defaults)
    }

    private static func isoDeadline(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - 분류 교정

    /// The reader had no way to move a misfiled item at all: five corrections
    /// last week had to go through the classifier's instructions and wait for the
    /// next run.
    @MainActor
    @Test("항목을 직접 다른 칸으로 옮기고 되돌릴 수 있다")
    func movingAnItemBetweenBuckets() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [
            item(id: "gmail:tos", title: "이용약관 개정 안내"),
        ], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try stateStore.save(state)

        let model = model(directory, stateStore)
        let entry = try #require(model.entries(.action).first)
        #expect(!entry.isReclassified)

        // One step at a time, in both directions.
        model.move(entry, to: .reference)
        #expect(model.entries(.action).isEmpty)
        let moved = try #require(model.entries(.reference).first)
        #expect(moved.isReclassified)
        #expect(moved.item.category == .action, "저장된 분류는 그대로 두고 표시만 바꾼다")

        model.move(moved, to: .other)
        #expect(model.entries(.other).map(\.id) == ["gmail:tos"])

        // And back to whatever the model said, which is not an override.
        let inOther = try #require(model.entries(.other).first)
        model.clearCategoryOverride(inOther)
        #expect(model.entries(.action).map(\.id) == ["gmail:tos"])
        #expect(model.entries(.action).first?.isReclassified == false)
    }

    /// The override is the reader's own record and has to outlive a re-run, so it
    /// lives with the marks rather than in the briefing the pipeline rewrites.
    @MainActor
    @Test("직접 옮긴 결과는 다시 읽어도 남는다")
    func overrideSurvivesReload() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [item(id: "gmail:one")], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try stateStore.save(state)

        let first = model(directory, stateStore)
        let entry = try #require(first.entries(.action).first)
        first.move(entry, to: .other)

        let second = model(directory, stateStore)
        #expect(second.entries(.action).isEmpty)
        #expect(second.entries(.other).map(\.id) == ["gmail:one"])
    }

    // MARK: - 개수 상한

    /// `TODO 최대 개수` reached only the Notion export, so the one screen that is
    /// read every morning showed twelve action items under a setting that said
    /// ten — and eighteen reference items under one that said eight.
    @MainActor
    @Test("설정한 최대 개수가 화면에도 적용된다")
    func displayLimitsApplyToTheArchive() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        UserDefaults.standard.set(4, forKey: "briefingMaxActions")
        defer { UserDefaults.standard.removeObject(forKey: "briefingMaxActions") }

        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", (1...9).map {
            item(id: "gmail:\($0)", importance: $0)
        }, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try stateStore.save(state)

        let model = model(directory, stateStore)
        #expect(model.entries(.action).count == 9, "상한은 표시에만 걸리고 집계는 전체를 센다")
        #expect(model.openActionCount == 9)

        let shown = model.shown(.action)
        #expect(shown.entries.count == 4)
        #expect(shown.hidden == 5)
        #expect(shown.entries.map(\.id) == ["gmail:9", "gmail:8", "gmail:7", "gmail:6"], "중요한 것부터 남는다")

        // The rest has to stay reachable, not merely hidden.
        model.toggleBucketExpansion(.action)
        #expect(model.shown(.action).entries.count == 9)
        #expect(model.shown(.action).hidden == 0)
    }

    @MainActor
    @Test("검색 중에는 상한을 걸지 않는다")
    func searchIsNeverCapped() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        UserDefaults.standard.set(3, forKey: "briefingMaxActions")
        defer { UserDefaults.standard.removeObject(forKey: "briefingMaxActions") }

        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", (1...7).map {
            item(id: "gmail:\($0)", title: "장학금 서류 \($0)")
        }, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try stateStore.save(state)

        let model = model(directory, stateStore)
        #expect(model.shown(.action).entries.count == 3)
        model.search = "장학금"
        #expect(model.shown(.action).entries.count == 7)
        #expect(model.shown(.action).hidden == 0)
    }

    // MARK: - 오늘과 밀린 것

    /// 개요's 오늘 box had no lower bound on the deadline, so a mail that came
    /// due a fortnight ago sat in it permanently under a heading that said today.
    @MainActor
    @Test("지난 마감은 오늘이 아니라 밀린 것으로 간다")
    func overdueIsItsOwnList() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = KoreanDeadline.calendar.startOfDay(for: now)
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [
            item(id: "gmail:today", deadline: Self.isoDeadline(today.addingTimeInterval(3_600))),
            item(id: "gmail:yesterday", deadline: Self.isoDeadline(today.addingTimeInterval(-86_400))),
            item(id: "gmail:ancient", deadline: Self.isoDeadline(today.addingTimeInterval(-1_209_600))),
            item(id: "gmail:later", deadline: Self.isoDeadline(today.addingTimeInterval(864_000))),
        ], updatedAt: now)
        try stateStore.save(state)

        let model = model(directory, stateStore)
        #expect(model.dueToday(now: now).map(\.id) == ["gmail:today"])
        #expect(model.overdue(now: now).map(\.id) == ["gmail:yesterday", "gmail:ancient"], "가장 최근에 놓친 것이 먼저")
    }

    /// An item the reader pushed down to 기타 has stopped being something the
    /// first screen should chase them about.
    @MainActor
    @Test("기타로 내린 항목은 개요에서 재촉하지 않는다")
    func demotedItemsLeaveTheFrontPage() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = KoreanDeadline.calendar.startOfDay(for: now)
        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [
            item(id: "gmail:due", deadline: Self.isoDeadline(today.addingTimeInterval(3_600))),
        ], updatedAt: now)
        try stateStore.save(state)

        let model = model(directory, stateStore)
        #expect(model.dueToday(now: now).count == 1)
        let entry = try #require(model.entries(.action).first)
        model.move(entry, to: .reference)
        #expect(model.dueToday(now: now).isEmpty)
    }

    // MARK: - 낡음 표시

    @Test("마지막 성공 시각을 사람이 읽는 문장으로 만든다")
    func healthSummaryReadsAsASentence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(BriefingHealth(lastSuccessAt: nil).isStale(now: now))
        #expect(BriefingHealth(lastSuccessAt: nil).summary(now: now).contains("한 번도"))

        let fresh = BriefingHealth(lastSuccessAt: now.addingTimeInterval(-3_600))
        #expect(!fresh.isStale(now: now))
        #expect(fresh.summary(now: now).hasPrefix("마지막 성공 오늘"))

        let stale = BriefingHealth(lastSuccessAt: now.addingTimeInterval(-17 * 86_400))
        #expect(stale.isStale(now: now))
        #expect(stale.summary(now: now).contains("17일 전"))
    }

    @MainActor
    @Test("보관함은 며칠 전 브리핑인지 말한다")
    func archiveKnowsItIsStale() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = PersistentState()
        state.dailyBriefings["26/08/13"] = briefing("26/08/13", [item(id: "gmail:old")], updatedAt: now.addingTimeInterval(-17 * 86_400))
        try stateStore.save(state)

        let model = model(directory, stateStore)
        let day = try #require(model.selectedDay)
        #expect(model.isStale(day, now: now))
        #expect(model.stalenessSummary(day, now: now).contains("17일 전"))
    }

    // MARK: - 표시 흔적 정리

    /// Briefings are pruned by day and marks were pruned only by count, so a mark
    /// outlived the item it described and the file grew with every retired day.
    @MainActor
    @Test("사라진 브리핑의 오래된 표시는 함께 정리된다")
    func orphanedMarksAreDropped() throws {
        let directory = temporaryDirectory()
        let stateStore = StateStore(directory: directory)
        let archiveStore = BriefingArchiveStore(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        var marks = BriefingArchiveState()
        var ancient = BriefingMark()
        ancient.isDone = true
        ancient.updatedAt = now.addingTimeInterval(-200 * 86_400)
        marks.marks["gmail:gone"] = ancient
        var recent = BriefingMark()
        recent.isDone = true
        recent.updatedAt = now
        marks.marks["gmail:absent-today"] = recent
        var live = BriefingMark()
        live.note = "살아 있는 항목"
        live.updatedAt = now.addingTimeInterval(-200 * 86_400)
        marks.marks["gmail:live"] = live
        try archiveStore.save(marks)

        var state = PersistentState()
        state.dailyBriefings["26/08/30"] = briefing("26/08/30", [item(id: "gmail:live")], updatedAt: now)
        try stateStore.save(state)

        _ = BriefingArchiveModel(stateStore: stateStore, archiveStore: archiveStore, preferences: .defaults)

        let kept = archiveStore.load().marks
        #expect(kept["gmail:live"] != nil, "지금 있는 항목의 표시는 남는다")
        #expect(kept["gmail:absent-today"] != nil, "오늘 실행에 안 나왔을 뿐인 최근 표시도 남는다")
        #expect(kept["gmail:gone"] == nil, "가장 오래된 브리핑보다 오래됐고 항목도 없으면 지운다")
    }

    @Test("보관 기간은 한 학기를 담는다")
    func retentionCoversATerm() {
        #expect(PersistentState.retainedBriefingDays == 90)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var briefings: [String: DailyBriefing] = [:]
        for day in 0..<120 {
            let key = "26/\(String(format: "%02d", day / 30 + 1))/\(String(format: "%02d", day % 30 + 1))"
            briefings[key] = briefing(key, [item(id: "gmail:\(day)")], updatedAt: now.addingTimeInterval(TimeInterval(-day * 86_400)))
        }
        #expect(PersistentState.pruned(briefings).count == 90)
    }

    // MARK: - 모델 오류

    /// Ollama says exactly what is wrong and the pipeline used to throw it away,
    /// leaving a first-time reader with four words and nowhere to go.
    @Test("모델 오류는 Ollama가 말한 이유를 그대로 전한다")
    func modelFailureNamesTheReason() {
        let notFound = Data(#"{"error":"model '\#(AppConfig.model)' not found"}"#.utf8)
        let message = LocalClassifier.modelFailure(status: 404, body: notFound)
        #expect(message.contains(AppConfig.model))
        #expect(message.contains("ollama pull"))

        let other = LocalClassifier.modelFailure(status: 500, body: Data(#"{"error":"out of memory"}"#.utf8))
        #expect(other.contains("out of memory"))
        #expect(other.contains("500"))

        let silent = LocalClassifier.modelFailure(status: 502, body: Data("<html>".utf8))
        #expect(silent.contains("502"))
    }
}
#endif
