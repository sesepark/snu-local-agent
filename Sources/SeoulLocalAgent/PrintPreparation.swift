import Foundation
import AppKit
import CoreText
import PDFKit
import UniformTypeIdentifiers

/// 용지 이름을 실제 크기로. 사진과 글을 이 Mac에서 종이에 앉힐 때 쓴다.
///
/// PPD가 주는 이름은 프린터마다 다르고 봉투까지 섞여 있다. 아는 것만 정확히 적고, 모르는
/// 이름은 A4로 둔다 — 크기를 모르는 채로 그리는 것보다, 가장 흔한 종이에 맞춰 그린 뒤
/// CUPS의 `fit-to-page`가 마지막에 맞추게 하는 편이 어긋남이 적다.
enum PaperGeometry {
    /// 1pt = 1/72인치.
    static let sizes: [String: CGSize] = [
        "A3": CGSize(width: 841.89, height: 1190.55),
        "A4": CGSize(width: 595.28, height: 841.89),
        "A5": CGSize(width: 419.53, height: 595.28),
        "B5": CGSize(width: 498.90, height: 708.66),
        "Letter": CGSize(width: 612, height: 792),
        "Legal": CGSize(width: 612, height: 1008),
        "Executive": CGSize(width: 522, height: 756),
        "Tabloid": CGSize(width: 792, height: 1224),
    ]

    static func size(for name: String) -> CGSize {
        sizes[name] ?? sizes["A4"]!
    }

    /// 사람이 읽는 이름. 봉투 규격은 PPD 이름 그대로 두는 편이 헷갈리지 않는다.
    static func title(for name: String) -> String {
        switch name {
        case "Letter": "Letter (미국 편지지)"
        case "Legal": "Legal"
        case "Tabloid": "Tabloid"
        case "Executive": "Executive"
        default: name
        }
    }
}

/// 보낼 준비가 끝난 문서 하나.
struct PreparedPrintDocument: Sendable {
    let source: URL
    /// 실제로 서버로 흘려보낼 PDF. 원본이 이미 PDF면 원본 그대로다.
    let pdf: URL
    let pageCount: Int
    let bytes: Int
    /// 무슨 일이 있었는지 한 줄. "DOCX → PDF · 3쪽".
    let note: String
    /// 우리가 만든 파일인가. 원본은 절대 지우지 않는다.
    let isTemporary: Bool
}

/// 던져 넣은 것을 프린터가 받을 수 있는 PDF 한 개로 만든다.
///
/// 변환을 **이 Mac에서** 하는 이유가 있다. 서버의 CUPS도 이미지와 글을 나름대로 PDF로
/// 바꿀 수 있지만, 그쪽 필터는 한글 글꼴을 모르고 HEIC를 열지 못한다. 여기서 만들면 화면에
/// 미리 쪽수를 셀 수 있고, 무엇이 몇 장 나올지 **보내기 전에** 말할 수 있다.
enum PrintPreparation {
    /// 흔한 사진 형식. 여기 없는 것도 내용을 보고 받아 주므로(`prepare` 아래쪽) 이 목록이
    /// 곧 한계는 아니다.
    ///
    /// **이 목록은 상수여야 한다.** 한때 `CGImageSourceCopyTypeIdentifiers()`와 `UTType`으로
    /// 시스템에 직접 물어 만들었는데, 그러면 이 값을 처음 읽는 순간 LaunchServices를 부른다.
    /// 앱이 막 뜨는 중에 그 호출은 돌아오지 않을 수 있고, 실제로 `--print`가 아무것도 찍지
    /// 못한 채 멈춰 있던 이유가 그것이었다. 목록이 조금 낡는 것보다 앱이 멈추지 않는 것이 중요하다.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "avif", "bmp", "gif",
        "webp", "jp2", "j2k", "pict", "ico", "icns", "psd", "exr", "hdr",
        // 흔한 카메라 RAW. ImageIO가 열어 준다.
        "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "srw",
    ]

    /// 폴더를 훑을 때만 쓰는, 시스템에 물어 만든 더 넓은 목록.
    ///
    /// 사람이 파일을 드롭한 **뒤에** 처음 읽히므로 LaunchServices를 불러도 안전하다.
    /// 앱이 뜨는 경로에서는 절대 건드리지 않는다.
    static var systemImageExtensions: Set<String> {
        var found = imageExtensions
        for identifier in (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [] {
            guard let type = UTType(identifier) else { continue }
            found.formUnion(type.tags[.filenameExtension]?.map { $0.lowercased() } ?? [])
        }
        return found
    }

    /// 글로 읽어 그대로 앉히는 것들. LibreOffice 없이 동작한다.
    static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "log", "json", "xml",
        "yaml", "yml", "swift", "py", "c", "h", "cpp", "hpp", "java", "js",
        "ts", "sh", "tex", "rtf",
    ]

    /// LibreOffice가 열어야 하는 것들.
    static let officeExtensions: Set<String> = ["docx", "doc", "pptx", "ppt", "xlsx", "xls", "odt", "odp", "ods", "hwp", "hwpx"]

    static var acceptedExtensions: Set<String> {
        systemImageExtensions.union(textExtensions).union(officeExtensions).union(["pdf"])
    }

    static func accepts(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 한 파일이 감당할 수 있는 상한. 이보다 큰 것은 준비 단계에서 몇 분을 쓰거나 메모리를
    /// 다 먹는다. 인쇄할 문서가 이만큼 크면 대개 잘못 넣은 파일이다.
    static let sizeLimit = 500 * 1024 * 1024

    /// 화면의 드롭 안내에 적는 줄. 목록이 코드와 어긋나지 않도록 여기서 만든다.
    static let dropHint = "여기로 인쇄할 파일을 드롭하세요 · PDF · 사진(HEIC 포함) · TXT·MD·CSV · DOCX·PPTX·XLSX·HWP"

    static func directory() throws -> URL { try ToolWorkspace.directory("Print") }

    /// 사진과 글을 앉힐 쪽의 크기.
    ///
    /// 회전을 골랐으면 **가로세로를 바꾼 쪽에** 앉힌다. 세로 A4에 앉혀 놓고 나중에 90°
    /// 돌리면, 돌린 세로 쪽이 세로 종이에 들어가느라 0.707배로 작아진다 — 가로로 긴
    /// 슬라이드를 눕혀 크게 뽑으려던 것이 오히려 작아지는 것이다. 처음부터 가로 쪽에
    /// 앉혀 두면 그것을 돌렸을 때 종이에 꼭 맞는다.
    static func pageSize(paper: String, rotation: PrintOptions.Rotation) -> CGSize {
        let size = PaperGeometry.size(for: paper)
        return rotation.swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }

    static func prepare(
        _ source: URL, paper: String, rotation: PrintOptions.Rotation = .none
    ) async throws -> PreparedPrintDocument {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AgentError.processFailed("파일을 찾지 못했습니다: \(source.lastPathComponent)")
        }
        let size = fileSize(source)
        guard size > 0 else {
            throw AgentError.processFailed("빈 파일입니다: \(source.lastPathComponent)")
        }
        guard size <= sizeLimit else {
            throw AgentError.processFailed("\(byteText(size))로 너무 큽니다(상한 \(byteText(sizeLimit))): \(source.lastPathComponent)")
        }

        let ext = source.pathExtension.lowercased()
        if ext == "pdf" { return try passthrough(source) }
        if imageExtensions.contains(ext) { return try imageDocument(source, paper: paper, rotation: rotation) }
        if textExtensions.contains(ext) { return try textDocument(source, paper: paper, rotation: rotation) }
        if officeExtensions.contains(ext) { return try await officeDocument(source, paper: paper) }

        // 확장자를 모른다고 곧바로 거절하지 않는다. 확장자가 없는 파일도 있고, 낯선
        // 확장자를 단 평범한 텍스트도 있다. 내용을 보고 정한다.
        if PDFDocument(url: source) != nil { return try passthrough(source) }
        if CGImageSourceCreateWithURL(source as CFURL, nil).map({ CGImageSourceGetCount($0) > 0 }) == true {
            return try imageDocument(source, paper: paper, rotation: rotation)
        }
        if looksLikeText(source) { return try textDocument(source, paper: paper, rotation: rotation) }
        // A 한글 문서 saved without its extension still announces itself in the
        // first bytes, and reading it costs milliseconds.
        if HangulDocument.format(of: source) != nil {
            let destination = try output(for: source)
            let converted = try FileConverter.hangulToPDF(source, to: destination, paper: paper)
            if let document = PDFDocument(url: destination), document.pageCount > 0 {
                return PreparedPrintDocument(
                    source: source, pdf: destination, pageCount: document.pageCount,
                    bytes: fileSize(destination),
                    note: "\(converted.detail) · 앱이 직접 읽어 다시 조판했습니다 \(document.pageCount)쪽",
                    isTemporary: true
                )
            }
        }
        if FileConverter.sofficePath != nil, let converted = try? await officeDocument(source, paper: paper) { return converted }
        let name = ext.isEmpty ? source.lastPathComponent : "\(ext.uppercased()) 파일"
        throw AgentError.processFailed("\(name)은 아직 보낼 수 없습니다. PDF로 바꾼 뒤 넣어 주세요.")
    }

    /// 앞부분을 읽어 글로 볼 수 있는지 본다.
    ///
    /// 0바이트가 섞여 있거나 어느 인코딩으로도 읽히지 않으면 글이 아니다. 그런 것을 글로
    /// 앉히면 종이 몇 십 장에 깨진 기호가 찍힌다.
    static func looksLikeText(_ source: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: source) else { return false }
        defer { try? handle.close() }
        guard let sample = try? handle.read(upToCount: 8192), !sample.isEmpty else { return false }
        if sample.contains(0) { return false }
        if String(data: sample, encoding: .utf8) != nil { return true }
        let korean = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
        ))
        return String(data: sample, encoding: korean) != nil
    }

    // MARK: PDF

    private static func passthrough(_ source: URL) throws -> PreparedPrintDocument {
        guard let document = PDFDocument(url: source) else {
            throw AgentError.processFailed("PDF를 열지 못했습니다: \(source.lastPathComponent)")
        }
        if document.isLocked {
            throw AgentError.processFailed("암호가 걸린 PDF입니다. PDF 편집에서 암호를 푼 뒤 다시 넣어 주세요: \(source.lastPathComponent)")
        }
        guard document.pageCount > 0 else {
            throw AgentError.processFailed("쪽이 하나도 없는 PDF입니다: \(source.lastPathComponent)")
        }
        // 인쇄를 금지한 PDF라도 CUPS는 찍는다. 막지는 않되 말은 해 둔다 — 나온 종이를
        // 보고 "왜 되지?" 하는 것보다 낫다.
        let note = document.allowsPrinting
            ? "PDF · \(document.pageCount)쪽"
            : "PDF · \(document.pageCount)쪽 · 원본이 인쇄를 제한하고 있습니다"
        return PreparedPrintDocument(
            source: source, pdf: source, pageCount: document.pageCount,
            bytes: fileSize(source), note: note, isTemporary: false
        )
    }

    // MARK: 사진

    /// 사진 한 장을 고른 용지 한 쪽에 앉힌다.
    ///
    /// 픽셀 크기 그대로의 PDF를 만들지 않는 이유: 그렇게 만들면 종이보다 크거나 작은 쪽이
    /// 생기고, 무엇이 어떻게 잘릴지는 프린터 드라이버가 정하게 된다. 여기서 여백을 두고
    /// 비율을 지켜 앉히면 결과가 화면에서 예측한 것과 같아진다.
    private static func imageDocument(
        _ source: URL, paper: String, rotation: PrintOptions.Rotation
    ) throws -> PreparedPrintDocument {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        else { throw AgentError.processFailed("사진을 읽지 못했습니다: \(source.lastPathComponent)") }

        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32) ?? 1

        let page = pageSize(paper: paper, rotation: rotation)
        let destination = try output(for: source)
        var mediaBox = CGRect(origin: .zero, size: page)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
            throw AgentError.processFailed("PDF를 만들지 못했습니다: \(source.lastPathComponent)")
        }
        context.beginPDFPage(nil)
        // 회전이 필요한 사진은 가로세로가 바뀐다. 놓을 자리를 먼저 그 기준으로 잡는다.
        let rotated = orientation >= 5
        let pixels = CGSize(
            width: rotated ? CGFloat(image.height) : CGFloat(image.width),
            height: rotated ? CGFloat(image.width) : CGFloat(image.height)
        )
        let margin: CGFloat = 24
        let box = CGRect(x: margin, y: margin, width: page.width - margin * 2, height: page.height - margin * 2)
        let scale = min(box.width / pixels.width, box.height / pixels.height)
        let drawn = CGSize(width: pixels.width * scale, height: pixels.height * scale)
        let frame = CGRect(
            x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2,
            width: drawn.width, height: drawn.height
        )
        context.saveGState()
        context.translateBy(x: frame.midX, y: frame.midY)
        applyOrientation(orientation, to: context)
        let unrotated = CGRect(
            x: -(rotated ? drawn.height : drawn.width) / 2,
            y: -(rotated ? drawn.width : drawn.height) / 2,
            width: rotated ? drawn.height : drawn.width,
            height: rotated ? drawn.width : drawn.height
        )
        context.draw(image, in: unrotated)
        context.restoreGState()
        context.endPDFPage()
        context.closePDF()

        return PreparedPrintDocument(
            source: source, pdf: destination, pageCount: 1, bytes: fileSize(destination),
            note: "\(image.width)×\(image.height) → \(paper) 1쪽", isTemporary: true
        )
    }

    /// EXIF 방향값을 그리기 좌표계로 옮긴다. 원점은 이미 그림 한가운데에 있다.
    private static func applyOrientation(_ orientation: UInt32, to context: CGContext) {
        switch orientation {
        case 2: context.scaleBy(x: -1, y: 1)
        case 3: context.rotate(by: .pi)
        case 4: context.scaleBy(x: 1, y: -1)
        case 5: context.rotate(by: -.pi / 2); context.scaleBy(x: -1, y: 1)
        case 6: context.rotate(by: -.pi / 2)
        case 7: context.rotate(by: .pi / 2); context.scaleBy(x: -1, y: 1)
        case 8: context.rotate(by: .pi / 2)
        default: break
        }
    }

    // MARK: 글

    private static func textDocument(
        _ source: URL, paper: String, rotation: PrintOptions.Rotation = .none
    ) throws -> PreparedPrintDocument {
        let attributed = try attributedString(from: source)
        guard attributed.length > 0 else {
            throw AgentError.processFailed("빈 파일입니다: \(source.lastPathComponent)")
        }
        let page = pageSize(paper: paper, rotation: rotation)
        let destination = try output(for: source)
        var mediaBox = CGRect(origin: .zero, size: page)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
            throw AgentError.processFailed("PDF를 만들지 못했습니다: \(source.lastPathComponent)")
        }

        let margin: CGFloat = 56
        let box = CGRect(x: margin, y: margin, width: page.width - margin * 2, height: page.height - margin * 2)
        let path = CGPath(rect: box, transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var start = 0
        var pages = 0
        // 500쪽에서 멈춘다. 실수로 던진 몇 십 MB짜리 로그 하나가 종이를 다 쓰는 일은 없어야 한다.
        while start < attributed.length, pages < 500 {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            context.beginPDFPage(nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
            start += visible.length
            pages += 1
        }
        context.closePDF()
        guard pages > 0 else {
            throw AgentError.processFailed("글을 종이에 앉히지 못했습니다: \(source.lastPathComponent)")
        }
        let truncated = start < attributed.length ? " · 500쪽에서 잘랐습니다" : ""
        return PreparedPrintDocument(
            source: source, pdf: destination, pageCount: pages, bytes: fileSize(destination),
            note: "\(source.pathExtension.uppercased()) → \(paper) \(pages)쪽\(truncated)", isTemporary: true
        )
    }

    /// 파일을 글로 읽는다.
    ///
    /// 인코딩을 세 번 시도하는 이유: 학교에서 받는 오래된 한글 텍스트는 아직도 EUC-KR이고,
    /// UTF-8로만 읽으면 통째로 실패하거나 깨진 글자가 종이에 그대로 찍힌다.
    private static func attributedString(from source: URL) throws -> NSAttributedString {
        if source.pathExtension.lowercased() == "rtf" {
            let data = try Data(contentsOf: source)
            if let rich = try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
            ) { return rich }
        }
        var text: String?
        if let utf8 = try? String(contentsOf: source, encoding: .utf8) {
            text = utf8
        } else {
            var used: String.Encoding = .utf8
            if let detected = try? String(contentsOf: source, usedEncoding: &used) {
                text = detected
            } else {
                let korean = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
                ))
                text = try? String(contentsOf: source, encoding: korean)
            }
        }
        guard let text else {
            throw AgentError.processFailed("글자 인코딩을 알아내지 못했습니다: \(source.lastPathComponent)")
        }
        let monospaced = ["swift", "py", "c", "h", "cpp", "hpp", "java", "js", "ts", "sh", "json", "xml", "yaml", "yml", "csv", "tsv", "log", "tex"]
        let isCode = monospaced.contains(source.pathExtension.lowercased())
        let font = isCode
            ? NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            : NSFont.systemFont(ofSize: 10.5)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1.5
        paragraph.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: 오피스 문서

    /// 한글 문서 need no LibreOffice — `FileConverter.documentToPDF` reads them
    /// itself when the high-fidelity filter is not installed — so the check for
    /// it only stands in the way of the formats that genuinely need it.
    private static func officeDocument(_ source: URL, paper: String) async throws -> PreparedPrintDocument {
        let hangul = HangulDocument.isHangul(source)
        guard hangul || FileConverter.sofficePath != nil else {
            throw AgentError.processFailed("\(source.pathExtension.uppercased()) 문서를 보내려면 LibreOffice가 필요합니다. `brew install --cask libreoffice` 후 다시 시도해 주세요.")
        }
        let destination = try output(for: source)
        var note = "\(source.pathExtension.uppercased()) → PDF"
        if hangul, !FileConverter.hasHangulFilter {
            // Typeset onto the paper that is actually going into the printer,
            // rather than onto A4 that the print path then scales.
            let converted = try FileConverter.hangulToPDF(source, to: destination, paper: paper)
            note = "\(converted.detail) · 앱이 직접 읽어 다시 조판했습니다"
        } else {
            _ = try await FileConverter.documentToPDF(source, to: destination, progress: { _ in })
        }
        guard let document = PDFDocument(url: destination), document.pageCount > 0 else {
            throw AgentError.processFailed("PDF로 바꾸지 못했습니다: \(source.lastPathComponent)")
        }
        return PreparedPrintDocument(
            source: source, pdf: destination, pageCount: document.pageCount, bytes: fileSize(destination),
            note: "\(note) \(document.pageCount)쪽", isTemporary: true
        )
    }

    // MARK: 잡일

    private static func output(for source: URL) throws -> URL {
        ToolWorkspace.outputURL(for: source, extension: "pdf", in: try directory())
    }

    static func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int) ?? 0
    }

    static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// 시험 인쇄용 한 쪽. 프린터가 실제로 종이를 뱉는지 확인하는 것이 전부이므로 짧다.
    static func testPage(paper: String) throws -> URL {
        let directory = try directory()
        let source = directory.appending(path: "테스트 페이지.txt")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy년 M월 d일 HH:mm"
        let body = """
        서울대 로컬 에이전트 · 프린터 테스트

        \(formatter.string(from: Date()))
        용지: \(paper)

        이 종이가 나왔다면 이 Mac에서 집 서버의 프린터까지 가는 길이 열려 있습니다.
        가나다라마바사 · ABCDEFG · 0123456789
        """
        try body.write(to: source, atomically: true, encoding: .utf8)
        let prepared = try textDocument(source, paper: paper)
        try? FileManager.default.removeItem(at: source)
        return prepared.pdf
    }
}
