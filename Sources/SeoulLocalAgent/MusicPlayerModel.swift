import Foundation
import AVFoundation
import AppKit
import Combine
import MediaPlayer

// MARK: - 상태

enum MusicPlayerStatus: Equatable {
    case idle
    /// 광고 없는 음원을 찾는 중. 이 상태가 화면에 보이는 것이 중요하다 — 누르고 나서
    /// 소리가 나기까지 몇 초가 걸릴 수 있고, 그동안 아무 말이 없으면 고장으로 보인다.
    case resolving(String)
    case buffering
    case playing
    case paused
    case failed(String)

    var isActive: Bool {
        switch self {
        case .playing, .buffering, .resolving: true
        case .idle, .paused, .failed: false
        }
    }
}

/// 지금 소리가 어디서 나는가.
///
/// 화면이 이 값을 그대로 보여 준다. 폴백으로 넘어간 곡에는 광고가 붙을 수 있고,
/// 그 사실을 숨기지 않는 것이 이 기능의 조건이다.
enum MusicRoute: Equatable {
    case none
    /// 내 파일·Audius·Internet Archive. `AVPlayer`가 직접 연다. 광고가 끼어들 자리가
    /// 구조적으로 없다.
    case adFree
    /// YouTube 임베드 플레이어. 광고 없는 음원을 찾지 못한 곡만 여기로 온다.
    case youtube
}

enum MusicSearchScope: String, CaseIterable, Identifiable, Sendable {
    case youtube, local, free

    var id: String { rawValue }

    var korean: String {
        switch self {
        case .youtube: "YouTube"
        case .local: "내 음악"
        case .free: "무료 음원"
        }
    }

    var explanation: String {
        switch self {
        case .youtube: "YouTube에서 찾습니다. 재생은 광고 없는 음원으로 대신합니다."
        case .local: "이 Mac에 있는 파일에서 찾습니다. 찾은 것은 전부 바로 재생됩니다."
        case .free: "Audius와 Internet Archive에서 찾습니다. 찾은 것은 전부 바로 재생됩니다."
        }
    }
}

// MARK: - 플레이어

/// 음악 탭 전체의 상태와 재생.
///
/// 재생은 `AVPlayer` 하나로 한다. 웹뷰가 없고, 임베드 플레이어가 없고, 따라서 광고가
/// 끼어들 자리가 구조적으로 없다. 소리의 출처는 언제나 셋 중 하나다 — 내 파일,
/// Audius, Internet Archive.
@MainActor
final class MusicPlayerModel: ObservableObject {

    // MARK: 보관함

    @Published private(set) var library: MusicLibrary
    private let store: MusicLibraryStore
    private var saveTask: Task<Void, Never>?

    // MARK: 재생

    @Published private(set) var status: MusicPlayerStatus = .idle
    @Published private(set) var currentTrack: Track?
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?
    /// 사용자가 슬라이더를 잡고 있는 동안에는 재생 위치가 손을 밀어내지 않아야 한다.
    @Published var isScrubbing = false
    /// 건너뛴 곡처럼 잠깐 알려 주고 사라져야 하는 말.
    @Published var notice: String?

    @Published private(set) var route: MusicRoute = .none
    /// 광고 없는 음원을 못 찾은 곡을 YouTube로 넘길지. 끄면 그런 곡은 재생하지 않는다.
    @Published var allowsYouTubeFallback: Bool {
        didSet {
            UserDefaults.standard.set(allowsYouTubeFallback, forKey: "musicYouTubeFallback")
            if !allowsYouTubeFallback, route == .youtube { stop() }
        }
    }
    /// 마지막 수단. 처음 필요할 때까지 웹뷰를 만들지 않는다.
    let embed = YouTubeEmbedPlayer()

    private let player = AVPlayer()
    /// 후보를 들어 보는 용도의 두 번째 플레이어. 본 재생과 섞이면 어느 소리가 어느
    /// 곡인지 알 수 없으므로, 미리 듣기를 시작하면 본 재생은 멈춘다.
    private let previewPlayer = AVPlayer()
    @Published private(set) var previewingID: String?
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []
    /// 앞선 요청이 늦게 끝나 방금 고른 곡을 덮어쓰는 것을 막는다. 음원 찾기는 몇 초가
    /// 걸리므로 그사이에 사용자가 다른 곡을 누르는 일이 실제로 일어난다.
    private var playRequest = UUID()

    // MARK: 순서

    /// `library.queue`의 인덱스를 재생 순서대로 늘어놓은 것. 셔플은 대기열을 섞는 것이
    /// 아니라 이 순서만 섞는다 — 화면의 대기열은 내가 넣은 순서 그대로 보여야 한다.
    private var playOrder: [Int] = []
    private var orderPosition = 0

    // MARK: 소스

    private let localIndex = LocalMusicIndex()
    private let configuration = YouTubeConfigurationStore()
    private let audius = AudiusSource()
    private let archive = InternetArchiveSource()
    @Published private(set) var youtubeAPIKey: String?
    @Published var musicOnlySearch: Bool {
        didSet { UserDefaults.standard.set(musicOnlySearch, forKey: "musicOnlySearch") }
    }

    private var localSource: LocalMusicSource { LocalMusicSource(index: localIndex) }
    private var youtube: YouTubeCatalogSource { YouTubeCatalogSource(apiKey: youtubeAPIKey, musicOnly: musicOnlySearch) }
    private var resolver: PlaybackResolver { PlaybackResolver(local: localSource) }

    var isYouTubeConfigured: Bool { youtubeAPIKey != nil }
    var configurationFileURL: URL { configuration.debugURL }
    var libraryFileURL: URL { store.debugURL }

    // MARK: 검색

    @Published var query: String
    @Published var scope: MusicSearchScope = .youtube
    @Published private(set) var searchResults: [Track] = []
    @Published private(set) var isSearching = false
    @Published var searchError: String?
    private var searchTask: Task<Void, Never>?

    // MARK: 색인·가져오기·일괄 음원 찾기

    @Published private(set) var localTrackCount = 0
    @Published private(set) var scanStatus: String?
    @Published private(set) var importStatus: String?
    @Published private(set) var isImporting = false
    @Published private(set) var resolveStatus: String?
    private var resolveTask: Task<Void, Never>?

    // MARK: 시작

    /// 앱이 끝날 때 마지막으로 한 번 저장하기 위한 것. `PrintModel.current`와
    /// 같은 이유로 둔다 — `applicationWillTerminate`은 뷰 트리 밖이라 컨트롤러를
    /// 붙잡을 방법이 없다.
    static private(set) weak var current: MusicPlayerModel?

    init(store: MusicLibraryStore = MusicLibraryStore()) {
        self.store = store
        let loaded = store.load()
        self.library = loaded
        self.query = loaded.lastQuery
        self.musicOnlySearch = UserDefaults.standard.object(forKey: "musicOnlySearch") as? Bool ?? true
        self.allowsYouTubeFallback = UserDefaults.standard.object(forKey: "musicYouTubeFallback") as? Bool ?? true
        self.youtubeAPIKey = configuration.load()

        player.volume = Float(loaded.volume)
        player.actionAtItemEnd = .pause
        rebuildOrder()
        // 마지막에 듣던 곡을 화면에 올려 두되, 소리는 내지 않는다. 앱을 열자마자
        // 음악이 나오는 것은 거의 언제나 놀라는 일이다.
        if let id = loaded.currentTrackID, let track = loaded.track(id) {
            currentTrack = track
            duration = track.duration
            position = loaded.resumePosition
            status = .paused
        }
        installObservers()
        installEmbedBridge()
        configureRemoteCommands()
        Self.current = self
        Task { await refreshLocalCount() }
        // `--section`과 같은 이유다: 창을 눌러 보지 않고도 이 화면이 실제로 무엇을
        // 그리는지 확인할 수 있어야 한다. 검색만 하고 재생은 하지 않는다 — 확인하려고
        // 남의 Mac에서 소리를 내지는 않는다.
        if let index = CommandLine.arguments.firstIndex(of: "--music-query"),
           index + 1 < CommandLine.arguments.count {
            query = CommandLine.arguments[index + 1]
            if let scopeIndex = CommandLine.arguments.firstIndex(of: "--music-scope"),
               scopeIndex + 1 < CommandLine.arguments.count,
               let requested = MusicSearchScope(rawValue: CommandLine.arguments[scopeIndex + 1]) {
                scope = requested
            } else {
                scope = .free
            }
            Task { @MainActor in self.runSearch() }
        }
    }

    deinit {
        // `deinit`은 어느 스레드에서나 불릴 수 있어 메인 격리된 정리를 여기서 할 수
        // 없다. 관찰자는 앱이 끝날 때 함께 사라지고, 앱이 살아 있는 동안 이 모델은
        // 하나뿐이라 실제로 해제되는 경로가 없다.
    }

    // MARK: 저장

    /// 여러 번의 작은 변경을 한 번의 쓰기로 모은다. 좋아요를 연달아 누를 때마다
    /// 파일을 통째로 다시 쓰면 디스크만 갈린다.
    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        var snapshot = library
        snapshot.resumePosition = position
        snapshot.lastQuery = query
        try? store.save(snapshot)
    }

    // MARK: 관찰

    private func installObservers() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }

    }

    /// 지금 재생 중인 아이템 하나만 관찰한다.
    ///
    /// 알림 이름으로 전역 관찰을 걸고 `note.object`로 걸러 내는 쪽이 흔하지만, 그러면
    /// `Notification`을 메인 격리 안으로 넘겨야 하고 그 값은 `Sendable`이 아니다.
    /// 알림을 아이템에 묶어 두면 클로저 밖으로 나가는 값이 문자열 하나뿐이 된다.
    private func observeItem(_ item: AVPlayerItem) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackFinished() }
            },
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] note in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                    .localizedDescription ?? "재생이 끊겼습니다"
                MainActor.assumeIsolated { self?.playbackFailed(message) }
            }
        ]
    }

    /// 임베드 플레이어가 보내오는 것을 앱의 상태로 옮긴다. `AVPlayer` 쪽과 같은 값을
    /// 채우므로, 화면은 어느 경로인지 몰라도 같은 슬라이더와 같은 시간을 그린다.
    private func installEmbedBridge() {
        embed.onState = { [weak self] state in
            guard let self, self.route == .youtube else { return }
            switch state {
            case .playing: self.status = .playing; self.updateNowPlaying()
            case .paused: self.status = .paused; self.updateNowPlaying()
            case .buffering: self.status = .buffering
            case .ended: self.trackFinished()
            case .unstarted, .cued: break
            }
        }
        embed.onTime = { [weak self] time, duration in
            guard let self, self.route == .youtube else { return }
            if !self.isScrubbing { self.position = time }
            if duration > 0 { self.duration = duration }
        }
        embed.onFailure = { [weak self] message in
            guard let self, self.route == .youtube else { return }
            self.status = .failed(message)
        }
    }

    private func tick(_ time: CMTime) {
        guard route == .adFree else { return }
        if !isScrubbing, time.isNumeric { position = CMTimeGetSeconds(time) }
        if let item = player.currentItem {
            if item.duration.isNumeric {
                let seconds = CMTimeGetSeconds(item.duration)
                if seconds.isFinite, seconds > 0 { duration = seconds }
            }
            if item.status == .failed {
                playbackFailed(item.error?.localizedDescription ?? "이 음원을 열지 못했습니다")
                return
            }
        }
        switch player.timeControlStatus {
        case .playing where status != .playing:
            status = .playing
            updateNowPlaying()
        case .waitingToPlayAtSpecifiedRate where status == .playing:
            status = .buffering
        default: break
        }
    }

    // MARK: 재생 제어

    /// 목록을 통째로 대기열로 삼고 한 곡부터 시작한다. Spotify에서 앨범의 한 곡을
    /// 누르면 그 앨범이 대기열이 되는 것과 같다.
    func play(_ tracks: [Track], startingAt index: Int, shuffled: Bool? = nil) {
        guard !tracks.isEmpty else { return }
        library.remember(tracks)
        library.queue = tracks.map(\.id)
        if let shuffled { library.shuffle = shuffled }
        library.queueIndex = min(max(0, index), tracks.count - 1)
        rebuildOrder()
        startPlayback(at: library.queueIndex ?? 0, autoAdvanced: false)
        saveSoon()
    }

    func playNow(_ track: Track) { play([track], startingAt: 0) }

    /// 지금 곡 바로 다음에 끼워 넣는다.
    func playNext(_ track: Track) {
        library.remember(track)
        let insertAt = (library.queueIndex.map { $0 + 1 }) ?? library.queue.count
        library.queue.insert(track.id, at: min(insertAt, library.queue.count))
        rebuildOrder()
        notice = "다음에 재생: \(track.title)"
        saveSoon()
    }

    func enqueue(_ track: Track) {
        library.remember(track)
        library.queue.append(track.id)
        rebuildOrder()
        notice = "대기열에 넣었습니다: \(track.title)"
        saveSoon()
        if currentTrack == nil { startPlayback(at: library.queue.count - 1, autoAdvanced: false) }
    }

    func enqueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        library.remember(tracks)
        library.queue.append(contentsOf: tracks.map(\.id))
        rebuildOrder()
        notice = "대기열에 \(tracks.count)곡을 넣었습니다"
        saveSoon()
    }

    func removeFromQueue(at offsets: IndexSet) {
        let currentID = library.currentTrackID
        library.queue.remove(atOffsets: offsets)
        library.queueIndex = currentID.flatMap { library.queue.firstIndex(of: $0) }
        rebuildOrder()
        saveSoon()
    }

    func moveInQueue(from offsets: IndexSet, to destination: Int) {
        let currentID = library.currentTrackID
        library.queue.move(fromOffsets: offsets, toOffset: destination)
        library.queueIndex = currentID.flatMap { library.queue.firstIndex(of: $0) }
        rebuildOrder()
        saveSoon()
    }

    func clearQueue() {
        stop()
        library.queue = []
        library.queueIndex = nil
        rebuildOrder()
        saveSoon()
    }

    func jumpInQueue(to index: Int) {
        guard library.queue.indices.contains(index) else { return }
        startPlayback(at: index, autoAdvanced: false)
    }

    func togglePlayPause() {
        switch status {
        case .playing, .buffering:
            if route == .youtube { embed.pause() } else { player.pause() }
            status = .paused
            updateNowPlaying()
            saveSoon()
        case .paused:
            // 마지막에 듣던 곡을 복원만 해 둔 상태라면 아직 아무것도 열려 있지 않다.
            if route == .youtube {
                embed.play()
                status = .playing
                updateNowPlaying()
            } else if player.currentItem == nil, let index = library.queueIndex {
                startPlayback(at: index, autoAdvanced: false, from: position)
            } else {
                player.play()
                status = .playing
                updateNowPlaying()
            }
        case .idle, .failed:
            if let index = library.queueIndex ?? (library.queue.isEmpty ? nil : 0) {
                startPlayback(at: index, autoAdvanced: false)
            }
        case .resolving:
            break
        }
    }

    func next() { advance(auto: false) }

    func previous() {
        // 3초를 넘겼으면 처음으로. 물리 CD 플레이어부터 이어져 온 규칙이고, 사람들이
        // 실제로 기대하는 동작이다.
        if position > 3 {
            seek(to: 0)
            return
        }
        guard !playOrder.isEmpty else { return }
        guard let target = MusicQueueOrder.previous(
            from: orderPosition, count: playOrder.count, repeatMode: library.repeatMode
        ) else {
            seek(to: 0)
            return
        }
        orderPosition = target
        startPlayback(at: playOrder[target], autoAdvanced: false)
    }

    func seek(to seconds: TimeInterval) {
        position = seconds
        if route == .youtube {
            embed.seek(to: seconds)
        } else {
            player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updateNowPlaying()
    }

    func stop() {
        playRequest = UUID()
        player.pause()
        player.replaceCurrentItem(with: nil)
        embed.stop()
        route = .none
        status = .idle
        currentTrack = nil
        position = 0
        duration = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    func setVolume(_ value: Double) {
        library.volume = min(1, max(0, value))
        player.volume = Float(library.volume)
        embed.setVolume(library.volume)
        saveSoon()
    }

    func toggleShuffle() {
        library.shuffle.toggle()
        rebuildOrder()
        saveSoon()
    }

    func cycleRepeat() {
        library.repeatMode = library.repeatMode.next
        saveSoon()
    }

    // MARK: 순서

    private func rebuildOrder() {
        playOrder = MusicQueueOrder.order(
            count: library.queue.count,
            shuffle: library.shuffle,
            current: library.queueIndex
        )
        orderPosition = library.shuffle ? 0 : (library.queueIndex ?? 0)
    }

    private func trackFinished() {
        if library.repeatMode == .one, let index = library.queueIndex {
            startPlayback(at: index, autoAdvanced: true)
            return
        }
        advance(auto: true)
    }

    private func advance(auto: Bool) {
        guard !playOrder.isEmpty else { stop(); return }
        guard let target = MusicQueueOrder.next(
            from: orderPosition, count: playOrder.count, repeatMode: library.repeatMode
        ) else {
            // 끝났다. 멈추되 대기열은 그대로 둔다 — 다시 누르면 처음부터 간다.
            if route == .youtube { embed.pause() } else { player.pause() }
            status = .paused
            seek(to: 0)
            return
        }
        // 한 바퀴를 돌아 다시 시작할 때는 순서를 새로 섞는다. 같은 셔플을 두 번 도는
        // 것은 셔플이라기보다 정해진 순서다.
        if target == 0, library.shuffle { rebuildOrder() }
        orderPosition = target
        startPlayback(at: playOrder[target], autoAdvanced: auto)
    }

    // MARK: 한 곡을 실제로 트는 일

    private func startPlayback(at queueIndex: Int, autoAdvanced: Bool, from offset: TimeInterval = 0) {
        guard library.queue.indices.contains(queueIndex),
              let track = library.track(library.queue[queueIndex]) else {
            stop()
            return
        }
        library.queueIndex = queueIndex
        if let at = playOrder.firstIndex(of: queueIndex) { orderPosition = at }
        currentTrack = track
        duration = track.duration
        position = offset

        let request = UUID()
        playRequest = request

        if let url = track.asset?.streamURL {
            attach(url, track: track, from: offset)
            return
        }

        status = .resolving(track.title)
        Task { [weak self] in
            guard let self else { return }
            let asset = await self.resolver.resolve(track)
            guard self.playRequest == request else { return }
            self.library.attach(asset, to: track.id)
            let updated = self.library.track(track.id) ?? track
            self.currentTrack = updated
            self.saveSoon()
            if let url = asset?.streamURL {
                self.attach(url, track: updated, from: offset)
            } else if self.canFallBack(updated) {
                self.attachYouTube(updated, from: offset)
            } else {
                self.unplayable(updated, autoAdvanced: autoAdvanced)
            }
        }
    }

    /// 이 곡을 YouTube로 넘길 수 있는가. YouTube에서 찾은 곡이어야 하고, 폴백이
    /// 켜져 있어야 한다.
    private func canFallBack(_ track: Track) -> Bool {
        allowsYouTubeFallback && track.origin == .youtube
    }

    private func attach(_ url: URL, track: Track, from offset: TimeInterval) {
        embed.stop()
        route = .adFree
        let item = AVPlayerItem(url: url)
        observeItem(item)
        player.replaceCurrentItem(with: item)
        player.volume = Float(library.volume)
        if offset > 1 {
            player.seek(to: CMTime(seconds: offset, preferredTimescale: 600))
        }
        player.play()
        status = .buffering
        library.notePlayed(track)
        saveSoon()
        updateNowPlaying()
    }

    /// 마지막 수단으로 YouTube에 맡긴다. 여기까지 온 곡에는 광고가 붙을 수 있고,
    /// 화면이 그 사실을 계속 표시한다.
    private func attachYouTube(_ track: Track, from offset: TimeInterval) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        route = .youtube
        status = .buffering
        duration = track.duration
        embed.load(videoID: track.originID, startAt: offset)
        embed.setVolume(library.volume)
        library.notePlayed(track)
        saveSoon()
        updateNowPlaying()
    }

    /// 광고 없이 들을 방법을 못 찾은 곡. 조용히 넘기지 않고 왜 넘겼는지 남긴다.
    private func unplayable(_ track: Track, autoAdvanced: Bool) {
        notice = allowsYouTubeFallback
            ? "「\(track.title)」은 광고 없이 들을 수 있는 음원도, 재생 가능한 YouTube 영상도 없어 건너뜁니다."
            : "「\(track.title)」은 광고 없이 들을 수 있는 음원을 찾지 못해 건너뜁니다. 설정 › 음악에서 YouTube 폴백을 켜면 재생할 수 있습니다."
        // 대기열에 재생 가능한 곡이 하나도 없으면 무한히 돌 수 있다. 남은 곡 수만큼만
        // 넘긴다.
        let remaining = library.queue.filter { library.track($0)?.searchedWithoutResultAt == nil }.count
        if remaining > 0 {
            advance(auto: true)
        } else {
            player.pause()
            status = .failed("이 대기열에는 광고 없이 들을 수 있는 곡이 없습니다.")
        }
    }

    private func playbackFailed(_ message: String) {
        status = .failed(message)
        // 음원 주소가 죽은 경우가 대부분이다(Audius의 서명은 시간이 지나면 만료된다).
        // 붙여 둔 음원을 떼어 다음 재생 때 다시 찾게 한다.
        if let track = currentTrack, track.asset?.isManual == false, track.asset?.provider != .localFile {
            library.attach(nil, to: track.id)
            saveSoon()
        }
    }

    // MARK: 좋아요·플레이리스트

    func toggleLike(_ track: Track) {
        library.toggleLike(track)
        if currentTrack?.id == track.id { currentTrack = library.track(track.id) }
        saveSoon()
    }

    func isLiked(_ track: Track) -> Bool { library.isLiked(track.id) }

    @discardableResult
    func createPlaylist(named name: String, with tracks: [Track] = []) -> MusicPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var playlist = MusicPlaylist(name: trimmed.isEmpty ? "새 플레이리스트" : trimmed)
        library.remember(tracks)
        playlist.trackIDs = tracks.map(\.id)
        library.playlists.append(playlist)
        saveSoon()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        guard let index = library.playlists.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        library.playlists[index].name = trimmed
        library.playlists[index].updatedAt = Date()
        saveSoon()
    }

    func deletePlaylist(_ id: UUID) {
        library.playlists.removeAll { $0.id == id }
        saveSoon()
    }

    func addToPlaylist(_ tracks: [Track], playlist id: UUID) {
        library.addTracks(tracks, toPlaylist: id)
        notice = "\(tracks.count)곡을 넣었습니다"
        saveSoon()
    }

    func removeFromPlaylist(_ offsets: IndexSet, playlist id: UUID) {
        library.removeTracks(at: offsets, fromPlaylist: id)
        saveSoon()
    }

    func moveInPlaylist(_ offsets: IndexSet, to destination: Int, playlist id: UUID) {
        library.moveTracks(from: offsets, to: destination, inPlaylist: id)
        saveSoon()
    }

    // MARK: 검색

    func runSearch() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchError = nil
        guard !text.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        let scope = self.scope
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let results: [Track]
                switch scope {
                case .youtube:
                    results = try await self.youtube.search(text, limit: 30)
                case .local:
                    results = try await self.localSource.search(text, limit: 60)
                case .free:
                    // 두 곳을 함께 물어 Audius를 앞에 둔다. Audius 쪽이 곡 단위이고
                    // 메타데이터가 정확해 목록이 읽기 쉽다.
                    async let audiusResults = try? self.audius.search(text, limit: 20)
                    async let archiveResults = try? self.archive.search(text, limit: 12)
                    results = await (audiusResults ?? []) + (archiveResults ?? [])
                }
                guard !Task.isCancelled else { return }
                self.library.remember(results)
                self.searchResults = results
                self.isSearching = false
                if results.isEmpty { self.searchError = "결과가 없습니다." }
            } catch {
                guard !Task.isCancelled else { return }
                self.searchResults = []
                self.isSearching = false
                self.searchError = error.localizedDescription
            }
        }
    }

    // MARK: YouTube 플레이리스트 가져오기

    func importPlaylist(_ text: String) {
        let reference = YouTubeReference.parse(text)
        guard case .playlist(let id) = reference else {
            importStatus = "YouTube 플레이리스트 주소나 id를 넣으세요. (`…/playlist?list=PL…`)"
            return
        }
        guard isYouTubeConfigured else {
            importStatus = "YouTube API 키가 필요합니다. 설정 › 음악에서 넣으세요."
            return
        }
        isImporting = true
        importStatus = "가져오는 중…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let imported = try await self.youtube.playlistTracks(id)
                self.library.remember(imported.tracks)
                var playlist = MusicPlaylist(
                    name: imported.title,
                    trackIDs: imported.tracks.map(\.id),
                    importedFrom: .init(source: .youtube, id: id, importedAt: Date())
                )
                // 같은 목록을 다시 가져오면 새로 만들지 않고 갈아 끼운다. 두 번 눌러
                // 같은 이름의 목록이 둘이 되는 것은 거의 언제나 실수다.
                if let existing = self.library.playlists.firstIndex(where: { $0.importedFrom?.id == id }) {
                    playlist.id = self.library.playlists[existing].id
                    playlist.createdAt = self.library.playlists[existing].createdAt
                    self.library.playlists[existing] = playlist
                } else {
                    self.library.playlists.append(playlist)
                }
                self.isImporting = false
                self.importStatus = imported.truncated
                    ? "\(imported.tracks.count)곡을 가져왔습니다. 목록이 길어 앞부분만 가져왔습니다."
                    : "\(imported.tracks.count)곡을 가져왔습니다."
                self.saveNow()
            } catch {
                self.isImporting = false
                self.importStatus = error.localizedDescription
            }
        }
    }

    // MARK: 음원 일괄 찾기

    /// 목록에 있는 곡들의 음원을 미리 찾아 둔다. 재생을 누른 뒤에 기다리는 대신
    /// 미리 알아 두면, 어느 곡이 들리고 어느 곡이 안 들리는지를 듣기 전에 알 수 있다.
    func resolveMissing(in tracks: [Track], force: Bool = false) {
        resolveTask?.cancel()
        let targets = tracks.filter { track in
            guard track.asset == nil else { return false }
            return force || track.searchedWithoutResultAt == nil
        }
        guard !targets.isEmpty else {
            resolveStatus = "찾을 것이 없습니다."
            return
        }
        resolveTask = Task { [weak self] in
            guard let self else { return }
            var found = 0
            for (offset, track) in targets.enumerated() {
                if Task.isCancelled { break }
                self.resolveStatus = "음원 찾는 중 \(offset + 1)/\(targets.count) · \(track.title)"
                let asset = await self.resolver.resolve(track)
                if asset != nil { found += 1 }
                self.library.attach(asset, to: track.id)
                if self.currentTrack?.id == track.id { self.currentTrack = self.library.track(track.id) }
            }
            self.resolveStatus = Task.isCancelled
                ? "중지했습니다."
                : "\(targets.count)곡 중 \(found)곡의 음원을 찾았습니다."
            self.saveNow()
        }
    }

    func cancelResolving() { resolveTask?.cancel() }

    /// 사용자가 파일을 직접 지정한다. 자동으로 못 찾은 곡을 살리는 마지막 길이고,
    /// 자동 매칭이 이것을 덮어쓰지 않는다.
    func assignFile(_ url: URL, to track: Track) {
        Task { [weak self] in
            guard let self else { return }
            let asset = await LocalMusicSource.manualAsset(for: url)
            self.library.remember(track)
            self.library.attach(asset, to: track.id)
            if self.currentTrack?.id == track.id { self.currentTrack = self.library.track(track.id) }
            self.notice = "「\(track.title)」에 파일을 연결했습니다."
            self.saveNow()
        }
    }

    func clearAsset(of track: Track) {
        library.attach(nil, to: track.id)
        var updated = library.track(track.id)
        updated?.searchedWithoutResultAt = nil
        if let updated { library.catalog[updated.id] = updated }
        if currentTrack?.id == track.id { currentTrack = library.track(track.id) }
        saveSoon()
    }

    // MARK: 내 음악 색인

    func refreshLocalCount() async {
        localTrackCount = await localIndex.count
    }

    func rescanLocalLibrary() {
        let folders = library.resolvedLocalFolders
        scanStatus = "폴더를 훑는 중…"
        Task { [weak self] in
            guard let self else { return }
            let count = await self.localIndex.rescan(folders: folders) { done, total in
                Task { @MainActor [weak self] in
                    self?.scanStatus = "태그 읽는 중 \(done)/\(total)"
                }
            }
            self.localTrackCount = count
            self.scanStatus = "\(count)곡을 찾았습니다."
        }
    }

    func addLocalFolder(_ url: URL) {
        guard !library.localFolders.contains(url.path) else { return }
        // 기본값(`~/Music`)만 쓰고 있던 상태에서 폴더를 처음 더하면 기본값이 사라진다.
        // 명시적으로 함께 넣어 준다.
        if library.localFolders.isEmpty {
            library.localFolders = library.resolvedLocalFolders.map(\.path)
        }
        library.localFolders.append(url.path)
        saveNow()
        rescanLocalLibrary()
    }

    func removeLocalFolder(_ path: String) {
        library.localFolders.removeAll { $0 == path }
        saveNow()
        rescanLocalLibrary()
    }

    // MARK: 설정

    /// `설정 › 음악`으로 데려가는 일. 설정 창의 탭 선택은 `AutomationController`가
    /// 쥐고 있고, 그 창은 이 화면의 뷰 트리 밖에 있어서 화면이 직접 고를 수 없다.
    var requestSettingsTab: (@MainActor () -> Void)?

    /// 색인에 있는 곡 전부. 대기열에 통째로 넣을 때만 쓴다 — 화면에 늘 들고 있기에는
    /// 수천 곡이 될 수 있다.
    func allLocalTracks() async -> [Track] {
        await localIndex.all.map(LocalMusicSource.track).sorted {
            ($0.artist, $0.album ?? "", $0.title) < ($1.artist, $1.album ?? "", $1.title)
        }
    }

    func saveYouTubeKey(_ key: String) -> String {
        do {
            try configuration.save(key)
            youtubeAPIKey = configuration.load()
            return youtubeAPIKey == nil ? "키를 비웠습니다." : "저장했습니다."
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: 시스템 재생 정보

    /// 미디어 키와 제어 센터. `AVPlayer`로 직접 재생하므로 이 앱이 곧 재생 중인
    /// 앱이고, F7/F8/F9와 잠금 화면이 그대로 동작한다.
    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resumeFromRemote() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pauseFromRemote() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func resumeFromRemote() {
        guard status != .playing else { return }
        togglePlayPause()
    }

    private func pauseFromRemote() {
        guard status.isActive else { return }
        togglePlayPause()
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: status == .playing ? 1.0 : 0.0
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let duration = duration ?? track.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = status == .playing ? .playing : .paused
    }

    // MARK: 개요 타일용

    var overviewValue: String {
        switch status {
        case .playing, .buffering: currentTrack?.title ?? "재생 중"
        case .resolving: "음원 찾는 중"
        case .paused: currentTrack?.title ?? "멈춤"
        case .failed: "재생 실패"
        case .idle: library.playlists.isEmpty ? "설정 필요" : "\(library.playlists.count)개 플레이리스트"
        }
    }

    var overviewDetail: String {
        if let track = currentTrack, status.isActive || status == .paused { return track.availabilityNote }
        if !isYouTubeConfigured { return "설정 › 음악에서 YouTube API 키를 넣으세요" }
        return "내 음악 \(localTrackCount)곡 · 좋아요 \(library.likedIDs.count)곡"
    }
}

// MARK: - 터미널 점검

/// `--music-check`. 화면을 열지 않고 음악 탭이 실제로 닿는 곳을 한 번씩 두드려 본다.
///
/// `--connection-check`와 같은 이유로 있다: 무엇이 되고 무엇이 안 되는지를
/// 창을 눌러 보지 않고 알 수 있어야 하고, 고정 문자열이 아니라 **실제 시도**여야 한다.
/// 소리는 내지 않는다 — 음량 0으로 열어서 재생 준비까지만 확인한다.
enum MusicConnectionCheck {
    @MainActor
    static func run() async -> Bool {
        var failed = false
        func report(_ ok: Bool?, _ title: String, _ detail: String) {
            let mark = ok == nil ? "⚠️" : (ok! ? "✅" : "❌")
            if ok == false { failed = true }
            print("\(mark) \(title): \(detail)")
        }

        // 1. YouTube — 검색과 메타데이터에만 쓴다.
        let configuration = YouTubeConfigurationStore()
        if let key = configuration.load() {
            let catalog = YouTubeCatalogSource(apiKey: key, musicOnly: true)
            do {
                let tracks = try await catalog.search("아이유", limit: 5)
                report(!tracks.isEmpty, "YouTube 검색", "\(tracks.count)건" + (tracks.first.map { " · 예: \($0.artist) — \($0.title)" } ?? ""))
            } catch {
                report(false, "YouTube 검색", error.localizedDescription)
            }
        } else {
            report(nil, "YouTube 검색", "API 키가 없습니다 (\(configuration.debugURL.path))")
        }

        // 2. 광고 없는 음원 세 곳.
        let index = LocalMusicIndex()
        let localCount = await index.count
        report(localCount > 0 ? true : nil, "내 음악 색인", "\(localCount)곡" + (localCount == 0 ? " · 앱의 `내 음악 › 다시 훑기`를 한 번 누르세요" : ""))

        let audius = AudiusSource()
        var audiusAsset: PlaybackAsset?
        do {
            let tracks = try await audius.search("lofi", limit: 5)
            audiusAsset = tracks.first?.asset
            report(!tracks.isEmpty, "Audius 검색", "\(tracks.count)건" + (tracks.first.map { " · 예: \($0.artist) — \($0.title)" } ?? ""))
        } catch {
            report(false, "Audius 검색", error.localizedDescription)
        }

        let archive = InternetArchiveSource()
        var archiveAsset: PlaybackAsset?
        do {
            let tracks = try await archive.search("chopin nocturne", limit: 5)
            archiveAsset = tracks.first?.asset
            report(!tracks.isEmpty, "Internet Archive 검색", "\(tracks.count)건" + (tracks.first.map { " · 예: \($0.title)" } ?? ""))
        } catch {
            report(false, "Internet Archive 검색", error.localizedDescription)
        }

        // 3. 실제로 열리는가. 주소를 만들 수 있는 것과 소리가 나는 것은 다른 문제다.
        for (name, asset) in [("Audius 재생", audiusAsset), ("Internet Archive 재생", archiveAsset)] {
            guard let asset, let url = asset.streamURL else {
                report(false, name, "재생 주소를 만들지 못했습니다")
                continue
            }
            let ready = await canOpen(url)
            report(ready, name, ready ? "재생 준비 완료 · \(asset.provenance)" : "열지 못했습니다 · \(url.absoluteString.prefix(80))")
        }

        // 4. 맞추기 — YouTube에서 고른 곡이 광고 없는 음원으로 이어지는가.
        let sample = Track(origin: .youtube, originID: "checkcheck1",
                           title: "Nocturne in E flat major", artist: "Chopin", duration: 270)
        let resolved = await PlaybackResolver(local: LocalMusicSource(index: index)).resolve(sample)
        // 못 찾는 것 자체는 고장이 아니다. 상용 음악은 무료로 합법적인 음원이 아예
        // 없는 경우가 많고, 그때는 폴백이 있는지 없는지가 답이 된다.
        report(resolved != nil ? true : nil, "음원 맞추기",
               resolved.map { "\($0.provider.displayName) · \($0.provenance) · 확신 \(String(format: "%.2f", $0.confidence))" }
               ?? "이 곡에 맞는 광고 없는 음원을 찾지 못했습니다 (폴백이 켜져 있으면 YouTube로 재생됩니다)")

        print("• 보관함: \(MusicLibraryStore().debugURL.path)")
        return !failed
    }

    /// 소리를 내지 않고 열리는지만 본다. 음량 0으로 준비 상태까지만 기다린다.
    private static func canOpen(_ url: URL) async -> Bool {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0
        player.isMuted = true
        for _ in 0..<40 {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return false
    }
}

// MARK: - 음원 후보

/// 한 곡에 붙일 수 있는 음원 하나. 어디서 왔고, 얼마나 닮았고, 들어 보면 어떤지.
struct MusicCandidate: Identifiable, Equatable, Sendable {
    var id: String { "\(asset.provider.rawValue):\(asset.id)" }
    var asset: PlaybackAsset
    var title: String
    var artist: String
    var duration: TimeInterval?
    var thumbnailURL: URL?
    /// 대상 곡과 얼마나 닮았는지, 0…1.
    var score: Double

    var isConfident: Bool { score >= MusicMatching.confidentThreshold }
    var isAcceptable: Bool { score >= MusicMatching.acceptanceThreshold }
}

extension MusicPlayerModel {

    /// 보관함이 실제로 들고 있는 곡 중 광고 없는 음원이 아직 없는 것들.
    ///
    /// 검색 결과는 세지 않는다 — 아직 내 것이 아닌 곡이고, 그것까지 세면 목록이
    /// 무엇을 하라는 목록인지 알 수 없게 된다.
    var tracksNeedingAsset: [Track] {
        var seen = Set<String>()
        var result: [Track] = []
        for id in library.playlists.flatMap(\.trackIDs) + library.likedIDs + library.queue {
            guard !seen.contains(id), let track = library.track(id), track.asset == nil else { continue }
            seen.insert(id)
            result.append(track)
        }
        return result
    }

    /// 한 곡에 붙일 수 있는 음원 후보를 세 곳에서 모아 점수 순으로.
    ///
    /// `query`를 비워 두면 곡의 아티스트와 제목으로 찾는다. 비워 두지 않는 것이
    /// 이 화면의 핵심이다 — 자동으로 못 찾은 곡은 대개 표기가 달라서 못 찾은 것이고
    /// (한글 제목 대 로마자, 앨범명 대 곡명), 사람이 다르게 쳐 보면 바로 나온다.
    func candidates(for track: Track, query: String = "") async -> [MusicCandidate] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(track.artist) \(track.title)".trimmingCharacters(in: .whitespaces)
            : query
        guard !text.isEmpty else { return [] }

        let local = localSource
        async let localTracks = local.rank(text, limit: 15)
        async let audiusTracks = try? audius.search(text, limit: 20)
        async let archiveTracks = try? archive.search(text, limit: 15)
        let found = await localTracks + (audiusTracks ?? []) + (archiveTracks ?? [])

        var seen = Set<String>()
        return found.compactMap { candidate -> MusicCandidate? in
            guard let asset = candidate.asset else { return nil }
            let key = "\(asset.provider.rawValue):\(asset.id)"
            guard seen.insert(key).inserted else { return nil }
            return MusicCandidate(
                asset: asset,
                title: candidate.title,
                artist: candidate.artist,
                duration: candidate.duration,
                thumbnailURL: candidate.thumbnailURL,
                score: MusicMatching.score(
                    queryTitle: track.title, queryArtist: track.artist, queryDuration: track.duration,
                    candidateTitle: candidate.title, candidateArtist: candidate.artist,
                    candidateDuration: candidate.duration
                )
            )
        }
        .sorted { $0.score > $1.score }
    }

    /// 사람이 고른 후보를 곡에 붙인다. 자동 매칭이 나중에 이것을 덮지 않는다.
    func choose(_ candidate: MusicCandidate, for track: Track) {
        var asset = candidate.asset
        asset.isManual = true
        asset.confidence = max(asset.confidence, candidate.score)
        asset.resolvedAt = Date()
        library.remember(track)
        library.attach(asset, to: track.id)
        if currentTrack?.id == track.id { currentTrack = library.track(track.id) }
        notice = "「\(track.title)」에 \(asset.provider.displayName) 음원을 연결했습니다."
        saveNow()
    }
}

// MARK: - 미리 듣기

extension MusicPlayerModel {
    func togglePreview(_ candidate: MusicCandidate) {
        if previewingID == candidate.id {
            stopPreview()
            return
        }
        guard let url = candidate.asset.streamURL else { return }
        // 사람은 두 곡을 동시에 들을 수 없다. 본 재생을 멈추고 후보만 들려준다.
        if status == .playing || status == .buffering { togglePlayPause() }
        previewPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        previewPlayer.volume = Float(library.volume)
        previewPlayer.play()
        previewingID = candidate.id
    }

    func stopPreview() {
        previewPlayer.pause()
        previewPlayer.replaceCurrentItem(with: nil)
        previewingID = nil
    }
}
