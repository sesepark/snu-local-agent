import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 출력 형식

/// The formats worth offering: every one of them opens somewhere useful without
/// the recipient installing anything. macOS encodes all but WebP itself, and
/// WebP is worth the one Homebrew dependency because it is the only lossy
/// format the whole web accepts that also keeps transparency.
enum ImageOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case original
    case jpeg
    case png
    case heic
    case webp
    case avif

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "원본 형식 유지"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .avif: "AVIF"
        }
    }

    var detail: String {
        switch self {
        case .original: "형식은 그대로 두고 용량만 줄입니다."
        case .jpeg: "어디서나 열립니다. 확실하지 않을 때 고르면 되는 기본값입니다."
        case .png: "무손실이라 화질이 그대로지만 용량은 거의 줄지 않습니다. 투명 지원."
        case .heic: "애플 기기에서 JPEG의 절반 용량입니다. 윈도우·웹에서는 열리지 않을 수 있습니다."
        case .webp: "웹·메신저·문서 어디에나 들어가고 투명도 유지합니다."
        case .avif: "가장 작지만 가장 최신이라 오래된 프로그램에서는 열리지 않습니다."
        }
    }

    var fileExtension: String {
        switch self {
        case .original: ""
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .webp: "webp"
        case .avif: "avif"
        }
    }

    var utType: UTType? {
        switch self {
        case .original: nil
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .webp: UTType("org.webmproject.webp")
        case .avif: UTType("public.avif")
        }
    }

    var supportsAlpha: Bool { self != .jpeg }

    /// PNG has no quality dial at all, so a level can only change its resolution.
    var isLossless: Bool { self == .png }

    /// Only WebP leaves ImageIO; everything else is encoded in-process.
    var requiresCWebP: Bool { self == .webp }

    /// Deliberately per-format: 0.4 is a mild setting for JPEG and a brutal one
    /// for AVIF, so a single shared number would make "강하게" mean different
    /// things depending on which format happened to be selected.
    func quality(for level: CompressionLevel) -> Double {
        switch self {
        case .jpeg, .original:
            switch level {
            case .light: 0.85
            case .standard: 0.60
            case .strong: 0.40
            }
        case .heic:
            switch level {
            case .light: 0.80
            case .standard: 0.55
            case .strong: 0.40
            }
        case .avif:
            switch level {
            case .light: 0.70
            case .standard: 0.50
            case .strong: 0.35
            }
        case .webp:
            switch level {
            case .light: 0.82
            case .standard: 0.72
            case .strong: 0.58
            }
        case .png:
            1
        }
    }

    static var cwebpPath: String? {
        ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isWebPAvailable: Bool { cwebpPath != nil }

    /// `원본 유지` has to become something concrete before encoding. A source in
    /// a format ImageIO cannot write (or does not recognise) falls back to JPEG
    /// rather than failing.
    static func resolved(_ choice: ImageOutputFormat, for source: URL) -> ImageOutputFormat {
        guard choice == .original else { return choice }
        switch source.pathExtension.lowercased() {
        case "png": return .png
        case "heic", "heif": return .heic
        case "webp": return isWebPAvailable ? .webp : .jpeg
        case "avif": return .avif
        default: return .jpeg
        }
    }
}

// MARK: - 압축

struct ImageCompressor: FileCompressor {
    private let runner = ProcessRunner()

    // MARK: 미리 읽기

    func inspect(_ source: URL, request: CompressionRequest) throws -> CompressionSourceInfo {
        let bytes = CompressionWorkspace.fileSize(of: source)
        guard let dimensions = Self.pixelSize(of: source) else {
            throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
        }
        let format = ImageOutputFormat.resolved(request.imageFormat, for: source)
        let megapixels = Double(dimensions.width * dimensions.height) / 1_000_000
        let rate = CompressionProgressEstimator.imageRates[format] ?? 100
        let attempts = request.isTargeting ? CompressionProgressEstimator.targetSizeAttempts : 1
        return CompressionSourceInfo(
            bytes: bytes,
            detail: "\(dimensions.width)×\(dimensions.height)",
            estimatedSeconds: max(0.02, megapixels / rate * attempts)
        )
    }

    /// Reads the header only — no pixels are decoded, so a folder of 48 MP
    /// photos is measured in milliseconds and the estimate can be size-aware.
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        // A sideways EXIF tag means the photo is displayed with the axes swapped.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5 ... 8).contains(orientation) ? (height, width) : (width, height)
    }

    // MARK: 본 처리

    func compress(
        _ source: URL,
        to destination: URL,
        request: CompressionRequest,
        progress: @escaping @Sendable (Double, Double?) -> Void
    ) async throws -> CompressionOutcome {
        let format = ImageOutputFormat.resolved(request.imageFormat, for: source)
        if format.requiresCWebP, ImageOutputFormat.cwebpPath == nil {
            throw AgentError.processFailed("WebP로 저장하려면 `brew install webp`가 필요합니다.")
        }
        let originalBytes = CompressionWorkspace.fileSize(of: source)
        let step: @Sendable (Double) -> Void = { progress($0, nil) }
        step(0.1)

        let encoded: Encoded
        if request.isTargeting {
            encoded = try await searchForTarget(source, format: format, request: request, progress: step)
        } else {
            encoded = try await encode(
                source,
                format: format,
                quality: format.quality(for: request.level),
                maxPixel: request.level.imageMaxPixel,
                edit: request.edit,
                progress: step
            )
        }
        step(0.95)

        // Re-encoding an already-optimised photo can easily make it bigger. When
        // the user asked to keep the format there is nothing to gain from that,
        // so the original is handed back untouched.
        // Not when the photo was edited: handing back the untouched original would
        // silently throw the user's crop away.
        if encoded.data.count >= originalBytes, request.imageFormat == .original, request.edit.isIdentity {
            let keep = destination.deletingPathExtension().appendingPathExtension(source.pathExtension)
            try? FileManager.default.removeItem(at: keep)
            try FileManager.default.copyItem(at: source, to: keep)
            let size = Self.pixelSize(of: source)
            return CompressionOutcome(
                output: keep,
                bytes: originalBytes,
                detail: size.map { "\($0.width)×\($0.height)" } ?? "",
                note: "원본이 이미 더 작습니다"
            )
        }

        try encoded.data.write(to: destination, options: .atomic)
        return CompressionOutcome(
            output: destination,
            bytes: encoded.data.count,
            detail: "\(encoded.width)×\(encoded.height)",
            note: format.isLossless ? "PNG는 무손실이라 해상도만 줄었습니다" : nil
        )
    }

    struct Encoded: Sendable {
        let data: Data
        let width: Int
        let height: Int
    }

    // MARK: 목표 용량

    /// Binary search on quality. Everything happens in memory — one pass on a
    /// 12 MP photo is 20~30 ms — so six attempts still finish well under a
    /// second. PNG has no quality dial, so for that format the search runs on
    /// resolution instead.
    private func searchForTarget(
        _ source: URL,
        format: ImageOutputFormat,
        request: CompressionRequest,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Encoded {
        let target = request.targetBytes
        if format.isLossless {
            var maxPixel = Self.pixelSize(of: source).map { max($0.width, $0.height) } ?? 4000
            var best = try await encode(source, format: format, quality: 1, maxPixel: maxPixel, edit: request.edit, progress: { _ in })
            for _ in 0 ..< 6 where best.data.count > target && maxPixel > 200 {
                maxPixel = Int(Double(maxPixel) * 0.75)
                best = try await encode(source, format: format, quality: 1, maxPixel: maxPixel, edit: request.edit, progress: { _ in })
            }
            return best
        }

        var maxPixel = request.level.imageMaxPixel
        for round in 0 ..< 3 {
            var low = 0.2
            var high = 0.95
            var best: Encoded?
            for step in 0 ..< 6 {
                let quality = (low + high) / 2
                let candidate = try await encode(source, format: format, quality: quality, maxPixel: maxPixel, edit: request.edit, progress: { _ in })
                progress(0.1 + 0.8 * (Double(round * 6 + step) / 18))
                if candidate.data.count <= target {
                    best = candidate
                    low = quality
                } else {
                    high = quality
                }
            }
            if let best { return best }
            // Even the lowest quality overshoots: the photo has to get smaller.
            let current = maxPixel ?? Self.pixelSize(of: source).map { max($0.width, $0.height) } ?? 4000
            maxPixel = max(320, current / 2)
        }
        return try await encode(source, format: format, quality: 0.2, maxPixel: maxPixel, edit: request.edit, progress: { _ in })
    }

    // MARK: 인코딩

    private func encode(
        _ source: URL,
        format: ImageOutputFormat,
        quality: Double,
        maxPixel: Int?,
        edit: PhotoEdit = .identity,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Encoded {
        var decoded = try Self.decode(source, maxPixel: maxPixel)
        // Applied here rather than by writing an edited file first: this keeps the
        // one decode-encode pass, and the source metadata the destination copies
        // is still the photo's own.
        if !edit.isIdentity {
            decoded = Decoded(image: edit.apply(to: decoded.image), properties: decoded.properties)
        }
        progress(0.4)
        if format.requiresCWebP {
            return try await encodeWebP(decoded, quality: quality)
        }
        guard let type = format.utType else {
            throw AgentError.processFailed("알 수 없는 출력 형식입니다.")
        }
        let image = Self.flattenIfNeeded(decoded.image, format: format)
        guard let data = Self.encodeWithImageIO(
            image, type: type, quality: quality, properties: decoded.properties, isLossless: format.isLossless
        ) else {
            throw AgentError.processFailed("\(format.title)으로 변환하지 못했습니다: \(source.lastPathComponent)")
        }
        return Encoded(data: data, width: image.width, height: image.height)
    }

    /// `@unchecked` because ImageIO hands metadata back as `[CFString: Any]`,
    /// which Swift cannot prove is safe to move between tasks. It is: this is a
    /// snapshot that is read and then written, never mutated after creation.
    struct Decoded: @unchecked Sendable {
        let image: CGImage
        /// The source's own metadata, already corrected for whether the rotation
        /// was baked into the pixels.
        let properties: [CFString: Any]
    }

    /// Decodes at the size we actually want.
    ///
    /// The downscaling path goes through `CGImageSourceCreateThumbnailAtIndex`
    /// rather than a manual redraw: it subsamples while decoding, so it is both
    /// faster and lighter on memory than decoding 48 MP and shrinking it. It
    /// also applies the EXIF transform, which means the rotation ends up in the
    /// pixels — so the orientation tag written alongside must be reset to 1 or
    /// every portrait photo comes out rotated twice.
    static func decode(_ source: URL, maxPixel: Int?) throws -> Decoded {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]) ?? [:]
        // The destination takes the real size from the image itself; leaving a
        // stale width here would only invite disagreement.
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)

        guard let maxPixel else {
            guard let image = CGImageSourceCreateImageAtIndex(
                imageSource, 0, [kCGImageSourceShouldCache: false] as CFDictionary
            ) else {
                throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
            }
            return Decoded(image: image, properties: properties)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            throw AgentError.processFailed("사진 크기를 줄이지 못했습니다: \(source.lastPathComponent)")
        }
        return Decoded(image: image, properties: Self.uprighted(properties))
    }

    /// Marks metadata as already-upright, at both the top level and inside the
    /// TIFF dictionary, since a leftover tag in either place rotates the result.
    static func uprighted(_ properties: [CFString: Any]) -> [CFString: Any] {
        var corrected = properties
        corrected[kCGImagePropertyOrientation] = 1
        if var tiff = corrected[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            corrected[kCGImagePropertyTIFFDictionary] = tiff
        }
        return corrected
    }

    /// JPEG cannot carry alpha, so a cutout or a screenshot with rounded corners
    /// would otherwise come out with black fringes. Reuses the 누끼 compositor.
    static func flattenIfNeeded(_ image: CGImage, format: ImageOutputFormat) -> CGImage {
        guard !format.supportsAlpha, Self.hasAlpha(image) else { return image }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        return CutoutComposer.compose(image, background: white) ?? image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    static func encodeWithImageIO(
        _ image: CGImage,
        type: UTType,
        quality: Double,
        properties: [CFString: Any],
        isLossless: Bool
    ) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var options = properties
        if !isLossless { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: WebP

    /// ImageIO reads WebP but cannot write it, so this is the one format that
    /// leaves the process.
    ///
    /// The intermediate is PNG: lossless, so nothing is thrown away before the
    /// real encode; alpha-capable, so a cutout stays transparent; and readable
    /// by cwebp's `-metadata all`, so the shot information survives whatever the
    /// source format was — including HEIC, which cwebp cannot open at all.
    /// TIFF looks like the better carrier and is not: cwebp answers a TIFF with
    /// "EXIF extraction from TIFF is unsupported" and silently drops the lot.
    private func encodeWebP(_ decoded: Decoded, quality: Double) async throws -> Encoded {
        guard let cwebp = ImageOutputFormat.cwebpPath else {
            throw AgentError.processFailed("WebP로 저장하려면 `brew install webp`가 필요합니다.")
        }
        guard let intermediate = Self.encodeWithImageIO(
            decoded.image, type: .png, quality: 1, properties: decoded.properties, isLossless: true
        ) else {
            throw AgentError.processFailed("WebP 변환용 중간 파일을 만들지 못했습니다.")
        }
        let directory = try CompressionWorkspace.directory()
        let stem = UUID().uuidString.prefix(8)
        let input = directory.appending(path: "\(stem).png")
        let output = directory.appending(path: "\(stem).webp")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try intermediate.write(to: input, options: .atomic)
        _ = try await runner.run(
            cwebp,
            ["-quiet", "-mt", "-metadata", "all", "-q", String(Int((quality * 100).rounded())), input.path, "-o", output.path],
            expectsStandardOutput: false
        )
        guard let data = try? Data(contentsOf: output) else {
            throw AgentError.processFailed("WebP로 변환하지 못했습니다.")
        }
        return Encoded(data: data, width: decoded.image.width, height: decoded.image.height)
    }
}
