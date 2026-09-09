import Foundation
import CryptoKit

/// Identifies the evidence a classification was based on, so an item that shows up
/// again unchanged can reuse the previous result instead of being sent to the model.
enum SourceFingerprint {
    static func of(_ item: SourceItem) -> String {
        of(subject: item.subject, body: item.body, timestamp: item.timestamp)
    }

    static func of(subject: String, body: String, timestamp: Date) -> String {
        let material = "\(subject)\u{1}\(body)\u{1}\(Int(timestamp.timeIntervalSince1970))"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

/// Keeps connector transport wrappers out of both the model prompt and the
/// Notion page. It does not interpret a message; it only removes known Gog
/// framing and collapses layout whitespace.
enum InboxTextSanitizer {
    static func clean(_ value: String) -> String {
        var text = value.precomposedStringWithCanonicalMapping
        text = text.replacingOccurrences(
            of: "<<<EXTERNAL_UNTRUSTED_CONTENT[^>]*>>>",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "<<<END_EXTERNAL_UNTRUSTED_CONTENT[^>]*>>>",
            with: "",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "(?im)^\\s*Source:\\s*google_api\\s*-*\\s*",
            with: "",
            options: .regularExpression
        )
        // Attachment placeholders (U+FFFC) arrive from Messages and Mail and carry
        // no meaning for the classifier.
        text = text.replacingOccurrences(of: "\u{FFFC}", with: " ")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200))
    }
}

enum InboxEvidenceGate {
    private static let transportOnly: Set<String> = ["google_api", "slack_api", "unknown", "(텍스트 없는 메시지)"]

    static func canonicalBody(body: String, snippet: String, subject: String) -> String {
        let candidates = [body, snippet, subject].map(InboxTextSanitizer.clean)
        for candidate in candidates where isUsable(candidate) { return candidate }
        return ""
    }

    static func isUsable(_ text: String) -> Bool {
        let clean = InboxTextSanitizer.clean(text)
        guard clean.count >= 4 else { return false }
        return !transportOnly.contains(clean.lowercased())
    }
}

/// Group only clearly repeated operational notifications. This deliberately
/// avoids fuzzy semantic merging: an uncertain item stays separate rather than
/// hiding a real request.
enum IncidentGrouper {
    static func group(_ items: [SourceItem]) -> [SourceItem] {
        let buckets = Dictionary(grouping: items, by: incidentKey)
        return buckets.values.compactMap { group in
            guard let first = group.sorted(by: { $0.timestamp > $1.timestamp }).first else { return nil }
            guard group.count > 1 else { return first }
            let links = group.map(\.link).prefix(4).map(\.absoluteString).joined(separator: " | ")
            let combinedBody = "동일 유형 알림 \(group.count)건으로 묶음. 최근 원문: \(first.body) 관련 링크: \(links)"
            return SourceItem(
                id: first.id,
                source: first.source,
                account: first.account,
                author: first.author,
                timestamp: first.timestamp,
                subject: first.subject,
                body: String(combinedBody.prefix(1_200)),
                link: first.link,
                // Losing this would break next-day carry-forward for grouped items.
                stableID: first.stableID
            )
        }
        .sorted(by: { $0.timestamp > $1.timestamp })
    }

    private static func incidentKey(_ item: SourceItem) -> String {
        let raw = "\(item.author) \(item.subject)".lowercased()
        let family: String?
        if raw.contains("payment") || raw.contains("billing") || raw.contains("결제") { family = "payment" }
        else if raw.contains("deployment") || raw.contains("deploy") || raw.contains("배포") { family = "deployment" }
        else if raw.contains("build failed") || raw.contains("빌드 실패") { family = "build-failed" }
        else { family = nil }
        guard let family else { return "unique:\(item.id)" }
        // Values such as a retry count, dollar amount, or date must not split
        // one otherwise identical operational incident into many entries.
        let sender = raw.replacingOccurrences(of: "[^a-z가-힣]", with: "", options: .regularExpression)
        return "\(item.source)|\(sender.prefix(48))|\(family)"
    }
}

enum BriefPresentation {
    static func title(for item: ClassifiedItem) -> String {
        if let value = usable(item.displayTitle, limit: 90) { return presentationText(value) }
        let source = item.sourceItem.source
        let subject = InboxTextSanitizer.clean(item.sourceItem.subject)
        let compact = subject.isEmpty ? "새 항목" : String(subject.prefix(52))
        return "\(source) 확인: \(compact)"
    }

    /// The exact text written into a Notion to_do, and therefore the text the
    /// next day's carry-forward reads back.
    static func todoTitle(for item: ClassifiedItem) -> String {
        let title = title(for: item)
        guard let deadline = deadlineText(item.deadline) else { return title }
        return "\(title) · 마감 \(deadline)"
    }

    struct ParsedDeadline {
        let date: Date
        let includesTime: Bool
    }

    private static let seoul = TimeZone(identifier: "Asia/Seoul") ?? .current

    static func parseDeadline(_ raw: String) -> ParsedDeadline? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for options in [ISO8601DateFormatter.Options([.withInternetDateTime, .withFractionalSeconds]),
                        ISO8601DateFormatter.Options([.withInternetDateTime])] {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = options
            if let date = parser.date(from: trimmed) { return ParsedDeadline(date: date, includesTime: true) }
        }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = seoul
        dateOnly.dateFormat = "yyyy-MM-dd"
        if let date = dateOnly.date(from: trimmed) { return ParsedDeadline(date: date, includesTime: false) }
        return nil
    }

    /// The instant after which a deadline is genuinely past. A date without a time
    /// stays valid until the end of that day in Seoul, so a same-day deadline is not
    /// dropped by a morning run.
    static func deadlineExpiry(_ raw: String) -> Date? {
        guard let parsed = parseDeadline(raw) else { return nil }
        guard !parsed.includesTime else { return parsed.date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = seoul
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: parsed.date))
    }

    /// The model answers with ISO-8601. Printing that verbatim gave readers
    /// "마감 2026-09-09T18:00:00Z"; this renders it as a Seoul wall-clock time.
    static func deadlineText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let parsed = parseDeadline(trimmed) else {
            // Anything the model wrote in another shape is shown as-is rather than dropped.
            return String(trimmed.prefix(40))
        }
        let display = DateFormatter()
        display.locale = Locale(identifier: "ko_KR")
        display.timeZone = seoul
        display.dateFormat = parsed.includesTime ? "M월 d일 HH시 mm분" : "M월 d일"
        return display.string(from: parsed.date)
    }

    static func summary(for item: ClassifiedItem) -> String {
        if let value = usable(item.displaySummary, limit: 700) { return presentationText(value) }
        let value = InboxTextSanitizer.clean(item.summary)
        return value.isEmpty ? "원문을 확인해 주세요." : value
    }

    /// A soft quality gate: reject only transport leakage or unusable UI text.
    /// It never retries the model; the deterministic Korean-labelled fallback
    /// above keeps a briefing writable even for an imperfect model response.
    static func usable(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let text = InboxTextSanitizer.clean(value)
        guard !text.isEmpty, text.count <= limit,
              !text.contains("<<<"), !text.contains("http://"), !text.contains("https://"),
              !text.contains("\n"), !text.contains("- [") else { return nil }
        return text
    }

    private static func presentationText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "^(?:[-*]\\s*)?(?:\\[.?\\]\\s*)?(?:\\*{1,2})?", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\*{1,2}$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The reader's own standing judgements, applied after the model has spoken.
///
/// The model is told all of this in the prompt and mostly follows it, but it is
/// a 3B-active local model reading sixty messages a morning, and the same few
/// kinds of item came back misfiled every run: a terms-of-service amendment
/// filed next to a real request, a scholarship the reader could actually apply
/// for buried among things to merely read, a hobby project's deploy failure
/// sitting at the top of 오늘 꼭 할 일.
///
/// These are the cases where the right answer does not need reading
/// comprehension, only recognition, so a deterministic rule beats another round
/// of prompt wording. Each one moves an item by exactly one step and adjusts
/// importance by one, never more: the point is to correct a systematic tilt, not
/// to overrule a judgement the model made from evidence this cannot see.
enum ReaderPriorityRules {
    enum Direction: Equatable { case up, down }

    struct Adjustment: Equatable {
        let direction: Direction
        let reason: String
        /// Set only where the promotion implies something concrete to do, since
        /// an item in 오늘 꼭 할 일 whose next action reads "원문 확인" is not a task.
        var nextAction: String?
    }

    // Boilerplate every service sends when its lawyers change a document. It is
    // worth a line in the record and nothing more, unless the reader has to do
    // something to keep or refuse the change.
    private static let policyWords = ["이용약관", "이용 약관", "약관 개정", "약관 변경", "약관이 변경", "개인정보 처리방침", "개인정보처리방침", "terms of service", "terms of use", "privacy policy", "policy update"]
    // Only phrasings that require something. "동의하지 않으면 해지할 수 있습니다" is
    // the standard escape clause in every one of these notices, so reading 해지
    // or 탈퇴 as a duty would exempt nearly all of them from the rule.
    private static let policyDuties = ["회신", "재동의", "동의 절차", "서명", "제출해", "본인 확인이 필요", "정지될 수", "제한될 수", "action required", "must accept"]

    // A context word and a failure word rather than whole phrases: these mails
    // arrive as "Run failed: Deploy production" as often as in Korean, and a
    // fixed phrase list missed every English one.
    private static let buildWords = ["배포", "빌드", "파이프라인", "워크플로우", "deploy", "build", "pipeline", "workflow"]
    private static let failureWords = ["실패", "failed", "failure"]
    // Somebody asking the reader to fix it is a request, not a robot's report.
    private static let requestWords = ["부탁", "해주세요", "해 주세요", "요청드립니다", "확인 바랍니다", "please fix", "can you"]
    private static let outageWords = ["서비스 중단", "서비스가 중단", "장애", "데이터 손실", "downtime", "outage", "결제 실패", "payment failed", "이용이 정지"]

    private static let scholarshipWords = ["장학금", "장학생", "장학"]
    private static let applyWords = ["신청", "접수", "지원 자격", "모집"]
    private static let resultWords = ["선정 결과", "선발 결과", "지급 완료", "선정자 발표"]

    private static let participationWords = ["신청", "등록", "접수", "참가", "사전등록", "registration", "register", "rsvp"]

    static func adjustment(for item: ClassifiedItem, preferences: BriefingPreferences = .defaults) -> Adjustment? {
        // An explicit user pattern already said what this item is. Nothing here
        // is allowed to argue with that.
        guard item.pinnedByUserRule != true else { return nil }
        // The display text is included because it is often the only Korean
        // rendering of an English notification, and the rules read both.
        let text = """
        \(item.sourceItem.subject) \(item.sourceItem.body) \(item.facts ?? "") \(item.summary) \
        \(item.displayTitle ?? "") \(item.displaySummary ?? "")
        """.lowercased()

        if contains(policyWords, text), !contains(policyDuties, text) {
            return Adjustment(direction: .down, reason: "약관·방침 개정 안내이고 직접 해야 할 일이 없어 한 단계 내렸습니다")
        }
        if contains(buildWords, text), contains(failureWords, text),
           !contains(outageWords, text), !contains(requestWords, text) {
            return Adjustment(direction: .down, reason: "개인 프로젝트의 배포·빌드 실패 알림이고 서비스 중단이 적혀 있지 않아 한 단계 내렸습니다")
        }
        if contains(scholarshipWords, text), contains(applyWords, text), !contains(resultWords, text) {
            return Adjustment(
                direction: .up,
                reason: "직접 신청할 수 있는 장학 안내라 한 단계 올렸습니다",
                nextAction: "신청 자격과 마감을 확인하고 신청 여부를 정하세요."
            )
        }
        if BriefingPreferenceRules.matches(preferences.interestPatterns, in: text), contains(participationWords, text) {
            return Adjustment(
                direction: .up,
                reason: "관심 분야 행사이고 참가 신청이 열려 있어 한 단계 올렸습니다",
                nextAction: "참가 신청 마감을 확인하고 등록 여부를 정하세요."
            )
        }
        return nil
    }

    static func applying(_ adjustment: Adjustment?, to item: ClassifiedItem) -> ClassifiedItem {
        guard let adjustment, let category = moved(item.category, adjustment.direction) else { return item }
        let up = adjustment.direction == .up
        let importance = category == .excluded ? 1 : min(5, max(1, item.importance + (up ? 1 : -1)))
        let action = up ? (concrete(item.displayNextAction ?? item.nextAction) ?? adjustment.nextAction ?? item.nextAction) : ""
        return ClassifiedItem(
            sourceItem: item.sourceItem, facts: item.facts, category: category, summary: item.summary,
            reason: "\(adjustment.reason): \(item.reason)", importance: importance,
            nextAction: action, deadline: item.deadline,
            displayTitle: item.displayTitle, displaySummary: item.displaySummary,
            displayNextAction: up ? action : nil, confidence: item.confidence,
            pinnedByUserRule: item.pinnedByUserRule, contentFingerprint: item.contentFingerprint,
            bodyExcerpt: item.bodyExcerpt
        )
    }

    /// One step, and only within the three buckets: `excluded` cannot sink
    /// further and `action` cannot rise.
    private static func moved(_ category: BriefCategory, _ direction: Direction) -> BriefCategory? {
        switch (category, direction) {
        case (.excluded, .up): .reference
        case (.reference, .up): .action
        case (.action, .down): .reference
        case (.reference, .down): .excluded
        default: nil
        }
    }

    private static let vagueActions = ["원문 확인", "확인", "확인 필요", "확인만 필요", "내용 확인", "참고"]

    private static func concrete(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !vagueActions.contains(text) else { return nil }
        return text
    }

    private static func contains(_ words: [String], _ text: String) -> Bool {
        words.contains { text.contains($0) }
    }
}

enum BriefingQualityGate {
    static func normalized(_ items: [ClassifiedItem], preferences: BriefingPreferences = .defaults) -> [ClassifiedItem] {
        items.map { item in
            var result = item
            if !InboxEvidenceGate.isUsable(item.sourceItem.body) {
                result.confidence = 0
                return result
            }
            let adjustment = ReaderPriorityRules.adjustment(for: result, preferences: preferences)
            // Demoting an item the reader's own rules are about to promote would
            // strip its next action on the way past and hand back something
            // labelled 할 일 that says "원문 확인".
            var demotedByGate = false
            if result.category == .action, result.pinnedByUserRule != true, adjustment?.direction != .up {
                let evidence = "\(result.sourceItem.subject) \(result.sourceItem.body) \(result.facts ?? "")".lowercased()
                let optionalOpportunity = ["모집", "포럼", "특강", "학술대회", "장학금", "사전등록", "registration", "forum"].contains { evidence.contains($0) }
                    && !["요청", "회신", "제출", "승인", "필수", "required", "must"].contains { evidence.contains($0) }
                if optionalOpportunity || (result.confidence ?? 1) < 0.55 {
                    demotedByGate = true
                    let carried = (result.contentFingerprint, result.bodyExcerpt)
                    result = ClassifiedItem(
                        sourceItem: result.sourceItem,
                        facts: result.facts,
                        category: .reference,
                        summary: result.summary,
                        reason: "직접 요청이 아닌 선택 가능한 정보이거나 행동 근거가 부족해 확인 항목으로 이동: \(result.reason)",
                        importance: min(result.importance, 3),
                        nextAction: "원문 확인",
                        deadline: result.deadline,
                        displayTitle: result.displayTitle,
                        displaySummary: result.displaySummary,
                        displayNextAction: "원문 확인",
                        confidence: min(result.confidence ?? 1, 0.5),
                        pinnedByUserRule: result.pinnedByUserRule
                    )
                    // Rebuilding an item by hand loses whatever field was added
                    // to it last: without this the demoted item is re-analysed
                    // every morning, and shows no 원문 in the archive.
                    (result.contentFingerprint, result.bodyExcerpt) = carried
                }
            }
            // One step in total. When the gate has already moved an item down,
            // a rule that agrees with it must not move it down again.
            return demotedByGate ? result : ReaderPriorityRules.applying(adjustment, to: result)
        }
    }
}

enum ClassifiedIncidentMerger {
    static func merge(_ items: [ClassifiedItem]) -> [ClassifiedItem] {
        let grouped = Dictionary(grouping: items, by: incidentKey)
        return grouped.values.compactMap { group in
            guard var representative = group.max(by: { lhs, rhs in
                if lhs.importance == rhs.importance { return lhs.sourceItem.timestamp < rhs.sourceItem.timestamp }
                return lhs.importance < rhs.importance
            }) else { return nil }
            guard group.count > 1 else { return representative }
            let facts = group.compactMap(\.facts).filter { !$0.isEmpty }
            representative.facts = String(facts.joined(separator: " ").prefix(600))
            representative.displaySummary = "관련 알림 \(group.count)건을 하나로 묶었습니다. \(BriefPresentation.summary(for: representative))"
            return representative
        }.sorted { lhs, rhs in
            if lhs.importance == rhs.importance { return lhs.sourceItem.timestamp > rhs.sourceItem.timestamp }
            return lhs.importance > rhs.importance
        }
    }

    private static func incidentKey(_ item: ClassifiedItem) -> String {
        let raw = "\(item.sourceItem.author) \(item.sourceItem.subject) \(item.facts ?? "")".lowercased()
        let family: String
        if raw.contains("payment") || raw.contains("결제") || raw.contains("invoice") { family = "billing" }
        else if raw.contains("deploy") || raw.contains("배포") || raw.contains("build failed") { family = "deployment" }
        else if raw.contains("refund") || raw.contains("환불") { family = "refund" }
        else if raw.contains("login") || raw.contains("로그인") || raw.contains("oauth") { family = "security" }
        else { return item.trackingID }
        let sender = item.sourceItem.author.lowercased().replacingOccurrences(of: "[^a-z0-9가-힣]", with: "", options: .regularExpression)
        return "\(item.sourceItem.source)|\(sender.prefix(40))|\(family)"
    }
}


/// Decides what an earlier day's briefing still owes today.
///
/// Two things survive into the next report: an action the user has not ticked off
/// in Notion and whose deadline has not passed, and a calendar entry for something
/// that has not happened yet. Everything else belongs to the day it was collected.
enum CarryForwardPolicy {
    struct Outcome {
        var carried: [ClassifiedItem] = []
        /// Unfinished, but past its stated deadline. Counted rather than carried.
        var expired: [ClassifiedItem] = []
        /// Unfinished, no deadline to expire, and old enough that carrying it
        /// again would be noise. Counted the same way.
        var stale: [ClassifiedItem] = []
    }

    /// 마감이 없는 할 일을 이만큼 지나면 더 이월하지 않는다.
    ///
    /// 마감이 **적힌** 항목은 그 날짜가 지나면 알아서 빠지지만, 마감이 없는 항목에는 빠질
    /// 날이 없어서 체크할 때까지 영원히 따라온다. 그렇게 쌓인 더미는 `오늘 꼭 할 일`이라는
    /// 이름을 못 쓰게 만든다 — 오늘 해야 하는 것과 3주 전에 지나간 것이 같은 자리에 서면,
    /// 사람은 그 자리를 아예 안 읽게 된다.
    ///
    /// 14일인 이유는 학사 일정의 리듬이다. 한 주를 넘겨 다음 주까지 밀린 일은 아직 살아
    /// 있을 수 있지만, 두 주를 넘도록 손대지 않은 요청은 이미 끝났거나 잊힌 것이다.
    /// 세어서 화면에 적으므로 조용히 사라지지는 않고, 보관함에서 그날을 펼치면 그대로 있다.
    static let staleAfterDays = 14

    /// `completedIDs` are the `trackingID`s the reader has ticked off in the
    /// 브리핑 보관함. Everything else that was an action yesterday is still an
    /// action today.
    ///
    /// This used to be driven by the set of *unchecked* to_do titles read back
    /// out of the Notion page, which meant two things went wrong quietly: an
    /// item whose generated title changed between runs lost its identity, and
    /// an item past the page's `briefingMaxActions` cut-off was never written
    /// as a to_do at all and so could never be carried. Keying on the tracking
    /// ID and inverting the test — carry unless explicitly finished — fixes
    /// both.
    /// - Parameter overrides: 사람이 보관함에서 직접 옮긴 분류. **모델의 분류보다 우선한다.**
    ///
    ///   이것을 읽지 않던 동안, `기타`로 내린 항목도 모델이 매긴 `action` 그대로 매일
    ///   이월되어 다음 날 `오늘 꼭 할 일`에 다시 섰다. 옮기기는 화면에만 남고 파이프라인은
    ///   그것을 본 적이 없었던 셈이라, 같은 항목을 며칠이고 다시 내려야 했다.
    static func evaluate(previousItems: [ClassifiedItem], completedIDs: Set<String>, overrides: [String: BriefCategory] = [:], now: Date) -> Outcome {
        var outcome = Outcome()
        for item in previousItems {
            let effective = overrides[item.trackingID] ?? item.category
            if isUpcomingCalendarEntry(item, now: now) {
                // 앞으로 있을 일정은 분류와 상관없이 이월하지만, 사람이 `기타`로 내린
                // 것은 예외다. 그것은 "이 일정은 나와 상관없다"는 분명한 말이다.
                if effective != .excluded { outcome.carried.append(item) }
                continue
            }
            guard effective == .action, !completedIDs.contains(item.trackingID) else { continue }
            if let expiry = BriefPresentation.deadlineExpiry(item.deadline) {
                if expiry <= now { outcome.expired.append(item) } else { outcome.carried.append(item) }
            } else if isStale(item, now: now) {
                // 마감이 없어서 만료될 날이 없는 항목. 여기서 끊지 않으면 무한히 쌓인다.
                outcome.stale.append(item)
            } else {
                outcome.carried.append(item)
            }
        }
        return outcome
    }

    /// 마감이 없는 채로 너무 오래된 항목인가. 나이는 **메일이 도착한 시각**으로 잰다 —
    /// 이월 횟수를 따로 세는 값이 없고, 도착 시각은 이미 항목에 실려 있어서 새 필드를
    /// 만들지 않고도 같은 것을 말해 준다.
    static func isStale(_ item: ClassifiedItem, now: Date) -> Bool {
        guard let cutoff = KoreanDeadline.calendar.date(byAdding: .day, value: -staleAfterDays, to: now) else { return false }
        return item.sourceItem.timestamp < cutoff
    }

    static func isUpcomingCalendarEntry(_ item: ClassifiedItem, now: Date) -> Bool {
        item.sourceItem.source == SourceName.calendar && item.sourceItem.timestamp > now
    }

    /// Items already covered by a carried-over result, with identical evidence, do
    /// not need to be classified again. This is what keeps an unchanged calendar
    /// entry from being re-summarised on every run.
    static func unchangedItems(in collected: [SourceItem], alreadyCarried carried: [ClassifiedItem]) -> Set<String> {
        var fingerprints: [String: String] = [:]
        for item in carried {
            guard let fingerprint = item.contentFingerprint else { continue }
            fingerprints[item.trackingID] = fingerprint
        }
        guard !fingerprints.isEmpty else { return [] }
        var unchanged = Set<String>()
        for item in collected {
            let key = item.stableID ?? item.id
            guard let fingerprint = fingerprints[key], fingerprint == SourceFingerprint.of(item) else { continue }
            unchanged.insert(item.id)
        }
        return unchanged
    }
}
