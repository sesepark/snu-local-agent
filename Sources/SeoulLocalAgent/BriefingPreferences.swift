import Foundation

/// The reader's own standing criteria for what matters.
///
/// Two things read this: the classifier, which is handed `userInstructions` as
/// data appended to its system prompt, and `ReaderPriorityRules`, which applies
/// the handful of judgements that do not depend on reading comprehension. Both
/// are visible and editable in 설정 › 분류 기준 — there is no hidden list of
/// important or ignored senders anywhere in the app.
struct BriefingPreferences: Codable, Equatable {
    /// Written in the first person because it is appended to the prompt as the
    /// reader's own words. `briefing-eval.py` reads this same block out of this
    /// file so the eval measures what the app actually sends.
    static let defaultInstructions = """
    나는 서울대학교 전기·정보공학부 학부생(25학번)이다.
    피지컬 AI와 로보틱스, 온디바이스 AI가 내 주 관심 분야다.
    교수·조교·학사 행정의 직접 요청과 이미 약속하거나 신청한 일은 중요하게 본다.
    장학금·장학생 안내는 내가 신청할 수 있고 신청 방법이나 기한이 적혀 있으면 할 일로 본다.
    관심 분야의 포럼·특강·학술대회·모집처럼 내가 참가할 수 있는 기회는 한 단계 올려 본다. 참가 신청이 열려 있으면 할 일, 정보뿐이면 확인 항목이다.
    관심 분야라도 회사 뉴스레터·제품 업데이트·홍보 메일은 기회가 아니므로 올리지 않고 기타로 제외한다.
    그 밖의 수강·연구·인턴·취업·강연·행사 공지는 직접 요청이 없다면 확인 항목으로 둔다.
    서비스 중단, 결제 실패, 데이터 손실, 보안 침해는 중요하게 본다.
    이용약관·개인정보 처리방침 개정 안내는 내가 해야 할 일이 적혀 있지 않으면 기타로 제외한다.
    내 개인 프로젝트의 배포·빌드 실패 알림은 확인 항목이다. 쓰던 서비스가 실제로 멈췄다고 적혀 있을 때만 할 일이다.
    일반 뉴스레터와 홍보 메일은 기타로 제외한다.
    """

    /// The fields whose announcements are worth one step more than the same
    /// announcement in any other field. Kept as patterns rather than left to the
    /// prompt alone because "관심 분야" means nothing to a model that cannot see
    /// which fields are meant, and because the promotion should be reproducible.
    static let defaultInterests = [
        "피지컬 ai", "physical ai", "embodied ai", "로보틱스", "robotics", "로봇",
        "휴머노이드", "humanoid", "자율주행", "온디바이스", "on-device", "임베디드 ai", "ai 반도체",
    ]

    var userInstructions: String = Self.defaultInstructions
    /// One case-insensitive substring per line. Matches sender, account,
    /// subject, or body. These lists are always visible and editable in UI.
    var ignoredPatterns: [String] = []
    var importantPatterns: [String] = []
    var interestPatterns: [String] = Self.defaultInterests

    static let defaults = BriefingPreferences()

    init(
        userInstructions: String = Self.defaultInstructions,
        ignoredPatterns: [String] = [],
        importantPatterns: [String] = [],
        interestPatterns: [String] = Self.defaultInterests
    ) {
        self.userInstructions = userInstructions
        self.ignoredPatterns = ignoredPatterns
        self.importantPatterns = importantPatterns
        self.interestPatterns = interestPatterns
    }

    /// Written by hand for the same reason `BriefingMark`'s is: the synthesised
    /// decoder throws on a missing key, so adding one field in a later version
    /// would make every existing settings file undecodable — and `load()` below
    /// answers an undecodable file with the defaults, silently discarding what
    /// the reader had typed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userInstructions = try container.decodeIfPresent(String.self, forKey: .userInstructions) ?? Self.defaultInstructions
        ignoredPatterns = try container.decodeIfPresent([String].self, forKey: .ignoredPatterns) ?? []
        importantPatterns = try container.decodeIfPresent([String].self, forKey: .importantPatterns) ?? []
        interestPatterns = try container.decodeIfPresent([String].self, forKey: .interestPatterns) ?? Self.defaultInterests
    }
}

struct BriefingPreferencesStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "briefing-preferences.json")
    }

    func load() -> BriefingPreferences {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(BriefingPreferences.self, from: data) else { return .defaults }
        return value
    }

    func save(_ preferences: BriefingPreferences) throws {
        try LocalFileStorage.write(try JSONEncoder().encode(preferences), to: url)
    }
}

enum BriefingPreferenceRules {
    static func partition(_ items: [SourceItem], preferences: BriefingPreferences) -> (included: [SourceItem], ignored: [SourceItem], importantIDs: Set<String>) {
        var included: [SourceItem] = []
        var ignored: [SourceItem] = []
        var importantIDs = Set<String>()
        for item in items {
            let haystack = "\(item.source) \(item.account) \(item.author) \(item.subject) \(item.body)".lowercased()
            let important = matches(preferences.importantPatterns, in: haystack)
            let ignore = matches(preferences.ignoredPatterns, in: haystack)
            if important {
                included.append(item)
                importantIDs.insert(item.id)
            } else if ignore {
                ignored.append(item)
            } else {
                included.append(item)
            }
        }
        return (included, ignored, importantIDs)
    }

    static func matches(_ patterns: [String], in haystack: String) -> Bool {
        patterns.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains { !$0.isEmpty && haystack.contains($0) }
    }
}

extension Array where Element == String {
    static func preferenceLines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
