import SwiftUI
import WebKit

/// YouTube 원본 페이지 + uBlock Origin Lite. 음원 추출이나 다른 음원 대체를 하지 않는다.
@MainActor
final class YouTubeEmbedPlayer: NSObject, ObservableObject {
    enum State: Int { case unstarted = -1, ended = 0, playing = 1, paused = 2, buffering = 3, cued = 5 }
    private(set) var webView: WKWebView?
    let adBlock: YouTubeAdBlock
    private var pageTask: Task<Void, Never>?
    private var readinessTask: Task<Void, Never>?
    private var pageLoaded = false
    private var isReady = false
    private var hasPlaybackStarted = false
    private var currentVideo: (id: String, start: TimeInterval)?
    private var pending: (id: String, start: TimeInterval)?
    private var lastVolume: Double = 0.8
    var onState: ((State) -> Void)?
    var onTime: ((TimeInterval, TimeInterval) -> Void)?
    var onFailure: ((String) -> Void)?

    init(adBlock: YouTubeAdBlock = YouTubeAdBlock()) {
        self.adBlock = adBlock
        super.init()
        adBlock.onSettingsChanged = { [weak self] in self?.resetPlayer() }
    }
    private func resetPlayer() {
        objectWillChange.send()
        pageTask?.cancel()
        readinessTask?.cancel()
        pageTask = nil
        readinessTask = nil
        if let webView {
            adBlock.unregister(webView)
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "music")
            webView.stopLoading()
            webView.loadHTMLString("<html><body style='background:black'></body></html>", baseURL: nil)
            webView.removeFromSuperview()
        }
        webView = nil
        pending = nil
        isReady = false
        pageLoaded = false
        onState?(.paused)
    }
    func retryAdBlock() { resetPlayer(); adBlock.retry(); prepare() }

    @discardableResult
    func prepare() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.inactiveSchedulingPolicy = .none
        if adBlock.enabled { configuration.webExtensionController = adBlock.controller }
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(MusicMessageProxy(owner: self), name: "music")
        configuration.userContentController.addUserScript(WKUserScript(source: Self.watchBridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if adBlock.enabled {
            configuration.userContentController.addUserScript(WKUserScript(source: Self.adGuardScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 225), configuration: configuration)
        view.navigationDelegate = self
        view.underPageBackgroundColor = .black
        webView = view
        pageTask = Task { @MainActor [weak self, weak view] in
            guard let self, let view else { return }
            do {
                try await self.adBlock.prepare()
                try Task.checkCancellation()
                guard self.webView === view else { return }
                self.adBlock.register(view)
                self.pageLoaded = true
                if let pending = self.pending { self.pending = nil; self.loadWatchPage(pending) }
            } catch {
                if !Task.isCancelled { self.onFailure?(error.localizedDescription) }
            }
        }
        return view
    }
    func load(videoID: String, startAt: TimeInterval = 0) {
        guard videoID.count == 11, videoID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
              startAt.isFinite, startAt >= 0, startAt < Double(Int.max) else {
            onFailure?("올바른 YouTube 영상 주소가 아닙니다."); return
        }
        currentVideo = (videoID, startAt)
        prepare()
        if pageLoaded { loadWatchPage((videoID, startAt)) }
        else { pending = (videoID, startAt) }
    }
    private func loadWatchPage(_ video: (id: String, start: TimeInterval)) {
        isReady = false
        hasPlaybackStarted = false
        var url = URLComponents(string: "https://www.youtube.com/watch")!
        url.queryItems = [URLQueryItem(name: "v", value: video.id), URLQueryItem(name: "t", value: "\(Int(video.start))s")]
        webView?.load(URLRequest(url: url.url!))
        readinessTask?.cancel()
        readinessTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !self.hasPlaybackStarted, self.currentVideo?.id == video.id else { return }
            self.stop()
            self.onFailure?("YouTube 원본을 준비하지 못했습니다. 네트워크 또는 YouTube의 로그인·재생 제한을 확인하세요.")
        }
    }
    func play() {
        if !isReady, let currentVideo { load(videoID: currentVideo.id, startAt: currentVideo.start) }
        else { evaluate("command('play')") }
    }
    func pause() { evaluate("command('pause')") }
    func seek(to seconds: TimeInterval) {
        guard seconds.isFinite, seconds >= 0 else { return }
        currentVideo?.start = seconds
        evaluate("command('seek', \(seconds))")
    }
    func setVolume(_ value: Double) {
        guard value.isFinite else { return }
        lastVolume = min(1, max(0, value))
        evaluate("command('volume', \(lastVolume))")
    }
    func stop() {
        pending = nil
        currentVideo = nil
        readinessTask?.cancel()
        evaluate("command('stop')")
        isReady = false
        webView?.stopLoading()
        webView?.loadHTMLString("<html><body style='background:black'></body></html>", baseURL: nil)
    }
    private func evaluate(_ script: String) { webView?.evaluateJavaScript(script, completionHandler: nil) }
    static func message(for code: Int) -> String {
        switch code {
        case 2: "영상 주소가 올바르지 않습니다."
        case 5: "이 영상을 플레이어에서 재생할 수 없습니다."
        case 100: "영상이 삭제되었거나 비공개입니다."
        case 101, 150: "업로더가 외부 재생을 막아 둔 영상입니다."
        default: "재생할 수 없습니다 (\(code))."
        }
    }
}
extension YouTubeEmbedPlayer: WKScriptMessageHandler {
    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard message.webView === webView, pageLoaded,
                  let payload = message.body as? [String: Any], let type = payload["type"] as? String,
                  let host = message.frameInfo.request.url?.host, host == "www.youtube.com" || host == "www.youtube-nocookie.com" else { return }
            if type == "adDetected", adBlock.enabled {
                adBlock.reportAdDetected(); stop()
                onFailure?("YouTube 광고가 감지되어 재생을 중단했습니다. 광고 차단을 다시 시도하세요.")
                return
            }
            guard message.frameInfo.isMainFrame,
                  payload["videoID"] as? String == currentVideo?.id, currentVideo != nil else { return }
            switch type {
            case "ready":
                isReady = true
                setVolume(lastVolume)
                if let currentVideo, currentVideo.start > 0 { seek(to: currentVideo.start) }
                play()
            case "state":
                if let state = payload["state"] as? Int, let value = State(rawValue: state) {
                    if value == .playing { hasPlaybackStarted = true; readinessTask?.cancel() }
                    onState?(value)
                }
            case "time":
                if let time = payload["time"] as? Double, let duration = payload["duration"] as? Double,
                   time.isFinite, duration.isFinite, time >= 0, duration >= 0 {
                    currentVideo?.start = time
                    onTime?(time, duration)
                }
            case "failed":
                readinessTask?.cancel()
                onFailure?(String((payload["message"] as? String ?? "YouTube 재생 실패").prefix(300)))
            default: break
            }
        }
    }
}
extension YouTubeEmbedPlayer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { adBlock.navigated(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { onFailure?("YouTube 연결 실패: \(error.localizedDescription)") }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(Self.allowsNavigation(navigationAction.request.url) ? .allow : .cancel)
    }
    static func allowsNavigation(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return ["youtube.com", "youtube-nocookie.com", "ytimg.com", "googlevideo.com", "google.com", "gstatic.com", "doubleclick.net"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static let adGuardScript = """
    (() => {
      if (!['www.youtube.com','www.youtube-nocookie.com'].includes(location.hostname)) return;
      let reported = false;
      const check = () => {
        const player = document.querySelector('.html5-video-player.ad-showing, .html5-video-player.ad-interrupting');
        if (!player) return;
        player.querySelectorAll('video').forEach(video => { video.muted = true; video.pause(); });
        if (!reported) { reported = true; try { window.webkit.messageHandlers.music.postMessage({type:'adDetected'}); } catch (_) {} }
      };
      new MutationObserver(check).observe(document, {subtree:true, childList:true, attributes:true, attributeFilter:['class']});
      document.addEventListener('play', check, true);
      document.addEventListener('DOMContentLoaded', check, {once:true});
    })();
    """
    static let watchBridgeScript = """
    (() => {
      if (location.hostname !== 'www.youtube.com' || location.pathname !== '/watch') return;
      const videoID = new URL(location.href).searchParams.get('v');
      const post = data => { try { window.webkit.messageHandlers.music.postMessage({...data,videoID}); } catch (_) {} };
      let video = null, failed = false;
      window.command = (name, arg) => {
        if (!video) return;
        switch (name) {
          case 'play': video.play().catch(() => post({type:'state',state:2})); break;
          case 'pause': case 'stop': video.pause(); break;
          case 'seek': if (Number.isFinite(arg)) video.currentTime = arg; break;
          case 'volume': video.volume = Math.min(1,Math.max(0,arg)); video.muted = arg === 0; break;
        }
      };
      const style = () => {
        if (!document.head || document.getElementById('seoul-music-player-style')) return;
        const css = document.createElement('style'); css.id = 'seoul-music-player-style';
        css.textContent = 'html,body{background:#000!important;overflow:hidden!important} #movie_player{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;z-index:99999!important} #movie_player video.html5-main-video{width:100%!important;height:100%!important;left:0!important;top:0!important;object-fit:contain!important} ytd-masthead,#secondary,#below{display:none!important}';
        document.head.appendChild(css);
      };
      const tick = () => {
        style();
        const found = document.querySelector('#movie_player video');
        if (found && found !== video) {
          video = found; video.muted = true;
          for (const [event,state] of [['playing',1],['pause',2],['waiting',3],['ended',0]]) {
            found.addEventListener(event, () => { if (found === video) post({type:'state',state}); });
          }
          post({type:'ready'});
        }
        if (video && Number.isFinite(video.duration)) post({type:'time',time:video.currentTime,duration:video.duration});
        const error = document.querySelector('yt-playability-error-supported-renderers');
        if (!failed && error && error.getBoundingClientRect().height > 0 && error.textContent.trim()) {
          failed = true; if (video) video.pause(); post({type:'failed',message:error.textContent.trim().slice(0,300)});
        }
      };
      document.addEventListener('DOMContentLoaded', tick, {once:true});
      setInterval(tick,250);
    })();
    """
}
@MainActor
private final class MusicMessageProxy: NSObject, WKScriptMessageHandler {
    weak var owner: YouTubeEmbedPlayer?
    init(owner: YouTubeEmbedPlayer) { self.owner = owner }
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { owner?.userContentController(userContentController, didReceive: message) }
    }
}

struct YouTubeEmbedView: NSViewRepresentable {
    @ObservedObject var player: YouTubeEmbedPlayer
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 225))
        attach(to: container)
        return container
    }
    private func attach(to container: NSView) {
        let webView = player.prepare()
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }
    func updateNSView(_ container: NSView, context: Context) { attach(to: container) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 200))
        return CGSize(width: max(200, size.width), height: max(200, size.height))
    }
}
