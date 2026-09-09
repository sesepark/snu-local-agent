import EventKit
import Foundation

/// Where this app is allowed to write, and the promise it makes about it.
///
/// Everything the app creates goes into one calendar and one reminder list of
/// its own, both named 서울대 로컬 에이전트. Nothing is ever added to, edited in,
/// or removed from a calendar the user made. That keeps the blast radius of a
/// mistake to a single list the user can delete in one gesture, and it means an
/// entry's origin is obvious from where it sits.
enum AgentCalendar {
    static let title = "서울대 로컬 에이전트"

    /// A calendar this app owns. Used before every write, so a bug elsewhere
    /// cannot reach the user's own calendars.
    static func isOwned(_ calendar: EKCalendar) -> Bool {
        calendar.title == title && calendar.allowsContentModifications
    }
}

/// A created entry, as far as the archive needs to remember it.
struct CalendarPlacement: Equatable {
    let identifier: String
    let date: Date
    let isReminder: Bool
}

enum CalendarWriteError: LocalizedError {
    case noWritableSource(String)
    case notOurs

    var errorDescription: String? {
        switch self {
        case .noWritableSource(let kind):
            "\(kind)을(를) 만들 수 있는 계정을 찾지 못했습니다. 캘린더 앱에서 iCloud 또는 '내 Mac' 계정을 켠 뒤 다시 시도해 주세요."
        case .notOurs:
            "이 앱이 만들지 않은 항목은 건드리지 않습니다."
        }
    }
}

/// Creates and removes entries in the app's own calendar and reminder list.
///
/// `EKEventStore` is not `Sendable`, so every method makes its own and never
/// lets it escape. Stores are cheap next to the work they do here, and one
/// long-lived shared store would have to be pinned to an actor that every
/// caller then has to hop to.
struct CalendarWriter: Sendable {

    // MARK: - 권한

    static func eventAccess() -> EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static func reminderAccess() -> EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .reminder) }

    static func requestEventAccess() async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else {
            throw AgentError.processFailed("캘린더 권한이 허용되지 않았습니다. 시스템 설정 > 개인정보 보호 및 보안 > 캘린더에서 서울대 로컬 에이전트를 허용하세요.")
        }
    }

    static func requestReminderAccess() async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw AgentError.processFailed("미리 알림 권한이 허용되지 않았습니다. 시스템 설정 > 개인정보 보호 및 보안 > 미리 알림에서 서울대 로컬 에이전트를 허용하세요.")
        }
    }

    // MARK: - 쓰기

    /// An item with a time becomes an hour-long event at that time; an item with
    /// only a day becomes an all-day event, rather than one silently pinned to
    /// midnight where nobody looks.
    func addEvent(title: String, notes: String, url: URL?, at date: Date, includesTime: Bool, durationMinutes: Int = 60) throws -> CalendarPlacement {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.calendar = try container(for: .event, in: store)
        event.title = title
        event.notes = notes
        event.url = url
        event.isAllDay = !includesTime
        if includesTime {
            event.startDate = date
            event.endDate = date.addingTimeInterval(TimeInterval(durationMinutes * 60))
        } else {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = KoreanDeadline.timeZone
            let start = calendar.startOfDay(for: date)
            event.startDate = start
            event.endDate = start
        }
        try store.save(event, span: .thisEvent, commit: true)
        guard let identifier = event.eventIdentifier else {
            throw AgentError.processFailed("만든 일정의 식별자를 읽지 못했습니다.")
        }
        return CalendarPlacement(identifier: identifier, date: event.startDate, isReminder: false)
    }

    func addReminder(title: String, notes: String, url: URL?, due: Date?, includesTime: Bool) throws -> CalendarPlacement {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = try container(for: .reminder, in: store)
        reminder.title = title
        reminder.notes = notes
        reminder.url = url
        if let due {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = KoreanDeadline.timeZone
            let units: Set<Calendar.Component> = includesTime
                ? [.year, .month, .day, .hour, .minute]
                : [.year, .month, .day]
            reminder.dueDateComponents = calendar.dateComponents(units, from: due)
            // Without an alarm a dated reminder never speaks up, which is most of
            // the reason for putting it there.
            if includesTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        try store.save(reminder, commit: true)
        return CalendarPlacement(identifier: reminder.calendarItemIdentifier, date: due ?? Date(), isReminder: true)
    }

    /// Whether what we recorded is still there. A user who deleted the event in
    /// Calendar.app should see the archive offer to add it again, not claim it
    /// already exists.
    func exists(_ placement: CalendarPlacement) -> Bool {
        missing([placement]).isEmpty
    }

    /// The identifiers among these that no longer exist, checked through one
    /// store rather than one per item — the archive asks this about every placed
    /// item each time the screen appears, and a fresh `EKEventStore` per row is
    /// a real cost once there are a few dozen.
    ///
    /// Returns nothing when access has not been granted. That case is the reason
    /// this is written as "which are missing" rather than "which exist": without
    /// permission every lookup returns nil, and a caller that trusted it would
    /// erase every calendar link the user had made.
    func missing(_ placements: [CalendarPlacement]) -> Set<String> {
        guard !placements.isEmpty else { return [] }
        let store = EKEventStore()
        return PlacementReconciliation.lost(
            placements,
            hasEventAccess: Self.eventAccess() == .fullAccess,
            hasReminderAccess: Self.reminderAccess() == .fullAccess
        ) { placement in
            placement.isReminder
                ? store.calendarItem(withIdentifier: placement.identifier) != nil
                : store.event(withIdentifier: placement.identifier) != nil
        }
    }

    func remove(_ placement: CalendarPlacement) throws {
        let store = EKEventStore()
        if placement.isReminder {
            guard let reminder = store.calendarItem(withIdentifier: placement.identifier) as? EKReminder else { return }
            guard AgentCalendar.isOwned(reminder.calendar) else { throw CalendarWriteError.notOurs }
            try store.remove(reminder, commit: true)
        } else {
            guard let event = store.event(withIdentifier: placement.identifier) else { return }
            guard AgentCalendar.isOwned(event.calendar) else { throw CalendarWriteError.notOurs }
            try store.remove(event, span: .thisEvent, commit: true)
        }
    }

    // MARK: - 전용 캘린더

    /// Finds this app's calendar or list, creating it the first time.
    private func container(for entity: EKEntityType, in store: EKEventStore) throws -> EKCalendar {
        if let existing = store.calendars(for: entity).first(where: AgentCalendar.isOwned) { return existing }
        let calendar = EKCalendar(for: entity, eventStore: store)
        calendar.title = AgentCalendar.title
        calendar.cgColor = CGColor(red: 0.0, green: 0.29, blue: 0.55, alpha: 1)
        guard let source = source(for: entity, in: store) else {
            throw CalendarWriteError.noWritableSource(entity == .event ? "캘린더" : "미리 알림 목록")
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    /// The account the new calendar belongs to. The account the user's own
    /// default sits in is the right answer whenever it can hold a new calendar,
    /// because it is the one that syncs to their phone.
    private func source(for entity: EKEntityType, in store: EKEventStore) -> EKSource? {
        let usable: (EKSource) -> Bool = { $0.sourceType == .calDAV || $0.sourceType == .local || $0.sourceType == .exchange }
        let preferred = entity == .event ? store.defaultCalendarForNewEvents?.source : store.defaultCalendarForNewReminders()?.source
        if let preferred, usable(preferred) { return preferred }
        return store.sources.first { $0.sourceType == .calDAV && $0.title.lowercased() == "icloud" }
            ?? store.sources.first { $0.sourceType == .local }
            ?? store.sources.first(where: usable)
    }
}

/// When a recorded calendar link may be forgotten.
///
/// Split out from the EventKit call so the rule can be tested without a calendar
/// database: the dangerous case is not "the event is gone" but "we could not
/// look, and concluded it was gone". Revoking calendar permission makes every
/// lookup return nil, and the first version of this would have wiped every link
/// the user had made from the archive in one pass.
enum PlacementReconciliation {
    static func lost(
        _ placements: [CalendarPlacement],
        hasEventAccess: Bool,
        hasReminderAccess: Bool,
        found: (CalendarPlacement) -> Bool
    ) -> Set<String> {
        var gone = Set<String>()
        for placement in placements {
            let canLookUp = placement.isReminder ? hasReminderAccess : hasEventAccess
            guard canLookUp, !found(placement) else { continue }
            gone.insert(placement.identifier)
        }
        return gone
    }
}

/// Today's schedule, for the 개요 screen. Reading is already allowed wherever the
/// briefing reads the calendar, so this costs nothing extra.
struct CalendarGlance: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String

    var timeText: String {
        guard !isAllDay else { return "하루 종일" }
        return "\(start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}

extension CalendarSource {
    /// The rest of today, plus anything already under way. Events that finished
    /// before now are left out: the point is what is still ahead.
    func today(now: Date = Date()) -> [CalendarGlance] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = KoreanDeadline.timeZone
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.isAllDay || $0.endDate >= now }
            .sorted { ($0.isAllDay ? start : $0.startDate) < ($1.isAllDay ? start : $1.startDate) }
            .compactMap { event in
                guard let identifier = event.eventIdentifier else { return nil }
                return CalendarGlance(
                    id: identifier,
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "제목 없는 일정",
                    start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                    calendarTitle: event.calendar.title
                )
            }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
