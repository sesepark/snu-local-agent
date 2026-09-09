import Foundation
import AVFoundation
import CoreGraphics
import PDFKit

// MARK: - 파일 종류

/// What a dropped file is, and therefore which compressor handles it. A single
/// batch routinely mixes all three — a folder of lecture material holds slides,
/// scans and a recording — so the tab sorts them itself instead of asking.
enum CompressionKind: String, CaseIterable, Identifiable, Sendable {
    case image
    case pdf
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "사진"
        case .pdf: "PDF"
        case .video: "영상"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "film"
        }
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "webp", "jp2"]
    static let pdfExtensions: Set<String> = ["pdf"]
    static var videoExtensions: Set<String> { MediaImporter.videoExtensions }

    static func of(_ url: URL) -> CompressionKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if pdfExtensions.contains(ext) { return .pdf }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    static var allExtensions: Set<String> {
        imageExtensions.union(pdfExtensions).union(videoExtensions)
    }
}

// MARK: - 압축 정도

/// The three steps the user actually chooses between. Each one carries a full
/// parameter set per file kind rather than a single "quality" number, because
/// the same 0.4 means something very different to AVIF than to JPEG, and PDFs
/// respond almost entirely to downsampling rather than to quality at all.
enum CompressionLevel: String, CaseIterable, Identifiable, Sendable {
    case light
    case standard
    case strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "가볍게"
        case .standard: "표준"
        case .strong: "강하게"
        }
    }

    var detail: String {
        switch self {
        case .light: "화질을 거의 그대로 두고 해상도도 원본을 유지합니다."
        case .standard: "일상적인 공유에 충분합니다. 사진은 긴 변 2560px, 영상은 1080p로 맞춥니다."
        case .strong: "용량을 최우선으로 줄입니다. 사진은 긴 변 1600px, 영상은 720p입니다."
        }
    }

    /// `nil` keeps the source resolution.
    var imageMaxPixel: Int? {
        switch self {
        case .light: nil
        case .standard: 2560
        case .strong: 1600
        }
    }

    var pdfMaxPixel: Int {
        switch self {
        case .light: 3000
        case .standard: 2000
        case .strong: 1400
        }
    }

    var pdfQuality: Double {
        switch self {
        case .light: 0.80
        case .standard: 0.60
        case .strong: 0.40
        }
    }

    var pdfResolution: Int {
        switch self {
        case .light: 200
        case .standard: 144
        case .strong: 96
        }
    }

    /// Used only when the Quartz filter cannot shrink a page at all and the
    /// document turns out to carry no text worth preserving.
    var pdfRasterDPI: Double {
        switch self {
        case .light: 200
        case .standard: 144
        case .strong: 96
        }
    }

    var pdfRasterQuality: Double {
        switch self {
        case .light: 0.80
        case .standard: 0.60
        case .strong: 0.45
        }
    }

    /// `nil` keeps the source resolution; 4K is still capped so a phone's 8K
    /// clip does not sail through "가볍게" untouched.
    var videoMaxPixel: Int? {
        switch self {
        case .light: 3840
        case .standard: 1920
        case .strong: 1280
        }
    }

    /// VideoToolbox's 1–100 quality scale.
    var videoQuality: Int {
        switch self {
        case .light: 60
        case .standard: 50
        case .strong: 40
        }
    }

    var audioBitrateKbps: Int {
        switch self {
        case .light: 192
        case .standard: 128
        case .strong: 96
        }
    }
}

// MARK: - 모드

enum CompressionMode: String, CaseIterable, Identifiable, Sendable {
    case level
    case targetSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .level: "압축 3단계"
        case .targetSize: "목표 용량"
        }
    }
}

/// Everything the tab has configured, frozen at the moment a batch starts so a
/// picker change mid-run cannot make half the files come out differently.
struct CompressionRequest: Sendable {
    var mode: CompressionMode = .level
    var level: CompressionLevel = .standard
    var targetBytes: Int = 1_048_576
    var imageFormat: ImageOutputFormat = .jpeg
    var videoCodec: VideoOutputCodec = .h264
    /// Per photo, not per run: the caller rebuilds the request for each item so a
    /// crop made on one picture never lands on the next one.
    var edit: PhotoEdit = .identity

    var isTargeting: Bool { mode == .targetSize }
}

// MARK: - 결과

/// What one compressor hands back. `note` is for things the user needs told
/// rather than errors — a PDF that could not shrink, a file already smaller
/// than anything we could produce.
struct CompressionOutcome: Sendable {
    let output: URL
    let bytes: Int
    let detail: String
    var note: String?
}

/// Read from the source before any work starts: enough to show the card and to
/// seed the estimate, without decoding anything.
struct CompressionSourceInfo: Sendable {
    let bytes: Int
    let detail: String
    /// Seconds this file is expected to take, from the measured rates below.
    let estimatedSeconds: Double
}

protocol FileCompressor: Sendable {
    /// Cheap enough to run on every file the moment a batch is dropped: it reads
    /// headers, never pixels. Async only because a video's duration comes from
    /// `AVAsset`, which loads asynchronously.
    func inspect(_ source: URL, request: CompressionRequest) async throws -> CompressionSourceInfo
    /// `progress` reports how far along this file is, plus how many seconds it
    /// has left when the backend actually knows — ffmpeg does, ImageIO does not.
    func compress(
        _ source: URL,
        to destination: URL,
        request: CompressionRequest,
        progress: @escaping @Sendable (Double, Double?) -> Void
    ) async throws -> CompressionOutcome
}

// MARK: - 대기열 항목

/// One file and everything that has happened to it. Mirrors `CutoutItem`, with
/// the before/after numbers that are the whole point of this tab.
struct CompressionItem: Identifiable, Sendable {
    enum State: Sendable, Equatable {
        case waiting
        case working(Double)
        case done
        case skipped(String)
        case failed(String)
    }

    let id = UUID()
    let source: URL
    let kind: CompressionKind
    var originalBytes: Int
    var originalDetail: String
    var output: URL?
    var compressedBytes: Int?
    var outputDetail: String?
    var note: String?
    var state: State = .waiting
    /// Applied while compressing, so the crop costs no extra encode pass and the
    /// shot metadata still travels the compressor's own path.
    var edit: PhotoEdit = .identity

    var isFinished: Bool { if case .done = state { true } else { false } }

    var isFailed: Bool {
        switch state {
        case .failed, .skipped: true
        default: false
        }
    }

    /// Negative means it got smaller, which is the normal case.
    var savedFraction: Double? {
        guard let compressedBytes, originalBytes > 0 else { return nil }
        return 1 - Double(compressedBytes) / Double(originalBytes)
    }

    var sizeText: String {
        guard let compressedBytes else { return CompressionFormat.bytes(originalBytes) }
        let saved = Int(((savedFraction ?? 0) * 100).rounded())
        return "\(CompressionFormat.bytes(originalBytes)) → \(CompressionFormat.bytes(compressedBytes)) (−\(saved)%)"
    }

    var specText: String {
        guard let outputDetail, outputDetail != originalDetail else { return originalDetail }
        return "\(originalDetail) → \(outputDetail)"
    }

    var statusText: String {
        switch state {
        // An edited card is back to waiting on purpose; saying only "대기 중" left
        // the user to guess why the finished result had disappeared.
        case .waiting: edit.isIdentity ? "대기 중" : "편집함 · 다시 실행하면 반영됩니다"
        case .working(let fraction): fraction > 0 ? "처리 중 \(Int(fraction * 100))%" : "처리 중"
        case .done: note ?? sizeText
        case .skipped(let reason): reason
        case .failed(let message): message
        }
    }
}

// MARK: - 표시 형식

enum CompressionFormat {
    static func bytes(_ count: Int) -> String {
        let value = Double(count)
        if value >= 1_048_576 { return String(format: "%.1f MB", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KB", value / 1024) }
        return "\(count) B"
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return minutes > 0 ? "\(minutes)분 \(remainder)초" : "\(remainder)초"
    }
}

// MARK: - 남은 시간 추정

/// Estimates how much longer a mixed batch will take.
///
/// The unit is predicted seconds, not files: one batch happily holds a 2 MP
/// screenshot, a 48 MP photo and a ten-minute lecture recording, and counting
/// files would put the estimate out by an order of magnitude. Each kind gets a
/// calibration multiplier that is corrected from what actually happened, so the
/// published rates below only ever matter for the first file or two — after
/// that the estimate reflects this machine. Because the correction compares
/// against wall-clock time it also absorbs however many files run at once.
///
/// A video reports its own remaining time from ffmpeg, which is a measurement
/// rather than a guess, so `note(id:remaining:)` overrides the estimate for
/// whichever file is currently encoding.
struct CompressionProgressEstimator: Sendable {
    /// Measured on an M2 Max: megapixels per second, per output format.
    static let imageRates: [ImageOutputFormat: Double] = [
        .original: 120, .jpeg: 130, .png: 28, .heic: 85, .avif: 85, .webp: 24,
    ]
    /// Seconds per PDF page through the Quartz filter.
    static let pdfSecondsPerPage = 0.012
    /// Multiples of realtime the hardware encoder manages.
    static let videoSpeed = 10.0
    /// A target-size search re-encodes the same file several times.
    static let targetSizeAttempts = 4.0

    private struct Entry: Sendable {
        let kind: CompressionKind
        let estimate: Double
        var liveRemaining: Double?
    }

    private var entries: [UUID: Entry] = [:]
    private var calibration: [CompressionKind: Double] = [:]

    var isEmpty: Bool { entries.isEmpty }

    mutating func add(id: UUID, kind: CompressionKind, estimate: Double) {
        entries[id] = Entry(kind: kind, estimate: max(0.01, estimate))
    }

    /// ffmpeg's own reckoning for the file it is working on.
    mutating func note(id: UUID, remaining: Double) {
        entries[id]?.liveRemaining = max(0, remaining)
    }

    mutating func finish(id: UUID, actual: Double) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        guard actual > 0.05, entry.estimate > 0 else { return }
        let ratio = min(10, max(0.1, actual / entry.estimate))
        let previous = calibration[entry.kind] ?? 1
        calibration[entry.kind] = previous * 0.6 + ratio * 0.4
    }

    mutating func drop(id: UUID) {
        entries.removeValue(forKey: id)
    }

    var remainingSeconds: Double {
        entries.values.reduce(0) { total, entry in
            total + (entry.liveRemaining ?? entry.estimate * (calibration[entry.kind] ?? 1))
        }
    }

    /// Matches the wording the 자동 브리핑 screen already uses.
    static func text(_ seconds: Double) -> String {
        guard seconds > 0.5 else { return "" }
        if seconds < 60 { return "예상 남은 시간 약 \(max(1, Int(seconds.rounded())))초" }
        return "예상 남은 시간 약 \(max(1, Int((seconds / 60).rounded())))분"
    }
}

// MARK: - 작업 폴더

enum CompressionWorkspace {
    /// Where results land before the user picks a real destination. Separate
    /// from the 누끼 folder so clearing one never disturbs the other.
    static func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SeoulLocalAgent-Compress", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func outputURL(for source: URL, extension fileExtension: String, in directory: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        return directory.appending(path: "\(stem)-압축-\(UUID().uuidString.prefix(6)).\(fileExtension)")
    }

    static func saveName(for item: CompressionItem) -> String {
        let stem = item.source.deletingPathExtension().lastPathComponent
        let ext = item.output?.pathExtension ?? item.source.pathExtension
        return "\(stem)-압축.\(ext)"
    }

    /// A save target that does not stand on an existing file.
    ///
    /// Both photo tabs save a whole batch into one folder, and two photos from
    /// different folders can share a name. Writing straight to it replaced the
    /// first result with the second, with nothing said.
    static func uniqueURL(in directory: URL, name: String) -> URL {
        let candidate = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for suffix in 2 ... 999 {
            let next = directory.appending(path: "\(stem) \(suffix).\(ext)")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return directory.appending(path: "\(stem)-\(UUID().uuidString.prefix(6)).\(ext)")
    }

    static func fileSize(of url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Walks a dropped folder for anything this tab can handle. Bounded on both
    /// depth and count so dropping a home folder by accident cannot hang the app.
    static func expand(_ urls: [URL], maxDepth: Int = 3, limit: Int = 500) -> (files: [URL], truncated: Bool) {
        var files: [URL] = []
        var truncated = false
        var queue: [(URL, Int)] = urls.map { ($0, 0) }
        while !queue.isEmpty {
            let (url, depth) = queue.removeFirst()
            if files.count >= limit { truncated = true; break }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard depth < maxDepth else { continue }
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )) ?? []
                queue.append(contentsOf: children.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { ($0, depth + 1) })
            } else if CompressionKind.of(url) != nil {
                files.append(url)
            }
        }
        return (files, truncated)
    }
}


// MARK: - 미리보기

/// One thumbnail routine for all three kinds, so the card does not need to know
/// what it is showing. Always renders the *result* when there is one, which is
/// what makes a too-aggressive setting visible before anything is saved.
enum CompressionThumbnail {
    static func image(for item: CompressionItem, maxPixel: Int) async -> CGImage? {
        let url = item.output ?? item.source
        switch item.kind {
        case .image:
            // Reuses the 누끼 tab's downscaling compositor; a phone photo is far
            // larger than the card and redoing that per redraw would stutter.
            return CutoutComposer.preview(of: url, maxPixel: maxPixel, background: CGColor(gray: 1, alpha: 1))
        case .pdf:
            return pdfFirstPage(url, maxPixel: maxPixel)
        case .video:
            return await videoFrame(url, maxPixel: maxPixel)
        }
    }

    static func pdfFirstPage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(1, Double(maxPixel) / Double(max(bounds.width, bounds.height)))
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    static func videoFrame(_ url: URL, maxPixel: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // A frame one second in: the very first frame of a lecture recording is
        // usually a black fade.
        for seconds in [1.0, 0.0] {
            if let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image {
                return image
            }
        }
        return nil
    }
}
