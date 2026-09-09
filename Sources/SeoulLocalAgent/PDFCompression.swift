import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers

// MARK: - PDF 압축

/// Shrinks a PDF the way Preview's "파일 크기 줄이기" does: a Quartz filter is
/// installed on a PDF context, the pages are replayed into it, and the filter
/// intercepts only the image drawing. Text stays text and vectors stay vectors,
/// so the result is still selectable and searchable.
///
/// Measured on this Mac, that is worth −35~61% on a figure-heavy paper and
/// nothing at all on a page whose content the filter will not touch. For that
/// second case there is a rasterising fallback, but it is guarded hard: turning
/// a text PDF into page images makes it *bigger* (+246% on an 18-page paper was
/// the measurement) as well as unsearchable, so it only ever runs on documents
/// that carry no extractable text and that the filter could not shrink.
struct PDFCompressor: FileCompressor {
    /// Below this many characters per page a document is treated as a scan or a
    /// graphic rather than something anyone will select text from.
    static let textPerPageThreshold = 50
    /// The filter counts as having failed below this much saving.
    static let ineffectiveThreshold = 0.05

    // MARK: 미리 읽기

    func inspect(_ source: URL, request: CompressionRequest) throws -> CompressionSourceInfo {
        let bytes = CompressionWorkspace.fileSize(of: source)
        guard let document = PDFDocument(url: source) else {
            throw AgentError.processFailed("PDF를 열지 못했습니다: \(source.lastPathComponent)")
        }
        guard !document.isEncrypted || document.unlock(withPassword: "") else {
            throw AgentError.processFailed("암호가 걸린 PDF는 압축할 수 없습니다: \(source.lastPathComponent)")
        }
        let pages = max(1, document.pageCount)
        let attempts = request.isTargeting ? 4.0 : 1.0
        return CompressionSourceInfo(
            bytes: bytes,
            detail: "\(pages)쪽",
            estimatedSeconds: max(0.05, Double(pages) * CompressionProgressEstimator.pdfSecondsPerPage * attempts)
        )
    }

    /// Annotations, links and form fields do not survive the page replay, so the
    /// tab warns before touching a PDF that has any.
    static func annotationWarning(for source: URL) -> String? {
        guard let document = PDFDocument(url: source) else { return nil }
        for index in 0 ..< document.pageCount where !(document.page(at: index)?.annotations.isEmpty ?? true) {
            return "주석·링크가 있는 PDF입니다. 압축하면 사라집니다."
        }
        return nil
    }

    static func textDensity(of document: PDFDocument) -> Int {
        guard document.pageCount > 0 else { return 0 }
        let characters = (0 ..< document.pageCount)
            .compactMap { document.page(at: $0)?.string?.count }
            .reduce(0, +)
        return characters / document.pageCount
    }

    // MARK: 본 처리

    func compress(
        _ source: URL,
        to destination: URL,
        request: CompressionRequest,
        progress: @escaping @Sendable (Double, Double?) -> Void
    ) async throws -> CompressionOutcome {
        guard let document = PDFDocument(url: source) else {
            throw AgentError.processFailed("PDF를 열지 못했습니다: \(source.lastPathComponent)")
        }
        guard !document.isEncrypted || document.unlock(withPassword: "") else {
            throw AgentError.processFailed("암호가 걸린 PDF는 압축할 수 없습니다: \(source.lastPathComponent)")
        }
        let originalBytes = CompressionWorkspace.fileSize(of: source)
        let pages = max(1, document.pageCount)
        let density = Self.textDensity(of: document)
        let step: @Sendable (Double) -> Void = { progress($0, nil) }
        step(0.1)

        let attempts: [(quality: Double, maxPixel: Int)] = request.isTargeting
            ? Self.targetLadder()
            : [(request.level.pdfQuality, request.level.pdfMaxPixel)]

        var best: (url: URL, bytes: Int)?
        for (index, attempt) in attempts.enumerated() {
            try Task.checkCancellation()
            let candidate = destination.deletingPathExtension()
                .appendingPathExtension("try\(index).pdf")
            guard Self.applyFilter(
                source, to: candidate,
                quality: attempt.quality, maxPixel: attempt.maxPixel, resolution: request.level.pdfResolution
            ) else {
                try? FileManager.default.removeItem(at: candidate)
                continue
            }
            let bytes = CompressionWorkspace.fileSize(of: candidate)
            if let current = best, current.bytes <= bytes {
                try? FileManager.default.removeItem(at: candidate)
            } else {
                if let current = best { try? FileManager.default.removeItem(at: current.url) }
                best = (candidate, bytes)
            }
            step(0.1 + 0.6 * (Double(index + 1) / Double(attempts.count)))
            if request.isTargeting, let bytes = best?.bytes, bytes <= request.targetBytes { break }
        }

        // The filter left it essentially untouched. If nobody is going to select
        // text out of this document, rebuilding it from page images is the only
        // thing left that can help — and it helps enormously on the posters and
        // scans that hit this path.
        let filteredBytes = best?.bytes ?? originalBytes
        if Double(filteredBytes) > Double(originalBytes) * (1 - Self.ineffectiveThreshold),
           density < Self.textPerPageThreshold {
            let raster = destination.deletingPathExtension().appendingPathExtension("raster.pdf")
            if Self.rasterize(
                document, to: raster,
                dpi: request.level.pdfRasterDPI, quality: request.level.pdfRasterQuality
            ) {
                let bytes = CompressionWorkspace.fileSize(of: raster)
                if bytes > 0, bytes < filteredBytes {
                    if let current = best { try? FileManager.default.removeItem(at: current.url) }
                    best = (raster, bytes)
                } else {
                    try? FileManager.default.removeItem(at: raster)
                }
            }
        }
        step(0.9)

        // Never hand back something larger than what came in.
        guard let winner = best, winner.bytes > 0, winner.bytes < originalBytes else {
            if let current = best { try? FileManager.default.removeItem(at: current.url) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return CompressionOutcome(
                output: destination,
                bytes: originalBytes,
                detail: "\(pages)쪽",
                note: density >= Self.textPerPageThreshold
                    ? "글자 위주라 더 줄일 수 없습니다"
                    : "이 PDF는 더 줄일 수 없습니다"
            )
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: winner.url, to: destination)
        let rasterized = winner.url.lastPathComponent.contains("raster")
        return CompressionOutcome(
            output: destination,
            bytes: winner.bytes,
            detail: "\(pages)쪽",
            note: rasterized ? "글자가 없어 쪽 이미지로 다시 만들었습니다" : nil
        )
    }

    /// Quality barely moves a PDF — measured, q0.95 and q0.05 land within a few
    /// percent of each other — so the ladder walks the resolution cap down,
    /// which is the parameter that actually does the work.
    static func targetLadder() -> [(quality: Double, maxPixel: Int)] {
        [(0.75, 2400), (0.60, 1600), (0.45, 1100), (0.35, 700)]
    }

    // MARK: Quartz 필터

    /// The same dictionary shape as `/System/Library/Filters/Reduce File Size.qfilter`,
    /// built in memory so no temporary `.qfilter` ever touches disk.
    static func filterProperties(quality: Double, maxPixel: Int, resolution: Int) -> [String: Any] {
        [
            "Name": "SeoulLocalAgent 용량 줄이기",
            "FilterType": 1,
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "ImageCompression": "ImageJPEGCompress",
                        "Compression Quality": quality,
                        "ImageScaleSettings": [
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": maxPixel,
                            "ImageSizeMin": 0,
                            "ImageResolution": resolution,
                        ],
                    ],
                ],
            ],
        ]
    }

    static func applyFilter(_ source: URL, to destination: URL, quality: Double, maxPixel: Int, resolution: Int) -> Bool {
        let properties = filterProperties(quality: quality, maxPixel: maxPixel, resolution: resolution)
        guard let filter = QuartzFilter(properties: properties),
              let document = CGPDFDocument(source as CFURL),
              document.numberOfPages > 0,
              let firstPage = document.page(at: 1) else { return false }
        var mediaBox = firstPage.getBoxRect(.mediaBox)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else { return false }
        guard filter.apply(to: context) else {
            context.closePDF()
            return false
        }
        for index in 1 ... document.numberOfPages {
            guard let page = document.page(at: index) else { continue }
            var box = page.getBoxRect(.mediaBox)
            context.beginPage(mediaBox: &box)
            context.drawPDFPage(page)
            context.endPage()
        }
        filter.remove(from: context)
        context.closePDF()
        return FileManager.default.fileExists(atPath: destination.path)
    }

    // MARK: 래스터화 폴백

    /// Draws every page into a bitmap, compresses that as JPEG and rebuilds the
    /// document from the results. Destroys selectable text, which is why the
    /// caller checks there is none before reaching for this.
    static func rasterize(_ document: PDFDocument, to destination: URL, dpi: Double, quality: Double) -> Bool {
        guard document.pageCount > 0, let firstPage = document.page(at: 0) else { return false }
        var mediaBox = firstPage.bounds(for: .mediaBox)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else { return false }
        let scale = dpi / 72
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            let width = max(1, Int((bounds.width * scale).rounded()))
            let height = max(1, Int((bounds.height * scale).rounded()))
            guard let bitmap = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { continue }
            // PDF pages assume paper, so anything not drawn has to read as white
            // rather than as the bitmap's default black.
            bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
            bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            bitmap.scaleBy(x: scale, y: scale)
            bitmap.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: bitmap)
            guard let raw = bitmap.makeImage(),
                  let jpeg = Self.jpegRoundTrip(raw, quality: quality) else { continue }
            var box = bounds
            context.beginPage(mediaBox: &box)
            context.draw(jpeg, in: bounds)
            context.endPage()
        }
        context.closePDF()
        return FileManager.default.fileExists(atPath: destination.path)
    }

    /// Compresses the bitmap and reads it back, so the page carries a JPEG
    /// rather than the raw pixels the context would otherwise embed.
    static func jpegRoundTrip(_ image: CGImage, quality: Double) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
