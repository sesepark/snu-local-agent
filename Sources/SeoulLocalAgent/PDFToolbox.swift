import Foundation
import AppKit
import CoreGraphics
import PDFKit

// MARK: - 도장·서명

/// An image laid on top of a page: a signature, a seal, a "제출용" stamp.
///
/// Positions are fractions of the page rather than points, so the same
/// signature lands in the same visual place on an A4 form and on a US Letter
/// one, and the sheet can show a live preview without knowing the page size.
struct PDFStamp: Sendable, Equatable {
    /// Centre of the image, origin bottom-left, in the page's own unit square.
    var centre = CGPoint(x: 0.72, y: 0.14)
    /// Width as a fraction of the page width.
    var width: Double = 0.22
    var opacity: Double = 1

    static let identity = PDFStamp()
}

enum PDFStampScope: String, CaseIterable, Identifiable, Sendable {
    case selected
    case first
    case last
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .selected: "고른 쪽"
        case .first: "첫 쪽"
        case .last: "마지막 쪽"
        case .all: "모든 쪽"
        }
    }

    func indexes(pageCount: Int, selected: Set<Int>) -> Set<Int> {
        guard pageCount > 0 else { return [] }
        switch self {
        case .selected: return selected
        case .first: return [0]
        case .last: return [pageCount - 1]
        case .all: return Set(0 ..< pageCount)
        }
    }
}

/// The diagonal "대외비" across the page, the other thing people open Acrobat for.
struct PDFWatermark: Sendable, Equatable {
    var text = "대외비"
    var opacity: Double = 0.18
    var angleDegrees: Double = 35
    /// Height of the text as a fraction of the page's short edge.
    var size: Double = 0.12
}

// MARK: - 조작

/// Everything PDF 편집 does, as free functions over `PDFDocument`.
///
/// Kept apart from the view model so each operation can be tested on its own —
/// page maths is exactly the kind of code that is quietly off by one — and so
/// the model is only ever bookkeeping and undo.
enum PDFToolbox {
    static func load(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw AgentError.processFailed("PDF를 열지 못했습니다: \(url.lastPathComponent)")
        }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else {
                throw AgentError.processFailed("암호가 걸린 PDF입니다. 암호를 입력해 주세요: \(url.lastPathComponent)")
            }
        }
        guard document.pageCount > 0 else {
            throw AgentError.processFailed("쪽이 없는 PDF입니다: \(url.lastPathComponent)")
        }
        return document
    }

    /// Pages are copied, not moved: a `PDFPage` belongs to its document, and
    /// inserting the live object into another one empties the first.
    static func merge(_ documents: [PDFDocument]) -> PDFDocument {
        let merged = PDFDocument()
        var next = 0
        for document in documents {
            for index in 0 ..< document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: next)
                next += 1
            }
        }
        return merged
    }

    static func removing(_ indexes: Set<Int>, from document: PDFDocument) -> PDFDocument {
        let kept = (0 ..< document.pageCount).filter { !indexes.contains($0) }
        return extracting(kept, from: document)
    }

    /// Order is the caller's, so this doubles as "reorder": handing it
    /// `[2, 0, 1]` returns those three pages in that order.
    static func extracting(_ indexes: [Int], from document: PDFDocument) -> PDFDocument {
        let result = PDFDocument()
        var next = 0
        for index in indexes {
            guard index >= 0, index < document.pageCount,
                  let page = document.page(at: index)?.copy() as? PDFPage
            else { continue }
            result.insert(page, at: next)
            next += 1
        }
        return result
    }

    /// PDF rotation is stored as a multiple of 90 on the page, so this changes
    /// no pixels and costs nothing however large the page is.
    static func rotating(_ indexes: Set<Int>, by degrees: Int, in document: PDFDocument) -> PDFDocument {
        for index in indexes {
            guard let page = document.page(at: index) else { continue }
            var rotation = (page.rotation + degrees) % 360
            if rotation < 0 { rotation += 360 }
            page.rotation = rotation
        }
        return document
    }

    /// Moves the given pages so the first of them lands at `destination`,
    /// keeping their relative order.
    static func moving(_ indexes: Set<Int>, to destination: Int, in document: PDFDocument) -> (document: PDFDocument, selection: Set<Int>) {
        let moved = indexes.sorted()
        guard !moved.isEmpty else { return (document, indexes) }
        let remaining = (0 ..< document.pageCount).filter { !indexes.contains($0) }
        let clamped = max(0, min(remaining.count, destination))
        var order = Array(remaining[0 ..< clamped])
        order.append(contentsOf: moved)
        order.append(contentsOf: remaining[clamped...])
        let selection = Set(clamped ..< clamped + moved.count)
        return (extracting(order, from: document), selection)
    }

    // MARK: 암호

    static func write(_ document: PDFDocument, to url: URL, userPassword: String? = nil) throws {
        var options: [PDFDocumentWriteOption: Any] = [:]
        if let userPassword, !userPassword.isEmpty {
            // The PDF standard stores passwords in a Latin-1 encoding, so a
            // Korean one cannot be written at all. Left to itself `write` just
            // returns false, which would have reached the user as "저장하지
            // 못했습니다" with no way to work out why.
            guard userPassword.canBeConverted(to: .isoLatin1) else {
                throw AgentError.processFailed("PDF 암호에는 영문·숫자·기호만 쓸 수 있습니다. 한글은 PDF 표준이 지원하지 않습니다.")
            }
            options[.userPasswordOption] = userPassword
            // Without an owner password too, macOS writes a file that opens with
            // the user password but claims no permissions are set, which some
            // readers treat as unprotected.
            options[.ownerPasswordOption] = userPassword
        }
        // 사용자가 고른 자리에 곧바로 쓰지 않는다. `PDFDocument.write`는 그 파일을 열어
        // 처음부터 덮어 나가므로, 도중에 앱이 끝나거나 디스크가 차면 **그 자리에 있던
        // 원래 PDF까지** 잘린 채로 남는다. 같은 폴더에 다 쓴 뒤 바꿔치기하면, 어느 순간에
        // 끊기든 그 자리에는 온전한 옛 파일이거나 온전한 새 파일만 있다.
        let staged = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).쓰는중")
        let wrote = options.isEmpty ? document.write(to: staged) : document.write(to: staged, withOptions: options)
        guard wrote else {
            try? FileManager.default.removeItem(at: staged)
            throw AgentError.processFailed("PDF를 저장하지 못했습니다.")
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw AgentError.processFailed("PDF를 저장하지 못했습니다: \(error.localizedDescription)")
        }
    }

    // MARK: 겹쳐 그리기

    /// Re-renders every page with something drawn on top.
    ///
    /// Goes through `CGPDFDocument` rather than `PDFPage.draw(with:to:)` because
    /// `getDrawingTransform` has a defined answer for a rotated page, and a
    /// scanned handout is very often rotated. The overlay is called with the
    /// context already restored, so it draws in the finished page's own space
    /// with the origin at the bottom left.
    static func overlay(
        _ document: PDFDocument,
        into url: URL,
        draw: (CGContext, Int, CGRect) -> Void
    ) throws {
        guard let data = document.dataRepresentation(),
              let provider = CGDataProvider(data: data as CFData),
              let source = CGPDFDocument(provider)
        else { throw AgentError.processFailed("PDF를 다시 그리지 못했습니다.") }
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw AgentError.processFailed("PDF 파일을 만들지 못했습니다.") }

        for number in 1 ... max(1, source.numberOfPages) {
            guard let page = source.page(at: number) else { continue }
            let box = page.getBoxRect(.mediaBox)
            let sideways = (page.rotationAngle / 90) % 2 != 0
            let size = sideways ? CGSize(width: box.height, height: box.width) : box.size
            let target = CGRect(origin: .zero, size: size)
            // `CFData` holding the raw `CGRect`, which is what the key is
            // documented to take. An `NSValue` is accepted and then quietly
            // ignored, leaving every page at the default US Letter size with the
            // real page drawn small in one corner.
            let mediaBox = withUnsafeBytes(of: target) { Data($0) } as CFData
            context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
            context.saveGState()
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
            context.clip(to: box)
            context.drawPDFPage(page)
            context.restoreGState()
            draw(context, number - 1, target)
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func stamped(_ document: PDFDocument, image: CGImage, stamp: PDFStamp, pages: Set<Int>, into url: URL) throws -> PDFDocument {
        let aspect = Double(image.height) / Double(max(1, image.width))
        try overlay(document, into: url) { context, index, page in
            guard pages.contains(index) else { return }
            let width = page.width * stamp.width
            let height = width * aspect
            let rect = CGRect(
                x: page.width * stamp.centre.x - width / 2,
                y: page.height * stamp.centre.y - height / 2,
                width: width, height: height
            )
            context.saveGState()
            context.setAlpha(stamp.opacity)
            context.draw(image, in: rect)
            context.restoreGState()
        }
        guard let result = PDFDocument(url: url) else {
            throw AgentError.processFailed("도장을 넣은 PDF를 읽지 못했습니다.")
        }
        return result
    }

    static func watermarked(_ document: PDFDocument, watermark: PDFWatermark, pages: Set<Int>, into url: URL) throws -> PDFDocument {
        let text = watermark.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentError.processFailed("워터마크에 넣을 글자를 입력해 주세요.") }
        try overlay(document, into: url) { context, index, page in
            guard pages.contains(index) else { return }
            let pointSize = min(page.width, page.height) * watermark.size
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: pointSize, weight: .bold),
                .foregroundColor: NSColor.black.withAlphaComponent(watermark.opacity),
            ]
            let string = NSAttributedString(string: text, attributes: attributes)
            let size = string.size()
            context.saveGState()
            context.translateBy(x: page.width / 2, y: page.height / 2)
            context.rotate(by: watermark.angleDegrees * .pi / 180)
            // `flipped: false` so the text sits the right way up in PDF space,
            // where y grows upwards.
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            string.draw(at: CGPoint(x: -size.width / 2, y: -size.height / 2))
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
        }
        guard let result = PDFDocument(url: url) else {
            throw AgentError.processFailed("워터마크를 넣은 PDF를 읽지 못했습니다.")
        }
        return result
    }

    // MARK: 쪽 범위

    /// Parses what someone actually types into a page box: `1-3, 7, 12-`.
    ///
    /// One-based on the way in because that is what the page numbers on screen
    /// say, zero-based on the way out because that is what `PDFDocument` wants.
    static func parseRanges(_ text: String, pageCount: Int) -> [Int] {
        guard pageCount > 0 else { return [] }
        var result: [Int] = []
        var seen: Set<Int> = []
        for chunk in text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }) {
            let piece = chunk.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let bounds = piece.split(separator: "-", omittingEmptySubsequences: false)
            func clamp(_ value: Int) -> Int { max(1, min(pageCount, value)) }
            if bounds.count == 1, let single = Int(bounds[0]) {
                let index = clamp(single) - 1
                if seen.insert(index).inserted { result.append(index) }
            } else if bounds.count == 2 {
                let start = Int(bounds[0]).map(clamp) ?? 1
                let end = Int(bounds[1]).map(clamp) ?? pageCount
                guard start <= end else { continue }
                for value in start ... end where seen.insert(value - 1).inserted {
                    result.append(value - 1)
                }
            }
        }
        return result
    }

    static func describe(_ document: PDFDocument) -> String {
        guard let first = document.page(at: 0) else { return "\(document.pageCount)쪽" }
        let box = first.bounds(for: .mediaBox)
        let sideways = first.rotation % 180 != 0
        let width = sideways ? box.height : box.width
        let height = sideways ? box.width : box.height
        // Points to millimetres, so the size reads as A4 rather than as 595×842.
        let millimetres = "\(Int((width / 72 * 25.4).rounded()))×\(Int((height / 72 * 25.4).rounded()))mm"
        return "\(document.pageCount)쪽 · \(millimetres)"
    }
}
