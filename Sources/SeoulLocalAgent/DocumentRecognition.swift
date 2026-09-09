import Foundation
import Vision
import PDFKit
import AppKit
import CoreGraphics

/// On-device text recognition for slides, scanned handouts, and screen captures.
/// It uses Apple's Vision framework, which ships with macOS: nothing is
/// downloaded and no image ever leaves the machine.
struct DocumentRecognizer {
    struct Result {
        let text: String
        let pageCount: Int
        /// True when at least one page had no embedded text and had to be scanned.
        let usedOpticalRecognition: Bool
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "gif", "webp"]
    static let supportedExtensions: Set<String> = imageExtensions.union(["pdf"])

    static func isSupported(_ url: URL) -> Bool { supportedExtensions.contains(url.pathExtension.lowercased()) }

    /// A page that already carries this much selectable text is a real text PDF;
    /// anything less is treated as a scan and sent through recognition.
    private static let embeddedTextThreshold = 40

    func recognize(fileURL: URL, progress: @escaping @Sendable (String) async -> Void) async throws -> Result {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentError.processFailed("파일을 찾을 수 없습니다: \(fileURL.lastPathComponent)")
        }
        if fileURL.pathExtension.lowercased() == "pdf" {
            return try await recognizePDF(fileURL, progress: progress)
        }
        guard Self.imageExtensions.contains(fileURL.pathExtension.lowercased()) else {
            throw AgentError.processFailed("이미지 또는 PDF 파일만 인식할 수 있습니다.")
        }
        await progress("이미지에서 글자를 찾고 있습니다.")
        guard let image = NSImage(contentsOf: fileURL), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AgentError.processFailed("이미지를 읽지 못했습니다.")
        }
        let text = try Self.recognizeText(in: cgImage)
        guard !text.isEmpty else { throw AgentError.processFailed("이미지에서 글자를 찾지 못했습니다.") }
        return Result(text: text, pageCount: 1, usedOpticalRecognition: true)
    }

    private func recognizePDF(_ fileURL: URL, progress: @escaping @Sendable (String) async -> Void) async throws -> Result {
        guard let document = PDFDocument(url: fileURL), document.pageCount > 0 else {
            throw AgentError.processFailed("PDF를 열지 못했습니다.")
        }
        var pages: [String] = []
        var usedOCR = false
        for index in 0 ..< document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let embedded = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if embedded.count >= Self.embeddedTextThreshold {
                await progress("\(index + 1)/\(document.pageCount)쪽 · 내장 텍스트 사용")
                pages.append(embedded)
                continue
            }
            await progress("\(index + 1)/\(document.pageCount)쪽 · 스캔 페이지 글자 인식 중")
            usedOCR = true
            guard let cgImage = Self.render(page) else { continue }
            let recognized = try Self.recognizeText(in: cgImage)
            if !recognized.isEmpty { pages.append(recognized) }
        }
        let text = pages.enumerated()
            .map { "## \($0.offset + 1)쪽\n\($0.element)" }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { throw AgentError.processFailed("PDF에서 글자를 찾지 못했습니다.") }
        return Result(text: text, pageCount: document.pageCount, usedOpticalRecognition: usedOCR)
    }

    /// Recognition accuracy depends on resolution, so a page is rasterised at 2x
    /// into a grayscale buffer, which is a quarter of the memory of RGBA.
    private static func render(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0, width * height < 80_000_000 else { return nil }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ko-KR", "en-US"]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        return assembleLines(from: observations)
    }

    /// Vision returns observations as boxes, not as lines of a document. Grouping
    /// by vertical position and then sorting left to right keeps slide bullets and
    /// two-column handouts readable instead of interleaved.
    static func assembleLines(from observations: [VNRecognizedTextObservation]) -> String {
        let candidates = observations.compactMap { observation -> (text: String, midY: CGFloat, minX: CGFloat)? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return (best.string, box.midY, box.minX)
        }
        guard !candidates.isEmpty else { return "" }
        let sorted = candidates.sorted { lhs, rhs in
            abs(lhs.midY - rhs.midY) < 0.012 ? lhs.minX < rhs.minX : lhs.midY > rhs.midY
        }
        var lines: [String] = []
        var current: [String] = []
        var lineY = sorted[0].midY
        for candidate in sorted {
            if abs(candidate.midY - lineY) < 0.012 {
                current.append(candidate.text)
            } else {
                lines.append(current.joined(separator: " "))
                current = [candidate.text]
                lineY = candidate.midY
            }
        }
        lines.append(current.joined(separator: " "))
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Interactive region capture. Returns nil when the user presses Escape.
    static func captureScreenRegion() async throws -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "SeoulLocalAgent-Capture-\(UUID().uuidString).png")
        _ = try await ProcessRunner().run("/usr/sbin/screencapture", ["-i", "-x", destination.path], expectsStandardOutput: false)
        guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
        return destination
    }
}
