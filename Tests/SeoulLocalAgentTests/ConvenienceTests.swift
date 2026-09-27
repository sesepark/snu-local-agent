import Testing
import Foundation
import AppKit
import SwiftUI
import ImageIO
@testable import SeoulLocalAgent

@Suite("편의 개선 회귀 검증", .serialized)
struct ConvenienceTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "convenience-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var svg: Data {
        Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32"><rect x="8" y="4" width="40" height="20" fill="#ff0000"/></svg>"##.utf8)
    }

    @Test("새 기본값은 자동 판단과 핵심 압축이며 사용자 전문을 포함한다")
    func summaryDefaults() {
        let preferences = TranscriptOrganizationPreferences()
        #expect(preferences.defaultKind == .automatic)
        #expect(preferences.detail == .concise)
        #expect(preferences.lecturePrompt.contains("## 🚨 시험 / 평가 관련"))
        #expect(preferences.lecturePrompt.contains("## 🚨 결정사항 / Action Items"))
        #expect(preferences.lecturePrompt.contains("# 세미나 출력 형식"))
        #expect(preferences.lecturePrompt.contains("GPT가 시험에 나올 내용을 추측하지 않는다"))
        let system = TranscriptOrganizer().systemPrompt(prompt: preferences.lecturePrompt, detail: .concise)
        #expect(!system.contains("누락 방지를 우선"))
        #expect(!system.contains("세부 설명과 예시를 적극 보존"))
    }

    @Test("기존 기본 설정은 새 기본값으로 이전한다")
    func migrateDefaults() throws {
        var old = TranscriptOrganizationPreferences(defaultKind: .lecture, detail: .sourcePreserving,
            lecturePrompt: TranscriptOrganizationPreferences.legacyLecturePrompt,
            meetingPrompt: TranscriptOrganizationPreferences.legacyMeetingPrompt,
            generalPrompt: TranscriptOrganizationPreferences.legacyGeneralPrompt)
        old.schemaVersion = 1
        let migrated = try JSONDecoder().decode(TranscriptOrganizationPreferences.self, from: JSONEncoder().encode(old))
        #expect(migrated.defaultKind == .automatic)
        #expect(migrated.detail == .concise)
        #expect(migrated.lecturePrompt == TranscriptOrganizationPreferences.defaultLecturePrompt)
        #expect(migrated.schemaVersion == 2)
    }

    @Test("사용자 프롬프트·상세도·모델은 이전과 재실행 후 보존한다")
    func preserveCustomPreferences() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var original = TranscriptOrganizationPreferences(defaultKind: .meeting, detail: .sourcePreserving,
            lecturePrompt: "내 개인 프롬프트", meetingPrompt: "담당자와 기한만", generalPrompt: "연구 결과 중심", model: "local-test:latest")
        original.schemaVersion = 1
        let store = TranscriptOrganizationPreferencesStore(directory: directory)
        try store.save(original)
        let restored = store.load()
        #expect(restored.lecturePrompt == original.lecturePrompt)
        #expect(restored.meetingPrompt == original.meetingPrompt)
        #expect(restored.detail == .sourcePreserving)
        #expect(restored.model == "local-test:latest")
        let partial = try JSONDecoder().decode(TranscriptOrganizationPreferences.self,
            from: Data(#"{"lecturePrompt":"보존할 내용"}"#.utf8))
        #expect(partial.lecturePrompt == "보존할 내용")
        #expect(partial.detail == .concise)
    }

    @Test("모델 문맥은 상한을 지키고 클라우드·임베딩·작은 문맥은 거부한다")
    func modelValidation() throws {
        #expect(try SummaryModelAPI.validatedContextLength(Data(#"{"capabilities":["completion"],"model_info":{"qwen.context_length":131072}}"#.utf8)) == 32768)
        #expect(try SummaryModelAPI.validatedContextLength(Data(#"{"model_info":{"llama.context_length":8192}}"#.utf8)) == 8192)
        for input in [#"{"remote_model":"cloud"}"#, #"{"remote_host":"https://ollama.com"}"#,
                      #"{"capabilities":["embedding"]}"#, #"{"model_info":{"x.context_length":2048}}"#] {
            #expect(throws: (any Error).self) { try SummaryModelAPI.validatedContextLength(Data(input.utf8)) }
        }
    }

    @Test("SVG 스크립트·외부 리소스·엔티티·비정상 XML 차단")
    func svgSecurity() throws {
        try WatermarkImporter.validateSVG(svg)
        let forbidden = [
            #"<svg><script>alert(1)</script></svg>"#,
            #"<svg onload="alert(1)"/>"#,
            #"<svg><image href="https://example.com/p.png"/></svg>"#,
            #"<svg><style>rect{fill:url(https://example.com/a)}</style></svg>"#,
            #"<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg/>"#,
            #"<svg><foreignObject/></svg>"#,
            #"<html/>"#, #"<svg><rect></svg>"#,
            #"<svg><animate attributeName="href" to="https://example.com"/></svg>"#,
            #"<svg><style>rect{fill:u\72l(https://example.com/a)}</style></svg>"#,
            #"<svg><rect style="fill:u&#114;l(https://example.com/a)"/></svg>"#,
        ]
        for input in forbidden {
            #expect(throws: (any Error).self) { try WatermarkImporter.validateSVG(Data(input.utf8)) }
        }
        try WatermarkImporter.validateSVG(Data(#"<svg xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="g"/></defs><rect fill="url(#g)"/></svg>"#.utf8))
    }

    @Test("SVG·PNG 실제 렌더링, 색상·투명도·원본 이동 후 재시작 유지")
    @MainActor
    func backgroundRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "logo.svg")
        try svg.write(to: file)
        let image = try WatermarkImporter.image(from: svg, extension: "svg")
        let png = try WatermarkImporter.cachedPNG(image)
        #expect(png.starts(with: [0x89, 0x50, 0x4e, 0x47]))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        #expect(bitmap.pixelsWide == 64 && bitmap.pixelsHigh == 32)
        #expect(try #require(bitmap.colorAt(x: 20, y: 12)).redComponent > 0.9)
        #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
        let appearance = AppearanceModel(directory: directory.appending(path: "settings"))
        try appearance.importFile(file)
        appearance.preferences.position = .bottomTrailing
        appearance.preferences.opacity = 0.12
        try FileManager.default.moveItem(at: file, to: directory.appending(path: "moved.svg"))
        let restored = AppearanceModel(directory: directory.appending(path: "settings"))
        #expect(restored.customImage != nil)
        #expect(restored.preferences.position == .bottomTrailing)
        #expect(restored.preferences.opacity == 0.12)
        let pngFile = directory.appending(path: "logo.png")
        try png.write(to: pngFile)
        try restored.importFile(pngFile)
        #expect(restored.preferences.sourceName == "logo.png")
        let previous = restored.preferences
        let bad = directory.appending(path: "bad.svg")
        try Data("<svg><script/></svg>".utf8).write(to: bad)
        #expect(throws: (any Error).self) { try restored.importFile(bad) }
        #expect(restored.preferences == previous)
        #expect(AppearanceModel(directory: directory.appending(path: "settings")).preferences == previous)
        #expect(throws: (any Error).self) { try WatermarkImporter.image(from: Data("not png".utf8), extension: "png") }
        #expect(throws: (any Error).self) { try WatermarkImporter.image(from: png, extension: "jpeg") }
    }

    @Test("내역은 여러 건 재시작·저장 위치·파일 소실·도구별 비우기를 처리한다")
    @MainActor
    func historyRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "output.png")
        try svg.write(to: file)
        let history = ToolHistory(directory: directory)
        for index in 0..<6 {
            history.record(.init(id: UUID(), tool: index == 5 ? "Convert" : "Compress", source: file,
                output: file, saveName: "결과.png", settings: "설정 \(index)", detail: "완료", succeeded: index != 3))
        }
        #expect(history.entries.count == 6)
        let saved = directory.appending(path: "saved.png")
        try FileManager.default.copyItem(at: file, to: saved)
        let entry = try #require(history.entries.first)
        history.markSaved(id: entry.id, at: saved)
        history.record(entry) // Finishing a batch must not erase an earlier export location.
        #expect(history.entries.first?.savedURL == saved)
        let restored = ToolHistory(directory: directory)
        #expect(restored.entries.count == 6)
        #expect(restored.entries.first?.availableOutput == saved)
        try FileManager.default.removeItem(at: saved)
        #expect(restored.entries.first?.availableOutput == file)
        restored.removeRecords(tool: "Compress")
        #expect(restored.entries.count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(ToolHistory(directory: directory).entries.count == 1)
        try FileManager.default.removeItem(at: file)
        #expect(restored.entries.first?.availableOutput == nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "tool-history.json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("깨진 내역 파일은 빈 기록으로 덮어쓰지 않는다")
    @MainActor
    func corruptHistoryPreserved() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "tool-history.json")
        let original = Data("broken archive".utf8)
        try original.write(to: url)
        let history = ToolHistory(directory: directory)
        #expect(history.error != nil)
        history.removeRecords(tool: "Compress")
        history.record(.init(id: UUID(), tool: "Compress", source: url, saveName: "a", settings: "a", detail: "a", succeeded: false))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("저장 실패 시 기존 결과 보존, 정상 교체·자기 자신 저장·폴더 저장")
    func safeExport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appending(path: "existing.txt")
        try Data("original".utf8).write(to: target)
        #expect(throws: (any Error).self) {
            try LocalFileStorage.copyPreservingDestination(directory.appending(path: "missing"), to: target)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        let source = directory.appending(path: "source.txt")
        try Data("replacement".utf8).write(to: source)
        try LocalFileStorage.copyPreservingDestination(source, to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "replacement")
        try LocalFileStorage.copyPreservingDestination(target, to: target)
        #expect(try String(contentsOf: target, encoding: .utf8) == "replacement")
        let folder = directory.appending(path: "pages")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("page".utf8).write(to: folder.appending(path: "page.txt"))
        let copied = directory.appending(path: "exported-pages")
        try LocalFileStorage.copyPreservingDestination(folder, to: copied)
        #expect(FileManager.default.fileExists(atPath: copied.appending(path: "page.txt").path))
    }

    @Test("입력 중복 제거와 지원하지 않는 파일 안내")
    func imports() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "photo.png")
        try svg.write(to: file)
        let unsupported = directory.appending(path: "document.txt")
        try Data().write(to: unsupported)
        #expect(ToolWorkspace.expand([directory, file, file], accepting: ["png"]).files.count == 1)
        #expect(ToolWorkspace.rejectionMessage([file, unsupported], accepting: ["png"])?.contains("1개") == true)
    }

    @Test("YouTube 원본 우선, 자동 매칭 무시, 사용자 지정 파일 보존")
    func musicRouting() {
        var track = Track(origin: .youtube, originID: "dQw4w9WgXcQ", title: "원본", artist: "아티스트")
        #expect(MusicPlaybackPolicy.usesOriginalYouTube(track, enabled: true))
        #expect(!MusicPlaybackPolicy.usesOriginalYouTube(track, enabled: false))
        track.asset = PlaybackAsset(provider: .audius, id: "other", title: "다른 음원", artist: "아티스트",
            duration: 10, confidence: 1, resolvedAt: .now, isManual: false)
        #expect(MusicPlaybackPolicy.usesOriginalYouTube(track, enabled: true))
        track.asset?.isManual = true
        #expect(!MusicPlaybackPolicy.usesOriginalYouTube(track, enabled: true))
    }

    @Test("잘못된 YouTube ID는 웹뷰 생성 전에 거부한다")
    @MainActor
    func invalidVideoID() {
        let embed = YouTubeEmbedPlayer()
        var failed = false
        embed.onFailure = { _ in failed = true }
        embed.load(videoID: "';alert(1)//")
        #expect(failed)
        #expect(embed.webView == nil)
    }

    private func transcript(_ text: String) -> TranscriptRun {
        .init(id: UUID(), recordingID: "fixture", createdAt: .now, completedAt: .now, duration: 1,
              settings: .init(), backend: nil, text: text, segments: [], engineVersion: "fixture", isLegacy: false)
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SummaryMockProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("선택한 모델로 모든 구간·통합·언로드 요청, 최종 통합에도 새 프롬프트 적용")
    func summaryPipeline() async throws {
        SummaryMockProtocol.state.reset(mode: .success)
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        let organizer = TranscriptOrganizer(model: "fixture-selected:latest", session: session)
        let run = transcript(String(repeating: "교수: 시험 범위는 3장이고 다음 주까지 과제를 제출하세요.\n\n", count: 900))
        let result = try await organizer.organize(transcript: run, detail: .concise,
            prompt: TranscriptOrganizationPreferences.defaultLecturePrompt) { _ in }
        #expect(result.contains("시험 범위"))
        await organizer.unload()
        let requests = SummaryMockProtocol.state.requests
        let generated = requests.filter { $0.url?.path == "/api/generate" }
        #expect(generated.count >= 4)
        for request in generated {
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
            #expect(body["model"] as? String == "fixture-selected:latest")
            if body["system"] != nil {
                #expect((body["system"] as? String)?.contains("GPT가 시험에 나올 내용을 추측하지 않는다") == true)
                #expect((body["system"] as? String)?.contains("세부 내용을 삭제하지") != true)
                #expect((body["options"] as? [String: Any])?["num_ctx"] as? Int == 32768)
            }
        }
        #expect(generated.contains { request in
            let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any]
            return (body?["system"] as? String)?.contains("전체를 관련 주제로 통합") == true
        })
        #expect((try JSONSerialization.jsonObject(with: generated.last?.httpBody ?? Data()) as? [String: Any])?["keep_alive"] as? Int == 0)
    }

    @Test("잘린 요약·빈 응답·HTTP 실패를 성공으로 저장하지 않는다")
    func summaryFailures() async throws {
        let session = mockSession()
        defer { session.invalidateAndCancel() }
        let run = transcript("시험 범위는 3장입니다.")
        for mode in [SummaryMockState.Mode.length, .empty, .httpFailure] {
            SummaryMockProtocol.state.reset(mode: mode)
            await #expect(throws: (any Error).self) {
                try await TranscriptOrganizer(model: "fixture-selected", session: session).organize(
                    transcript: run, detail: .concise, prompt: "핵심만 정리") { _ in }
            }
        }
        #expect(run.text == "시험 범위는 3장입니다.")
    }

    @Test("여러 배치·재실행은 내역 누적, 한 도구 중단은 다른 도구에 영향 없음")
    @MainActor
    func batchHistoryAndIsolation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appending(path: "input.png")
        try svg.write(to: input)
        let history = ToolHistory(directory: directory)
        let first = BatchToolModel(name: "First", idleStatus: "대기", history: history, resultDirectory: directory)
        let second = BatchToolModel(name: "Second", idleStatus: "대기", history: history, resultDirectory: directory)
        first.load([input], worker: FixtureWorker(delay: 5))
        try await settle(first)
        first.load([input], worker: FixtureWorker(delay: 5))
        try await settle(first)
        first.rerun(FixtureWorker(delay: 5))
        try await settle(first)
        #expect(history.entries.count == 3)
        first.clear()
        #expect(history.entries.count == 3)
        first.load([input, input], worker: FixtureWorker(delay: 200))
        second.load([input], worker: FixtureWorker(delay: 80))
        first.stop()
        try await settle(first)
        try await settle(second)
        #expect(second.jobs.first?.isFinished == true)
        #expect(first.jobs.first?.isFinished == false)
        #expect(first.jobs.count == 1)
        #expect(ToolHistory(directory: directory).entries.count == 5)
    }

    @MainActor
    private func settle(_ model: BatchToolModel) async throws {
        for _ in 0..<150 {
            if !model.isRunning { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("배치가 제한 시간 내에 종료되지 않았습니다.")
    }

    @Test("오프스크린 워터마크 UI 렌더링은 포커스를 변경하지 않는다")
    @MainActor
    func offscreenRendering() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appearance = AppearanceModel(directory: directory)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyWindow = NSApp?.keyWindow
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: CrestWatermark(appearance: appearance)
                .environment(\.colorScheme, scheme).frame(width: 800, height: 500))
            #expect(renderer.nsImage != nil)
        }
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
        #expect(NSApp?.keyWindow === keyWindow)
    }

    @Test("설정·다중 내역 화면 오프스크린 이미지 생성, 창 활성화 없음")
    @MainActor
    func offscreenScreens() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let appearance = AppearanceModel(directory: directory)
        let file = directory.appending(path: "테스트 로고.svg")
        try svg.write(to: file)
        try appearance.importFile(file)
        let history = ToolHistory(directory: directory)
        for index in 0..<4 {
            history.record(.init(id: UUID(), tool: "Compress", source: file, output: file,
                saveName: "결과.png", settings: "압축 3단계 · 표준", detail: "\(index + 2) MB → 1 MB · 완료", succeeded: true))
        }
        let artifactDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/convenience-qa")
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keyWindow = NSApp?.keyWindow
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: AppearanceSettingsView(appearance: appearance)
                .environment(\.colorScheme, scheme))
            view.frame = NSRect(x: 0, y: 0, width: 620, height: 640)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: artifactDirectory.appending(path: "appearance-\(scheme == .dark ? "dark" : "light").png"))
        }
        let view = NSHostingView(rootView: ToolHistoryPanel(tool: "Compress", isBusy: false, history: history,
            expanded: true, retry: { _ in }).padding(24).background(Color.white).environment(\.colorScheme, .light))
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 640)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: artifactDirectory.appending(path: "history.png"))
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
        #expect(NSApp?.keyWindow === keyWindow)
    }
}

private struct FixtureWorker: BatchToolWorker {
    var delay: Int
    var accepts: Set<String> { ["png"] }
    var saveSuffix: String { "fixture" }
    func outputExtension(for source: URL) -> String { "png" }
    func inspect(_ source: URL) async throws -> ToolJobInfo { .init(detail: "fixture", estimatedSeconds: 0.1) }
    func run(_ source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ToolOutcome {
        try await Task.sleep(for: .milliseconds(delay))
        progress(0.5)
        return .init(output: source, detail: "fixture", headline: "완료")
    }
}

private final class SummaryMockState: @unchecked Sendable {
    enum Mode { case success, length, empty, httpFailure }
    private let lock = NSLock()
    private var mode = Mode.success
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func reset(mode: Mode) { lock.lock(); defer { lock.unlock() }; self.mode = mode; recorded = [] }
    func reply(_ request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            captured.httpBody = data
        }
        recorded.append(captured)
        if request.url?.path == "/api/show" {
            return (200, Data(#"{"capabilities":["completion"],"model_info":{"fixture.context_length":32768}}"#.utf8))
        }
        switch mode {
        case .success: return (200, Data(###"{"response":"## 핵심 요약\n- 시험 범위: 3장.\n- 다음 주까지 과제 제출.","done_reason":"stop"}"###.utf8))
        case .length: return (200, Data(#"{"response":"잘린 요약","done_reason":"length"}"#.utf8))
        case .empty: return (200, Data(#"{"response":""}"#.utf8))
        case .httpFailure: return (500, Data())
        }
    }
}

private final class SummaryMockProtocol: URLProtocol, @unchecked Sendable {
    static let state = SummaryMockState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.state.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
