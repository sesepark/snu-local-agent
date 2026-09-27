import Foundation

/// eTL이 지금 알고 있는 마감과 수업 일정을 통째로 적어 둔 것.
///
/// 일정 달력이 이것을 읽는다. 달력이 브리핑 이력만 보고 그려지면 세 가지가 어긋난다.
/// 아직 D-3에 걸리지 않아 브리핑에 뜬 적 없는 과제는 달력에 없고, 교수가 마감을 옮겨도 달력은
/// 브리핑에 찍힌 옛 날짜를 붙들고 있으며, 제출을 끝낸 과제도 손으로 체크하기 전까지 남아 있다.
/// 브리핑은 "무엇이 새로 생겼나"를 말하는 자리이므로 그 이력으로 현재 상태를 대신할 수 없다.
///
/// 그래서 수집이 끝날 때마다 이 파일을 통째로 다시 쓴다. 덧붙이지 않고 갈아 끼우는 이유는
/// eTL에서 사라진 과제가 달력에 남지 않게 하기 위해서다.
struct ETLDeadlineEntry: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case assignment
        case event
    }

    /// 브리핑 항목의 `stableID`와 같은 값을 쓴다. 같은 과제가 양쪽에 있을 때 하나로 합치려면
    /// 이름이 같아야 한다.
    var id: String
    var kind: Kind
    /// 어느 과목의 것인가. 한 과목을 읽지 못한 실행이 그 과목의 마감만 그대로 이어받으려면
    /// 이름이 아니라 번호로 짚어야 한다.
    var courseID: Int?
    var courseName: String
    var title: String
    var dueAt: Date?
    var lockAt: Date?
    var endAt: Date?
    var submittedAt: Date?
    var isMissing: Bool = false
    var isExcused: Bool = false
    var link: URL?
    var locationName: String?

    /// 달력에 찍힐 날. 과제는 마감, 일정은 시작 시각이다.
    var date: Date? { kind == .assignment ? dueAt : (dueAt ?? endAt) }

    /// 더 할 일이 없는가. 일정은 참석 여부를 eTL이 모르므로 언제나 열려 있는 것으로 둔다.
    var isSettled: Bool { kind == .assignment && (submittedAt != nil || isExcused) }
}

struct ETLDeadlineSnapshot: Codable, Sendable {
    var updatedAt: Date = .distantPast
    var entries: [ETLDeadlineEntry] = []

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SeoulLocalAgent/etl-deadlines.json")
    }

    /// 파일이 없거나 읽히지 않으면 빈 것으로 둔다. 달력은 eTL이 없어도 그려져야 한다.
    ///
    /// `ETLDigestStore`와 달리 손으로 쓴 디코더를 두지 않았다. 저쪽은 기억이라 한 번 버리면
    /// 기준선을 다시 잡느라 그 실행의 브리핑이 비지만, 이쪽은 수집마다 통째로 다시 쓰이는
    /// 사본이다. 필드가 늘어 옛 파일을 못 읽어도 다음 수집 한 번이면 제자리로 돌아온다.
    static func load(url: URL = ETLDeadlineSnapshot.url) -> Self {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? Self.decoder.decode(Self.self, from: data) else { return Self() }
        return snapshot
    }

    func save(url: URL = ETLDeadlineSnapshot.url) {
        guard let data = try? Self.encoder.encode(self) else { return }
        try? LocalFileStorage.write(data, to: url)
    }

    /// 날짜가 있는 것만, 이른 것부터.
    var dated: [ETLDeadlineEntry] {
        entries.filter { $0.date != nil }.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
    }

    func entry(id: String) -> ETLDeadlineEntry? {
        entries.first { $0.id == id }
    }

    /// 사람이 열어 볼 수 있게 ISO-8601로 적는다. 이 파일은 사용자가 직접 지워 되돌릴 수 있는
    /// 자리이므로 읽히는 편이 낫다.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
