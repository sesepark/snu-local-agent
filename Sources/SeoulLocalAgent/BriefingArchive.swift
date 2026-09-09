import AppKit
import Foundation

/// What the reader did with one briefing item: ticked it off, wrote a note on
/// it, put it on the calendar.
///
/// This used to live in Notion — the checkbox on the page *was* the completion
/// state, and the next morning's carry-forward read those checkboxes back over
/// the network to decide what was still outstanding. Keeping it here instead
/// means the app can answer "무엇이 남았나" on its own, and keys the answer to
/// `ClassifiedItem.trackingID` rather than to the rendered title, so an item
/// whose wording changes between runs is still recognised as the same thing.
struct BriefingMark: Codable, Equatable {
    var isDone = false
    var completedAt: Date?
    var note = ""
    /// `EKEvent.eventIdentifier` / `EKReminder.calendarItemIdentifier` of what
    /// this item was turned into, so a second run does not add it twice.
    var calendarEventID: String?
    var reminderID: String?
    /// When the calendar entry sits, kept here so the archive can say
    /// "9월 3일 14시" without opening EventKit for every visible row.
    var scheduledAt: Date?
    /// Where the reader put this item when the model put it somewhere else.
    ///
    /// Kept with the reader's marks rather than written back into the stored
    /// briefing, for the same reason `BriefingQualityGate` runs at display time:
    /// the briefing is what the pipeline produced and stays that, while this is
    /// what the reader decided, and it survives a re-run that re-analyses the
    /// same thread. It is also the honest record — the archive can still say
    /// what the model thought and what the reader changed it to.
    var categoryOverride: BriefCategory?
    var updatedAt = Date()

    var isPlaced: Bool { calendarEventID != nil || reminderID != nil }
    /// A mark with nothing in it is not worth storing, and pruning it keeps the
    /// file proportional to what the user actually touched.
    var isBlank: Bool { !isDone && note.isEmpty && !isPlaced && categoryOverride == nil }

    init() {}

    /// Written by hand rather than synthesised: the synthesised decoder fails on
    /// a missing key, which would mean that adding one field in a later version
    /// silently discarded every mark the user had already made.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        calendarEventID = try container.decodeIfPresent(String.self, forKey: .calendarEventID)
        reminderID = try container.decodeIfPresent(String.self, forKey: .reminderID)
        scheduledAt = try container.decodeIfPresent(Date.self, forKey: .scheduledAt)
        categoryOverride = try container.decodeIfPresent(BriefCategory.self, forKey: .categoryOverride)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

struct BriefingArchiveState: Codable {
    var marks: [String: BriefingMark] = [:]
    /// 사람이 "이건 규칙으로 만들지 않겠다"고 말한 제안들.
    ///
    /// 없으면 같은 제안이 매일 다시 뜬다. 제안은 도움이 되는 동안에만 제안이고, 거절한
    /// 뒤에도 계속 나오면 그때부터는 화면을 가리는 것일 뿐이다.
    var dismissedRuleSuggestions: Set<String> = []

    var completedIDs: Set<String> { Set(marks.filter(\.value.isDone).map(\.key)) }

    /// 사람이 직접 옮긴 분류. 이월할 때는 모델이 매긴 분류가 아니라 이쪽을 봐야 한다 —
    /// `기타`로 내린 항목이 다음 날 다시 `오늘 꼭 할 일`에 서면, 옮긴 것이 아무 뜻도
    /// 없었던 것이 된다.
    var categoryOverrides: [String: BriefCategory] { marks.compactMapValues(\.categoryOverride) }

    /// Briefings themselves are pruned at thirty days; their marks are kept
    /// longer and by count instead, because a mark is two hundred bytes and
    /// losing one silently resurrects a finished task.
    static let retainedMarks = 2_000

    static func pruned(_ marks: [String: BriefingMark], keeping limit: Int = retainedMarks) -> [String: BriefingMark] {
        let live = marks.filter { !$0.value.isBlank }
        guard live.count > limit else { return live }
        let kept = live.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(limit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    init(marks: [String: BriefingMark] = [:], dismissedRuleSuggestions: Set<String> = []) {
        self.marks = marks
        self.dismissedRuleSuggestions = dismissedRuleSuggestions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        marks = try container.decodeIfPresent([String: BriefingMark].self, forKey: .marks) ?? [:]
        dismissedRuleSuggestions = try container.decodeIfPresent(Set<String>.self, forKey: .dismissedRuleSuggestions) ?? []
    }
}

/// Separate from `state.json` on purpose. That file is a checkpoint the pipeline
/// rewrites on every run and prunes to thirty days; this one is the user's own
/// record and must not be lost when a run rewrites the checkpoint. It holds no
/// message bodies — only identifiers, a flag, and whatever note was typed.
struct BriefingArchiveStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "briefing-archive.json")
    }

    var debugPath: String { url.path }

    func load() -> BriefingArchiveState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(BriefingArchiveState.self, from: data) else { return BriefingArchiveState() }
        return state
    }

    func save(_ state: BriefingArchiveState) throws {
        var stored = state
        stored.marks = BriefingArchiveState.pruned(state.marks)
        try LocalFileStorage.write(try JSONEncoder().encode(stored), to: url)
    }

    /// 표를 건드리지 않고 거절 목록만 고친다. 보관함 모델이 표의 사본을 들고 있으므로,
    /// 통째로 덮어쓰면 그 사이에 눌린 체크 하나가 사라질 수 있다.
    func dismissSuggestion(_ id: String) throws {
        var state = load()
        state.dismissedRuleSuggestions.insert(id)
        try LocalFileStorage.write(try JSONEncoder().encode(state), to: url)
    }
}

/// The 브리핑 보관함 screen's brain: the days the pipeline has produced, the
/// reader's marks on them, and the two things the reader can do with an item —
/// tick it off, or put it on the calendar.
///
/// Briefings themselves still live in `state.json`, which the pipeline already
/// writes, prunes to thirty days and strips message bodies from. Copying them
/// into a second file would mean two things to keep in step; this reads that
/// one and joins it to the marks by `trackingID`.
@MainActor
final class BriefingArchiveModel: ObservableObject {

    enum Bucket: String, CaseIterable, Identifiable {
        case action = "오늘 꼭 할 일"
        case reference = "확인해야 할 것"
        case other = "기타"

        var id: String { rawValue }

        /// The pipeline's category this heading stands for. Reclassifying an item
        /// from the screen moves it between these, so the two vocabularies have to
        /// be joined in exactly one place.
        var category: BriefCategory {
            switch self {
            case .action: .action
            case .reference: .reference
            case .other: .excluded
            }
        }

        init(_ category: BriefCategory) {
            switch category {
            case .action: self = .action
            case .reference: self = .reference
            case .excluded: self = .other
            }
        }

        var symbol: String {
            switch self {
            case .action: "checkmark.circle"
            case .reference: "eye"
            case .other: "tray"
            }
        }

        /// What a row offers to do with an item filed here, in the order the two
        /// buttons should read. One step at a time in either direction, which is
        /// how the reader asked for promotions and demotions to work.
        var neighbours: [Bucket] {
            switch self {
            case .action: [.reference]
            case .reference: [.action, .other]
            case .other: [.reference]
            }
        }

        var moveVerb: String {
            switch self {
            case .action: "오늘 꼭 할 일로 올리기"
            case .reference: "확인해야 할 것으로 옮기기"
            case .other: "기타로 내리기"
            }
        }

        var emptyText: String {
            switch self {
            case .action: "이 날 처리할 일이 없습니다."
            case .reference: "확인할 항목이 없습니다."
            case .other: "제외된 항목이 없습니다."
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let item: ClassifiedItem
        let dateKey: String
        var mark: BriefingMark

        var id: String { item.trackingID }

        /// Where this item actually sits: what the reader decided if they
        /// decided anything, otherwise what the pipeline concluded.
        var category: BriefCategory { mark.categoryOverride ?? item.category }
        var bucket: Bucket { Bucket(category) }
        /// True only when the reader moved it somewhere the model did not put it,
        /// so the row can say so instead of quietly disagreeing with the report.
        var isReclassified: Bool {
            guard let override = mark.categoryOverride else { return false }
            return override != item.category
        }

        var title: String { BriefPresentation.title(for: item) }
        var summary: String { BriefPresentation.summary(for: item) }
        var deadlineText: String? { BriefPresentation.deadlineText(item.deadline) }
        var source: String { item.sourceItem.source }
        var author: String { item.sourceItem.author.trimmingCharacters(in: .whitespacesAndNewlines) }
        var link: URL { item.sourceItem.link }
        var receivedAt: Date { item.sourceItem.timestamp }

        /// Written out in Korean rather than through `Date.formatted`, which
        /// follows the Mac's region and put "Aug 13, 2026 at 7:15 PM" two lines
        /// above a 마감 the app had already rendered as "8월 14일 19시 15분".
        var receivedText: String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.timeZone = KoreanDeadline.timeZone
            formatter.dateFormat = "M월 d일 HH:mm"
            return formatter.string(from: receivedAt)
        }

        var nextAction: String? {
            BriefPresentation.usable(item.displayNextAction, limit: 200)
                ?? item.nextAction.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        /// The message as it arrived, as far as the archive keeps it: a cleaned
        /// excerpt of the first 800 characters, stored with the classification.
        ///
        /// The screen used to show only the model's own summary, which meant an
        /// email whose summary missed the point could not be checked without
        /// leaving for Gmail — the exact trip this archive exists to avoid.
        var bodyText: String {
            (item.bodyExcerpt ?? item.sourceItem.body).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        static let bodyPreviewLength = 220

        var hasLongBody: Bool { bodyText.count > Self.bodyPreviewLength }

        var bodyPreview: String {
            guard hasLongBody else { return bodyText }
            return String(bodyText.prefix(Self.bodyPreviewLength)).trimmingCharacters(in: .whitespaces) + "…"
        }

        /// The whole item as plain text, for 복사.
        ///
        /// SwiftUI can only carry a selection inside one `Text`, so no amount of
        /// dragging across a row will ever produce this; a copy command has to.
        var plainText: String {
            var lines = [title, "\(source) · \(author.isEmpty ? "발신자 미상" : author) · \(receivedText)"]
            if let deadlineText { lines.append("마감 \(deadlineText)") }
            lines.append("")
            lines.append(summary)
            if let nextAction { lines.append("요청: \(nextAction)") }
            if !bodyText.isEmpty { lines += ["", bodyText] }
            if !mark.note.isEmpty { lines += ["", "메모: \(mark.note)"] }
            lines += ["", link.absoluteString]
            return lines.joined(separator: "\n")
        }

        /// What the app already put on the calendar for this item, if anything.
        var placement: CalendarPlacement? {
            if let identifier = mark.calendarEventID {
                return CalendarPlacement(identifier: identifier, date: mark.scheduledAt ?? receivedAt, isReminder: false)
            }
            if let identifier = mark.reminderID {
                return CalendarPlacement(identifier: identifier, date: mark.scheduledAt ?? receivedAt, isReminder: true)
            }
            return nil
        }

        /// The deadline read as a date, when there is one worth trusting.
        func suggestedDate(now: Date = Date()) -> KoreanDeadline.Parsed? {
            KoreanDeadline.parse(item.deadline, now: now)
        }

        /// Past its deadline, not merely due today. Worth separating: a list
        /// headed 오늘 that silently includes a deadline from two weeks ago reads
        /// as a bug rather than as a warning.
        func isOverdue(now: Date = Date()) -> Bool {
            guard let expiry = BriefPresentation.deadlineExpiry(item.deadline) else { return false }
            return expiry <= now
        }
    }

    /// 달력의 한 칸에 놓이는 일 하나.
    ///
    /// 같은 항목이 두 가지 이유로 날짜를 가질 수 있다. 본문에 적힌 **마감**과, 사람이
    /// 캘린더·미리 알림으로 넘기며 확인한 **일정**이다. 둘은 같은 날일 수도 다른 날일 수도
    /// 있어서 하나로 뭉뚱그리면 달력이 거짓말을 한다 — "금요일까지"인 과제를 수요일에
    /// 하겠다고 정해 둔 것은 서로 다른 두 사실이다.
    struct DatedEntry: Identifiable, Equatable {
        enum Kind: String {
            /// 항목에 적힌 마감을 날짜로 읽은 것.
            case deadline
            /// 사람이 캘린더나 미리 알림으로 넘기면서 고른 시각.
            case scheduled

            var title: String { self == .deadline ? "마감" : "일정" }
            var symbol: String { self == .deadline ? "flag.checkered" : "calendar.badge.checkmark" }
        }

        let entry: Entry
        let kind: Kind
        let date: Date
        /// 시각까지 읽혔는가. 아니면 그날 하루를 뜻하고, 화면은 시간을 적지 않는다.
        let includesTime: Bool

        var id: String { "\(entry.id)|\(kind.rawValue)" }
        var isDone: Bool { entry.mark.isDone }

        /// 지난 마감인가. 끝낸 것은 지난 것이 아니다 — 지났다고 표시하는 것은 아직
        /// 해야 하는 일에만 뜻이 있다.
        func isLate(now: Date = Date()) -> Bool {
            guard kind == .deadline, !isDone else { return false }
            return date < now
        }

        /// 화면이 이 항목을 두고 재촉해도 되는가.
        ///
        /// 지났다는 사실만으로는 부족하다. **사람이 `기타`로 내린 것은 모델이 급하다고
        /// 본 것보다 앞선다** — 이미 "이 일은 나와 상관없다"고 말한 항목을 지났다고 붉게
        /// 세우면, 매일 같은 것을 다시 내리라고 조르는 화면이 된다. 이월과 보관함이
        /// 따르는 것과 같은 순서다.
        func nags(now: Date = Date()) -> Bool {
            entry.bucket != .other && isLate(now: now)
        }

        var timeText: String? {
            guard includesTime else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.timeZone = KoreanDeadline.timeZone
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        }
    }

    @Published private(set) var days: [DailyBriefing] = []
    @Published var selectedDateKey: String = ""
    @Published var search = ""
    @Published var hidesDone = false
    @Published var expanded: Set<String> = []
    @Published var status = ""
    @Published var error: String?
    @Published var isExporting = false
    /// One at a time: re-analysis loads the model, and two rows racing would
    /// mean two copies of it in memory for no benefit.
    @Published private(set) var isReanalyzing = false
    /// Non-nil while the confirm-the-date sheet is up.
    @Published var scheduling: Entry?
    /// Which of the two destinations the sheet opens on, so "미리 알림으로
    /// 보내기…" does not land on a sheet set to 캘린더 일정.
    @Published var schedulingPrefersReminder = false

    private let stateStore: StateStore
    private let archiveStore: BriefingArchiveStore
    /// Read once, and applied to stored briefings as they are shown rather than
    /// when they were written. That is what lets a change to the reader's own
    /// rules re-file yesterday's items without asking the model to read the
    /// inbox again — and it is already how `BriefingQualityGate` behaved.
    private var preferences: BriefingPreferences
    /// Non-nil only in tests, which must not depend on the settings file that
    /// happens to be on the machine running them.
    private let injectedPreferences: BriefingPreferences?
    private let writer = CalendarWriter()
    private var marks: [String: BriefingMark] = [:]
    /// 규칙으로 만들지 않겠다고 거절한 제안들. `persist()`가 표만 쓰고 이것을 빠뜨리면
    /// 체크 한 번에 거절이 통째로 지워지므로 모델이 함께 들고 있는다.
    private var dismissedSuggestions: Set<String> = []
    /// Bumped whenever the days or the marks change. Both caches below key on it.
    private var revision = 0
    private var visibleCache: (key: String, entries: [Entry])?
    private var dueCache: (key: String, groups: (due: [Entry], overdue: [Entry]))?
    private var datedCache: (key: String, entries: [DatedEntry])?
    private var correctionsCache: (key: Int, corrections: [ClassificationCorrection])?

    /// Both stores are injectable so a test can point them at a temporary
    /// directory. Without that, running the suite would read — and the write
    /// tests would overwrite — the real briefings in Application Support.
    init(
        stateStore: StateStore = StateStore(),
        archiveStore: BriefingArchiveStore = BriefingArchiveStore(),
        preferences: BriefingPreferences? = nil
    ) {
        self.stateStore = stateStore
        self.archiveStore = archiveStore
        self.injectedPreferences = preferences
        self.preferences = preferences ?? BriefingPreferencesStore().load()
        reload()
    }

    // MARK: - 읽기

    func reload() {
        revision &+= 1
        // Re-read on every refresh so editing 분류 기준 in 설정 re-files what is
        // already on screen, without another run of the model.
        if injectedPreferences == nil { preferences = BriefingPreferencesStore().load() }
        let state = stateStore.load()
        days = state.dailyBriefings.values.sorted { sortKey($0) > sortKey($1) }
        let archived = archiveStore.load()
        marks = archived.marks
        dismissedSuggestions = archived.dismissedRuleSuggestions
        if days.first(where: { $0.dateKey == selectedDateKey }) == nil {
            selectedDateKey = days.first?.dateKey ?? ""
        }
        dropOrphanedMarks()
    }

    /// Marks whose item is gone.
    ///
    /// Briefings are pruned by day; marks were pruned only by count, so a mark
    /// outlived the item it belonged to and the file grew with every retired
    /// briefing while the reader could no longer see any of it. Only marks older
    /// than the oldest surviving day are dropped, so a tick made on an item that
    /// is merely absent from today's run is never mistaken for an orphan.
    private func dropOrphanedMarks() {
        guard let oldest = days.compactMap({ Self.date(fromKey: $0.dateKey) }).min() else { return }
        let alive = Set(days.flatMap { $0.items.map(\.trackingID) })
        let kept = marks.filter { alive.contains($0.key) || $0.value.updatedAt >= oldest }
        guard kept.count != marks.count else { return }
        marks = kept
        persist()
    }

    private func sortKey(_ briefing: DailyBriefing) -> Date {
        BriefingArchiveModel.date(fromKey: briefing.dateKey) ?? briefing.updatedAt
    }

    /// `dateKey` is "yy/MM/dd" in Seoul, which sorts correctly as a string but
    /// reads badly, so the screen shows a real date built back out of it.
    static func date(fromKey key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = KoreanDeadline.timeZone
        formatter.dateFormat = "yy/MM/dd"
        return formatter.date(from: key)
    }

    static func dayTitle(_ key: String) -> String {
        guard let date = date(fromKey: key) else { return key }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = KoreanDeadline.timeZone
        formatter.dateFormat = "M월 d일 (E)"
        return formatter.string(from: date)
    }

    var selectedDay: DailyBriefing? { days.first { $0.dateKey == selectedDateKey } }

    /// Whether what is on screen is old enough to warn about. Measured from when
    /// the briefing was produced, not from the calendar day it was filed under,
    /// so re-running an old day's briefing today clears the warning honestly.
    func isStale(_ day: DailyBriefing, now: Date = Date()) -> Bool {
        daysSince(day, now: now) >= BriefingHealth.staleAfterDays
    }

    func stalenessSummary(_ day: DailyBriefing, now: Date = Date()) -> String {
        let days = daysSince(day, now: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = KoreanDeadline.timeZone
        formatter.dateFormat = "M월 d일 HH:mm"
        return "\(days)일 전에 정리한 브리핑입니다 · \(formatter.string(from: day.updatedAt))"
    }

    private func daysSince(_ day: DailyBriefing, now: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = KoreanDeadline.timeZone
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: day.updatedAt), to: calendar.startOfDay(for: now)).day ?? 0
    }

    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var selectedIndex: Int? { days.firstIndex { $0.dateKey == selectedDateKey } }

    func step(_ offset: Int) {
        guard let index = selectedIndex else { return }
        let next = index + offset
        guard days.indices.contains(next) else { return }
        selectedDateKey = days[next].dateKey
        expanded.removeAll()
    }

    var canStepBack: Bool { selectedIndex.map { $0 + 1 < days.count } ?? false }
    var canStepForward: Bool { (selectedIndex ?? 0) > 0 }

    /// Everything on show, before bucketing. Searching widens the scope to every
    /// retained day, because "그때 그 메일이 언제였더라" is the whole reason to
    /// keep more than one day around.
    ///
    /// Memoised. SwiftUI evaluates `body` far more often than the data changes,
    /// and this walks every retained day through `BriefingQualityGate` — thirty
    /// days of a hundred items each, several times per redraw, is work the screen
    /// cannot afford to repeat for a result that has not changed.
    private var visible: [Entry] {
        let key = "\(revision)|\(selectedDateKey)|\(search)"
        if let cached = visibleCache, cached.key == key { return cached.entries }
        let computed = computeVisible()
        visibleCache = (key, computed)
        return computed
    }

    private func computeVisible() -> [Entry] {
        let scope = isSearching ? days : days.filter { $0.dateKey == selectedDateKey }
        var seen = Set<String>()
        var entries: [Entry] = []
        for day in scope {
            for item in BriefingQualityGate.normalized(day.items, preferences: preferences) where seen.insert(item.trackingID).inserted {
                entries.append(Entry(item: item, dateKey: day.dateKey, mark: marks[item.trackingID] ?? BriefingMark()))
            }
        }
        guard isSearching else { return entries }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            "\(entry.title) \(entry.summary) \(entry.author) \(entry.source) \(entry.mark.note)".lowercased().contains(needle)
        }
    }

    func entries(_ bucket: Bucket) -> [Entry] {
        let matching = visible.filter { $0.bucket == bucket }
        let shown = hidesDone ? matching.filter { !$0.mark.isDone } : matching
        // Finished items sink; among the rest the most important comes first, and
        // ties break on when the thing arrived.
        return shown.sorted { lhs, rhs in
            if lhs.mark.isDone != rhs.mark.isDone { return !lhs.mark.isDone }
            // 지난 마감은 끝낸 것 바로 위로 가라앉는다. 중요도만으로 세우면 3주 전에
            // 지나간 일이 오늘 해야 하는 일보다 위에 서고, 그 자리는 그때부터 읽히지 않는다.
            let leftLate = lhs.isOverdue(), rightLate = rhs.isOverdue()
            if leftLate != rightLate { return !leftLate }
            if lhs.item.importance != rhs.item.importance { return lhs.item.importance > rhs.item.importance }
            return lhs.receivedAt > rhs.receivedAt
        }
    }

    /// Which headings the reader has asked to see in full.
    @Published var expandedBuckets: Set<Bucket> = []

    /// How many rows a heading shows before it stops.
    ///
    /// `TODO 최대 개수` / `확인 항목 최대 개수` in 설정 used to reach only the Notion
    /// export. Once the briefing moved into the app, the one screen that reads it
    /// every morning ignored both settings, which is how a day with twelve action
    /// items and eighteen reference items got presented as a briefing. 기타 is a
    /// counted tray and keeps its own fixed ceiling.
    func limit(for bucket: Bucket) -> Int? {
        // A search is an explicit request for everything that matches, so it is
        // the one case where a cap would be wrong.
        guard !isSearching, !expandedBuckets.contains(bucket) else { return nil }
        switch bucket {
        case .action: return AppConfig.briefingMaxActions
        case .reference: return AppConfig.briefingMaxReferences
        case .other: return Self.otherBucketLimit
        }
    }

    static let otherBucketLimit = 5

    /// The rows actually drawn under a heading, and how many were held back.
    func shown(_ bucket: Bucket) -> (entries: [Entry], hidden: Int) {
        let all = entries(bucket)
        guard let limit = limit(for: bucket), all.count > limit else { return (all, 0) }
        return (Array(all.prefix(limit)), all.count - limit)
    }

    func toggleBucketExpansion(_ bucket: Bucket) {
        if expandedBuckets.contains(bucket) { expandedBuckets.remove(bucket) } else { expandedBuckets.insert(bucket) }
    }

    /// Counted over everything in the bucket, never over the capped view: the
    /// number in the day bar answers "how much is left", not "how much fits".
    var openActionCount: Int { entries(.action).filter { !$0.mark.isDone }.count }

    /// Everything on screen as plain text, in the order it is shown.
    ///
    /// The reader's way of taking a whole morning's briefing somewhere else —
    /// a message to a lab mate, a note in their own notebook — without the app
    /// having to know about that destination. Notion export writes the same
    /// content through a service; this writes it to the clipboard.
    func plainText() -> String {
        var lines = [Self.dayTitle(selectedDateKey) + " 브리핑"]
        if isSearching { lines.append("검색: \(search)") }
        for bucket in Bucket.allCases {
            let items = entries(bucket)
            guard !items.isEmpty else { continue }
            lines += ["", "## \(bucket.rawValue) (\(items.count))"]
            for entry in items {
                lines.append("")
                lines.append("\(entry.mark.isDone ? "[x]" : "[ ]") \(entry.plainText)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// What the 개요 screen shows, in two separate lists.
    ///
    /// It used to be one list under a heading that said 오늘, with no lower
    /// bound on the deadline, so a mail whose deadline passed a fortnight ago
    /// sat there forever labelled "지남 ·" and there was no day on which the box
    /// emptied. A deadline from two weeks ago is real and worth showing, but it
    /// is not today's work and it must not crowd today's work out: they are now
    /// two headings with two ceilings.
    static let dueTodayLimit = 6
    static let overdueLimit = 4

    /// Open action items whose deadline falls inside today.
    func dueToday(now: Date = Date()) -> [Entry] { deadlineGroups(now: now).due }

    /// Open action items whose deadline has already passed, newest miss first.
    func overdue(now: Date = Date()) -> [Entry] { deadlineGroups(now: now).overdue }

    private func deadlineGroups(now: Date) -> (due: [Entry], overdue: [Entry]) {
        var dayCalendar = Calendar(identifier: .gregorian)
        dayCalendar.timeZone = KoreanDeadline.timeZone
        // Keyed by the day, not the instant: 개요 asks this on every redraw, but
        // the answer only changes when the data changes or the date rolls over.
        let key = "\(revision)|\(dayCalendar.startOfDay(for: now).timeIntervalSince1970)"
        if let cached = dueCache, cached.key == key { return cached.groups }
        let computed = computeDeadlineGroups(now: now)
        dueCache = (key, computed)
        return computed
    }

    private func computeDeadlineGroups(now: Date) -> (due: [Entry], overdue: [Entry]) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = KoreanDeadline.timeZone
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return ([], []) }
        var seen = Set<String>()
        var due: [Entry] = []
        var late: [Entry] = []
        for day in days {
            // The same normalisation the archive shows through. Without it 개요
            // could chase the reader about an item that 보관함 has already filed
            // under 확인해야 할 것, and the two screens would disagree about the
            // same mail. Walking every day is affordable because the result is
            // cached per revision and per calendar day.
            for item in BriefingQualityGate.normalized(day.items, preferences: preferences)
            where seen.insert(item.trackingID).inserted {
                let mark = marks[item.trackingID] ?? BriefingMark()
                // The reader's own filing wins here too: an item they pushed down
                // to 기타 has stopped being something 개요 should chase them about.
                guard (mark.categoryOverride ?? item.category) == .action, !mark.isDone,
                      let parsed = KoreanDeadline.parse(item.deadline, now: now), parsed.date < endOfDay else { continue }
                let entry = Entry(item: item, dateKey: day.dateKey, mark: mark)
                if entry.isOverdue(now: now) && parsed.date < startOfDay { late.append(entry) } else { due.append(entry) }
            }
        }
        let byImportance: (Entry, Entry) -> Bool = { $0.item.importance > $1.item.importance }
        // Most recently missed first: a deadline from yesterday is still worth
        // rescuing, one from a month ago is history.
        return (due.sorted(by: byImportance), late.sorted { lhs, rhs in
            let leftDate = KoreanDeadline.parse(lhs.item.deadline, now: now)?.date ?? .distantPast
            let rightDate = KoreanDeadline.parse(rhs.item.deadline, now: now)?.date ?? .distantPast
            return leftDate > rightDate
        })
    }

    // MARK: - 분류 교정 학습

    /// 설정의 분류 기준을 고쳤을 때 알린다. 컨트롤러가 화면에 들고 있는 사본을 다시 읽어야
    /// 하기 때문이다 — 그러지 않으면 설정 창에서 다음에 `저장`을 누르는 순간, 방금 규칙으로
    /// 굳힌 한 줄이 낡은 사본에 덮여 사라진다.
    var didChangePreferences: (() -> Void)?

    /// 사람이 옮긴 분류들, 최근 것부터. 화면과 프롬프트가 같은 것을 본다.
    ///
    /// `visible`·`dueToday`와 같은 이유로 기억해 둔다. 이 계산은 보관된 90일을 전부
    /// 훑는데, SwiftUI는 자료가 바뀌지 않아도 `body`를 몇 번이고 다시 부른다 — 검색창에
    /// 한 글자 칠 때마다 만 건을 다시 훑는 것은 화면이 감당할 일이 아니다.
    var corrections: [ClassificationCorrection] {
        if let cached = correctionsCache, cached.key == revision { return cached.corrections }
        let computed = ClassificationLearning.corrections(days: days, marks: marks)
        correctionsCache = (revision, computed)
        return computed
    }

    /// 규칙으로 굳히자고 제안할 것들. 거절한 것은 빠져 있다.
    var ruleSuggestions: [RuleSuggestion] {
        ClassificationLearning.suggestions(from: corrections, dismissed: dismissedSuggestions)
    }

    /// 제안을 받아 분류 기준 목록에 한 줄 넣는다.
    ///
    /// 넣은 뒤에는 같은 제안이 다시 뜨지 않게 거절 목록에도 넣는다. 규칙이 이미 있는데
    /// 제안이 남아 있으면, 누른 것이 아무 일도 하지 않은 것처럼 보인다.
    func applyRuleSuggestion(_ suggestion: RuleSuggestion) {
        let store = BriefingPreferencesStore()
        var preferences = store.load()
        switch suggestion.destination {
        case .ignored:
            guard !preferences.ignoredPatterns.contains(where: { $0.caseInsensitiveCompare(suggestion.pattern) == .orderedSame }) else { break }
            preferences.ignoredPatterns.append(suggestion.pattern)
        case .important:
            guard !preferences.importantPatterns.contains(where: { $0.caseInsensitiveCompare(suggestion.pattern) == .orderedSame }) else { break }
            preferences.importantPatterns.append(suggestion.pattern)
        }
        do {
            try store.save(preferences)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        dismissRuleSuggestion(suggestion, quietly: true)
        // 새 규칙은 이미 쌓인 브리핑에도 곧바로 적용된다. `reload`가 분류 기준을 다시
        // 읽으므로, 모델을 한 번 더 돌리지 않고도 화면이 새 규칙대로 다시 그려진다.
        reload()
        didChangePreferences?()
        status = "‘\(suggestion.pattern)’을 \(suggestion.destination.title) 규칙에 넣었습니다. 설정 › 분류 기준에서 지울 수 있습니다."
    }

    func dismissRuleSuggestion(_ suggestion: RuleSuggestion, quietly: Bool = false) {
        objectWillChange.send()
        dismissedSuggestions.insert(suggestion.id)
        do {
            try archiveStore.dismissSuggestion(suggestion.id)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        if !quietly { status = "이 제안을 다시 띄우지 않습니다. 분류 기준은 그대로입니다." }
    }

    // MARK: - 달력

    /// 보관함이 들고 있는 모든 날의 항목 가운데 **날짜가 읽히는 것들**, 이른 것부터.
    ///
    /// 보관함의 `visible`과 달리 고른 날짜와 검색에 매이지 않는다. 달력은 하루가 아니라
    /// 한 달을 보는 화면이고, 어제 온 메일의 다음 주 마감은 어제를 펼쳐 보지 않아도
    /// 보여야 하기 때문이다.
    ///
    /// `dueToday`와 같은 방식으로 기억해 둔다. 이 계산은 보관된 모든 날을 훑고,
    /// SwiftUI는 자료가 바뀌지 않아도 `body`를 몇 번이고 다시 부른다.
    func datedEntries(now: Date = Date()) -> [DatedEntry] {
        let key = "\(revision)|\(KoreanDeadline.calendar.startOfDay(for: now).timeIntervalSince1970)"
        if let cached = datedCache, cached.key == key { return cached.entries }
        let computed = computeDatedEntries(now: now)
        datedCache = (key, computed)
        return computed
    }

    /// 날짜(그날 0시)별로 묶은 것. 달력 칸 하나가 곧 이 사전의 열쇠 하나다.
    ///
    /// 하루 안의 차례는 **끝낸 것을 맨 아래로** 내린다. 달력 칸에는 두 줄만 들어가는데,
    /// 이미 끝낸 일이 그 두 자리를 차지하면 아직 해야 하는 일은 `+3`이라는 숫자 뒤로
    /// 숨는다 — 달력을 여는 이유가 정확히 그 두 줄이므로, 거기에 끝난 일이 서면 안 된다.
    func datedEntriesByDay(now: Date = Date()) -> [Date: [DatedEntry]] {
        Dictionary(grouping: datedEntries(now: now)) { KoreanDeadline.calendar.startOfDay(for: $0.date) }
            .mapValues { group in
                group.sorted { lhs, rhs in
                    if lhs.isDone != rhs.isDone { return !lhs.isDone }
                    return lhs.date < rhs.date
                }
            }
    }

    private func computeDatedEntries(now: Date) -> [DatedEntry] {
        let calendar = KoreanDeadline.calendar
        var seen = Set<String>()
        var deadlines: [DatedEntry] = []
        var scheduled: [DatedEntry] = []
        for day in days {
            // 보관함이 보여 주는 것과 같은 정규화를 거친다. 이것을 건너뛰면 달력과
            // 보관함이 같은 메일에 대해 서로 다른 말을 하게 된다.
            for item in BriefingQualityGate.normalized(day.items, preferences: preferences)
            where seen.insert(item.trackingID).inserted {
                let mark = marks[item.trackingID] ?? BriefingMark()
                let entry = Entry(item: item, dateKey: day.dateKey, mark: mark)
                // 사람이 넘긴 일정. `scheduledAt`만으로는 부족하다 — 시트를 열어 날짜를
                // 고르다 취소해도 값이 남을 수 있으므로, 실제로 캘린더나 미리 알림에
                // 들어간 것만 일정으로 친다.
                if entry.placement != nil, let at = mark.scheduledAt {
                    scheduled.append(DatedEntry(entry: entry, kind: .scheduled, date: at, includesTime: true))
                }
                if let parsed = KoreanDeadline.parse(item.deadline, now: now) {
                    deadlines.append(DatedEntry(entry: entry, kind: .deadline, date: parsed.date, includesTime: parsed.includesTime))
                }
            }
        }
        // 같은 항목의 마감과 일정이 **같은 날**이면 일정 하나만 남긴다. 사람이 확인해
        // 넣은 시각이 본문에서 읽어 낸 것보다 정확하고, 한 칸에 같은 제목이 두 줄로
        // 서면 달력은 그만큼 읽기 어려워진다.
        let scheduledDays = Set(scheduled.map { "\($0.entry.id)|\(calendar.startOfDay(for: $0.date).timeIntervalSince1970)" })
        let kept = deadlines.filter { !scheduledDays.contains("\($0.entry.id)|\(calendar.startOfDay(for: $0.date).timeIntervalSince1970)") }
        return (kept + scheduled).sorted { $0.date < $1.date }
    }

    /// 마감이 적혀 있는데 날짜로 읽히지 않은 항목들.
    ///
    /// 달력이 이것을 조용히 빠뜨리면 사람은 달력에 없는 것을 없는 일로 읽는다. "가급적
    /// 빠른 시일 내"처럼 날짜가 아닌 말이 대부분이라 없앨 수 있는 것이 아니고, 그래서
    /// 세어서 화면에 적는다.
    func undatedDeadlineEntries(now: Date = Date()) -> [Entry] {
        var seen = Set<String>()
        var result: [Entry] = []
        for day in days {
            for item in BriefingQualityGate.normalized(day.items, preferences: preferences)
            where seen.insert(item.trackingID).inserted {
                guard !item.deadline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      KoreanDeadline.parse(item.deadline, now: now) == nil else { continue }
                let mark = marks[item.trackingID] ?? BriefingMark()
                guard mark.scheduledAt == nil, !mark.isDone else { continue }
                result.append(Entry(item: item, dateKey: day.dateKey, mark: mark))
            }
        }
        return result.sorted { $0.receivedAt > $1.receivedAt }
    }

    /// 달력에서 고른 날을 보관함에서 열 수 있게, 그 항목이 실려 온 날로 옮긴다.
    ///
    /// 달력의 날짜(마감)와 보관함의 날짜(브리핑이 만들어진 날)는 다른 값이다. 이것이
    /// 없으면 달력에서 다음 주 마감을 눌렀을 때 보관함은 다음 주를 펼치려 하고, 그런
    /// 날의 브리핑은 아직 없다.
    func revealInArchive(_ dated: DatedEntry) {
        selectedDateKey = dated.entry.dateKey
        search = ""
        expanded.insert(dated.entry.id)
    }

    // MARK: - 분류 교정

    /// Move one item to another heading.
    ///
    /// The reader had no way to do this at all: five misfiled items last week had
    /// to be corrected by editing the classifier's instructions in 설정 and
    /// waiting for the next run. This is the direct route, and because it is
    /// stored as a mark rather than written into the briefing, tomorrow's run
    /// cannot quietly undo it.
    func move(_ entry: Entry, to bucket: Bucket) {
        let target = bucket.category
        mutate(entry.id) { mark in
            // Agreeing with the model is not an override; recording it as one
            // would mean a later prompt change could never move the item again.
            mark.categoryOverride = target == entry.item.category ? nil : target
        }
        status = target == entry.item.category
            ? "모델 분류로 되돌렸습니다."
            : "\(bucket.rawValue)(으)로 옮겼습니다. 다음 실행에도 유지됩니다."
    }

    func clearCategoryOverride(_ entry: Entry) {
        mutate(entry.id) { $0.categoryOverride = nil }
        status = "모델 분류로 되돌렸습니다."
    }

    /// Send one stored item back through the local model.
    ///
    /// A batch that ran past the generation ceiling used to close as valid JSON
    /// with empty fields, so the item reached the archive titled "Gmail 확인: …"
    /// with "원문을 확인해 주세요." for a summary — and stayed that way forever,
    /// because nothing short of deleting the state file would make the pipeline
    /// look at it again. The evidence it runs on is the stored excerpt: the full
    /// body is deliberately not kept, and re-reading Gmail for one row would mean
    /// the archive quietly reaching back out to the network.
    func reanalyze(_ entry: Entry) async {
        guard !isReanalyzing else { return }
        let excerpt = entry.bodyText
        guard !excerpt.isEmpty else {
            error = "이 항목은 저장된 본문이 없어 다시 분석할 수 없습니다. 원문을 열어 확인해 주세요."
            return
        }
        isReanalyzing = true
        status = "이 항목을 다시 분석하고 있습니다…"
        defer { isReanalyzing = false }
        let original = entry.item.sourceItem
        let rebuilt = SourceItem(
            id: original.id, source: original.source, account: original.account, author: original.author,
            timestamp: original.timestamp, subject: original.subject, body: excerpt, link: original.link,
            stableID: original.stableID, audience: original.audience
        )
        do {
            let classifier = LocalClassifier()
            // 다시 분석할 때도 교정 예시를 같이 보낸다. 그러지 않으면 이 한 번만 다른
            // 프롬프트로 돌아, 브리핑 전체와 다른 기준으로 판단한 결과가 섞인다.
            let answered = try await classifier.classify(
                [rebuilt],
                userInstructions: preferences.userInstructions,
                corrections: ClassificationLearning.promptBlock(from: corrections) ?? ""
            )
            await classifier.unload()
            guard var replacement = BriefingQualityGate.normalized(answered, preferences: preferences).first else {
                error = "모델이 이 항목에 대한 결과를 돌려주지 않았습니다."
                return
            }
            replacement.contentFingerprint = entry.item.contentFingerprint
            replacement.bodyExcerpt = entry.item.bodyExcerpt
            try store(replacement, on: entry.dateKey)
            reload()
            status = "다시 분석했습니다."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Writes one re-analysed item back into the day it belongs to. Everything
    /// else in the checkpoint is left exactly as it was.
    private func store(_ item: ClassifiedItem, on dateKey: String) throws {
        var state = stateStore.load()
        guard var day = state.dailyBriefings[dateKey],
              let index = day.items.firstIndex(where: { $0.trackingID == item.trackingID }) else { return }
        day.items[index] = item
        day.updatedAt = Date()
        state.dailyBriefings[dateKey] = day
        try stateStore.save(state)
    }

    // MARK: - 표시

    func isExpanded(_ entry: Entry) -> Bool { expanded.contains(entry.id) }

    func toggleExpanded(_ entry: Entry) {
        if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
    }

    // MARK: - 쓰기

    /// `marks` is deliberately not `@Published` — it is a dictionary the whole
    /// screen reads through `entries(_:)`, so the announcement belongs to the
    /// change, not to the storage.
    private func mutate(_ id: String, _ change: (inout BriefingMark) -> Void) {
        objectWillChange.send()
        var mark = marks[id] ?? BriefingMark()
        change(&mark)
        mark.updatedAt = Date()
        marks[id] = mark
        revision &+= 1
        persist()
    }

    private func persist() {
        do {
            try archiveStore.save(BriefingArchiveState(marks: marks, dismissedRuleSuggestions: dismissedSuggestions))
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func toggleDone(_ entry: Entry) {
        mutate(entry.id) { mark in
            mark.isDone.toggle()
            mark.completedAt = mark.isDone ? Date() : nil
        }
    }

    func setNote(_ note: String, for entry: Entry) {
        guard (marks[entry.id]?.note ?? "") != note else { return }
        mutate(entry.id) { $0.note = note }
    }

    func note(for entry: Entry) -> String { marks[entry.id]?.note ?? "" }

    func mark(for id: String) -> BriefingMark { marks[id] ?? BriefingMark() }

    // MARK: - 캘린더

    /// One press when the deadline is unambiguous; otherwise the sheet, because
    /// a guessed date written straight into someone's calendar is worse than
    /// one extra confirmation.
    func schedule(_ entry: Entry, asReminder: Bool = false) async {
        guard let parsed = entry.suggestedDate(), parsed.isConfident else {
            ask(entry, asReminder: asReminder)
            return
        }
        await place(entry, at: parsed.date, includesTime: parsed.includesTime, asReminder: asReminder)
    }

    func ask(_ entry: Entry, asReminder: Bool) {
        schedulingPrefersReminder = asReminder
        scheduling = entry
    }

    func place(_ entry: Entry, at date: Date, includesTime: Bool, asReminder: Bool) async {
        error = nil
        do {
            if asReminder {
                if CalendarWriter.reminderAccess() != .fullAccess { try await CalendarWriter.requestReminderAccess() }
            } else {
                if CalendarWriter.eventAccess() != .fullAccess { try await CalendarWriter.requestEventAccess() }
            }
            let notes = calendarNotes(for: entry)
            let placement = asReminder
                ? try writer.addReminder(title: entry.title, notes: notes, url: entry.link, due: date, includesTime: includesTime)
                : try writer.addEvent(title: entry.title, notes: notes, url: entry.link, at: date, includesTime: includesTime)
            mutate(entry.id) { mark in
                if asReminder { mark.reminderID = placement.identifier } else { mark.calendarEventID = placement.identifier }
                mark.scheduledAt = placement.date
            }
            let when = includesTime
                ? placement.date.formatted(date: .abbreviated, time: .shortened)
                : placement.date.formatted(date: .abbreviated, time: .omitted)
            status = "\(AgentCalendar.title) \(asReminder ? "목록" : "캘린더")에 \(when)로 추가했습니다."
            scheduling = nil
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func unschedule(_ entry: Entry) {
        guard let placement = entry.placement else { return }
        do {
            try writer.remove(placement)
            mutate(entry.id) { mark in
                mark.calendarEventID = nil
                mark.reminderID = nil
                mark.scheduledAt = nil
            }
            status = "캘린더에서 지웠습니다."
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// A recorded entry the user has since deleted in Calendar.app should stop
    /// claiming to exist, or the archive quietly refuses to add it back.
    func reconcilePlacements() {
        var changed = false
        var placements: [String: CalendarPlacement] = [:]
        for (id, mark) in marks {
            guard mark.isPlaced else { continue }
            let placement = CalendarPlacement(
                identifier: mark.calendarEventID ?? mark.reminderID ?? "",
                date: mark.scheduledAt ?? Date(),
                isReminder: mark.calendarEventID == nil
            )
            placements[id] = placement
        }
        // One store for the whole sweep, and nothing at all when permission is
        // gone — otherwise every lookup would come back empty and this would
        // quietly forget every calendar entry the user had made.
        let gone = writer.missing(Array(placements.values))
        guard !gone.isEmpty else { return }
        objectWillChange.send()
        for (id, placement) in placements where gone.contains(placement.identifier) {
            marks[id]?.calendarEventID = nil
            marks[id]?.reminderID = nil
            marks[id]?.scheduledAt = nil
            changed = true
        }
        if changed {
            revision &+= 1
            persist()
        }
    }

    private func calendarNotes(for entry: Entry) -> String {
        var lines = [entry.summary]
        if let action = entry.nextAction { lines.append("할 일: \(action)") }
        if let deadline = entry.deadlineText { lines.append("마감: \(deadline)") }
        lines.append("출처: \(entry.source) · \(entry.author)")
        lines.append(entry.link.absoluteString)
        return lines.joined(separator: "\n")
    }

    // MARK: - 내보내기

    /// Notion is opt-in now. Nothing is sent anywhere until this is pressed, and
    /// only the day on screen goes.
    func exportToNotion() async {
        guard let briefing = selectedDay else { return }
        isExporting = true
        error = nil
        defer { isExporting = false }
        do {
            let url = try await BriefingService().exportToNotion(briefing)
            status = "Notion에 내보냈습니다."
            reload()
            NSWorkspace.shared.open(url)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    var notionURL: URL? { selectedDay?.notionURL }
}
