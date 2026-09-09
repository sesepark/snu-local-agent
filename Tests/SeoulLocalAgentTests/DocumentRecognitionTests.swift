import Foundation
import AppKit
import CoreText
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

/// Kept in its own file: AppKit and CoreText widen the overload set enough to slow
/// type checking in the main suite.
@Suite("Document recognition")
struct DocumentRecognitionTests {
    @Test("On-device recognition reads text out of an image")
    func visionRecognisesRenderedText() throws {
        let image = try #require(Self.renderTextImage("Local OCR"))
        let text = try DocumentRecognizer.recognizeText(in: image)
        #expect(text.contains("OCR"))
    }

    @Test("A text PDF is read through its embedded text, not re-scanned")
    func pdfUsesEmbeddedText() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTextPDF("Embedded lecture handout text for recognition", to: url)

        let result = try await DocumentRecognizer().recognize(fileURL: url) { _ in }
        #expect(result.pageCount == 1)
        #expect(!result.usedOpticalRecognition)
        #expect(result.text.contains("Embedded lecture handout"))
    }

    private static func renderTextImage(_ text: String) -> CGImage? {
        let width = 1_000
        let height = 260
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 96),
            .foregroundColor: NSColor.black,
        ])
        context.textPosition = CGPoint(x: 40, y: 90)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        return context.makeImage()
    }

    private static func writeTextPDF(_ text: String, to url: URL) throws {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw AgentError.processFailed("PDF context를 만들지 못했습니다.")
        }
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.black,
        ])
        context.textPosition = CGPoint(x: 60, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url)
    }
}
#endif
