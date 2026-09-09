import Foundation
import AVFoundation

// MARK: - 색인 한 줄

struct LocalMusicEntry: Codable, Sendable, Hashable {
    var path: String
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval?
    /// 파일이 바뀌었는지 보는 값. 경로만 보면 같은 이름으로 갈아 끼운 파일을 놓친다.
    var modified: Date
    var size: Int64
}

// MARK: - 색인

/// 이 Mac에 있는 음악 파일의 목록.
///
/// 재생 소스 중 유일하게 네트워크가 필요 없고, 광고가 없다는 것이 논쟁의 여지 없이
/// 참인 곳이다. 그래서 음원을 찾을 때 언제나 여기부터 본다.
///
/// 한 번 읽은 파일은 다시 읽지 않는다. `AVURLAsset`으로 태그를 읽는 것은 파일당 수
/// 밀리초지만, 수천 곡이면 매 실행 몇십 초가 되고 그동안 화면이 비어 있게 된다.
/// 경로·수정 시각·크기가 같으면 이전에 읽은 값을 그대로 쓴다.
actor LocalMusicIndex {
    static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "alac", "m4b", "caf", "mp4"
    ]

    private let url: URL
    private var entries: [String: LocalMusicEntry] = [:]
    private var loaded = false

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "music-local-index.json")
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder.musicDecoder.decode([LocalMusicEntry].self, from: data) else { return }
        entries = Dictionary(stored.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func persist() {
        try? LocalFileStorage.write(
            (try? JSONEncoder.musicEncoder.encode(Array(entries.values).sorted { $0.path < $1.path })) ?? Data(),
            to: url
        )
    }

    var count: Int {
        loadIfNeeded()
        return entries.count
    }

    var all: [LocalMusicEntry] {
        loadIfNeeded()
        return Array(entries.values)
    }

    /// 폴더들을 훑어 색인을 최신으로 만든다. 사라진 파일은 색인에서 빠진다.
    ///
    /// `progress`는 파일을 실제로 읽을 때만 부른다. 캐시에 맞은 파일까지 보고하면
    /// 진행 표시가 순식간에 지나가 아무 정보도 주지 못한다.
    func rescan(folders: [URL], progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> Int {
        loadIfNeeded()
        var found: [String: LocalMusicEntry] = [:]
        var candidates: [(URL, Date, Int64)] = []

        for folder in folders { candidates.append(contentsOf: Self.walk(folder)) }

        var toRead: [(URL, Date, Int64)] = []
        for (fileURL, modified, size) in candidates {
            let path = fileURL.path
            if let cached = entries[path], cached.modified == modified, cached.size == size {
                found[path] = cached
            } else {
                toRead.append((fileURL, modified, size))
            }
        }

        for (index, item) in toRead.enumerated() {
            progress(index + 1, toRead.count)
            found[item.0.path] = await Self.read(item.0, modified: item.1, size: item.2)
        }

        entries = found
        persist()
        return entries.count
    }

    /// 폴더 하나를 훑어 오디오 파일과 그 크기·수정 시각을 모은다.
    ///
    /// `FileManager`의 열거자는 `async` 문맥에서 반복할 수 없어(`makeIterator`가
    /// 비동기에서 막혀 있다) 동기 함수로 떼어 두었다. 어차피 파일 시스템을 훑는 일은
    /// 기다릴 것이 없는 일이라 비동기로 둘 이유도 없다.
    private nonisolated static func walk(_ folder: URL) -> [(URL, Date, Int64)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [(URL, Date, Int64)] = []
        for case let fileURL as URL in enumerator {
            guard audioExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            found.append((fileURL, values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0)))
        }
        return found
    }

    /// 태그를 읽는다. 태그가 없는 파일도 버리지 않고 파일 이름에서 읽어 낸다 —
    /// 직접 뜯어 넣은 파일에는 태그가 없는 경우가 흔하고, 그런 파일이 색인에서
    /// 통째로 빠지면 "내 음악에 있는데 안 나온다"가 된다.
    private static func read(_ fileURL: URL, modified: Date, size: Int64) async -> LocalMusicEntry {
        let asset = AVURLAsset(url: fileURL)
        var title = ""
        var artist = ""
        var album: String?
        var duration: TimeInterval?

        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                guard let key = item.commonKey else { continue }
                let value = try? await item.load(.stringValue)
                switch key {
                case .commonKeyTitle: title = value ?? title
                case .commonKeyArtist: artist = value ?? artist
                case .commonKeyAlbumName: album = value ?? album
                default: break
                }
            }
        }
        if let loaded = try? await asset.load(.duration), loaded.isNumeric {
            let seconds = CMTimeGetSeconds(loaded)
            if seconds.isFinite, seconds > 0 { duration = seconds }
        }

        if title.isEmpty || artist.isEmpty {
            let guessed = guessFromFilename(fileURL)
            if title.isEmpty { title = guessed.title }
            if artist.isEmpty { artist = guessed.artist }
        }
        return LocalMusicEntry(
            path: fileURL.path,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            modified: modified,
            size: size
        )
    }

    /// `01 - Artist - Title.mp3`, `Artist - Title.flac`, `Title.m4a`.
    static func guessFromFilename(_ fileURL: URL) -> (artist: String, title: String) {
        var name = fileURL.deletingPathExtension().lastPathComponent
        // 앞의 트랙 번호는 곡 이름이 아니다.
        if let range = name.range(of: #"^\s*\d{1,3}\s*[-._ ]\s*"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        let parts = name.components(separatedBy: " - ")
        if parts.count >= 2 {
            let artist = parts[0].trimmingCharacters(in: .whitespaces)
            let title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty, !title.isEmpty { return (artist, title) }
        }
        // 아티스트를 모르면 상위 폴더 이름을 쓴다. 음악 폴더는 대개 아티스트/앨범/파일이다.
        let parent = fileURL.deletingLastPathComponent()
        let grandparent = parent.deletingLastPathComponent().lastPathComponent
        return (grandparent.isEmpty ? "" : grandparent, name.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - 소스

/// 색인을 카탈로그이자 재생 소스로 감싼 것.
struct LocalMusicSource: MusicCatalogSource, MusicStreamSource {
    let kind = MusicCatalogKind.local
    let provider = PlaybackProviderKind.localFile
    let index: LocalMusicIndex

    func search(_ query: String, limit: Int = 50) async throws -> [Track] {
        let needle = MusicMatching.tokens(query)
        guard !needle.isEmpty else { return [] }
        let scored = await index.all.compactMap { entry -> (Double, Track)? in
            let haystack = MusicMatching.tokens("\(entry.artist) \(entry.title) \(entry.album ?? "")")
            let hits = needle.filter { token in haystack.contains { $0.hasPrefix(token) } }.count
            guard hits == needle.count else { return nil }
            // 제목이 짧을수록 정확히 그 곡일 가능성이 높다. 같은 낱말을 담은 30분짜리
            // 믹스보다 3분짜리 곡을 위로 올린다.
            return (Double(hits) / Double(max(1, haystack.count)), Self.track(entry))
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    /// 후보를 고를 때 쓰는 느슨한 검색. `search`는 친 낱말이 전부 맞아야 하지만,
    /// 여기서는 조금이라도 닮은 것을 점수 순으로 보여 줘야 한다 — 못 찾은 곡을 사람이
    /// 직접 고르는 화면에서는 "0건"보다 "닮은 것 다섯 개"가 훨씬 쓸모 있다.
    func rank(_ query: String, limit: Int = 15) async -> [Track] {
        let needle = MusicMatching.tokens(query)
        guard !needle.isEmpty else { return [] }
        let scored = await index.all.compactMap { entry -> (Double, Track)? in
            let haystack = MusicMatching.tokens("\(entry.artist) \(entry.title) \(entry.album ?? "")")
            guard !haystack.isEmpty else { return nil }
            let hits = needle.filter { token in haystack.contains { $0.hasPrefix(token) } }.count
            guard hits > 0 else { return nil }
            return (Double(hits) / Double(needle.count), Self.track(entry))
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    static func track(_ entry: LocalMusicEntry) -> Track {
        Track(
            origin: .local,
            originID: entry.path,
            title: entry.title.isEmpty ? (entry.path as NSString).lastPathComponent : entry.title,
            artist: entry.artist,
            album: entry.album,
            duration: entry.duration,
            asset: asset(entry, confidence: 1, manual: false)
        )
    }

    static func asset(_ entry: LocalMusicEntry, confidence: Double, manual: Bool) -> PlaybackAsset {
        PlaybackAsset(
            provider: .localFile,
            id: entry.path,
            title: entry.title,
            artist: entry.artist,
            duration: entry.duration,
            confidence: confidence,
            resolvedAt: Date(),
            isManual: manual
        )
    }

    func findAsset(title: String, artist: String, duration: TimeInterval?) async throws -> PlaybackAsset? {
        var best: (score: Double, entry: LocalMusicEntry)?
        for entry in await index.all {
            let score = MusicMatching.score(
                queryTitle: title, queryArtist: artist, queryDuration: duration,
                candidateTitle: entry.title, candidateArtist: entry.artist,
                candidateDuration: entry.duration
            )
            if score > (best?.score ?? 0) { best = (score, entry) }
        }
        guard let best, best.score >= MusicMatching.acceptanceThreshold else { return nil }
        return Self.asset(best.entry, confidence: best.score, manual: false)
    }

    /// 사용자가 파일을 직접 지정했을 때. 색인에 없어도 되고, 점수도 매기지 않는다 —
    /// 사람이 고른 것이 자동 매칭보다 언제나 옳다.
    static func manualAsset(for fileURL: URL) async -> PlaybackAsset {
        let asset = AVURLAsset(url: fileURL)
        var duration: TimeInterval?
        if let loaded = try? await asset.load(.duration), loaded.isNumeric {
            let seconds = CMTimeGetSeconds(loaded)
            if seconds.isFinite, seconds > 0 { duration = seconds }
        }
        let guessed = LocalMusicIndex.guessFromFilename(fileURL)
        return PlaybackAsset(
            provider: .localFile,
            id: fileURL.path,
            title: guessed.title,
            artist: guessed.artist,
            duration: duration,
            confidence: 1,
            resolvedAt: Date(),
            isManual: true
        )
    }
}
