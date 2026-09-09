import Foundation

// MARK: - 어디서 찾았고, 무엇으로 소리를 내는가

/// 곡을 **찾은** 곳. 메타데이터의 출처일 뿐, 재생과는 관계가 없다.
///
/// 이 앱에서 YouTube는 여기까지만 온다. 검색·제목·썸네일·플레이리스트를 주고,
/// 소리는 내지 않는다. 광고 없는 재생을 무료로 보장할 수 있는 방법이 YouTube에는
/// 없기 때문이다(Premium은 유료라 제외했다). 그래서 카탈로그와 재생을 아예 다른
/// 타입으로 갈라 놓았다 — 한쪽을 늘려도 다른 쪽이 따라 늘지 않는다.
enum MusicCatalogKind: String, Codable, Sendable, CaseIterable {
    case youtube
    case local
    case audius
    case internetArchive

    var displayName: String {
        switch self {
        case .youtube: "YouTube"
        case .local: "내 음악"
        case .audius: "Audius"
        case .internetArchive: "Internet Archive"
        }
    }

    var symbol: String {
        switch self {
        case .youtube: "play.rectangle"
        case .local: "internaldrive"
        case .audius: "waveform.circle"
        case .internetArchive: "building.columns"
        }
    }
}

/// 실제로 소리를 내는 곳. **광고가 구조적으로 존재하지 않는 것만** 여기에 들어온다.
///
/// - `localFile` 이 Mac에 있는 내 파일. 네트워크도 광고도 없다.
/// - `audius` 아티스트가 무료 청취용으로 올린 공개 트랙. 공개 API이고 광고가 없다.
/// - `internetArchive` 퍼블릭 도메인·CC 음원. 공개 API이고 광고가 없다.
///
/// YouTube가 이 목록에 없는 것이 이 기능의 전제다. 임베드 플레이어는 광고를 붙일 수
/// 있고, 그것을 막는 코드는 약관 위반이라 만들지 않는다.
enum PlaybackProviderKind: String, Codable, Sendable, CaseIterable {
    case localFile
    case audius
    case internetArchive

    var displayName: String {
        switch self {
        case .localFile: "내 파일"
        case .audius: "Audius"
        case .internetArchive: "Internet Archive"
        }
    }

    var symbol: String {
        switch self {
        case .localFile: "internaldrive"
        case .audius: "waveform.circle"
        case .internetArchive: "building.columns"
        }
    }
}

/// 앱 이름은 Audius 공개 API가 요구하는 유일한 식별자다. 키가 아니라 예의에 가깝다.
enum MusicAppIdentity {
    static let appName = "SeoulLocalAgent"
}

/// 한 곡을 실제로 재생할 수 있게 하는 것.
///
/// URL을 저장하지 않고 계산한다. Audius의 스트림 주소는 서명이 붙은 임시 주소로
/// 리다이렉트되므로 저장해 두면 며칠 뒤에 죽고, 파일 경로는 저장해도 되지만 두 가지를
/// 한 필드에 섞으면 나중에 어느 쪽인지 알 수 없다.
struct PlaybackAsset: Codable, Hashable, Sendable {
    var provider: PlaybackProviderKind
    /// 제공자마다 뜻이 다르다. `localFile`은 파일 경로, `audius`는 트랙 id,
    /// `internetArchive`는 `<식별자>/<파일 이름>`.
    var id: String
    var title: String
    var artist: String
    var duration: TimeInterval?
    /// 0…1. 자동으로 맞춘 것이 얼마나 확실한지. 화면이 "이 곡이 맞습니까"를 물을지
    /// 말없이 재생할지를 이 값으로 정한다.
    var confidence: Double
    var resolvedAt: Date
    /// 사람이 직접 고른 것. 자동 매칭이 이것을 덮어쓰지 않는다.
    var isManual: Bool

    var streamURL: URL? {
        switch provider {
        case .localFile:
            return URL(fileURLWithPath: id)
        case .audius:
            var components = URLComponents(string: "https://api.audius.co/v1/tracks/\(id)/stream")
            components?.queryItems = [URLQueryItem(name: "app_name", value: MusicAppIdentity.appName)]
            return components?.url
        case .internetArchive:
            guard let slash = id.firstIndex(of: "/") else { return nil }
            let identifier = String(id[id.startIndex..<slash])
            let file = String(id[id.index(after: slash)...])
            var components = URLComponents(string: "https://archive.org/download/")
            components?.path += "\(identifier)/\(file)"
            return components?.url
        }
    }

    /// 화면에 한 줄로 적는 출처. "왜 이 소리가 나는지"를 사용자가 늘 볼 수 있어야 한다.
    var provenance: String {
        switch provider {
        case .localFile: (id as NSString).lastPathComponent
        // 아티스트를 모르는 항목이 흔하다. 빈 이름을 붙이면 `Audius · `로 끝나는
        // 어색한 문장이 되므로 이름이 있을 때만 붙인다.
        case .audius: artist.isEmpty ? "Audius" : "Audius · \(artist)"
        case .internetArchive: artist.isEmpty ? "Internet Archive · \(title)" : "Internet Archive · \(artist)"
        }
    }
}

// MARK: - 곡

/// 한 곡. 어디서 찾았는지(`origin`)와 무엇으로 소리를 내는지(`asset`)가 분리되어 있다.
///
/// `id`는 `"<카탈로그>:<식별자>"`로 실행 사이에도 같은 값이라, 좋아요·최근 재생·
/// 대기열·모든 플레이리스트가 메타데이터 한 벌을 같이 본다.
struct Track: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var origin: MusicCatalogKind
    var originID: String
    var title: String
    var artist: String
    var album: String?
    /// 없을 수 있다. 라이브 스트림에는 길이가 없고, 0으로 적으면 거짓말이 된다.
    var duration: TimeInterval?
    var thumbnailURL: URL?
    var addedAt: Date

    /// 광고 없이 이 곡을 들려줄 수 있는 것. `nil`이면 아직 찾지 않았거나 못 찾았다.
    var asset: PlaybackAsset?
    /// 찾아봤지만 없었던 시각. `nil`과 구별해야 "아직 안 찾음"과 "찾아봤는데 없음"을
    /// 화면이 다르게 말할 수 있다.
    var searchedWithoutResultAt: Date?

    init(
        origin: MusicCatalogKind,
        originID: String,
        title: String,
        artist: String,
        album: String? = nil,
        duration: TimeInterval? = nil,
        thumbnailURL: URL? = nil,
        addedAt: Date = Date(),
        asset: PlaybackAsset? = nil
    ) {
        self.id = "\(origin.rawValue):\(originID)"
        self.origin = origin
        self.originID = originID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.thumbnailURL = thumbnailURL
        self.addedAt = addedAt
        self.asset = asset
    }

    var isPlayable: Bool { asset?.streamURL != nil }

    /// 이 곡을 앱 밖에서 볼 수 있는 곳. 재생이 안 되는 곡에 대해 "그래도 원곡은 여기서
    /// 볼 수 있다"고 말해 주기 위한 것이지, 앱 안에서 여는 경로가 아니다.
    var externalURL: URL? {
        switch origin {
        case .youtube: URL(string: "https://www.youtube.com/watch?v=\(originID)")
        case .local: URL(fileURLWithPath: originID)
        case .audius: URL(string: "https://audius.co/tracks/\(originID)")
        case .internetArchive: URL(string: "https://archive.org/details/\(originID.split(separator: "/").first.map(String.init) ?? originID)")
        }
    }

    /// 재생 상태를 한 문장으로. 화면 세 곳이 각자 다르게 쓰던 문장을 하나로 모았다.
    var availabilityNote: String {
        if let asset { return asset.provenance }
        if searchedWithoutResultAt != nil { return "광고 없이 들을 수 있는 음원을 찾지 못했습니다" }
        return "음원을 아직 찾지 않았습니다"
    }
}

// MARK: - 플레이리스트

struct MusicPlaylist: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// 곡이 아니라 곡 id. 카탈로그에 한 벌만 두므로, 음원을 새로 찾으면 그 곡이 들어간
    /// 모든 목록이 함께 재생 가능해진다.
    var trackIDs: [String]
    var createdAt: Date
    var updatedAt: Date
    var importedFrom: ImportOrigin?

    struct ImportOrigin: Codable, Hashable, Sendable {
        var source: MusicCatalogKind
        var id: String
        var importedAt: Date
    }

    init(name: String, trackIDs: [String] = [], importedFrom: ImportOrigin? = nil) {
        self.id = UUID()
        self.name = name
        self.trackIDs = trackIDs
        self.createdAt = Date()
        self.updatedAt = Date()
        self.importedFrom = importedFrom
    }
}

// MARK: - 반복

enum RepeatMode: String, Codable, Sendable, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var symbol: String {
        switch self {
        case .off, .all: "repeat"
        case .one: "repeat.1"
        }
    }

    var korean: String {
        switch self {
        case .off: "반복 없음"
        case .all: "전체 반복"
        case .one: "한 곡 반복"
        }
    }
}

// MARK: - 재생 순서

/// 대기열의 어느 칸을 다음에 틀 것인가.
///
/// 모델에서 떼어 낸 이유는 이 규칙이 화면도 네트워크도 필요 없는 순수한 결정이고,
/// 동시에 틀리기 쉬운 곳이기 때문이다 — 셔플과 반복이 겹칠 때 마지막 곡에서 무엇이
/// 일어나야 하는지는 눈으로 보고 알기 어렵다.
enum MusicQueueOrder {
    /// 셔플이 켜져 있으면 순서를 섞되 **지금 듣는 곡을 맨 앞에** 둔다. 그러지 않으면
    /// 셔플을 켜는 순간 듣던 곡이 대기열 한가운데로 밀려나 `이전`이 엉뚱한 곳으로 간다.
    static func order(count: Int, shuffle: Bool, current: Int?) -> [Int] {
        guard count > 0 else { return [] }
        guard shuffle else { return Array(0..<count) }
        var indices = Array(0..<count).shuffled()
        if let current, let at = indices.firstIndex(of: current) { indices.swapAt(0, at) }
        return indices
    }

    /// 다음 자리. `nil`이면 여기서 멈춘다.
    static func next(from position: Int, count: Int, repeatMode: RepeatMode) -> Int? {
        guard count > 0 else { return nil }
        let candidate = position + 1
        if candidate < count { return candidate }
        return repeatMode == .all ? 0 : nil
    }

    /// 이전 자리. `nil`이면 처음으로 되감는다.
    static func previous(from position: Int, count: Int, repeatMode: RepeatMode) -> Int? {
        guard count > 0 else { return nil }
        let candidate = position - 1
        if candidate >= 0 { return candidate }
        return repeatMode == .all ? count - 1 : nil
    }
}

// MARK: - 보관함

/// 음악에 대해 앱이 기억하는 전부를 한 값으로.
///
/// 파일 하나로 쓴다. 좋아요·플레이리스트·최근 재생·대기열이 같은 카탈로그를 가리키므로
/// 따로 쓰면 두 쓰기 사이에 죽었을 때 제목 없는 곡을 가리키는 플레이리스트가 남는다.
/// 원자적 쓰기 한 번은 절반만 적용될 수 없다.
struct MusicLibrary: Codable, Sendable, Equatable {
    var catalog: [String: Track] = [:]
    var playlists: [MusicPlaylist] = []
    /// 최신이 앞. 화면이 따로 정렬하지 않아도 읽는 순서가 맞는다.
    var likedIDs: [String] = []
    var recentIDs: [String] = []
    var queue: [String] = []
    var queueIndex: Int?
    var shuffle = false
    var repeatMode: RepeatMode = .off
    var volume: Double = 0.8
    /// 앱을 닫을 때 어디까지 들었는지. 다시 열면 그 자리에서 이어 간다.
    var resumePosition: TimeInterval = 0
    var lastQuery: String = ""
    /// 내 음악을 찾을 폴더. 비어 있으면 `~/Music`을 쓴다.
    var localFolders: [String] = []

    static let recentLimit = 100

    // MARK: 조회

    func track(_ id: String) -> Track? { catalog[id] }
    func tracks(_ ids: [String]) -> [Track] { ids.compactMap { catalog[$0] } }
    func isLiked(_ id: String) -> Bool { likedIDs.contains(id) }

    var likedTracks: [Track] { tracks(likedIDs) }
    var recentTracks: [Track] { tracks(recentIDs) }
    var queueTracks: [Track] { tracks(queue) }

    var currentTrackID: String? {
        guard let index = queueIndex, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    var resolvedLocalFolders: [URL] {
        localFolders.isEmpty
            ? [URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Music", directoryHint: .isDirectory)]
            : localFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: 변경

    /// 카탈로그에 넣되, 이미 알던 곡의 `addedAt`과 이미 찾아 둔 음원은 지키지 않고
    /// 잃지 않는다. 검색 결과에 다시 뜬 곡이 방금 추가된 것처럼 보이거나, 애써 찾은
    /// 음원이 검색 한 번에 날아가면 안 된다.
    mutating func remember(_ track: Track) {
        guard let existing = catalog[track.id] else {
            catalog[track.id] = track
            return
        }
        var merged = track
        merged.addedAt = min(existing.addedAt, track.addedAt)
        merged.asset = track.asset ?? existing.asset
        merged.searchedWithoutResultAt = merged.asset == nil
            ? (track.searchedWithoutResultAt ?? existing.searchedWithoutResultAt)
            : nil
        catalog[track.id] = merged
    }

    mutating func remember(_ tracks: [Track]) { tracks.forEach { remember($0) } }

    /// 음원 하나를 곡에 붙인다. 사람이 고른 것은 자동 매칭이 덮지 않는다.
    mutating func attach(_ asset: PlaybackAsset?, to trackID: String) {
        guard var track = catalog[trackID] else { return }
        if track.asset?.isManual == true, asset?.isManual != true { return }
        track.asset = asset
        track.searchedWithoutResultAt = asset == nil ? Date() : nil
        catalog[trackID] = track
    }

    mutating func toggleLike(_ track: Track) {
        remember(track)
        if let index = likedIDs.firstIndex(of: track.id) {
            likedIDs.remove(at: index)
        } else {
            likedIDs.insert(track.id, at: 0)
        }
    }

    mutating func notePlayed(_ track: Track) {
        remember(track)
        recentIDs.removeAll { $0 == track.id }
        recentIDs.insert(track.id, at: 0)
        if recentIDs.count > Self.recentLimit { recentIDs.removeLast(recentIDs.count - Self.recentLimit) }
    }

    mutating func addTracks(_ tracks: [Track], toPlaylist playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        remember(tracks)
        // 같은 곡을 두 번 넣지 않는다. 중복이 있으면 셔플이 그 곡만 두 배로 자주 고르고,
        // 지울 때 어느 쪽을 지운 것인지도 알 수 없다.
        let existing = Set(playlists[index].trackIDs)
        playlists[index].trackIDs.append(contentsOf: tracks.map(\.id).filter { !existing.contains($0) })
        playlists[index].updatedAt = Date()
    }

    mutating func removeTracks(at offsets: IndexSet, fromPlaylist playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.remove(atOffsets: offsets)
        playlists[index].updatedAt = Date()
    }

    mutating func moveTracks(from offsets: IndexSet, to destination: Int, inPlaylist playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.move(fromOffsets: offsets, toOffset: destination)
        playlists[index].updatedAt = Date()
    }

    /// 아무도 가리키지 않는 카탈로그 항목을 버린다. 없으면 파일이 영원히 자란다 —
    /// 한 번 듣고 만 검색 결과가 전부 남아 몇 달 뒤에는 죽은 메타데이터 수 MB를
    /// 매 실행마다 읽게 된다.
    mutating func pruneCatalog() {
        var reachable = Set(likedIDs)
        reachable.formUnion(recentIDs)
        reachable.formUnion(queue)
        for playlist in playlists { reachable.formUnion(playlist.trackIDs) }
        catalog = catalog.filter { reachable.contains($0.key) }
    }
}

// MARK: - 저장

/// 이 앱의 다른 개인 파일과 같은 방식으로 쓴다: 소유자만 읽을 수 있게, 임시 파일을
/// 거쳐서. 쓰다가 죽어도 반쯤 적힌 플레이리스트가 남지 않는다.
struct MusicLibraryStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "music-library.json")
    }

    var debugURL: URL { url }

    func load() -> MusicLibrary {
        guard let data = try? Data(contentsOf: url) else { return MusicLibrary() }
        // 형식이 바뀌어 못 읽어도 빈 보관함으로 계속 간다. 원본은 지우지 않으므로
        // 나중에 손으로 되살릴 수 있고, 음악이 앱의 다른 기능을 막을 이유는 없다.
        return (try? JSONDecoder.musicDecoder.decode(MusicLibrary.self, from: data)) ?? MusicLibrary()
    }

    func save(_ library: MusicLibrary) throws {
        var pruned = library
        pruned.pruneCatalog()
        try LocalFileStorage.write(try JSONEncoder.musicEncoder.encode(pruned), to: url)
    }
}

extension JSONEncoder {
    static var musicEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var musicDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - 시간 표기

enum MusicFormat {
    /// `3:07`과 `1:02:11`. 길이를 모르는 것은 `0:00`이 아니라 `--:--`이다 — 라이브
    /// 스트림에는 길이가 정말로 없고, 0이라고 적으면 거짓이 된다.
    static func time(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
