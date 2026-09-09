import Foundation

/// YouTube에서 고른 곡을 **광고 없이 들을 수 있는 음원**으로 바꾸는 곳.
///
/// 순서가 곧 정책이다. 내 파일이 언제나 먼저다 — 네트워크가 필요 없고, 음질이 내가
/// 고른 그대로이며, 광고가 없다는 것이 논쟁의 여지 없이 참이다. 그다음이 Audius,
/// 그다음이 Internet Archive다. 셋 다 못 찾으면 **아무것도 재생하지 않는다.** 조용히
/// 비슷한 곡을 틀어 주는 것은 사용자가 자기가 고른 곡을 듣고 있다고 믿게 만들기 때문에
/// 아무것도 틀지 않는 것보다 나쁘다.
struct PlaybackResolver: Sendable {
    let local: LocalMusicSource
    var allowsAudius = true
    var allowsArchive = true

    private let audius = AudiusSource()
    private let archive = InternetArchiveSource()

    init(local: LocalMusicSource, allowsAudius: Bool = true, allowsArchive: Bool = true) {
        self.local = local
        self.allowsAudius = allowsAudius
        self.allowsArchive = allowsArchive
    }

    func resolve(_ track: Track) async -> PlaybackAsset? {
        // 이미 붙어 있으면 그대로 쓴다. 사람이 고른 것이면 더더욱 건드리지 않는다.
        if let asset = track.asset, asset.streamURL != nil { return asset }

        if let found = try? await local.findAsset(
            title: track.title, artist: track.artist, duration: track.duration
        ) {
            return found
        }

        // 네트워크 두 곳은 동시에 물어본다. 하나씩 하면 Internet Archive의 항목별
        // 메타데이터 왕복 때문에 한 곡에 몇 초씩 걸린다.
        async let audiusAsset: PlaybackAsset? = allowsAudius
            ? try? audius.findAsset(title: track.title, artist: track.artist, duration: track.duration)
            : nil
        async let archiveAsset: PlaybackAsset? = allowsArchive
            ? try? archive.findAsset(title: track.title, artist: track.artist, duration: track.duration)
            : nil

        let candidates = await [audiusAsset, archiveAsset].compactMap { $0 }
        return candidates.max { $0.confidence < $1.confidence }
    }
}
