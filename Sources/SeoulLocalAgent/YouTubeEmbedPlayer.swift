import SwiftUI
import WebKit

/// 광고 없는 음원을 못 찾은 곡을 위한 **마지막 수단**.
///
/// YouTube가 공식으로 제공하는 IFrame Player API를 그대로 쓴다. 광고를 막는 코드도,
/// 스트림을 꺼내는 코드도, 플레이어를 가리는 코드도 없다 — 그런 것은 약관 위반이고,
/// 이 앱은 만들지 않는다. 그래서 이 경로로 재생되는 곡에는 YouTube가 붙이는 광고가
/// 나올 수 있고, 화면은 어느 곡이 이 경로인지 늘 표시한다.
///
/// 이 경로를 타기 전에 언제나 내 파일·Audius·Internet Archive를 먼저 본다. 폴백은
/// 설정에서 끌 수 있고, 껐을 때 못 찾은 곡은 재생하지 않는다.
@MainActor
final class YouTubeEmbedPlayer: NSObject, ObservableObject {

    enum State: Int {
        case unstarted = -1, ended = 0, playing = 1, paused = 2, buffering = 3, cued = 5
    }

    /// 앱이 사는 동안 하나만 만든다. 화면을 떠나 뷰에서 떨어져도 이 객체가 붙잡고
    /// 있으므로 소리가 이어진다.
    private(set) var webView: WKWebView?
    private var isReady = false
    private var pending: (id: String, start: TimeInterval)?
    private var lastVolume: Double = 0.8

    var onState: ((State) -> Void)?
    var onTime: ((TimeInterval, TimeInterval) -> Void)?
    var onFailure: ((String) -> Void)?

    /// 웹뷰를 실제로 만드는 것은 이 경로를 처음 쓸 때다. 광고 없는 음원만으로 듣는
    /// 사람의 앱에는 WebKit이 아예 올라오지 않는다.
    @discardableResult
    func prepare() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "music")
        // 앱이 `play`를 눌러 재생을 시작할 수 있어야 한다. 사용자의 클릭이 곧 재생
        // 명령이므로 사람이 누르지 않은 재생이 아니다.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 225), configuration: configuration)
        view.navigationDelegate = self
        view.underPageBackgroundColor = .black
        view.setValue(false, forKey: "drawsBackground")
        // `baseURL`을 youtube.com으로 두는 것은 IFrame API가 http(s) origin을 요구하기
        // 때문이다. Google이 공개한 iOS 헬퍼(youtube-ios-player-helper)도 같은 방식을
        // 쓴다. `file://`로 열면 origin이 `null`이라 임베드가 거부된다.
        let html = (try? String(contentsOf: Bundle.module.url(forResource: "youtube-player", withExtension: "html")!, encoding: .utf8)) ?? ""
        view.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
        webView = view
        return view
    }

    func load(videoID: String, startAt: TimeInterval = 0) {
        prepare()
        guard isReady else {
            pending = (videoID, startAt)
            return
        }
        evaluate("loadVideo('\(videoID)', \(Int(startAt)))")
        setVolume(lastVolume)
    }

    func play() { evaluate("command('play')") }
    func pause() { evaluate("command('pause')") }
    func seek(to seconds: TimeInterval) { evaluate("command('seek', \(seconds))") }

    func setVolume(_ value: Double) {
        lastVolume = value
        evaluate("command('volume', \(value))")
    }

    /// 소리를 끊는다. 웹뷰는 남겨 둔다 — 다음 폴백 곡에서 다시 만들면 두 번째
    /// 로딩이 눈에 띄게 느리다.
    func stop() {
        guard webView != nil else { return }
        evaluate("command('stop')")
    }

    private func evaluate(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }
}

extension YouTubeEmbedPlayer: WKScriptMessageHandler {
    /// WebKit은 스크립트 메시지를 **주 스레드에서** 부른다. 프로토콜 요구가 nonisolated라
    /// 그 사실을 컴파일러에게 한 번 말해 주어야 `message.body`를 읽을 수 있다.
    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else { return }
            let state = (payload["state"] as? NSNumber)?.intValue
            let time = (payload["time"] as? NSNumber)?.doubleValue
            let duration = (payload["duration"] as? NSNumber)?.doubleValue
            let code = (payload["code"] as? NSNumber)?.intValue
            let text = payload["message"] as? String
            handle(type: type, state: state, time: time, duration: duration, code: code, text: text)
        }
    }

    private func handle(
        type: String, state: Int?, time: Double?, duration: Double?, code: Int?, text: String?
    ) {
        switch type {
        case "ready":
            isReady = true
            if let pending {
                self.pending = nil
                load(videoID: pending.id, startAt: pending.start)
            }
        case "state":
            if let state, let value = State(rawValue: state) { onState?(value) }
        case "time":
            onTime?(time ?? 0, duration ?? 0)
        case "error":
            onFailure?(Self.message(for: code ?? 0))
        case "failed":
            onFailure?(text ?? "YouTube 플레이어를 불러오지 못했습니다")
        default:
            break
        }
    }

    /// IFrame API의 오류 코드. 특히 101·150은 "이 영상은 임베드가 막혀 있다"는
    /// 뜻이고, 그런 곡은 이 앱에서 어떤 방법으로도 재생할 수 없다.
    private static func message(for code: Int) -> String {
        switch code {
        case 2: "영상 주소가 올바르지 않습니다."
        case 5: "이 영상을 이 플레이어에서 재생할 수 없습니다."
        case 100: "영상이 삭제되었거나 비공개입니다."
        case 101, 150: "업로더가 외부 재생을 막아 둔 영상입니다."
        default: "재생할 수 없습니다 (\(code))."
        }
    }
}

extension YouTubeEmbedPlayer: WKNavigationDelegate {
    /// 앱 창 안에서 임의의 웹이 열리는 경로는 만들지 않는다. 로봇 콘솔 웹뷰와 같은
    /// 규칙이다 — 재생에 필요한 곳만 연다.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let host = navigationAction.request.url?.host?.lowercased() ?? ""
        let allowed = host.isEmpty
            || host.hasSuffix("youtube.com")
            || host.hasSuffix("youtube-nocookie.com")
            || host.hasSuffix("ytimg.com")
            || host.hasSuffix("googlevideo.com")
            || host.hasSuffix("google.com")
            || host.hasSuffix("gstatic.com")
            || host.hasSuffix("doubleclick.net")
        decisionHandler(allowed ? .allow : .cancel)
    }
}

// MARK: - 화면에 붙이기

/// 폴백으로 재생 중인 영상. 모델이 붙잡고 있는 웹뷰 하나를 그대로 화면에 건다.
///
/// 크기를 200×200보다 작게 만들지 않는다. YouTube의 임베드 요건이고, 컨트롤이 잘려
/// 보이면 조작할 수도 없다.
struct YouTubeEmbedView: NSViewRepresentable {
    @ObservedObject var player: YouTubeEmbedPlayer

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 225))
        let webView = player.prepare()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let webView = player.prepare()
        guard webView.superview !== container else { return }
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 200))
        return CGSize(width: max(200, size.width), height: max(200, size.height))
    }
}
