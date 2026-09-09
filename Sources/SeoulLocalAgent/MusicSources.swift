import Foundation

// MARK: - 오류

enum MusicSourceError: LocalizedError, Equatable {
    case notConfigured(String)
    case quotaExceeded
    case notFound
    case badResponse(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what): what
        case .quotaExceeded: "YouTube Data API 하루 할당량을 다 썼습니다. 내일 다시 검색할 수 있습니다."
        case .notFound: "찾지 못했습니다."
        case .badResponse(let detail): "응답을 이해하지 못했습니다: \(detail)"
        case .http(let code, let message): message.isEmpty ? "요청이 \(code)로 실패했습니다." : "\(message) (\(code))"
        }
    }
}

// MARK: - 두 가지 역할

/// 곡을 **찾는** 곳. 소리는 내지 않는다.
protocol MusicCatalogSource: Sendable {
    var kind: MusicCatalogKind { get }
    func search(_ query: String, limit: Int) async throws -> [Track]
}

/// 광고 없이 **소리를 내는** 곳. 카탈로그가 준 제목·아티스트로 같은 곡을 찾아 준다.
protocol MusicStreamSource: Sendable {
    var provider: PlaybackProviderKind { get }
    func findAsset(title: String, artist: String, duration: TimeInterval?) async throws -> PlaybackAsset?
}

// MARK: - 제목 정리와 맞추기

/// 두 곳에서 온 제목이 같은 곡인지 판단하는 규칙 전부.
///
/// 순수 함수만 둔다. 네트워크가 필요 없으니 테스트가 실제로 이 규칙을 검사할 수 있고,
/// "왜 이 곡이 저 음원에 붙었는가"를 재현해 볼 수 있다.
enum MusicMatching {
    /// 음악 영상 제목에 흔히 붙는 장식. 곡 이름이 아니라 업로드의 성격을 말하는 말들이라
    /// 맞추기 전에 떼어 낸다.
    static let decorations: Set<String> = [
        "official", "officialvideo", "officialmv", "officialaudio", "officiallyricvideo",
        "mv", "m/v", "musicvideo", "lyricvideo", "lyrics", "lyric", "audio", "video",
        "hd", "hq", "4k", "1080p", "720p", "full", "fullversion", "remastered",
        "visualizer", "performancevideo", "danceversion", "colorcoded",
        "가사", "공식", "뮤직비디오", "음원", "영상", "리릭", "리릭비디오"
    ]

    /// 괄호 안이 통째로 장식이면 그 괄호를 지운다. 안에 실제 정보(feat., remix, live)가
    /// 있으면 남긴다 — `(Live)`를 지우면 스튜디오 녹음과 구별할 수 없어진다.
    static func stripDecorations(_ title: String) -> String {
        var result = ""
        var buffer = ""
        var depth = 0
        for character in title {
            if character == "(" || character == "[" || character == "{" || character == "<" {
                depth += 1
                if depth == 1 { buffer = ""; continue }
            }
            if character == ")" || character == "]" || character == "}" || character == ">" {
                depth = max(0, depth - 1)
                if depth == 0 {
                    if !isAllDecoration(buffer) { result += " " + buffer + " " }
                    buffer = ""
                    continue
                }
            }
            if depth > 0 { buffer.append(character) } else { result.append(character) }
        }
        if depth > 0, !isAllDecoration(buffer) { result += " " + buffer }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAllDecoration(_ text: String) -> Bool {
        let words = text.lowercased()
            .replacingOccurrences(of: "/", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { decorations.contains($0) }
    }

    /// 비교용 형태. 대소문자·문장부호·공백·장식을 지우고 남는 낱말들.
    static func tokens(_ text: String) -> [String] {
        stripDecorations(text)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !decorations.contains($0) && $0 != "feat" && $0 != "ft" && $0 != "featuring" }
    }

    /// 채널 이름을 아티스트 이름으로. 자동 생성 음악 채널은 `- Topic`이 붙고, 사람이
    /// 만든 채널은 `VEVO`나 `Official`을 달고 다닌다.
    static func artistFromChannel(_ channel: String) -> String {
        var name = channel
        for suffix in [" - Topic", "VEVO", " Official", " official"] {
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// `아티스트 - 제목` 꼴이면 갈라 준다. YouTube 제목은 대개 이 모양이고, 갈라 두면
    /// 음원 검색이 훨씬 잘 맞는다. 확신이 없으면 원래대로 둔다.
    static func splitArtistAndTitle(_ raw: String, channelArtist: String) -> (artist: String, title: String) {
        let cleaned = stripDecorations(raw)
        for separator in [" - ", " – ", " — ", " ‐ "] {
            guard let range = cleaned.range(of: separator) else { continue }
            let left = String(cleaned[cleaned.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            // 양쪽 다 내용이 있어야 한다. `- Topic` 같은 잔여물로 곡 제목을 잃지 않는다.
            guard !left.isEmpty, !right.isEmpty, left.count < 60 else { continue }
            return (left, right)
        }
        return (channelArtist, cleaned.isEmpty ? raw : cleaned)
    }

    /// 두 곡이 같은 곡일 확률 비슷한 것, 0…1.
    ///
    /// 제목이 대부분이고 아티스트가 거들며, 길이가 크게 어긋나면 깎는다. 길이는 강한
    /// 신호다 — 같은 제목의 3분짜리와 1시간짜리는 곡과 `1 hour loop`의 차이다.
    static func score(
        queryTitle: String,
        queryArtist: String,
        queryDuration: TimeInterval?,
        candidateTitle: String,
        candidateArtist: String,
        candidateDuration: TimeInterval?
    ) -> Double {
        let titleScore = overlap(tokens(queryTitle), tokens(candidateTitle))
        let artistScore = overlap(tokens(queryArtist), tokens(candidateArtist))
        var total = titleScore * 0.72 + artistScore * 0.28
        // 아티스트를 모르는 쪽이 한쪽뿐이면 제목만으로 판단한다. 모르는 것을 틀린 것으로
        // 세면 Internet Archive처럼 업로더 이름밖에 없는 곳이 전부 탈락한다.
        if tokens(queryArtist).isEmpty || tokens(candidateArtist).isEmpty {
            total = titleScore * 0.9
        }
        if let queryDuration, let candidateDuration, queryDuration > 0, candidateDuration > 0 {
            let gap = abs(queryDuration - candidateDuration)
            if gap <= 5 { total += 0.06 }
            else if gap > 30 { total -= min(0.45, (gap - 30) / 240) }
        }
        return max(0, min(1, total))
    }

    /// 낱말 겹침.
    ///
    /// 짧은 쪽만 기준으로 재면(`shared / min`) 짧은 제목이 긴 제목을 전부 통과한다.
    /// 실제로 `Chopin — Nocturne in E flat major`를 찾다가 다른 아티스트의 `Nocturne`
    /// 한 곡에 1.0이 붙었고, 문턱을 넘어 재생될 뻔했다. 양쪽 길이를 함께 세는 Dice를
    /// 주로 쓰고, `제목`과 `제목 (Remix)`가 지나치게 벌어지지 않도록 짧은 쪽 기준을
    /// 조금만 섞는다.
    private static func overlap(_ left: [String], _ right: [String]) -> Double {
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let leftSet = Set(left), rightSet = Set(right)
        let shared = Double(leftSet.intersection(rightSet).count)
        let dice = 2 * shared / Double(leftSet.count + rightSet.count)
        let containment = shared / Double(min(leftSet.count, rightSet.count))
        return dice * 0.75 + containment * 0.25
    }

    /// 이 점수 아래로는 재생하지 않는다. 엉뚱한 곡을 조용히 틀어 주는 것이 아무것도
    /// 틀지 않는 것보다 나쁘다 — 사용자는 자기가 고른 곡을 듣고 있다고 믿기 때문이다.
    static let acceptanceThreshold = 0.62
    /// 이 위로는 아무 말 없이 재생한다. 사이 구간은 화면에 "다른 음원으로 재생 중"이라고
    /// 적어 둔다.
    static let confidentThreshold = 0.8
}

// MARK: - HTTP 공통

/// 세 소스가 같은 방식으로 JSON을 읽게 하는 최소한의 것.
enum MusicHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    static func json(_ url: URL) async throws -> Any {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw MusicSourceError.badResponse("HTTP 응답이 아닙니다")
        }
        guard (200..<300).contains(http.statusCode) else {
            // 실패한 이유가 본문에 적혀 있는 경우가 많다. 상태 코드만 보여 주면
            // "왜 안 되는지"를 사용자가 알 수 없다.
            let message = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { ($0 as? [String: Any])?["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String } ?? ""
            if http.statusCode == 403, message.localizedCaseInsensitiveContains("quota") {
                throw MusicSourceError.quotaExceeded
            }
            throw MusicSourceError.http(http.statusCode, message)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func object(_ url: URL) async throws -> [String: Any] {
        guard let value = try await json(url) as? [String: Any] else {
            throw MusicSourceError.badResponse("객체가 아닙니다")
        }
        return value
    }
}
