import Foundation

// MARK: - API 키

/// YouTube Data API 키.
///
/// 코드에 넣지 않는다. 키는 개인 자격 증명이고, 이 저장소는 공개된 곳에 올라갈 수
/// 있으며, 유출된 키는 남이 내 할당량을 태우는 데 쓰인다. 그래서 이 앱의 다른 개인
/// 파일(`gmail-accounts.json`)과 같은 자리에 같은 권한으로 둔다.
///
///     ~/Library/Application Support/SeoulLocalAgent/youtube-config.json
///     { "apiKey": "AIza..." }
///
/// 환경 변수 `YOUTUBE_API_KEY`가 있으면 그쪽이 이긴다. CI나 임시 실행에서 파일을
/// 만들지 않고도 쓸 수 있어야 하기 때문이다.
struct YouTubeConfigurationStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "youtube-config.json")
    }

    var debugURL: URL { url }

    private struct Stored: Codable { var apiKey: String }

    func load() -> String? {
        if let environment = ProcessInfo.processInfo.environment["YOUTUBE_API_KEY"],
           !environment.trimmingCharacters(in: .whitespaces).isEmpty {
            return environment.trimmingCharacters(in: .whitespaces)
        }
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        let key = stored.apiKey.trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    func save(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        try LocalFileStorage.write(try JSONEncoder().encode(Stored(apiKey: trimmed)), to: url)
    }
}

// MARK: - 주소에서 id 꺼내기

/// 붙여 넣은 것이 무엇인지 알아본다. 검색창 하나로 검색·영상·플레이리스트를 다 받으려면
/// 이 판정이 먼저 있어야 한다.
enum YouTubeReference: Equatable {
    case video(String)
    case playlist(String)
    case query(String)

    /// 11자 영상 id와 `PL`/`OLAK5uy_`/`RD` 계열 플레이리스트 id를 알아본다. 둘 다
    /// 아니면 검색어로 본다.
    static func parse(_ raw: String) -> YouTubeReference {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .query("") }

        if let components = URLComponents(string: text), let host = components.host?.lowercased(),
           host.contains("youtube.com") || host.contains("youtu.be") {
            let items = components.queryItems ?? []
            if let list = items.first(where: { $0.name == "list" })?.value, isPlaylistID(list) {
                // `watch?v=…&list=…`는 재생목록을 보고 있는 것이다. 목록이 우선이다.
                return .playlist(list)
            }
            if let video = items.first(where: { $0.name == "v" })?.value, isVideoID(video) {
                return .video(video)
            }
            let path = components.path.split(separator: "/").map(String.init)
            if host.contains("youtu.be"), let first = path.first, isVideoID(first) { return .video(first) }
            if let index = path.firstIndex(of: "shorts"), index + 1 < path.count, isVideoID(path[index + 1]) {
                return .video(path[index + 1])
            }
            if let index = path.firstIndex(of: "embed"), index + 1 < path.count, isVideoID(path[index + 1]) {
                return .video(path[index + 1])
            }
        }
        if isPlaylistID(text) { return .playlist(text) }
        if isVideoID(text) { return .video(text) }
        return .query(text)
    }

    static func isVideoID(_ value: String) -> Bool {
        value.count == 11 && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    static func isPlaylistID(_ value: String) -> Bool {
        guard value.count >= 13 else { return false }
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return false }
        return ["PL", "OLAK5uy_", "UU", "FL", "LL", "RD"].contains { value.hasPrefix($0) }
    }
}

// MARK: - ISO 8601 길이

enum YouTubeDuration {
    /// `PT4M13S` → 253. 정규식 없이 읽는다 — 이 형식은 단순하고, 정규식은 여기서
    /// 읽기만 어렵게 만든다.
    static func seconds(_ text: String) -> TimeInterval? {
        guard text.hasPrefix("P") else { return nil }
        var total: TimeInterval = 0
        var number = ""
        var inTime = false
        var sawAny = false
        for character in text.dropFirst() {
            if character == "T" { inTime = true; continue }
            if character.isNumber { number.append(character); continue }
            guard let value = Double(number) else { return nil }
            number = ""
            switch character {
            case "D": total += value * 86_400
            case "W": total += value * 604_800
            case "H": total += value * 3_600
            case "M": total += inTime ? value * 60 : value * 2_592_000
            case "S": total += value
            case "Y": total += value * 31_536_000
            default: return nil
            }
            sawAny = true
        }
        return sawAny ? total : nil
    }
}

// MARK: - 카탈로그

/// YouTube Data API v3. **검색·메타데이터·플레이리스트만** 한다.
///
/// 이 타입에는 재생이 없다. 광고 없는 재생을 무료로 보장할 방법이 YouTube에 없어서,
/// 이 앱은 YouTube를 "무엇을 들을지 정하는 곳"으로만 쓰고 소리는 다른 데서 낸다.
/// 그래서 비공식 스트림 추출도, 임베드 플레이어도, 광고를 건드리는 코드도 없다.
struct YouTubeCatalogSource: MusicCatalogSource {
    let kind = MusicCatalogKind.youtube
    private let apiKey: String?
    /// 음악 카테고리(10)로 좁힐지. 켜 두면 강의 영상이나 브이로그가 덜 섞인다.
    let musicOnly: Bool

    init(apiKey: String?, musicOnly: Bool = true) {
        self.apiKey = apiKey
        self.musicOnly = musicOnly
    }

    var isConfigured: Bool { apiKey != nil }

    private func url(_ path: String, _ items: [URLQueryItem]) throws -> URL {
        guard let apiKey else {
            throw MusicSourceError.notConfigured("YouTube API 키가 없습니다. 설정 › 음악에서 넣으세요.")
        }
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(path)")!
        components.queryItems = items + [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { throw MusicSourceError.badResponse("주소를 만들지 못했습니다") }
        return url
    }

    // MARK: 검색

    func search(_ query: String, limit: Int = 25) async throws -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        switch YouTubeReference.parse(trimmed) {
        case .video(let id):
            return try await videos([id])
        case .playlist(let id):
            return try await playlistTracks(id).tracks
        case .query(let text):
            var items = [
                URLQueryItem(name: "part", value: "snippet"),
                URLQueryItem(name: "type", value: "video"),
                URLQueryItem(name: "q", value: text),
                URLQueryItem(name: "maxResults", value: String(min(50, max(1, limit)))),
                URLQueryItem(name: "regionCode", value: "KR"),
                URLQueryItem(name: "relevanceLanguage", value: "ko")
            ]
            if musicOnly { items.append(URLQueryItem(name: "videoCategoryId", value: "10")) }
            let payload = try await MusicHTTP.object(try url("search", items))
            let ids = ((payload["items"] as? [[String: Any]]) ?? []).compactMap {
                (($0["id"] as? [String: Any])?["videoId"] as? String)
            }
            guard !ids.isEmpty else { return [] }
            // `search.list`는 길이를 주지 않는다. 길이는 나중에 음원을 맞출 때 가장 강한
            // 신호라 여기서 한 번 더 물어보는 값을 한다(1 유닛).
            return try await videos(ids)
        }
    }

    // MARK: 영상 상세

    func videos(_ ids: [String]) async throws -> [Track] {
        var result: [Track] = []
        for chunk in stride(from: 0, to: ids.count, by: 50).map({ Array(ids[$0..<min($0 + 50, ids.count)]) }) {
            let payload = try await MusicHTTP.object(try url("videos", [
                URLQueryItem(name: "part", value: "snippet,contentDetails"),
                URLQueryItem(name: "id", value: chunk.joined(separator: ","))
            ]))
            let items = (payload["items"] as? [[String: Any]]) ?? []
            let byID = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (String, Track)? in
                guard let id = item["id"] as? String, let track = Self.track(from: item, id: id) else { return nil }
                return (id, track)
            })
            // 물어본 순서대로 돌려준다. `videos.list`는 id 순서를 지켜 주지 않아서,
            // 그대로 쓰면 검색 결과의 관련도 순서가 뒤섞인다.
            result.append(contentsOf: chunk.compactMap { byID[$0] })
        }
        return result
    }

    private static func track(from item: [String: Any], id: String) -> Track? {
        guard let snippet = item["snippet"] as? [String: Any],
              let rawTitle = snippet["title"] as? String else { return nil }
        let channel = (snippet["channelTitle"] as? String) ?? ""
        let duration = ((item["contentDetails"] as? [String: Any])?["duration"] as? String)
            .flatMap(YouTubeDuration.seconds)
        let (artist, title) = MusicMatching.splitArtistAndTitle(
            rawTitle,
            channelArtist: MusicMatching.artistFromChannel(channel)
        )
        return Track(
            origin: .youtube,
            originID: id,
            title: title,
            artist: artist,
            duration: duration,
            thumbnailURL: thumbnail(snippet)
        )
    }

    private static func thumbnail(_ snippet: [String: Any]) -> URL? {
        guard let thumbnails = snippet["thumbnails"] as? [String: Any] else { return nil }
        for size in ["medium", "high", "standard", "default"] {
            if let entry = thumbnails[size] as? [String: Any],
               let value = entry["url"] as? String, let url = URL(string: value) { return url }
        }
        return nil
    }

    // MARK: 플레이리스트 가져오기

    struct ImportedPlaylist: Sendable {
        var title: String
        var playlistID: String
        var tracks: [Track]
        /// 가져오다 만 것인지. 500곡짜리 목록을 다 받으면 할당량과 시간이 많이 드므로
        /// 상한을 둔다. 잘렸다면 화면이 그렇게 말해야 한다.
        var truncated: Bool
    }

    func playlistTracks(_ playlistID: String, maxItems: Int = 300) async throws -> ImportedPlaylist {
        let title = try await playlistTitle(playlistID) ?? "가져온 플레이리스트"
        var videoIDs: [String] = []
        var pageToken: String?
        var truncated = false
        repeat {
            var items = [
                URLQueryItem(name: "part", value: "contentDetails"),
                URLQueryItem(name: "playlistId", value: playlistID),
                URLQueryItem(name: "maxResults", value: "50")
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let payload = try await MusicHTTP.object(try url("playlistItems", items))
            let page = ((payload["items"] as? [[String: Any]]) ?? []).compactMap {
                ($0["contentDetails"] as? [String: Any])?["videoId"] as? String
            }
            videoIDs.append(contentsOf: page)
            pageToken = payload["nextPageToken"] as? String
            if videoIDs.count >= maxItems {
                truncated = pageToken != nil
                videoIDs = Array(videoIDs.prefix(maxItems))
                break
            }
        } while pageToken != nil

        guard !videoIDs.isEmpty else { throw MusicSourceError.notFound }
        return ImportedPlaylist(
            title: title,
            playlistID: playlistID,
            tracks: try await videos(videoIDs),
            truncated: truncated
        )
    }

    private func playlistTitle(_ playlistID: String) async throws -> String? {
        let payload = try await MusicHTTP.object(try url("playlists", [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "id", value: playlistID)
        ]))
        let items = (payload["items"] as? [[String: Any]]) ?? []
        // 비공개 목록은 키만으로는 보이지 않는다. 그때는 항목을 가져오는 쪽에서
        // 실패하므로 여기서는 조용히 넘어간다.
        return (items.first?["snippet"] as? [String: Any])?["title"] as? String
    }
}
