import Foundation

// MARK: - Audius

/// 아티스트가 무료 청취용으로 올린 공개 트랙. 공개 API이고, 키가 없고, 광고가 없다.
///
/// 카탈로그이면서 동시에 재생 소스다 — 여기서 찾은 곡은 여기서 그대로 들을 수 있다.
/// `app_name`은 인증이 아니라 공개 API가 요구하는 호출자 표시다.
struct AudiusSource: MusicCatalogSource, MusicStreamSource {
    let kind = MusicCatalogKind.audius
    let provider = PlaybackProviderKind.audius

    private static func endpoint(_ path: String, _ items: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: "https://api.audius.co/v1/\(path)")
        components?.queryItems = items + [URLQueryItem(name: "app_name", value: MusicAppIdentity.appName)]
        return components?.url
    }

    private struct Candidate {
        var id: String
        var title: String
        var artist: String
        var duration: TimeInterval?
        var artwork: URL?
    }

    private func searchCandidates(_ query: String, limit: Int) async throws -> [Candidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let url = Self.endpoint("tracks/search", [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "limit", value: String(min(50, max(1, limit))))
        ]) else { return [] }
        let payload = try await MusicHTTP.object(url)
        return ((payload["data"] as? [[String: Any]]) ?? []).compactMap(Self.candidate)
    }

    private static func candidate(_ item: [String: Any]) -> Candidate? {
        guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
        // 지워졌거나 스트림 권한이 없는 트랙은 후보에서 뺀다. 넣어 두면 `/stream`이
        // 404를 돌려주고, 사용자에게는 "재생을 눌렀는데 아무 일도 없음"으로 보인다.
        if (item["is_delete"] as? Bool) == true { return nil }
        if let access = item["access"] as? [String: Any], (access["stream"] as? Bool) == false { return nil }
        if let streamable = item["is_streamable"] as? Bool, streamable == false { return nil }
        let user = item["user"] as? [String: Any]
        let artist = (user?["name"] as? String) ?? (user?["handle"] as? String) ?? ""
        let duration = (item["duration"] as? NSNumber)?.doubleValue
        let artwork = (item["artwork"] as? [String: Any]).flatMap { art -> URL? in
            for size in ["480x480", "150x150", "1000x1000"] {
                if let value = art[size] as? String, let url = URL(string: value) { return url }
            }
            return nil
        }
        return Candidate(id: id, title: title, artist: artist, duration: duration, artwork: artwork)
    }

    func search(_ query: String, limit: Int = 25) async throws -> [Track] {
        try await searchCandidates(query, limit: limit).map { candidate in
            Track(
                origin: .audius,
                originID: candidate.id,
                title: candidate.title,
                artist: candidate.artist,
                duration: candidate.duration,
                thumbnailURL: candidate.artwork,
                asset: PlaybackAsset(
                    provider: .audius,
                    id: candidate.id,
                    title: candidate.title,
                    artist: candidate.artist,
                    duration: candidate.duration,
                    // 자기 카탈로그에서 자기 음원을 쓰는 것이므로 맞출 것이 없다.
                    confidence: 1,
                    resolvedAt: Date(),
                    isManual: false
                )
            )
        }
    }

    func findAsset(title: String, artist: String, duration: TimeInterval?) async throws -> PlaybackAsset? {
        // 아티스트를 붙여 한 번, 제목만으로 한 번. 붙인 쪽이 훨씬 정확하지만, Audius의
        // 검색은 아티스트 이름이 다르면 아예 0건을 주는 경우가 있다.
        var candidates = try await searchCandidates("\(artist) \(title)", limit: 12)
        if candidates.isEmpty { candidates = try await searchCandidates(title, limit: 12) }
        return Self.best(candidates, title: title, artist: artist, duration: duration)
    }

    private static func best(
        _ candidates: [Candidate],
        title: String,
        artist: String,
        duration: TimeInterval?
    ) -> PlaybackAsset? {
        var bestScore = 0.0
        var bestCandidate: Candidate?
        for candidate in candidates {
            let score = MusicMatching.score(
                queryTitle: title, queryArtist: artist, queryDuration: duration,
                candidateTitle: candidate.title, candidateArtist: candidate.artist,
                candidateDuration: candidate.duration
            )
            if score > bestScore { bestScore = score; bestCandidate = candidate }
        }
        guard let bestCandidate, bestScore >= MusicMatching.acceptanceThreshold else { return nil }
        return PlaybackAsset(
            provider: .audius,
            id: bestCandidate.id,
            title: bestCandidate.title,
            artist: bestCandidate.artist,
            duration: bestCandidate.duration,
            confidence: bestScore,
            resolvedAt: Date(),
            isManual: false
        )
    }
}

// MARK: - Internet Archive

/// 퍼블릭 도메인과 CC 음원. 공개 API이고, 키가 없고, 광고가 없다.
///
/// 클래식·재즈·78회전 음반·라이브 아카이브가 두껍다. 최신 상용 음악은 여기에 없고,
/// 있는 척하지도 않는다.
struct InternetArchiveSource: MusicCatalogSource, MusicStreamSource {
    let kind = MusicCatalogKind.internetArchive
    let provider = PlaybackProviderKind.internetArchive

    /// AVFoundation이 확실히 여는 것만 고른다. 목록에 Flac이 먼저 오는 항목이 많지만
    /// 스트리밍으로는 MP3가 안전하고 가볍다.
    private static let preferredFormats = ["VBR MP3", "MP3", "128Kbps MP3", "64Kbps MP3", "MPEG-4 Audio", "Flac"]

    private struct Item {
        var identifier: String
        var title: String
        var creator: String
    }

    private func searchItems(_ query: String, limit: Int) async throws -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // 검색어를 그대로 Lucene 질의에 넣지 않는다. 사용자가 친 따옴표나 콜론이
        // 질의 문법으로 해석되면 결과가 조용히 0건이 된다.
        let escaped = trimmed.replacingOccurrences(of: "\"", with: " ")
            .replacingOccurrences(of: ":", with: " ")
        var components = URLComponents(string: "https://archive.org/advancedsearch.php")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "(\(escaped)) AND mediatype:(audio)"),
            URLQueryItem(name: "fl[]", value: "identifier"),
            URLQueryItem(name: "fl[]", value: "title"),
            URLQueryItem(name: "fl[]", value: "creator"),
            URLQueryItem(name: "rows", value: String(min(30, max(1, limit)))),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "output", value: "json")
        ]
        guard let url = components.url else { return [] }
        let payload = try await MusicHTTP.object(url)
        let documents = ((payload["response"] as? [String: Any])?["docs"] as? [[String: Any]]) ?? []
        return documents.compactMap { document in
            guard let identifier = document["identifier"] as? String else { return nil }
            let title = (document["title"] as? String) ?? identifier
            let creator = (document["creator"] as? String)
                ?? ((document["creator"] as? [String])?.first)
                ?? ""
            return Item(identifier: identifier, title: title, creator: creator)
        }
    }

    /// 한 항목 안의 재생 가능한 파일들. 아카이브의 한 "항목"은 앨범이나 콘서트 하나라
    /// 트랙이 여러 개인 경우가 흔하다.
    struct ArchiveFile: Sendable {
        var name: String
        var title: String
        var duration: TimeInterval?
    }

    func files(in identifier: String) async throws -> [ArchiveFile] {
        guard let url = URL(string: "https://archive.org/metadata/\(identifier)") else { return [] }
        let payload = try await MusicHTTP.object(url)
        let files = (payload["files"] as? [[String: Any]]) ?? []
        var byBase: [String: (rank: Int, file: ArchiveFile)] = [:]
        for entry in files {
            guard let name = entry["name"] as? String,
                  let format = entry["format"] as? String,
                  let rank = Self.preferredFormats.firstIndex(of: format) else { continue }
            let base = (name as NSString).deletingPathExtension
            let file = ArchiveFile(
                name: name,
                title: (entry["title"] as? String) ?? base,
                duration: (entry["length"] as? String).flatMap(Self.length)
            )
            // 같은 곡이 flac·mp3·wav로 세 번 들어 있다. 선호 순위가 앞선 것만 남긴다.
            if let existing = byBase[base], existing.rank <= rank { continue }
            byBase[base] = (rank, file)
        }
        return byBase.values.map(\.file).sorted { $0.name < $1.name }
    }

    /// 아카이브는 `115.52`(초)와 `01:56`(분:초)를 섞어 쓴다.
    static func length(_ text: String) -> TimeInterval? {
        if let seconds = Double(text) { return seconds }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    func search(_ query: String, limit: Int = 20) async throws -> [Track] {
        var tracks: [Track] = []
        // 항목마다 파일 목록을 한 번씩 더 물어야 한다. 앞쪽 몇 개만 펼치는 것으로
        // 충분하다 — 검색 결과 30개의 파일을 다 받으면 30번의 왕복이 된다.
        for item in try await searchItems(query, limit: limit).prefix(8) {
            let files = (try? await self.files(in: item.identifier)) ?? []
            for file in files.prefix(12) {
                tracks.append(Self.track(item: item, file: file))
            }
            if tracks.count >= limit { break }
        }
        return Array(tracks.prefix(limit))
    }

    /// 아카이브의 파일 `title`은 비어 있거나 `1`처럼 트랙 번호만 든 경우가 흔하고,
    /// 파일 이름 자체가 `1.mp3`·`2.mp3`인 항목도 많다(실제로 `CHOPIN Klavierwerke`가
    /// 그렇다). 그대로 두면 같은 이름의 줄이 세 개 늘어서서 어느 것이 어느 곡인지
    /// 알 수 없으므로, 번호뿐일 때는 항목 이름에 번호를 붙여 구별해 준다.
    static func displayTitle(fileTitle: String, fileName: String, itemTitle: String) -> String {
        let trimmed = fileTitle.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, Double(trimmed) == nil { return trimmed }
        let base = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        if !base.isEmpty, Double(base) == nil { return base }
        let number = trimmed.isEmpty ? base : trimmed
        return number.isEmpty ? itemTitle : "\(itemTitle) — \(number)"
    }

    private static func track(item: Item, file: ArchiveFile) -> Track {
        let id = "\(item.identifier)/\(file.name)"
        let title = displayTitle(fileTitle: file.title, fileName: file.name, itemTitle: item.title)
        return Track(
            origin: .internetArchive,
            originID: id,
            title: title,
            artist: item.creator,
            album: item.title,
            duration: file.duration,
            thumbnailURL: URL(string: "https://archive.org/services/img/\(item.identifier)"),
            asset: PlaybackAsset(
                provider: .internetArchive,
                id: id,
                title: title,
                artist: item.creator,
                duration: file.duration,
                confidence: 1,
                resolvedAt: Date(),
                isManual: false
            )
        )
    }

    func findAsset(title: String, artist: String, duration: TimeInterval?) async throws -> PlaybackAsset? {
        // 아티스트를 붙여 한 번, 제목만으로 한 번. 아카이브의 항목 이름은 대개 앨범이나
        // 연주회 이름이라 아티스트를 붙이면 오히려 0건이 되는 경우가 있다.
        var items = try await searchItems(artist.isEmpty ? title : "\(artist) \(title)", limit: 10)
        if items.isEmpty, !artist.isEmpty { items = try await searchItems(title, limit: 10) }
        var best: (score: Double, asset: PlaybackAsset)?
        for item in items.prefix(5) {
            let files = (try? await self.files(in: item.identifier)) ?? []
            for file in files {
                let candidateTitle = Self.displayTitle(fileTitle: file.title, fileName: file.name, itemTitle: item.title)
                let score = MusicMatching.score(
                    queryTitle: title, queryArtist: artist, queryDuration: duration,
                    candidateTitle: candidateTitle, candidateArtist: item.creator,
                    candidateDuration: file.duration
                )
                guard score >= MusicMatching.acceptanceThreshold, score > (best?.score ?? 0) else { continue }
                best = (score, PlaybackAsset(
                    provider: .internetArchive,
                    id: "\(item.identifier)/\(file.name)",
                    title: candidateTitle,
                    artist: item.creator,
                    duration: file.duration,
                    confidence: score,
                    resolvedAt: Date(),
                    isManual: false
                ))
            }
        }
        return best?.asset
    }
}
