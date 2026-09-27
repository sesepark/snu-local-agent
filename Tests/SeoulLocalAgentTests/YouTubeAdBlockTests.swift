import Testing
import Foundation
import WebKit
import AppKit
@testable import SeoulLocalAgent

@Suite("YouTube 광고 차단", .serialized)
struct YouTubeAdBlockTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "music-adblock-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("YouTube 도메인 경계를 검사하고 외부·HTTP 탐색을 거부한다")
    @MainActor func navigationBoundary() {
        for url in ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://youtube.com/embed/x", "https://r1.googlevideo.com/x", "about:blank"] {
            #expect(YouTubeEmbedPlayer.allowsNavigation(URL(string: url)))
        }
        for url in ["https://evilyoutube.com", "https://youtube.com.evil.example", "http://www.youtube.com", "file:///tmp/test", "javascript:alert(1)", "https://example.org"] {
            #expect(!YouTubeEmbedPlayer.allowsNavigation(URL(string: url)))
        }
        #expect(!YouTubeEmbedPlayer.allowsNavigation(nil))
    }

    @Test("공식 확장 해시·버전·라이선스와 필터를 확인한다")
    func authenticArchive() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try #require(YouTubeAdBlockArchive.bundledURL)
        let directory = try await YouTubeAdBlockArchive.extract(archive: archive, root: root)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "manifest.json"))) as? [String: Any])
        #expect(manifest["version"] as? String == YouTubeAdBlockArchive.version)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "rulesets/main/ublock-filters.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "rulesets/main/easylist.json").path))
        #expect(try String(contentsOf: directory.appending(path: "LICENSE.txt"), encoding: .utf8).contains("GNU GENERAL PUBLIC LICENSE"))
        // A damaged existing generated cache is reconstructed from the pinned archive.
        try Data("broken".utf8).write(to: directory.appending(path: "manifest.json"))
        let repaired = try await YouTubeAdBlockArchive.extract(archive: archive, root: root)
        #expect(repaired == directory)
        #expect(try Data(contentsOf: repaired.appending(path: "manifest.json")).count > 100)
    }

    @Test("변조된 확장은 압축 해제하거나 실행하지 않는다")
    func corruptArchive() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let bad = root.appending(path: "bad.zip")
        try Data("not-the-official-extension".utf8).write(to: bad)
        let output = root.appending(path: "output")
        do {
            _ = try await YouTubeAdBlockArchive.extract(archive: bad, root: output)
            Issue.record("변조된 확장을 허용했습니다")
        } catch { #expect(error.localizedDescription.contains("무결성")) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("광고 차단 기본값·변경·재생성 보존 및 누락 리소스 실패")
    @MainActor func defaultsAndFailure() async throws {
        let name = "music-adblock-defaults-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let adBlock = YouTubeAdBlock(defaults: defaults, archiveURL: nil)
        #expect(adBlock.enabled)
        do { try await adBlock.prepare(); Issue.record("확장 없이 성공했습니다") }
        catch { #expect(error.localizedDescription.contains("포함되어")) }
        if case .failed = adBlock.status {} else { Issue.record("차단 오류를 표시하지 않습니다") }
        adBlock.setEnabled(false)
        #expect(adBlock.status == .disabled)
        try await adBlock.prepare()
        #expect(!YouTubeAdBlock(defaults: defaults, archiveURL: nil).enabled)
        adBlock.setEnabled(true)
        #expect(adBlock.status == .idle)
    }

    @Test("실제 WebKit 확장의 필터 및 동적 스크립트 준비", .timeLimit(.minutes(2)))
    @MainActor func nativeExtensionIntegration() async throws {
        guard ProcessInfo.processInfo.environment["SEOUL_YOUTUBE_ADBLOCK_INTEGRATION"] == "1" else { return }
        _ = NSApplication.shared
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "music-adblock-integration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let adBlock = YouTubeAdBlock(defaults: defaults, cacheRoot: root)
        try await adBlock.prepare()
        #expect(adBlock.status == .active)
        #expect(adBlock.context != nil)
        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = adBlock.controller
        let filtered = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), configuration: configuration)
        let control = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        adBlock.register(filtered)
        defer { adBlock.unregister(filtered) }
        let html = "<html><head></head><body>fixture</body></html>"
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        filtered.loadHTMLString(html, baseURL: url)
        control.loadHTMLString(html, baseURL: url)
        try await Task.sleep(for: .seconds(1))
        let probe = """
        window.ytInitialPlayerResponse = {videoDetails:{videoId:'fixture'},playerAds:[{ad:true}],adPlacements:[{ad:true}],adSlots:[{ad:true}]};
        JSON.stringify({ads:window.ytInitialPlayerResponse.playerAds,placements:window.ytInitialPlayerResponse.adPlacements,slots:window.ytInitialPlayerResponse.adSlots,video:window.ytInitialPlayerResponse.videoDetails.videoId});
        """
        func result(_ view: WKWebView) async -> String {
            await withCheckedContinuation { continuation in
                view.evaluateJavaScript(probe) { value, error in continuation.resume(returning: (value as? String) ?? error?.localizedDescription ?? "no result") }
            }
        }
        let allowed = await result(control)
        let blocked = await result(filtered)
        FileHandle.standardError.write(Data(("[YouTubeFilter] control=" + allowed + " filtered=" + blocked + "\n").utf8))
        #expect(allowed.contains("placements"))
        #expect(!blocked.contains("placements"))
        #expect(!blocked.contains("\"ads\""))
        #expect(blocked.contains("fixture"))
        let embed = YouTubeEmbedPlayer(adBlock: adBlock)
        var adFailure: String?
        embed.onFailure = { adFailure = $0 }
        let guarded = embed.prepare()
        try await Task.sleep(for: .milliseconds(200))
        guarded.loadHTMLString("<html><head></head><body><div id='movie_player' class='html5-video-player ad-showing'><video></video></div></body></html>", baseURL: url)
        try await Task.sleep(for: .seconds(1))
        #expect(adFailure?.contains("광고") == true)
        if case .failed = adBlock.status {} else { Issue.record("차단되지 않은 광고를 감지하고 중단하지 않았습니다") }
        adBlock.setEnabled(false)
        #expect(adBlock.context == nil)
        #expect(adBlock.status == .disabled)
    }

    @Test("실제 YouTube 원본 재생·곡 전환·중간 탐색", .timeLimit(.minutes(3)))
    @MainActor func liveYouTubePlayback() async throws {
        guard ProcessInfo.processInfo.environment["SEOUL_YOUTUBE_LIVE"] == "1" else { return }
        _ = NSApplication.shared
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "youtube-live-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let adBlock = YouTubeAdBlock(defaults: defaults, cacheRoot: root)
        try await adBlock.prepare()
        let embed = YouTubeEmbedPlayer(adBlock: adBlock)
        // WebKit suspends hidden muted video. Keep audio at 0.1% for a background playback check.
        embed.setVolume(0.001)
        // A nonactivating test panel supplies normal WebKit visibility without taking focus.
        let panel = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 640, height: 360),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.contentView = embed.prepare()
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        var time: Double = 0
        var failure: String?
        embed.onTime = { seconds, _ in time = seconds }
        embed.onFailure = { failure = $0 }
        defer { embed.stop() }
        for id in ["dQw4w9WgXcQ", "9bZkp7q19f0"] {
            time = 0
            failure = nil
            embed.load(videoID: id)
            for _ in 0..<150 {
                try await Task.sleep(for: .milliseconds(200))
                if failure != nil || time > 3 { break }
            }
            if let failure { throw AgentError.processFailed("실제 YouTube 재생 실패: \(failure)") }
            if time <= 3 {
                let diagnostic: String = await withCheckedContinuation { continuation in
                    embed.webView?.evaluateJavaScript("JSON.stringify({url:location.href,visibility:document.visibilityState,video:[...document.querySelectorAll('video')].map(v=>({paused:v.paused,time:v.currentTime,duration:v.duration,ready:v.readyState,network:v.networkState,error:v.error&&v.error.message})),text:document.body.innerText.slice(0,600)})") { value, error in
                        continuation.resume(returning: (value as? String) ?? error?.localizedDescription ?? "no page")
                    }
                }
                FileHandle.standardError.write(Data(("[YouTubeLive] " + diagnostic + "\n").utf8))
            }
            try #require(time > 3)
            #expect(adBlock.status == .active)
            embed.seek(to: 90)
            try await Task.sleep(for: .seconds(4))
            #expect(time >= 90)
            #expect(failure == nil)
        }
    }
}
