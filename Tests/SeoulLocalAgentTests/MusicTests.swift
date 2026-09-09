#if canImport(Testing)
import Testing
import Foundation
@testable import SeoulLocalAgent

/// 음악 탭에서 화면 없이 검사할 수 있는 것들.
///
/// 여기서 지키려는 것은 두 가지다. 하나는 **엉뚱한 곡을 틀지 않는 것** — 자동으로
/// 맞춘 음원이 다른 곡이면 사용자는 자기가 고른 곡을 듣고 있다고 믿은 채로 다른 곡을
/// 듣게 되고, 그것은 아무것도 틀지 않는 것보다 나쁘다. 다른 하나는 **보관함이 곧
/// 원본이라는 것** — 플레이리스트와 좋아요는 이 파일에만 있고, 계정도 서버도 없어서
/// 이 파일이 잘못되면 되살릴 곳이 없다.
@Suite("음악")
struct MusicTests {

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "music-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func youtubeTrack(_ id: String, title: String, artist: String, duration: TimeInterval? = 200) -> Track {
        Track(origin: .youtube, originID: id, title: title, artist: artist, duration: duration)
    }

    // MARK: 붙여 넣은 것이 무엇인지

    @Test("영상 주소·짧은 주소·shorts에서 영상 id를 꺼낸다")
    func parsesVideoReferences() {
        #expect(YouTubeReference.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == .video("dQw4w9WgXcQ"))
        #expect(YouTubeReference.parse("https://youtu.be/dQw4w9WgXcQ?t=42") == .video("dQw4w9WgXcQ"))
        #expect(YouTubeReference.parse("https://www.youtube.com/shorts/dQw4w9WgXcQ") == .video("dQw4w9WgXcQ"))
        #expect(YouTubeReference.parse("https://music.youtube.com/watch?v=dQw4w9WgXcQ") == .video("dQw4w9WgXcQ"))
        #expect(YouTubeReference.parse("dQw4w9WgXcQ") == .video("dQw4w9WgXcQ"))
    }

    @Test("재생목록을 보고 있는 주소는 목록으로 읽는다")
    func prefersPlaylistOverVideo() {
        // `watch?v=…&list=…`는 목록을 재생하고 있는 화면이다. 영상 하나만 가져오면
        // 사용자가 가져오려던 것을 잃는다.
        let reference = YouTubeReference.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabcdefghijklmno")
        #expect(reference == .playlist("PLabcdefghijklmno"))
        #expect(YouTubeReference.parse("https://www.youtube.com/playlist?list=OLAK5uy_abcdefghijk") == .playlist("OLAK5uy_abcdefghijk"))
    }

    @Test("주소도 id도 아니면 검색어다")
    func fallsBackToQuery() {
        #expect(YouTubeReference.parse("아이유 밤편지") == .query("아이유 밤편지"))
        // 11자지만 공백이 있으니 영상 id가 아니다.
        #expect(YouTubeReference.parse("hello world") == .query("hello world"))
    }

    // MARK: 길이

    @Test("ISO 8601 길이를 초로 읽는다")
    func parsesDurations() {
        #expect(YouTubeDuration.seconds("PT4M13S") == 253)
        #expect(YouTubeDuration.seconds("PT1H2M11S") == 3_731)
        #expect(YouTubeDuration.seconds("PT45S") == 45)
        #expect(YouTubeDuration.seconds("P0D") == 0)
        #expect(YouTubeDuration.seconds("hello") == nil)
    }

    @Test("Internet Archive의 두 가지 길이 표기를 모두 읽는다")
    func parsesArchiveLengths() {
        #expect(InternetArchiveSource.length("115.52") == 115.52)
        #expect(InternetArchiveSource.length("01:56") == 116)
        #expect(InternetArchiveSource.length("1:02:11") == 3_731)
        #expect(InternetArchiveSource.length("") == nil)
    }

    @Test("길이를 모르는 것은 0:00이 아니라 --:--")
    func formatsTime() {
        #expect(MusicFormat.time(nil) == "--:--")
        #expect(MusicFormat.time(253) == "4:13")
        #expect(MusicFormat.time(3_731) == "1:02:11")
        #expect(MusicFormat.time(.infinity) == "--:--")
    }

    // MARK: 제목 정리

    @Test("장식만 든 괄호는 지우고 내용이 든 괄호는 남긴다")
    func stripsDecorations() {
        #expect(MusicMatching.stripDecorations("Song Title (Official Video)").trimmingCharacters(in: .whitespaces) == "Song Title")
        #expect(MusicMatching.stripDecorations("Song [MV]").trimmingCharacters(in: .whitespaces) == "Song")
        // `(Live)`를 지우면 스튜디오 녹음과 구별할 수 없어진다.
        #expect(MusicMatching.stripDecorations("Song (Live)").contains("Live"))
        #expect(MusicMatching.stripDecorations("Song (feat. Someone)").contains("Someone"))
    }

    @Test("자동 생성 음악 채널의 `- Topic`을 떼어 낸다")
    func cleansChannelNames() {
        #expect(MusicMatching.artistFromChannel("IU - Topic") == "IU")
        #expect(MusicMatching.artistFromChannel("HYBE LABELS") == "HYBE LABELS")
    }

    @Test("`아티스트 - 제목` 꼴을 갈라 준다")
    func splitsArtistAndTitle() {
        let split = MusicMatching.splitArtistAndTitle("IU - Through the Night (Official Video)", channelArtist: "1theK")
        #expect(split.artist == "IU")
        #expect(split.title == "Through the Night")
        // 구분자가 없으면 채널 이름을 아티스트로 쓴다.
        let plain = MusicMatching.splitArtistAndTitle("Through the Night", channelArtist: "IU")
        #expect(plain.artist == "IU")
        #expect(plain.title == "Through the Night")
    }

    // MARK: 맞추기

    @Test("같은 곡은 문턱을 넘고, 다른 곡은 넘지 못한다")
    func scoresMatches() {
        let same = MusicMatching.score(
            queryTitle: "Through the Night", queryArtist: "IU", queryDuration: 268,
            candidateTitle: "Through The Night (Official Audio)", candidateArtist: "IU", candidateDuration: 267
        )
        #expect(same >= MusicMatching.acceptanceThreshold)

        let different = MusicMatching.score(
            queryTitle: "Through the Night", queryArtist: "IU", queryDuration: 268,
            candidateTitle: "Blueming", candidateArtist: "IU", candidateDuration: 217
        )
        #expect(different < MusicMatching.acceptanceThreshold)
    }

    @Test("제목이 같아도 길이가 크게 다르면 깎는다")
    func penalisesDurationGap() {
        // 같은 이름의 `1 hour loop`를 곡으로 착각하면, 누른 것과 전혀 다른 것을 듣게 된다.
        let song = MusicMatching.score(
            queryTitle: "Lofi Beats", queryArtist: "Someone", queryDuration: 180,
            candidateTitle: "Lofi Beats", candidateArtist: "Someone", candidateDuration: 182
        )
        let loop = MusicMatching.score(
            queryTitle: "Lofi Beats", queryArtist: "Someone", queryDuration: 180,
            candidateTitle: "Lofi Beats", candidateArtist: "Someone", candidateDuration: 3_600
        )
        #expect(song > loop)
        #expect(loop < MusicMatching.acceptanceThreshold)
    }

    @Test("짧은 제목이 긴 제목을 통째로 통과하지 못한다")
    func rejectsShortTitleSubsumption() {
        // 실제로 걸렸던 것: `Chopin — Nocturne in E flat major`를 찾다가 다른 아티스트의
        // `Nocturne` 한 곡이 문턱을 넘어 재생될 뻔했다. 짧은 쪽만 기준으로 겹침을 재면
        // 한 낱말짜리 제목이 무엇에나 1.0으로 맞는다.
        let score = MusicMatching.score(
            queryTitle: "Nocturne in E flat major", queryArtist: "Chopin", queryDuration: 270,
            candidateTitle: "Nocturne", candidateArtist: "Durmen", candidateDuration: 210
        )
        #expect(score < MusicMatching.acceptanceThreshold)
    }

    @Test("Internet Archive의 번호뿐인 제목은 파일 이름이나 항목 이름으로 대신한다")
    func repairsArchiveTitles() {
        // 아카이브의 파일 `title`은 `1`처럼 트랙 번호만 든 경우가 흔하다. 그대로 두면
        // 목록에 숫자만 늘어선다.
        #expect(InternetArchiveSource.displayTitle(fileTitle: "1", fileName: "nocturne-op9-no2.mp3", itemTitle: "Chopin Nocturnes") == "nocturne-op9-no2")
        // `1.mp3`·`2.mp3`처럼 번호뿐인 파일이 한 항목에 여럿 있으면 같은 이름의 줄이
        // 여럿 늘어선다. 번호를 붙여 구별한다.
        #expect(InternetArchiveSource.displayTitle(fileTitle: "", fileName: "03.mp3", itemTitle: "Chopin Nocturnes") == "Chopin Nocturnes — 03")
        #expect(InternetArchiveSource.displayTitle(fileTitle: "", fileName: "", itemTitle: "Chopin Nocturnes") == "Chopin Nocturnes")
        #expect(InternetArchiveSource.displayTitle(fileTitle: "Nocturne Op.9 No.2", fileName: "a.mp3", itemTitle: "X") == "Nocturne Op.9 No.2")
    }

    @Test("한쪽이 아티스트를 모르면 제목만으로 판단한다")
    func toleratesMissingArtist() {
        // Internet Archive는 업로더 이름밖에 없는 항목이 많다. 모르는 것을 틀린 것으로
        // 세면 그런 항목이 전부 탈락한다.
        let score = MusicMatching.score(
            queryTitle: "Nocturne in E flat major", queryArtist: "Chopin", queryDuration: 270,
            candidateTitle: "Nocturne in E flat major", candidateArtist: "", candidateDuration: 268
        )
        #expect(score >= MusicMatching.acceptanceThreshold)
    }

    // MARK: 파일 이름 읽기

    @Test("태그가 없는 파일도 이름에서 아티스트와 제목을 읽는다")
    func guessesFromFilename() {
        let numbered = LocalMusicIndex.guessFromFilename(URL(fileURLWithPath: "/Music/IU/Palette/03 - IU - Palette.mp3"))
        #expect(numbered.artist == "IU")
        #expect(numbered.title == "Palette")

        // 구분자가 없으면 상위의 상위 폴더를 아티스트로 본다(아티스트/앨범/파일).
        let plain = LocalMusicIndex.guessFromFilename(URL(fileURLWithPath: "/Music/IU/Palette/Palette.flac"))
        #expect(plain.artist == "IU")
        #expect(plain.title == "Palette")
    }

    // MARK: 보관함

    @Test("좋아요는 누른 순서대로 앞에 쌓이고 다시 누르면 빠진다")
    func togglesLikes() {
        var library = MusicLibrary()
        let first = youtubeTrack("aaaaaaaaaaa", title: "A", artist: "X")
        let second = youtubeTrack("bbbbbbbbbbb", title: "B", artist: "Y")
        library.toggleLike(first)
        library.toggleLike(second)
        #expect(library.likedIDs == [second.id, first.id])
        library.toggleLike(first)
        #expect(library.likedIDs == [second.id])
    }

    @Test("최근 재생은 중복 없이 최신이 앞이고 상한을 넘지 않는다")
    func capsRecents() {
        var library = MusicLibrary()
        for index in 0..<(MusicLibrary.recentLimit + 10) {
            library.notePlayed(youtubeTrack(String(format: "%011d", index), title: "T\(index)", artist: "A"))
        }
        #expect(library.recentIDs.count == MusicLibrary.recentLimit)
        let repeated = youtubeTrack("00000000005", title: "T5", artist: "A")
        library.notePlayed(repeated)
        #expect(library.recentIDs.first == repeated.id)
        #expect(library.recentIDs.filter { $0 == repeated.id }.count == 1)
    }

    @Test("같은 곡을 플레이리스트에 두 번 넣지 않는다")
    func deduplicatesPlaylistAdditions() {
        var library = MusicLibrary()
        let playlist = MusicPlaylist(name: "밤")
        library.playlists = [playlist]
        let track = youtubeTrack("ccccccccccc", title: "C", artist: "Z")
        library.addTracks([track], toPlaylist: playlist.id)
        library.addTracks([track], toPlaylist: playlist.id)
        #expect(library.playlists[0].trackIDs == [track.id])
    }

    @Test("아무도 가리키지 않는 곡은 저장할 때 버린다")
    func prunesUnreferencedTracks() {
        var library = MusicLibrary()
        let kept = youtubeTrack("ddddddddddd", title: "D", artist: "Z")
        let dropped = youtubeTrack("eeeeeeeeeee", title: "E", artist: "Z")
        library.remember([kept, dropped])
        library.toggleLike(kept)
        library.pruneCatalog()
        #expect(library.track(kept.id) != nil)
        #expect(library.track(dropped.id) == nil)
    }

    @Test("찾아 둔 음원은 같은 곡을 다시 만나도 잃지 않는다")
    func keepsResolvedAssetAcrossSearches() {
        var library = MusicLibrary()
        let track = youtubeTrack("fffffffffff", title: "F", artist: "Z")
        library.remember(track)
        library.attach(
            PlaybackAsset(provider: .audius, id: "abc", title: "F", artist: "Z", duration: 200,
                          confidence: 0.9, resolvedAt: Date(), isManual: false),
            to: track.id
        )
        // 검색 결과에 같은 곡이 다시 떴다. 음원이 없는 새 값이 덮어쓰면, 찾는 데 몇
        // 초씩 걸린 결과가 검색 한 번에 날아간다.
        library.remember(youtubeTrack("fffffffffff", title: "F", artist: "Z"))
        #expect(library.track(track.id)?.asset?.id == "abc")
    }

    @Test("사람이 고른 파일은 자동 매칭이 덮어쓰지 않는다")
    func manualAssetWins() {
        var library = MusicLibrary()
        let track = youtubeTrack("ggggggggggg", title: "G", artist: "Z")
        library.remember(track)
        let manual = PlaybackAsset(provider: .localFile, id: "/Music/G.mp3", title: "G", artist: "Z",
                                   duration: 200, confidence: 1, resolvedAt: Date(), isManual: true)
        library.attach(manual, to: track.id)
        let automatic = PlaybackAsset(provider: .audius, id: "zzz", title: "G", artist: "Z",
                                      duration: 200, confidence: 0.99, resolvedAt: Date(), isManual: false)
        library.attach(automatic, to: track.id)
        #expect(library.track(track.id)?.asset?.id == "/Music/G.mp3")
    }

    // MARK: 음원 주소

    @Test("제공자마다 재생 주소를 스스로 만든다")
    func buildsStreamURLs() {
        let local = PlaybackAsset(provider: .localFile, id: "/Music/A B.mp3", title: "", artist: "",
                                  duration: nil, confidence: 1, resolvedAt: Date(), isManual: true)
        #expect(local.streamURL?.isFileURL == true)
        #expect(local.streamURL?.path == "/Music/A B.mp3")

        let audius = PlaybackAsset(provider: .audius, id: "3oqjbGv", title: "", artist: "",
                                   duration: nil, confidence: 1, resolvedAt: Date(), isManual: false)
        #expect(audius.streamURL?.absoluteString.contains("/v1/tracks/3oqjbGv/stream") == true)

        // 파일 이름에 공백이 있어도 주소가 깨지지 않아야 한다.
        let archive = PlaybackAsset(provider: .internetArchive, id: "etude/Etude in A-flat major.mp3",
                                    title: "", artist: "", duration: nil, confidence: 1,
                                    resolvedAt: Date(), isManual: false)
        #expect(archive.streamURL?.absoluteString.hasPrefix("https://archive.org/download/etude/") == true)
        #expect(archive.streamURL?.absoluteString.contains(" ") == false)
    }

    // MARK: 저장

    @Test("저장하고 다시 읽으면 그대로다")
    func roundTripsLibrary() throws {
        let store = MusicLibraryStore(directory: temporaryDirectory())
        var library = MusicLibrary()
        let track = youtubeTrack("hhhhhhhhhhh", title: "H", artist: "Z")
        library.remember(track)
        library.toggleLike(track)
        library.playlists = [MusicPlaylist(name: "출근길", trackIDs: [track.id])]
        library.queue = [track.id]
        library.queueIndex = 0
        library.shuffle = true
        library.repeatMode = .one
        library.volume = 0.42

        try store.save(library)
        let reloaded = store.load()
        #expect(reloaded.likedIDs == [track.id])
        #expect(reloaded.playlists.first?.name == "출근길")
        #expect(reloaded.repeatMode == .one)
        #expect(reloaded.shuffle)
        #expect(abs(reloaded.volume - 0.42) < 0.0001)
        #expect(reloaded.track(track.id)?.title == "H")
    }

    @Test("보관함 파일은 소유자만 읽을 수 있다")
    func writesOwnerOnly() throws {
        let directory = temporaryDirectory()
        let store = MusicLibraryStore(directory: directory)
        try store.save(MusicLibrary())
        let attributes = try FileManager.default.attributesOfItem(atPath: store.debugURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)
    }

    @Test("읽을 수 없는 파일은 빈 보관함이 되고 앱을 막지 않는다")
    func survivesCorruptFile() throws {
        let directory = temporaryDirectory()
        let store = MusicLibraryStore(directory: directory)
        try Data("이건 JSON이 아닙니다".utf8).write(to: store.debugURL)
        #expect(store.load().playlists.isEmpty)
    }

    // MARK: 재생 순서

    @Test("셔플을 켜도 지금 듣는 곡이 맨 앞에 온다")
    func shuffleKeepsCurrentFirst() {
        // 그러지 않으면 셔플을 켜는 순간 듣던 곡이 순서 한가운데로 밀려나고, `이전`이
        // 방금 듣던 곡이 아니라 엉뚱한 곡으로 간다.
        for _ in 0..<20 {
            let order = MusicQueueOrder.order(count: 8, shuffle: true, current: 5)
            #expect(order.first == 5)
            #expect(Set(order) == Set(0..<8))
        }
    }

    @Test("셔플이 꺼져 있으면 순서는 대기열 그대로다")
    func plainOrder() {
        #expect(MusicQueueOrder.order(count: 4, shuffle: false, current: 2) == [0, 1, 2, 3])
        #expect(MusicQueueOrder.order(count: 0, shuffle: true, current: nil).isEmpty)
    }

    @Test("마지막 곡 다음은 전체 반복일 때만 처음으로 돌아간다")
    func nextAtEnd() {
        #expect(MusicQueueOrder.next(from: 1, count: 3, repeatMode: .off) == 2)
        #expect(MusicQueueOrder.next(from: 2, count: 3, repeatMode: .off) == nil)
        #expect(MusicQueueOrder.next(from: 2, count: 3, repeatMode: .all) == 0)
        // 한 곡 반복은 이 함수까지 오지 않는다(같은 곡을 다시 튼다). 와도 멈춘다.
        #expect(MusicQueueOrder.next(from: 2, count: 3, repeatMode: .one) == nil)
    }

    @Test("첫 곡의 이전은 전체 반복일 때만 마지막으로 간다")
    func previousAtStart() {
        #expect(MusicQueueOrder.previous(from: 1, count: 3, repeatMode: .off) == 0)
        #expect(MusicQueueOrder.previous(from: 0, count: 3, repeatMode: .off) == nil)
        #expect(MusicQueueOrder.previous(from: 0, count: 3, repeatMode: .all) == 2)
    }

    // MARK: 반복

    @Test("반복은 없음 → 전체 → 한 곡 순으로 돈다")
    func cyclesRepeatMode() {
        #expect(RepeatMode.off.next == .all)
        #expect(RepeatMode.all.next == .one)
        #expect(RepeatMode.one.next == .off)
    }
}
#endif
