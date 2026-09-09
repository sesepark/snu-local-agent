import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - 모델

/// How much bigger, and by what means.
///
/// Real-ESRGAN is the open-source upscaler that photo tools have converged on;
/// the weights are RRDBNet checkpoints loaded through `spandrel` and run on this
/// Mac's GPU. The Lanczos option is not a worse model — it is not a model at
/// all, which is exactly why it belongs here: it needs no download and is the
/// honest choice for a picture that is merely small rather than degraded.
enum UpscaleModel: String, CaseIterable, Identifiable, Sendable {
    case realESRGANx4
    case realESRGANx2
    case lanczos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .realESRGANx4: "정밀 4배 (Real-ESRGAN)"
        case .realESRGANx2: "표준 2배 (Real-ESRGAN)"
        case .lanczos: "빠름 2배 (내장)"
        }
    }

    var detail: String {
        switch self {
        case .realESRGANx4: "가장 크게 늘리고 뭉개진 부분까지 되살립니다. 12MP 사진 기준 1분 안팎, 첫 실행에 약 65MB를 내려받습니다."
        case .realESRGANx2: "흐린 강의 슬라이드 사진에 알맞습니다. 4배보다 훨씬 빠르고 결과가 자연스럽습니다."
        case .lanczos: "다운로드 없이 즉시 처리합니다. 없던 디테일을 만들어내지는 않으니, 단순히 작은 사진을 크게 쓸 때 고르세요."
        }
    }

    var scale: Int {
        switch self {
        case .realESRGANx4: 4
        case .realESRGANx2, .lanczos: 2
        }
    }

    /// The `model` value understood by `scripts/media_runner.py`; `nil` means
    /// this choice never launches Python.
    var runnerValue: String? {
        switch self {
        case .realESRGANx4: "realesrgan-x4"
        case .realESRGANx2: "realesrgan-x2"
        case .lanczos: nil
        }
    }

    var usesRunner: Bool { runnerValue != nil }
}

enum UpscaleFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    case heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .png: "PNG (무손실)"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        }
    }

    var utType: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .heic: .heic
        }
    }
}

struct UpscaleRequest: Sendable {
    var model: UpscaleModel = .realESRGANx2
    var format: UpscaleFormat = .png
    /// Above this on the long edge the result is scaled back down. A 48 MP photo
    /// at four times over is 768 million pixels, which is a three-gigabyte file
    /// nothing will open — never what someone reaching for this tool wanted.
    var maximumLongEdge = 6000
}

// MARK: - 작업자

struct UpscaleWorker: BatchToolWorker {
    let request: UpscaleRequest

    var accepts: Set<String> { CompressionKind.imageExtensions }

    /// The model path goes through one resident process; Lanczos is Core Image
    /// and happily runs several at once.
    var concurrency: Int { request.model.usesRunner ? 1 : 3 }

    var saveSuffix: String { "확대" }

    func outputExtension(for source: URL) -> String { request.format.fileExtension }

    func inspect(_ source: URL) async throws -> ToolJobInfo {
        guard let size = Self.pixelSize(of: source) else {
            throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
        }
        let megapixels = Double(size.width * size.height) / 1_000_000
        let target = Self.targetSize(for: size, scale: request.model.scale, cap: request.maximumLongEdge)
        // Measured on an M2 Max: Real-ESRGAN manages about a third of a megapixel
        // of *input* per second; Lanczos is effectively instant.
        let seconds = request.model.usesRunner ? megapixels / 0.33 + 3 : 0.2
        return ToolJobInfo(
            detail: "\(size.width)×\(size.height) → \(target.width)×\(target.height)",
            estimatedSeconds: seconds
        )
    }

    func run(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ToolOutcome {
        guard let size = Self.pixelSize(of: source) else {
            throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
        }
        let target = Self.targetSize(for: size, scale: request.model.scale, cap: request.maximumLongEdge)
        progress(0.05)

        if let runnerModel = request.model.runnerValue {
            // The runner always writes PNG and this converts, which keeps every
            // image encoder the project depends on inside macOS rather than
            // adding a Python imaging plug-in per format.
            let scratch = try ToolWorkspace.directory("Upscale")
            let stage = scratch.appending(path: "확대-\(UUID().uuidString.prefix(6)).png")
            defer { try? FileManager.default.removeItem(at: stage) }
            _ = try await MediaDaemon.shared.send(
                task: "upscale", source: source, destination: stage,
                payload: [
                    "model": runnerModel,
                    "maxLongEdge": request.maximumLongEdge,
                ]
            ) { _, fraction in
                if let fraction { progress(0.05 + 0.85 * fraction) }
            }
            progress(0.92)
            try Self.convert(stage, to: destination, format: request.format)
        } else {
            try Self.lanczos(source, to: destination, target: target, format: request.format)
        }
        progress(1)

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw AgentError.processFailed("확대한 사진을 만들지 못했습니다.")
        }
        let actual = Self.pixelSize(of: destination) ?? target
        let before = CompressionWorkspace.fileSize(of: source)
        let after = CompressionWorkspace.fileSize(of: destination)
        let capped = actual.width < size.width * request.model.scale && actual.width > size.width
        return ToolOutcome(
            output: destination,
            detail: "\(size.width)×\(size.height) → \(actual.width)×\(actual.height)",
            headline: "\(CompressionFormat.bytes(before)) → \(CompressionFormat.bytes(after))",
            note: capped ? "원본이 커서 긴 변 \(request.maximumLongEdge)px에 맞춰 줄였습니다." : nil
        )
    }

    // MARK: 내장 확대

    /// Lanczos for the resample and a light unsharp mask afterwards, which is
    /// what makes it look like an enlargement rather than a blur. Core Image
    /// runs both on the GPU in one pass.
    static func lanczos(_ source: URL, to destination: URL, target: (width: Int, height: Int), format: UpscaleFormat) throws {
        guard let image = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
            throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
        }
        let scale = Double(target.width) / max(1, image.extent.width)
        guard let resampler = CIFilter(name: "CILanczosScaleTransform") else {
            throw AgentError.processFailed("확대 필터를 준비하지 못했습니다.")
        }
        resampler.setValue(image, forKey: kCIInputImageKey)
        resampler.setValue(scale, forKey: kCIInputScaleKey)
        resampler.setValue(1.0, forKey: kCIInputAspectRatioKey)
        guard var output = resampler.outputImage else {
            throw AgentError.processFailed("사진을 확대하지 못했습니다.")
        }
        if let sharpen = CIFilter(name: "CIUnsharpMask") {
            sharpen.setValue(output, forKey: kCIInputImageKey)
            sharpen.setValue(2.5, forKey: kCIInputRadiusKey)
            sharpen.setValue(0.5, forKey: kCIInputIntensityKey)
            if let sharpened = sharpen.outputImage { output = sharpened }
        }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(output, from: output.extent) else {
            throw AgentError.processFailed("확대한 사진을 만들지 못했습니다.")
        }
        try write(cgImage, to: destination, format: format)
    }

    /// Re-encodes the runner's PNG into the requested format. PNG asks for
    /// nothing, so the file is simply moved rather than decoded and written back
    /// out at the cost of a few hundred megabytes of work.
    static func convert(_ stage: URL, to destination: URL, format: UpscaleFormat) throws {
        if format == .png {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: stage, to: destination)
            return
        }
        guard let source = CGImageSourceCreateWithURL(stage as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw AgentError.processFailed("확대한 사진을 읽지 못했습니다.") }
        try write(image, to: destination, format: format)
    }

    static func write(_ image: CGImage, to destination: URL, format: UpscaleFormat, quality: Double = 0.92) throws {
        guard let sink = CGImageDestinationCreateWithURL(destination as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw AgentError.processFailed("결과 파일을 만들지 못했습니다.")
        }
        let options: [CFString: Any] = format == .png ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(sink, image, options as CFDictionary)
        guard CGImageDestinationFinalize(sink) else {
            throw AgentError.processFailed("결과 파일을 저장하지 못했습니다.")
        }
    }

    // MARK: 크기

    /// Reads the header only. A 48 MP photo does not need decoding just to find
    /// out how big it is.
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // A photo shot in portrait stores landscape pixels plus an orientation
        // flag, and the enlargement has to be described the way it will look.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5 ... 8).contains(orientation) ? (height, width) : (width, height)
    }

    static func targetSize(for size: (width: Int, height: Int), scale: Int, cap: Int) -> (width: Int, height: Int) {
        var width = size.width * scale
        var height = size.height * scale
        let longEdge = max(width, height)
        if longEdge > cap {
            let factor = Double(cap) / Double(longEdge)
            width = max(1, Int((Double(width) * factor).rounded()))
            height = max(1, Int((Double(height) * factor).rounded()))
        }
        return (width, height)
    }
}
