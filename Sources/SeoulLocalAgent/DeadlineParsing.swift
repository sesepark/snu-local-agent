import Foundation

/// Turns the deadline string a briefing item carries into an actual date, so it
/// can become a calendar event without the reader retyping it.
///
/// The model is asked for ISO-8601 and usually gives it, but it also passes
/// through whatever the original message said — "9월 15일까지", "내일 오후 6시",
/// "다음 주 금요일" — and those are the ones worth reading, because they are the
/// ones a person would otherwise have to transcribe by hand.
///
/// Written as explicit patterns rather than left to `NSDataDetector` alone: the
/// detector is a black box whose Korean handling changes between OS releases,
/// and a wrong date silently written into someone's calendar is worse than no
/// date at all. The detector is still consulted last, for the shapes the
/// patterns do not cover.
enum KoreanDeadline {
    struct Parsed: Equatable {
        let date: Date
        /// False when only a day was named, so a calendar entry should be all-day
        /// or take a sensible default hour rather than pretending to know one.
        let includesTime: Bool
        /// False when the text only hinted — a bare time with no day, or a shape
        /// the detector guessed at. The UI confirms these with a date picker
        /// instead of writing them straight to the calendar.
        let isConfident: Bool
    }

    static let timeZone = TimeZone(identifier: "Asia/Seoul") ?? .current

    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        return value
    }

    /// Phrases that name urgency rather than a date. Guessing a day for these
    /// would put a fabricated deadline on the calendar.
    private static let vague = ["가급적", "빠른", "빨리", "조속", "수시", "상시", "미정", "추후", "별도 공지", "없음"]

    static func parse(_ raw: String, now: Date = Date()) -> Parsed? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // The machine-readable shapes the classifier is asked for come first and
        // are always trusted.
        if let iso = BriefPresentation.parseDeadline(trimmed) {
            return Parsed(date: iso.date, includesTime: iso.includesTime, isConfident: true)
        }

        let text = normalized(trimmed)
        if vague.contains(where: { text.contains($0) }), day(in: text, now: now) == nil { return nil }

        let clock = time(in: text)
        if let day = day(in: text, now: now) {
            return Parsed(date: combine(day: day, clock: clock), includesTime: clock != nil, isConfident: true)
        }
        if let clock {
            // A time with no day means today, which is a guess worth confirming.
            let today = calendar.startOfDay(for: now)
            return Parsed(date: combine(day: today, clock: clock), includesTime: true, isConfident: false)
        }
        if let detected = detector(trimmed) { return detected }
        return nil
    }

    /// Collapses the spellings that only differ typographically, so one pattern
    /// matches "9 월 15 일", "9월15일" and "9월 15일" alike.
    private static func normalized(_ value: String) -> String {
        var text = value.replacingOccurrences(of: "\u{00A0}", with: " ")
        for (from, to) in ["금일": "오늘", "명일": "내일", "익일": "내일", "내일모레": "모레", "다음주": "다음 주", "이번주": "이번 주", "담주": "다음 주"] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text.replacingOccurrences(of: " ", with: "")
    }

    // MARK: - 날짜

    private static func day(in text: String, now: Date) -> Date? {
        let today = calendar.startOfDay(for: now)
        for (word, offset) in [("오늘", 0), ("내일", 1), ("모레", 2), ("글피", 3)] where text.contains(word) {
            return calendar.date(byAdding: .day, value: offset, to: today)
        }
        if let match = firstMatch(#"(\d{1,2})(일|주)(뒤|후|이내|내)"#, in: text),
           let count = Int(match[1]) {
            return calendar.date(byAdding: .day, value: match[2] == "주" ? count * 7 : count, to: today)
        }
        if let absolute = absoluteDay(in: text, today: today) { return absolute }
        if let weekday = weekday(in: text, today: today) { return weekday }
        return nil
    }

    private static func absoluteDay(in text: String, today: Date) -> Date? {
        var year: Int?
        if let match = firstMatch(#"(\d{4})년"#, in: text) { year = Int(match[1]) }

        var month: Int?
        var dayOfMonth: Int?
        if let match = firstMatch(#"(\d{1,2})월(\d{1,2})일"#, in: text) {
            month = Int(match[1])
            dayOfMonth = Int(match[2])
        } else if let match = firstMatch(#"(\d{1,2})[/.](\d{1,2})(?![\d/.])"#, in: text) {
            month = Int(match[1])
            dayOfMonth = Int(match[2])
        } else if let match = firstMatch(#"(?<![\d:])(\d{1,2})일"#, in: text) {
            // A bare "15일" means the fifteenth of whichever month is meant, so
            // the month is deliberately left unset: that is what tells the roll
            // below to move by a month rather than by a year.
            dayOfMonth = Int(match[1])
        } else if let match = firstMatch(#"(\d{1,2})월말"#, in: text), let value = Int(match[1]) {
            // "9월말" is a real deadline shape in notices; the last day of the
            // month is the only reading of it that is not a guess.
            guard let start = date(year: year, month: value, day: 1, notBefore: today),
                  let range = calendar.range(of: .day, in: .month, for: start) else { return nil }
            return calendar.date(byAdding: .day, value: range.count - 1, to: start)
        }

        guard let dayOfMonth, (1...31).contains(dayOfMonth) else { return nil }
        guard month == nil || (1...12).contains(month!) else { return nil }
        return date(year: year, month: month, day: dayOfMonth, notBefore: today)
    }

    /// Builds the date, rolling forward when no year was given. A deadline is
    /// something still ahead, so "1월 5일" read in December means next January —
    /// but a date only a few days past is left alone, because that is a genuinely
    /// missed deadline the report should still show as missed.
    private static func date(year: Int?, month: Int?, day: Int, notBefore reference: Date) -> Date? {
        var components = DateComponents()
        components.year = year ?? calendar.component(.year, from: reference)
        components.month = month ?? calendar.component(.month, from: reference)
        components.day = day
        guard let candidate = calendar.date(from: components) else { return nil }
        guard year == nil, candidate < calendar.date(byAdding: .day, value: -7, to: reference)! else { return candidate }
        let unit: Calendar.Component = month == nil ? .month : .year
        return calendar.date(byAdding: unit, value: 1, to: candidate)
    }

    private static let weekdayNames = ["일": 1, "월": 2, "화": 3, "수": 4, "목": 5, "금": 6, "토": 7]

    private static func weekday(in text: String, today: Date) -> Date? {
        guard let match = firstMatch(#"(다음주|이번주|다음|이번)?([일월화수목금토])요일"#, in: text),
              let target = weekdayNames[match[2]] else { return nil }
        let current = calendar.component(.weekday, from: today)
        // Counted forward from today rather than from the start of a calendar
        // week: "금요일까지" said on a Saturday means the coming Friday, which is
        // what anybody means, and no week-numbering convention has to be right.
        var offset = (target - current + 7) % 7
        if match[1] == "다음주" || match[1] == "다음" { offset += 7 }
        return calendar.date(byAdding: .day, value: offset, to: today)
    }

    // MARK: - 시각

    private struct Clock { var hour: Int; var minute: Int }

    private static func time(in text: String) -> Clock? {
        if text.contains("자정") { return Clock(hour: 0, minute: 0) }
        if text.contains("정오") { return Clock(hour: 12, minute: 0) }
        let afternoon = text.contains("오후") || text.contains("저녁") || text.contains("밤")
        if let match = firstMatch(#"(\d{1,2})시(?:(\d{1,2})분)?"#, in: text), let hour = Int(match[1]), hour <= 24 {
            return Clock(hour: adjust(hour, afternoon: afternoon), minute: Int(match[2]) ?? 0)
        }
        if let match = firstMatch(#"(\d{1,2}):(\d{2})"#, in: text),
           let hour = Int(match[1]), let minute = Int(match[2]), hour <= 24, minute < 60 {
            return Clock(hour: adjust(hour, afternoon: afternoon), minute: minute)
        }
        return nil
    }

    private static func adjust(_ hour: Int, afternoon: Bool) -> Int {
        guard afternoon, hour < 12 else { return min(hour, 23) }
        return hour + 12
    }

    private static func combine(day: Date, clock: Clock?) -> Date {
        guard let clock else { return day }
        return calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: day) ?? day
    }

    // MARK: - 마지막 수단

    /// Whatever the patterns above missed, in whichever language it was written.
    /// Never trusted: the result always goes through a picker first.
    private static func detector(_ text: String) -> Parsed? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let date = match.date else { return nil }
        // The detector reports no time by leaving the date at midnight, so that
        // is the only signal available for whether an hour was actually written.
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hasTime = (components.hour ?? 0) != 0 || (components.minute ?? 0) != 0
        return Parsed(date: date, includesTime: hasTime, isConfident: false)
    }

    // MARK: - 정규식

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}
