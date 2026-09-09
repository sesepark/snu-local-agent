import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import PDFKit
import Vision
import simd

// MARK: - 마무리

/// What the corrected page should look like.
///
/// The default is not "leave the colours alone": someone photographing a
/// handout wants it to read like a scan, and a phone photo of white paper in a
/// lecture hall is grey, yellow and unevenly lit. 원본 색 is there for the cases
/// where the colour is the content — a marked-up diagram, a colour-coded chart.
enum ScanFinish: String, CaseIterable, Identifiable, Sendable {
    case bright
    case colour
    case mono

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bright: "문서 (권장)"
        case .colour: "원본 색"
        case .mono: "흑백"
        }
    }

    var detail: String {
        switch self {
        case .bright: "종이를 하얗게 펴고 그늘과 손그림자를 지웁니다. 글씨는 그대로 둡니다."
        case .colour: "색을 그대로 두고 반듯하게 펴기만 합니다. 색이 내용인 자료에 쓰세요."
        case .mono: "글씨만 남기고 흑백으로 만듭니다. 용량이 가장 작습니다."
        }
    }

    var removesShading: Bool { self != .colour }
}

enum ScanResolution: String, CaseIterable, Identifiable, Sendable {
    case screen
    case standard
    case print

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: "화면용"
        case .standard: "표준"
        case .print: "인쇄용"
        }
    }

    /// The long edge in pixels. A4 at 200 dpi is about 2340, which is the point
    /// where text stops looking soft on screen and starts costing real megabytes.
    var longEdge: Int {
        switch self {
        case .screen: 1600
        case .standard: 2400
        case .print: 3500
        }
    }

    var detail: String {
        switch self {
        case .screen: "긴 변 1600px. 읽고 공유하기에 충분하고 가장 가볍습니다."
        case .standard: "긴 변 2400px. A4를 200dpi로 스캔한 것과 비슷합니다."
        case .print: "긴 변 3500px. 다시 인쇄하거나 작은 글씨를 확대할 때 고르세요."
        }
    }
}

enum ScanOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf
    case jpeg
    case png

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .jpeg: "JPEG"
        case .png: "PNG"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .jpeg: "jpg"
        case .png: "png"
        }
    }
}

struct ScanRequest: Sendable {
    var finish: ScanFinish = .bright
    var resolution: ScanResolution = .standard
    var format: ScanOutputFormat = .pdf
    /// Off for a picture that is already a flat scan and only needs the tidying.
    var detectsEdges = true
}

// MARK: - 작업자

struct ScanCorrectionWorker: BatchToolWorker {
    let request: ScanRequest

    var accepts: Set<String> { CompressionKind.imageExtensions }
    var concurrency: Int { 3 }
    var saveSuffix: String { "스캔" }

    func outputExtension(for source: URL) -> String { request.format.fileExtension }

    func inspect(_ source: URL) async throws -> ToolJobInfo {
        guard let size = UpscaleWorker.pixelSize(of: source) else {
            throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
        }
        let megapixels = Double(size.width * size.height) / 1_000_000
        return ToolJobInfo(
            detail: "\(size.width)×\(size.height)",
            // Edge detection is a Vision model pass; the rest is Core Image and
            // effectively free next to it.
            estimatedSeconds: megapixels * 0.12 + 0.4
        )
    }

    func run(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ToolOutcome {
        guard let original = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
            throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)")
        }
        progress(0.15)

        var image = original
        var cropped = false
        if request.detectsEdges, let quad = try await Self.documentQuad(in: source) {
            image = Self.correctPerspective(original, quad: quad)
            let size = original.extent.size
            func pixel(_ normalised: CGPoint) -> CGPoint {
                CGPoint(x: normalised.x * size.width, y: normalised.y * size.height)
            }
            if let ratio = Self.aspectRatio(
                topLeft: pixel(quad.topLeft), topRight: pixel(quad.topRight),
                bottomLeft: pixel(quad.bottomLeft), bottomRight: pixel(quad.bottomRight),
                imageSize: size
            ) {
                image = Self.restoreAspect(image, ratio: ratio)
            }
            cropped = true
        }
        progress(0.5)

        image = Self.resize(image, longEdge: request.resolution.longEdge)
        image = Self.applyFinish(image, finish: request.finish)
        progress(0.75)

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let page = context.createCGImage(image, from: image.extent) else {
            throw AgentError.processFailed("보정한 결과를 만들지 못했습니다.")
        }
        try Self.write(page, to: destination, format: request.format)
        progress(1)

        let before = CompressionWorkspace.fileSize(of: source)
        let after = CompressionWorkspace.fileSize(of: destination)
        return ToolOutcome(
            output: destination,
            detail: "\(Int(original.extent.width))×\(Int(original.extent.height)) → \(page.width)×\(page.height)",
            headline: "\(CompressionFormat.bytes(before)) → \(CompressionFormat.bytes(after))",
            note: request.detectsEdges && !cropped
                ? "문서 테두리를 찾지 못해 자르지 않고 보정만 했습니다."
                : nil
        )
    }

    // MARK: 테두리 찾기

    /// The four corners of the page, in Vision's bottom-left normalised space.
    ///
    /// `VNDetectDocumentSegmentationRequest` is the one trained on documents;
    /// the general rectangle detector is kept as a fallback because the document
    /// model returns nothing at all when the page fills the whole frame, which
    /// is exactly how a scan of a single sheet tends to be taken.
    static func documentQuad(in url: URL) async throws -> VNRectangleObservation? {
        let handler = VNImageRequestHandler(url: url, options: [:])
        let document = VNDetectDocumentSegmentationRequest()
        try? handler.perform([document])
        if let best = document.results?.first, best.confidence > 0.5 { return best }

        let rectangles = VNDetectRectanglesRequest()
        rectangles.minimumAspectRatio = 0.3
        rectangles.maximumObservations = 8
        rectangles.minimumConfidence = 0.6
        rectangles.minimumSize = 0.25
        rectangles.quadratureTolerance = 25
        try? handler.perform([rectangles])
        // The biggest one: a photographed page usually has smaller rectangles
        // inside it — a table, a figure, a text block with a border.
        return rectangles.results?.max { left, right in
            Self.area(of: left) < Self.area(of: right)
        }
    }

    private static func area(of observation: VNRectangleObservation) -> CGFloat {
        let width = hypot(
            observation.topRight.x - observation.topLeft.x,
            observation.topRight.y - observation.topLeft.y
        )
        let height = hypot(
            observation.topLeft.x - observation.bottomLeft.x,
            observation.topLeft.y - observation.bottomLeft.y
        )
        return width * height
    }

    /// Vision reports corners in a unit square with the origin bottom-left, and
    /// `CIImage` uses the same convention, so this is a plain multiply — no
    /// vertical flip, which is the usual source of upside-down results here.
    static func correctPerspective(_ image: CIImage, quad: VNRectangleObservation) -> CIImage {
        let extent = image.extent
        func point(_ normalised: CGPoint) -> CGPoint {
            CGPoint(x: extent.origin.x + normalised.x * extent.width,
                    y: extent.origin.y + normalised.y * extent.height)
        }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = point(quad.topLeft)
        filter.topRight = point(quad.topRight)
        filter.bottomLeft = point(quad.bottomLeft)
        filter.bottomRight = point(quad.bottomRight)
        filter.crop = true
        return filter.outputImage ?? image
    }

    // MARK: 보정

    static func resize(_ image: CIImage, longEdge: Int) -> CIImage {
        let current = max(image.extent.width, image.extent.height)
        guard current > CGFloat(longEdge), current > 0 else { return image }
        let scale = CGFloat(longEdge) / current
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        return filter.outputImage ?? image
    }

    /// Divides the page by an estimate of the light falling on it.
    ///
    /// The estimate is a *dilated* then blurred copy: taking the local maximum
    /// first removes the text from it, because a letter stroke is narrower than
    /// the radius and every pixel near it picks up the paper beside it instead.
    /// A plain blur does not do that — the ink drags the local average down, the
    /// page then gets divided by its own text, and the writing disappears along
    /// with the shadow. Dividing by the light leaves paper at a uniform white
    /// and text at its original darkness, which is what a scanner achieves by
    /// controlling the light instead.
    static func applyFinish(_ image: CIImage, finish: ScanFinish) -> CIImage {
        var result = image
        if finish.removesShading {
            let longEdge = max(image.extent.width, image.extent.height)
            let dilation = max(4, Float(longEdge / 110))
            let softening = max(8, Float(longEdge / 45))
            let dilate = CIFilter.morphologyMaximum()
            dilate.inputImage = image.clampedToExtent()
            dilate.radius = dilation
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = (dilate.outputImage ?? image).clampedToExtent()
            blur.radius = softening
            if let illumination = blur.outputImage?.cropped(to: image.extent) {
                let divide = CIFilter.divideBlendMode()
                divide.inputImage = illumination
                divide.backgroundImage = image
                if let flattened = divide.outputImage { result = flattened }
            }
            let controls = CIFilter.colorControls()
            controls.inputImage = result
            controls.contrast = finish == .mono ? 2.4 : 1.35
            controls.brightness = finish == .mono ? -0.08 : -0.02
            controls.saturation = finish == .mono ? 0 : 1
            if let adjusted = controls.outputImage { result = adjusted }
        } else {
            let controls = CIFilter.colorControls()
            controls.inputImage = result
            controls.contrast = 1.06
            if let adjusted = controls.outputImage { result = adjusted }
        }
        return result.cropped(to: image.extent)
    }

    // MARK: 원래 비율 되찾기

    /// The true width-to-height ratio of a rectangle seen at an angle.
    ///
    /// `CIPerspectiveCorrection` un-skews the quad but has no idea what shape it
    /// started as, so it hands back something the size of the quad's own edges —
    /// an A4 page photographed from the side comes out nearly square. This
    /// recovers the real ratio from the projection itself, following Zhang and
    /// He's whiteboard-rectification method: the two vanishing directions of a
    /// rectangle constrain the camera's focal length, and the focal length in
    /// turn fixes the ratio.
    ///
    /// Returns `nil` when the quad is too close to affine for the maths to be
    /// conditioned, which is the good case — a page photographed nearly head-on
    /// already has very nearly the right ratio.
    static func aspectRatio(topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint, imageSize: CGSize) -> Double? {
        // Homogeneous image coordinates about the principal point, which for a
        // photograph is close enough to the centre of the frame.
        func centred(_ point: CGPoint) -> SIMD3<Double> {
            SIMD3(Double(point.x) - Double(imageSize.width) / 2,
                  Double(point.y) - Double(imageSize.height) / 2,
                  1)
        }
        let m1 = centred(topLeft), m2 = centred(topRight)
        let m3 = centred(bottomLeft), m4 = centred(bottomRight)

        func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }

        let denominator2 = dot(cross(m2, m4), m3)
        let denominator3 = dot(cross(m3, m4), m2)
        guard abs(denominator2) > 1e-9, abs(denominator3) > 1e-9 else { return nil }
        let k2 = dot(cross(m1, m4), m3) / denominator2
        let k3 = dot(cross(m1, m4), m2) / denominator3

        let n2 = k2 * m2 - m1
        let n3 = k3 * m3 - m1

        // Nearly affine: the perspective carries no information about the focal
        // length, and the un-skewed edge lengths are already the answer.
        guard abs(k2 - 1) > 0.001, abs(k3 - 1) > 0.001, abs(n2.z) > 1e-9, abs(n3.z) > 1e-9 else { return nil }

        let squaredFocal = -(n2.x * n3.x + n2.y * n3.y) / (n2.z * n3.z)
        guard squaredFocal.isFinite, squaredFocal > 1 else { return nil }

        let width = (n2.x * n2.x + n2.y * n2.y) / squaredFocal + n2.z * n2.z
        let height = (n3.x * n3.x + n3.y * n3.y) / squaredFocal + n3.z * n3.z
        guard width > 0, height > 0 else { return nil }
        let ratio = (width / height).squareRoot()
        // A page is never thinner than 1:6 either way; anything past that is the
        // maths breaking down on a badly detected quad.
        guard ratio.isFinite, ratio > 0.16, ratio < 6 else { return nil }
        return ratio
    }

    /// Squeezes the un-skewed page back to the shape it really is.
    static func restoreAspect(_ image: CIImage, ratio: Double) -> CIImage {
        let current = image.extent.width / max(1, image.extent.height)
        guard current > 0, abs(current - ratio) > 0.01 else { return image }
        // The longer side is kept and the other adjusted, so nothing is
        // upsampled beyond what the photograph actually resolved.
        let target: CGSize = current > ratio
            ? CGSize(width: image.extent.height * ratio, height: image.extent.height)
            : CGSize(width: image.extent.width, height: image.extent.width / ratio)
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: target.width / image.extent.width,
            y: target.height / image.extent.height
        ))
        return scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x, y: -scaled.extent.origin.y))
    }

    // MARK: 저장

    static func write(_ image: CGImage, to destination: URL, format: ScanOutputFormat) throws {
        switch format {
        case .png:
            try UpscaleWorker.write(image, to: destination, format: .png)
        case .jpeg:
            try UpscaleWorker.write(image, to: destination, format: .jpeg, quality: 0.85)
        case .pdf:
            let size = NSSize(width: image.width, height: image.height)
            guard let page = PDFPage(image: NSImage(cgImage: image, size: size)) else {
                throw AgentError.processFailed("PDF 쪽을 만들지 못했습니다.")
            }
            let document = PDFDocument()
            document.insert(page, at: 0)
            guard document.write(to: destination) else {
                throw AgentError.processFailed("PDF를 저장하지 못했습니다.")
            }
        }
    }
}
