import SwiftUI
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AppAccent: String, CaseIterable, Identifiable {
    case blue, teal, green, purple, orange, pink

    static let defaultsKey = "appAccentColor"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: "파랑"
        case .teal: "청록"
        case .green: "초록"
        case .purple: "보라"
        case .orange: "주황"
        case .pink: "분홍"
        }
    }

    static var saved: AppAccent {
        AppAccent(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .blue
    }
}

struct WatermarkPreferences: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case crest, kaist, mit, custom, none

        var title: String {
            switch self {
            case .crest: "서울대 로고"
            case .kaist: "KAIST 로고"
            case .mit: "MIT 로고"
            case .custom: "사용자 SVG / PNG"
            case .none: "없음"
            }
        }

        var bundledResource: String? {
            switch self {
            case .crest: "SeoulCrestWatermark"
            case .kaist: "KAISTLogoWatermark"
            case .mit: "MITLogoWatermark"
            case .custom, .none: nil
            }
        }

        var isInstitutional: Bool { bundledResource != nil }
    }
    enum Position: String, Codable, CaseIterable {
        case center, topLeading, topTrailing, bottomLeading, bottomTrailing
        var title: String {
            switch self {
            case .center: "가운데"
            case .topLeading: "왼쪽 위"
            case .topTrailing: "오른쪽 위"
            case .bottomLeading: "왼쪽 아래"
            case .bottomTrailing: "오른쪽 아래"
            }
        }
        var alignment: Alignment {
            switch self {
            case .center: .center
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }
    }
    var mode: Mode = .crest
    var position: Position = .center
    var width = 520.0
    var opacity = 0.04
    var monochrome = false
    var imageFileName: String?
    var sourceName: String?
}

enum WatermarkImporter {
    static let maximumBytes = 10 * 1_024 * 1_024

    static func validateSVG(_ data: Data) throws {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw AgentError.processFailed("SVG는 UTF-8 형식, 10MB 이하만 지원합니다.")
        }
        let lowered = text.lowercased()
        guard !lowered.contains("<!doctype"), !lowered.contains("<!entity"), !lowered.contains("@import"),
              !lowered.contains("<?xml-stylesheet"), !lowered.contains("javascript:") else {
            throw AgentError.processFailed("스크립트·외부 리소스·XML 엔티티가 있는 SVG는 사용할 수 없습니다.")
        }
        // CSS resource URLs may only point to definitions inside this SVG.
        let pattern = #"url\(\s*[\"']?\s*([^\s\"')]+)"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            if let found = Range(match.range(at: 1), in: text), !text[found].hasPrefix("#") {
                throw AgentError.processFailed("외부 이미지나 폰트를 참조하는 SVG는 사용할 수 없습니다.")
            }
        }
        let delegate = SafeSVGParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.isSVG, !delegate.unsafe else {
            throw AgentError.processFailed("올바른 SVG가 아니거나 안전하지 않은 요소가 포함되어 있습니다.")
        }
    }

    @MainActor
    static func image(from data: Data, extension ext: String) throws -> NSImage {
        guard data.count <= maximumBytes else { throw AgentError.processFailed("배경 파일은 10MB 이하만 지원합니다.") }
        if ext.lowercased() == "svg" { try validateSVG(data) }
        else if ext.lowercased() == "png" {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = props[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0,
                  width.doubleValue * height.doubleValue <= 40_000_000 else {
                throw AgentError.processFailed("올바른 PNG가 아니거나 이미지가 너무 큽니다 (최대 4000만 픽셀).")
            }
        } else { throw AgentError.processFailed("SVG와 PNG만 지원합니다.") }
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
              image.size.width.isFinite, image.size.height.isFinite else {
            throw AgentError.processFailed("배경 이미지를 읽지 못했습니다.")
        }
        return image
    }

    @MainActor
    static func cachedPNG(_ image: NSImage) throws -> Data {
        let scale = min(1, 1_280 / max(image.size.width, image.size.height))
        let width = max(1, Int(image.size.width * scale))
        let height = max(1, Int(image.size.height * scale))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw AgentError.processFailed("배경 미리보기를 만들지 못했습니다.")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero,
                   operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw AgentError.processFailed("배경 이미지를 캐시하지 못했습니다.")
        }
        return png
    }
}

private final class SafeSVGParser: NSObject, XMLParserDelegate {
    var isSVG = false
    var unsafe = false
    private var sawRoot = false
    private var styleText: String?
    private var depth = 0
    private var elements = 0
    private func checkCSS(_ value: String) {
        let text = value.lowercased()
        if text.contains("\\") || text.contains("@import") || text.contains("javascript:") { unsafe = true }
        let regex = try? NSRegularExpression(pattern: #"url\(\s*[\"']?\s*([^\s\"')]+)"#, options: .caseInsensitive)
        for match in regex?.matches(in: value, range: NSRange(value.startIndex..., in: value)) ?? [] {
            if let range = Range(match.range(at: 1), in: value), !value[range].hasPrefix("#") { unsafe = true }
        }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1; elements += 1
        if depth > 128 || elements > 50_000 { unsafe = true }
        let element = name.lowercased().split(separator: ":").last.map(String.init) ?? ""
        if !sawRoot { isSVG = element == "svg"; sawRoot = true }
        if element == "style" { styleText = "" }
        if ["script", "foreignobject", "iframe", "object", "embed", "animate", "set", "animatetransform", "animatemotion"].contains(element) { unsafe = true }
        for (key, value) in attributes {
            checkCSS(value) // Decoded XML attributes, not just raw source text.
            let key = key.lowercased()
            if key.hasPrefix("on") || key == "xml:base" { unsafe = true }
            if key == "href" || key.hasSuffix(":href") || key == "src" {
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#") { unsafe = true }
            }
        }
        if unsafe { parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if styleText != nil { styleText?.append(string) }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if styleText != nil { styleText?.append(String(decoding: data, as: UTF8.self)) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        depth -= 1
        if name.lowercased().hasSuffix("style"), let text = styleText {
            checkCSS(text); styleText = nil
            if unsafe { parser.abortParsing() }
        }
    }
}

@MainActor
final class AppearanceModel: ObservableObject {
    static let shared = AppearanceModel()
    @Published var preferences: WatermarkPreferences { didSet { persist() } }
    @Published var accent: AppAccent {
        didSet { UserDefaults.standard.set(accent.rawValue, forKey: AppAccent.defaultsKey) }
    }
    @Published private(set) var customImage: NSImage?
    @Published private(set) var error: String?
    private let directory: URL
    private var preferencesURL: URL { directory.appending(path: "appearance.json") }

    init(directory: URL? = nil) {
        accent = .saved
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SeoulLocalAgent/Appearance", directoryHint: .isDirectory)
        let file = self.directory.appending(path: "appearance.json")
        if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(WatermarkPreferences.self, from: data) {
            preferences = value
        } else { preferences = .init() }
        if let name = preferences.imageFileName, name == (name as NSString).lastPathComponent {
            customImage = NSImage(contentsOf: self.directory.appending(path: name))
            if customImage == nil { error = "사용자 배경 캐시가 없습니다. 이미지를 다시 선택해 주세요." }
        }
    }

    func importFile(_ file: URL) throws {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= WatermarkImporter.maximumBytes else { throw AgentError.processFailed("배경 파일은 10MB 이하만 지원합니다.") }
        let data = try Data(contentsOf: file)
        let image = try WatermarkImporter.image(from: data, extension: file.pathExtension)
        let png = try WatermarkImporter.cachedPNG(image)
        let identifier = UUID().uuidString
        let name = "\(identifier).png"
        try LocalFileStorage.write(data, to: directory.appending(path: "\(identifier)-source.\(file.pathExtension.lowercased())"))
        try LocalFileStorage.write(png, to: directory.appending(path: name))
        var updated = preferences
        updated.imageFileName = name; updated.sourceName = file.lastPathComponent; updated.mode = .custom
        // Commit preferences only after all image writes succeed.
        try LocalFileStorage.write(try JSONEncoder().encode(updated), to: preferencesURL)
        customImage = NSImage(data: png)
        error = nil
        preferences = updated
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg, .png]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do { try importFile(file) } catch { self.error = error.localizedDescription }
    }

    func reset() { preferences = .init(); accent = .blue; customImage = nil }
    private func persist() {
        do { try LocalFileStorage.write(try JSONEncoder().encode(preferences), to: preferencesURL) }
        catch { self.error = "모양 설정을 저장하지 못했습니다: \(error.localizedDescription)" }
    }
}

struct AppearanceSettingsView: View {
    @ObservedObject var appearance = AppearanceModel.shared
    var body: some View {
        Form {
            Section("앱 색상") {
                Picker("강조 색상", selection: $appearance.accent) {
                    ForEach(AppAccent.allCases) { accent in
                        Label {
                            Text(accent.title)
                        } icon: {
                            Circle().fill(accent.color).frame(width: 12, height: 12)
                        }
                        .tag(accent)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("버튼, 선택 표시, 진행 막대와 주요 아이콘에 적용됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("배경 워터마크") {
                Picker("배경", selection: $appearance.preferences.mode) {
                    ForEach(WatermarkPreferences.Mode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                HStack {
                    Button("SVG / PNG 선택…") { appearance.chooseFile() }
                    Text(appearance.preferences.sourceName ?? "선택한 사용자 이미지 없음").font(.caption).lineLimit(2)
                }
                if let error = appearance.error { Text(error).foregroundStyle(.red).font(.caption) }
                Picker("위치", selection: $appearance.preferences.position) {
                    ForEach(WatermarkPreferences.Position.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("크기 \(Int(appearance.preferences.width))") {
                    Slider(value: $appearance.preferences.width, in: 180...800, step: 10)
                }
                LabeledContent("투명도 \(Int(appearance.preferences.opacity * 100))%") {
                    Slider(value: $appearance.preferences.opacity, in: 0.01...0.3, step: 0.01)
                }
                Toggle("사용자 이미지 단색 표시", isOn: $appearance.preferences.monochrome)
                Text("이미지는 앱 내부에 보관됩니다. 원본을 옮겨도 유지됩니다. 외부 리소스나 스크립트가 있는 SVG는 차단합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("기본 모양으로 복원") { appearance.reset() }
            }
            Section("미리보기") {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    CrestWatermark(appearance: appearance)
                    Text("본문은 배경 위에 표시됩니다.").foregroundStyle(.secondary)
                }.frame(height: 180).clipped()
            }
        }.formStyle(.grouped)
    }
}
