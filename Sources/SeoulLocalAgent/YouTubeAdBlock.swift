import AppKit
import WebKit
import CryptoKit
import SwiftUI

enum YouTubeAdBlockArchive {
    static let version = "2026.907.2003"
    static let sha256 = "851254d65c768cf23ba4fa27e51250344cee293d7e58b9387dbc62de6bc7c306"
    static var bundledURL: URL? { Bundle.module.url(forResource: "uBlockOriginLite.safari", withExtension: "zip") }
    static var cacheRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SeoulLocalAgent/MusicAdBlock", directoryHint: .isDirectory)
    }

    // The official, pinned archive is unpacked afresh, not executed from an unchecked cache.
    static func extract(archive: URL, root: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: archive)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == sha256 else { throw AgentError.processFailed("광고 차단 확장의 무결성 검증에 실패했습니다.") }
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let staging = root.appending(path: ".unpack-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, staging.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw AgentError.processFailed("광고 차단 확장 압축을 풀지 못했습니다.") }
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: staging.appending(path: "manifest.json"))) as? [String: Any]
            guard manifest?["version"] as? String == version,
                  fm.fileExists(atPath: staging.appending(path: "js/background.js").path),
                  fm.fileExists(atPath: staging.appending(path: "LICENSE.txt").path) else {
                throw AgentError.processFailed("광고 차단 확장 리소스가 올바르지 않습니다.")
            }
            let destination = root.appending(path: version, directoryHint: .isDirectory)
            // This folder contains only app-generated extension code, never music or user files.
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: staging, to: destination)
            return destination
        }.value
    }
}

@MainActor
final class YouTubeAdBlock: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    enum Status: Equatable {
        case idle, loading, active, disabled, failed(String)
        var title: String {
            switch self {
            case .idle: "광고 차단 켜짐 · 재생 시 준비"
            case .loading: "광고 차단 준비 중"
            case .active: "uBlock Origin Lite · 차단 활성"
            case .disabled: "광고 차단 꺼짐"
            case .failed: "광고 차단 오류 · 재생 중단"
            }
        }
    }
    @Published private(set) var status: Status = .idle
    @Published private(set) var enabled: Bool
    lazy var controller: WKWebExtensionController = {
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        let controller = WKWebExtensionController(configuration: configuration)
        controller.delegate = self
        return controller
    }()
    private(set) var context: WKWebExtensionContext?
    private var preparation: Task<Void, Error>?
    private var preparationID: UUID?
    private var bridgeView: WKWebView?
    private let archiveURL: URL?
    private let cacheRoot: URL
    private let defaults: UserDefaults
    private var tabs: [AdBlockTab] = []
    private let musicWindow = AdBlockWindow()
    var onSettingsChanged: (() -> Void)?
    private func trace(_ text: String) {
        if ProcessInfo.processInfo.environment["SEOUL_YOUTUBE_ADBLOCK_INTEGRATION"] == "1" {
            FileHandle.standardError.write(Data(("[YouTubeAdBlock] " + text + "\n").utf8))
        }
    }

    init(defaults: UserDefaults = .standard, archiveURL: URL? = YouTubeAdBlockArchive.bundledURL,
         cacheRoot: URL = YouTubeAdBlockArchive.cacheRoot) {
        self.defaults = defaults
        self.archiveURL = archiveURL
        self.cacheRoot = cacheRoot
        enabled = defaults.object(forKey: "music.youtubeAdBlockEnabled") as? Bool ?? true
        super.init()
        if !enabled { status = .disabled }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        defaults.set(value, forKey: "music.youtubeAdBlockEnabled")
        preparation?.cancel()
        if let context { try? controller.unload(context) }
        context = nil
        bridgeView = nil
        status = value ? .idle : .disabled
        onSettingsChanged?()
    }

    func retry() {
        guard enabled else { return }
        preparation?.cancel()
        if let context { try? controller.unload(context) }
        context = nil
        bridgeView = nil
        status = .idle
    }

    func reportAdDetected() {
        guard enabled else { return }
        status = .failed("YouTube 광고가 감지되어 재생을 중단했습니다. 필터를 다시 준비한 뒤 재시도하세요.")
    }

    func prepare() async throws {
        guard enabled else { status = .disabled; return }
        if status == .active { return }
        if case .failed(let message) = status { throw AgentError.processFailed(message) }
        if let preparation {
            if preparation.isCancelled {
                let previousID = preparationID
                try? await preparation.value
                if preparationID == previousID { self.preparation = nil; preparationID = nil }
                return try await prepare()
            }
            return try await preparation.value
        }
        let id = UUID()
        let task = Task { @MainActor [self] in
            status = .loading
            do {
                guard let archiveURL else { throw AgentError.processFailed("앱에 광고 차단 확장이 포함되어 있지 않습니다.") }
                let resourceURL = try await YouTubeAdBlockArchive.extract(archive: archiveURL, root: cacheRoot)
                trace("archive verified and extracted")
                try Task.checkCancellation()
                let webExtension = try await WKWebExtension(resourceBaseURL: resourceURL)
                trace("extension parsed")
                let context = WKWebExtensionContext(for: webExtension)
                context.uniqueIdentifier = "seoul-local-agent-ubol"
                context.baseURL = URL(string: "webkit-extension://seoul-music-adblock/")!
                // Broad host access is needed for uBOL scriptlets, but this controller sees ONLY
                // the isolated music player and its extension dashboard, not any browser tab.
                for permission in webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
                for pattern in webExtension.requestedPermissionMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
                self.context = context
                try controller.load(context)
                trace("native extension loaded")
                try await verifyBackground(context: context)
                try Task.checkCancellation()
                guard enabled else { throw CancellationError() }
                status = .active
                trace("filtering worker and scripting ready")
            } catch {
                if let context { try? controller.unload(context) }
                context = nil
                bridgeView = nil
                if !Task.isCancelled { status = .failed(error.localizedDescription) }
                throw error
            }
        }
        preparation = task
        preparationID = id
        defer { if preparationID == id { preparation = nil; preparationID = nil } }
        try await task.value
    }

    // A successful native load alone does not prove the extension's filtering worker is ready.
    // Query its own background API from its real extension origin before loading any YouTube.
    private func verifyBackground(context: WKWebExtensionContext) async throws {
        trace("creating extension bridge")
        guard let configuration = context.webViewConfiguration else {
            throw AgentError.processFailed("광고 차단 확장 페이지 구성을 만들지 못했습니다.")
        }
        let bridge = WKWebView(frame: .zero, configuration: configuration)
        bridgeView = bridge
        bridge.load(URLRequest(url: context.baseURL.appending(path: "dashboard.html")))
        trace("dashboard requested")
        for attempt in 0..<100 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
            let script = """
            if (typeof browser === 'undefined' || !browser.runtime) return {error:'browser API unavailable', url:location.href};
            try {
              const data = await Promise.race([browser.runtime.sendMessage({what:'getOptionsPageData'}),
                  new Promise(resolve => setTimeout(() => resolve(null), 1000))]);
              if (!data) return null;
              if (data.defaultFilteringMode < 2) {
                await browser.runtime.sendMessage({what:'setDefaultFilteringMode', level:3});
                return null;
              }
              const scripts = await browser.scripting.getRegisteredContentScripts();
              return {mode:data.defaultFilteringMode, broad:data.hasOmnipotence,
                      rules:data.enabledRulesets, scripts:scripts.length};
            } catch (error) { return {error:String(error), url:location.href}; }
            """
            if let value = await bridgeSnapshot(bridge, script: script, report: attempt % 10 == 0), value.mode >= 2, value.broad,
               value.rules.contains("ublock-filters"), value.rules.contains("easylist"), value.scripts > 0 {
                return
            }
        }
        throw AgentError.processFailed("uBlock Origin Lite의 필터·스크립트를 준비하지 못했습니다. 광고 차단 없이 자동 재생하지 않습니다.")
    }

    private struct Snapshot: Sendable { let mode: Int; let broad: Bool; let rules: [String]; let scripts: Int }
    private func bridgeSnapshot(_ bridge: WKWebView, script: String, report: Bool) async -> Snapshot? {
        await withCheckedContinuation { continuation in
            bridge.callAsyncJavaScript(script, in: nil, in: .page) { [weak self] result in
                if report { self?.trace("bridge response: \(result)") }
                guard case .success(let result) = result, let value = result as? [String: Any],
                      let mode = value["mode"] as? Int, let broad = value["broad"] as? Bool,
                      let rules = value["rules"] as? [String], let scripts = value["scripts"] as? Int else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: Snapshot(mode: mode, broad: broad, rules: rules, scripts: scripts))
            }
        }
    }

    func register(_ view: WKWebView) {
        guard !tabs.contains(where: { $0.view === view }) else { return }
        let tab = AdBlockTab(view: view, window: musicWindow)
        tabs.append(tab)
        musicWindow.musicTabs = tabs
        context?.didOpenTab(tab)
    }

    func navigated(_ view: WKWebView) {
        guard let tab = tabs.first(where: { $0.view === view }) else { return }
        context?.didChangeTabProperties([.URL, .loading], for: tab)
    }

    func unregister(_ view: WKWebView) {
        if let tab = tabs.first(where: { $0.view === view }) { context?.didCloseTab(tab) }
        tabs.removeAll { $0.view === view }
        musicWindow.musicTabs = tabs
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [musicWindow] }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { musicWindow }
}

@MainActor
private final class AdBlockWindow: NSObject, WKWebExtensionWindow {
    var musicTabs: [AdBlockTab] = []
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { musicTabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { musicTabs.first }
}

@MainActor
private final class AdBlockTab: NSObject, WKWebExtensionTab {
    weak var view: WKWebView?
    weak var musicWindow: AdBlockWindow?
    init(view: WKWebView, window: AdBlockWindow) { self.view = view; musicWindow = window }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { view }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { musicWindow }
    func url(for context: WKWebExtensionContext) -> URL? { view?.url }
    func title(for context: WKWebExtensionContext) -> String? { "YouTube 음악" }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(view?.isLoading ?? false) }
}
