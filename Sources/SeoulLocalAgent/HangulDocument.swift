import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO

// MARK: - 한글 문서

/// Reads 한글(HWP) documents without 한컴오피스 or LibreOffice.
///
/// The app needs this because the obvious route does not exist. LibreOffice's
/// built-in `hwpfilter` only knows HWP 3.0 from 1997; every 강의계획서 and
/// 보고서 a 서울대 student actually receives is HWP 5.x or HWPX, and for those
/// LibreOffice needs the separate H2Orestart extension and a Java runtime. That
/// path stays the high-fidelity one (see `FileConverter.hasHangulFilter`), but a
/// student who has just been sent a syllabus should not have to install two
/// gigabytes before the app will open it.
///
/// So both containers are read here directly:
///
/// - **HWP 5.x** is an OLE compound file. `BodyText/SectionN` is raw-DEFLATE'd
///   and holds a flat list of records — a 4-byte header packing tag, nesting
///   level and size, then the payload. Text lives in `HWPTAG_PARA_TEXT` as
///   UTF-16LE with control characters woven in; tables come from
///   `HWPTAG_TABLE` and the cell coordinates in each `HWPTAG_LIST_HEADER`;
///   pictures name a `BinData` stream declared in `DocInfo`.
/// - **HWPX** is a zip of OWPML XML, so the same document shape comes out of
///   `Contents/sectionN.xml` with `Contents/content.hpf` naming the images.
///
/// What is deliberately *not* reproduced is layout: fonts, columns, borders and
/// absolute positions are read past. The result is the document's content in
/// reading order, which is what re-typesetting to PDF, printing, and pulling
/// text all need.
struct HangulDocument: Sendable {
    enum Format: String, Sendable {
        case hwp5
        case hwpx

        var title: String { self == .hwp5 ? "HWP" : "HWPX" }
    }

    /// One cell of a table.
    ///
    /// `span` is how many columns it covers, and **zero means covered** — the
    /// cell to its left reaches over this position. Korean forms lean on merged
    /// cells so heavily that dropping the spans and keeping only the grid
    /// squeezes a full-width paragraph into one narrow column.
    struct Cell: Sendable, Equatable {
        var text: String = ""
        var span: Int = 1

        var isCovered: Bool { span == 0 }
        var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Content in reading order. A table keeps its rows so it can be laid out as
    /// a table rather than as one cell per line.
    enum Block: Sendable {
        case paragraph(String)
        case table([[Cell]])
        case image(Data)
    }

    var format: Format
    var blocks: [Block]
    var sectionCount: Int

    static let extensions: Set<String> = ["hwp", "hwpx"]

    static func isHangul(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    var isEmpty: Bool {
        !blocks.contains { block in
            switch block {
            case .paragraph(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .table(let rows): rows.contains { $0.contains { !$0.isBlank } }
            case .image: true
            }
        }
    }

    var imageCount: Int {
        blocks.reduce(0) { total, block in
            if case .image = block { return total + 1 }
            return total
        }
    }

    /// Tab-separated table rows, which is what pastes back into a spreadsheet.
    var plainText: String {
        var lines: [String] = []
        for block in blocks {
            switch block {
            case .paragraph(let text):
                lines.append(text)
            case .table(let rows):
                for row in Self.normalize(rows) {
                    lines.append(row.filter { !$0.isCovered }.map(\.text).joined(separator: "\t"))
                }
            case .image:
                continue
            }
        }
        // Collapse the runs of blank paragraphs that empty table cells and
        // spacing paragraphs leave behind.
        var output: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, output.last?.isEmpty ?? true { continue }
            output.append(trimmed)
        }
        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n")
    }

    // MARK: 읽기

    /// Looks at the bytes, not the extension: files arrive renamed, and an OLE
    /// container could equally be an old `.doc`.
    static func format(of url: URL) -> Format? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return nil }
        if ZipArchive.looksLikeZip(head) {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let archive = try? ZipArchive(data)
            else { return nil }
            return archive.contains("Contents/content.hpf") ? .hwpx : nil
        }
        guard CompoundFile.looksLikeCompoundFile(head),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let file = try? CompoundFile(data),
              let header = try? file.read("FileHeader"),
              header.count >= 32
        else { return nil }
        return String(decoding: header.prefix(17), as: UTF8.self) == "HWP Document File" ? .hwp5 : nil
    }

    static func read(_ url: URL) throws -> HangulDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if ZipArchive.looksLikeZip(data) { return try readHWPX(data) }
        if CompoundFile.looksLikeCompoundFile(data) { return try readHWP5(data) }
        throw AgentError.processFailed("한글 문서로 읽히지 않습니다: \(url.lastPathComponent)")
    }

    // MARK: - HWP 5.x

    /// Record tags used below. `HWPTAG_BEGIN` is 0x10 and the spec numbers
    /// everything as an offset from it, which is why these look arbitrary.
    private enum Tag {
        static let binData = 18
        static let paragraphText = 67
        static let listHeader = 72
        static let table = 77
        static let picture = 85
    }

    private static func readHWP5(_ data: Data) throws -> HangulDocument {
        let file = try CompoundFile(data)
        let header = try file.read("FileHeader")
        guard header.count >= 40, String(decoding: header.prefix(17), as: UTF8.self) == "HWP Document File" else {
            throw AgentError.processFailed("한글 문서가 아닙니다.")
        }
        let reader = ByteReader(header)
        let flags = reader.u32(36) ?? 0
        let compressed = flags & 0x01 != 0
        guard flags & 0x02 == 0 else {
            throw AgentError.processFailed("암호가 걸린 한글 문서입니다. 한글에서 암호를 푼 뒤 다시 넣어 주세요.")
        }
        guard flags & 0x04 == 0 else {
            throw AgentError.processFailed("배포용(읽기 전용) 한글 문서라 내용을 꺼낼 수 없습니다. 한글에서 열어 다른 이름으로 저장한 뒤 넣어 주세요.")
        }

        let binaries = try? binaryMap(in: file, compressed: compressed)
        var blocks: [Block] = []
        var sections = 0
        while true {
            let path = "BodyText/Section\(sections)"
            guard file.contains(path) else { break }
            let raw = try file.read(path)
            let body = compressed ? try Inflate.raw(raw) : raw
            let embedded = binaries ?? [:]
            blocks += Self.blocks(inSection: body) { identifier in
                guard let entry = embedded[identifier], let data = try? file.read(entry.name) else { return nil }
                return entry.deflated ? ((try? Inflate.raw(data)) ?? data) : data
            }
            sections += 1
            // A document with more sections than this is not a document.
            if sections > 256 { break }
        }
        guard sections > 0 else {
            throw AgentError.processFailed("한글 문서에서 본문을 찾지 못했습니다.")
        }
        return HangulDocument(format: .hwp5, blocks: blocks, sectionCount: sections)
    }

    /// `DocInfo` declares each embedded file: an id that names the `BinData`
    /// stream and an extension. Property bits 4–5 say whether that stream is
    /// itself deflated.
    private static func binaryMap(in file: CompoundFile, compressed: Bool) throws -> [UInt16: (name: String, deflated: Bool)] {
        let raw = try file.read("DocInfo")
        let info = compressed ? try Inflate.raw(raw) : raw
        var map: [UInt16: (String, Bool)] = [:]
        var identifier: UInt16 = 0
        forEachRecord(in: info) { tag, _, payload in
            guard tag == Tag.binData else { return }
            let reader = ByteReader(payload)
            guard let properties = reader.u16(0) else { return }
            // Only embedded items (type 1) live in BinData; type 0 is a link to a
            // file on the machine that wrote the document, which is long gone.
            guard properties & 0x0F == 1, let streamID = reader.u16(2), let nameLength = reader.u16(4) else { return }
            guard let suffix = reader.utf16(6, bytes: Int(nameLength) * 2), !suffix.isEmpty else { return }
            identifier += 1
            let storage = (properties >> 4) & 0x03
            map[streamID] = (String(format: "BinData/BIN%04X.%@", Int(streamID), suffix), storage == 1)
        }
        return map
    }

    /// Turns one decompressed `BodyText/SectionN` stream into blocks.
    ///
    /// `image` is handed a `BinData` id and returns the bytes, which is the only
    /// thing this walk needs from the surrounding compound file — and the seam
    /// the record tests drive it through.
    static func blocks(inSection body: Data, image: (UInt16) -> Data?) -> [Block] {
        var blocks: [Block] = []

        /// One open table. `level` is the nesting depth of its `HWPTAG_TABLE`
        /// record; anything shallower than that means the table has ended.
        struct OpenTable {
            let level: Int
            let index: Int
            var rows: [[Cell]]
            var cell: (row: Int, column: Int, span: Int)?
        }
        var tables: [OpenTable] = []

        func store(_ table: OpenTable) { blocks[table.index] = .table(table.rows) }

        func close(deeperThan level: Int) {
            while let table = tables.last, table.level > level {
                store(table)
                tables.removeLast()
            }
        }

        func put(_ text: String) {
            guard var table = tables.last, let cell = table.cell else {
                blocks.append(.paragraph(text))
                return
            }
            while table.rows.count <= cell.row { table.rows.append([]) }
            // Grow the row to the cell and to everything the cell spans, so a
            // later cell in the same row lands at its own column.
            let end = cell.column + max(cell.span, 1)
            while table.rows[cell.row].count < end { table.rows[cell.row].append(Cell(span: 0)) }
            table.rows[cell.row][cell.column].span = max(cell.span, 1)
            let existing = table.rows[cell.row][cell.column].text
            table.rows[cell.row][cell.column].text = existing.isEmpty ? text : "\(existing) \(text)"
            // Written into `blocks` when the table closes, not on every
            // paragraph: a long table would otherwise be copied once per line.
            tables[tables.count - 1] = table
        }

        forEachRecord(in: body) { tag, level, payload in
            switch tag {
            case Tag.table:
                close(deeperThan: level - 1)
                blocks.append(.table([]))
                tables.append(OpenTable(level: level, index: blocks.count - 1, rows: [], cell: nil))
            case Tag.listHeader:
                // A list header that carries cell coordinates belongs to the open
                // table; one that does not is a text box or a footnote, and its
                // paragraphs are left where they fall.
                guard var table = tables.last, table.level == level else { break }
                let reader = ByteReader(payload)
                guard let column = reader.u16(8), let row = reader.u16(10), column < 1024, row < 4096 else { break }
                let span = Int(reader.u16(12) ?? 1)
                table.cell = (Int(row), Int(column), max(1, min(span, 1024 - Int(column))))
                tables[tables.count - 1] = table
            case Tag.paragraphText:
                close(deeperThan: level)
                let text = decodeHWP5Text(payload)
                if !text.isEmpty || tables.last?.cell != nil { put(text) }
            case Tag.picture:
                // The bin item id sits after the border, the four corner points,
                // the crop box, the inside margins and three bytes of brightness
                // and contrast — a fixed 71 bytes in.
                guard let streamID = ByteReader(payload).u16(71),
                      let bytes = image(streamID), !bytes.isEmpty
                else { break }
                blocks.append(.image(bytes))
            default:
                break
            }
        }
        for table in tables.reversed() { store(table) }
        return blocks
    }

    /// Walks the record list. Each header packs tag (10 bits), nesting level
    /// (10 bits) and size (12 bits); a size of 0xFFF means the real size is the
    /// next four bytes.
    private static func forEachRecord(in data: Data, _ body: (Int, Int, Data) -> Void) {
        let bytes = [UInt8](data)
        var cursor = 0
        while cursor + 4 <= bytes.count {
            let header = UInt32(bytes[cursor]) | UInt32(bytes[cursor + 1]) << 8
                | UInt32(bytes[cursor + 2]) << 16 | UInt32(bytes[cursor + 3]) << 24
            cursor += 4
            let tag = Int(header & 0x3FF)
            let level = Int((header >> 10) & 0x3FF)
            var size = Int((header >> 20) & 0xFFF)
            if size == 0xFFF {
                guard cursor + 4 <= bytes.count else { return }
                size = Int(UInt32(bytes[cursor]) | UInt32(bytes[cursor + 1]) << 8
                    | UInt32(bytes[cursor + 2]) << 16 | UInt32(bytes[cursor + 3]) << 24)
                cursor += 4
            }
            guard size >= 0, cursor + size <= bytes.count else { return }
            body(tag, level, Data(bytes[cursor ..< cursor + size]))
            cursor += size
        }
    }

    /// UTF-16LE with control characters mixed in.
    ///
    /// The trap here is that most control characters are **eight** UTF-16 units
    /// wide, not one: the code, six units of payload, then the code again. Only
    /// the plain ones below stand alone. Reading them as single units feeds the
    /// following payload back as text, which is how stray glyphs end up in the
    /// middle of a sentence.
    static func decodeHWP5Text(_ payload: Data) -> String {
        let bytes = [UInt8](payload)
        var units: [UInt16] = []
        var cursor = 0
        while cursor + 2 <= bytes.count {
            let code = UInt16(bytes[cursor]) | UInt16(bytes[cursor + 1]) << 8
            cursor += 2
            if code >= 32 {
                units.append(code)
                continue
            }
            switch code {
            case 10, 13: units.append(10)          // 줄 나눔 · 문단 나눔
            case 24: units.append(0x2D)            // 하이픈
            case 30, 31: units.append(0x20)        // 묶음 빈칸 · 고정폭 빈칸
            case 0, 25, 26, 27, 28, 29: break      // 쓰지 않음 · 예약
            case 9:
                units.append(9)                    // 탭. 확장 제어 문자이기도 하다
                cursor += 14
            default:
                cursor += 14                       // 나머지 인라인·확장 제어 문자
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    // MARK: - HWPX

    private static func readHWPX(_ data: Data) throws -> HangulDocument {
        let archive = try ZipArchive(data)
        guard archive.contains("Contents/content.hpf") else {
            throw AgentError.processFailed("한글 문서(HWPX)가 아닙니다.")
        }
        let manifest = (try? archive.text("Contents/content.hpf")) ?? ""
        let images = imageHrefs(in: manifest)

        let sections = archive.names
            .filter { $0.hasPrefix("Contents/section") && $0.hasSuffix(".xml") }
            .sorted { lhs, rhs in
                (Int(lhs.dropFirst("Contents/section".count).dropLast(4)) ?? 0)
                    < (Int(rhs.dropFirst("Contents/section".count).dropLast(4)) ?? 0)
            }
        guard !sections.isEmpty else {
            throw AgentError.processFailed("한글 문서에서 본문을 찾지 못했습니다.")
        }

        var blocks: [Block] = []
        for section in sections {
            guard let xml = try? archive.read(section) else { continue }
            let reader = OWPMLReader(images: images) { name in try? archive.read(name) }
            blocks.append(contentsOf: reader.parse(xml))
        }
        return HangulDocument(format: .hwpx, blocks: blocks, sectionCount: sections.count)
    }

    /// `<opf:item id="image1" href="BinData/image1.png"/>` — the manifest is the
    /// only thing that ties a paragraph's `binaryItemIDRef` to a file in the zip.
    private static func imageHrefs(in manifest: String) -> [String: String] {
        var map: [String: String] = [:]
        let pattern = #"<opf:item\s+id="([^"]+)"\s+href="([^"]+)""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return map }
        let range = NSRange(manifest.startIndex ..< manifest.endIndex, in: manifest)
        for match in expression.matches(in: manifest, range: range) {
            guard let id = Range(match.range(at: 1), in: manifest),
                  let href = Range(match.range(at: 2), in: manifest)
            else { continue }
            map[String(manifest[id])] = String(manifest[href])
        }
        return map
    }

    /// Pulls the same three things out of OWPML that the record walker pulls out
    /// of HWP 5.x. Namespace handling stays off and names are compared after the
    /// prefix, because writers disagree about which prefix they declare.
    private final class OWPMLReader: NSObject, XMLParserDelegate {
        private let images: [String: String]
        private let load: (String) -> Data?
        private var blocks: [Block] = []

        private var text = ""
        private var inText = false
        private var tableStack: [[[Cell]]] = []
        private var rowStack: [[Cell]] = []
        private var cell: String?
        /// `<hp:cellSpan colSpan="9"/>` arrives before the cell's text ends.
        private var cellSpan = 1

        init(images: [String: String], load: @escaping (String) -> Data?) {
            self.images = images
            self.load = load
        }

        func parse(_ data: Data) -> [Block] {
            blocks = []
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = false
            parser.delegate = self
            parser.parse()
            flushParagraph()
            return blocks
        }

        private static func local(_ name: String) -> String {
            name.split(separator: ":").last.map(String.init) ?? name
        }

        private func append(_ piece: String) {
            if cell != nil { cell?.append(piece) } else { text.append(piece) }
        }

        private func flushParagraph() {
            if cell != nil { return }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            text = ""
            guard !trimmed.isEmpty else { return }
            blocks.append(.paragraph(trimmed))
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
        ) {
            switch Self.local(elementName) {
            case "p":
                if cell == nil { text = "" }
            case "t":
                inText = true
            case "lineBreak":
                append("\n")
            case "tab":
                append("\t")
            case "tbl":
                flushParagraph()
                tableStack.append([])
            case "tr":
                rowStack.append([])
            case "tc":
                cell = ""
                cellSpan = 1
            case "cellSpan":
                cellSpan = max(1, min(Int(attributes["colSpan"] ?? "1") ?? 1, 1024))
            case "img":
                guard let reference = attributes["binaryItemIDRef"],
                      let href = images[reference],
                      let data = load(href), !data.isEmpty
                else { break }
                if cell == nil { flushParagraph() }
                blocks.append(.image(data))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inText else { return }
            append(string)
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch Self.local(elementName) {
            case "t":
                inText = false
            case "p":
                if cell != nil { cell?.append("\n") } else { flushParagraph() }
            case "tc":
                if !rowStack.isEmpty {
                    let value = (cell ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    rowStack[rowStack.count - 1].append(Cell(
                        text: value.replacingOccurrences(of: "\n", with: " "), span: cellSpan
                    ))
                    // The columns this cell reaches over.
                    for _ in 1 ..< max(cellSpan, 1) { rowStack[rowStack.count - 1].append(Cell(span: 0)) }
                }
                cell = nil
                cellSpan = 1
            case "tr":
                guard let row = rowStack.popLast(), !tableStack.isEmpty else { break }
                tableStack[tableStack.count - 1].append(row)
            case "tbl":
                guard let rows = tableStack.popLast() else { break }
                // A table nested in a cell is emitted after the outer one rather
                // than inside it; drawing tables inside cells is layout, and
                // layout is what the high-fidelity path is for.
                blocks.append(.table(rows))
            default:
                break
            }
        }
    }
}

// MARK: - 종이에 앉히기

extension HangulDocument {
    /// Re-typesets the document into a PDF.
    ///
    /// This is a flow layout, not a reproduction: text runs down the page in
    /// reading order, tables are drawn as tab-aligned rows and pictures are
    /// placed at the width of the text block. Line and page breaks land where
    /// this typesetter puts them, not where 한글 put them — said plainly on
    /// screen so nobody prints an exam paper expecting the original pagination.
    @discardableResult
    func write(to destination: URL, pageSize: CGSize = PaperGeometry.size(for: "A4")) throws -> Int {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, nil) else {
            throw AgentError.processFailed("PDF를 만들지 못했습니다.")
        }
        let margin: CGFloat = 56
        let content = CGRect(
            x: margin, y: margin,
            width: pageSize.width - margin * 2, height: pageSize.height - margin * 2
        )

        // The page state is one value rather than a captured variable: `draw`
        // below both reads the cursor and opens pages, and letting a closure
        // reach back into an `inout` cursor is an exclusivity violation.
        var layout = PageLayout(context: context, content: content)
        layout.beginPage()
        for block in blocks {
            switch block {
            case .paragraph(let text):
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    layout.cursor -= 6
                    continue
                }
                draw(Self.attributed(trimmed), into: &layout)
            case .table(let rows):
                let grid = Self.normalize(rows)
                guard !grid.isEmpty else { continue }
                drawTable(grid, into: &layout)
                layout.cursor -= 8
            case .image(let data):
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { continue }
                let scale = min(1, content.width / CGFloat(image.width))
                var width = CGFloat(image.width) * scale
                var height = CGFloat(image.height) * scale
                // A picture taller than the page is shrunk rather than clipped.
                if height > content.height {
                    let fit = content.height / height
                    width *= fit
                    height *= fit
                }
                if layout.cursor - height < content.minY { layout.turnPage() }
                context.draw(image, in: CGRect(
                    x: content.minX + (content.width - width) / 2,
                    y: layout.cursor - height, width: width, height: height
                ))
                layout.cursor -= height + 12
            }
        }
        layout.endPage()
        let pages = layout.pages
        context.closePDF()
        guard pages > 0 else {
            throw AgentError.processFailed("문서를 종이에 앉히지 못했습니다.")
        }
        return pages
    }

    /// Where the next block goes: which page is open and how far down it is.
    private struct PageLayout {
        let context: CGContext
        let content: CGRect
        var cursor: CGFloat = 0
        var pages = 0
        private var open = false

        init(context: CGContext, content: CGRect) {
            self.context = context
            self.content = content
            cursor = content.maxY
        }

        mutating func beginPage() {
            context.beginPDFPage(nil)
            open = true
            pages += 1
            cursor = content.maxY
        }

        mutating func endPage() {
            guard open else { return }
            context.endPDFPage()
            open = false
        }

        mutating func turnPage() {
            endPage()
            beginPage()
        }
    }

    /// Lays one run of text out from the cursor down, opening pages as it fills
    /// them. Returns with the cursor just under the last line drawn.
    private func draw(_ attributed: NSAttributedString, into layout: inout PageLayout) {
        let content = layout.content
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var start = 0
        var guardCount = 0
        while start < attributed.length, guardCount < 2000 {
            guardCount += 1
            // Less than two lines left is not worth starting a paragraph on.
            if layout.cursor - content.minY < 28 { layout.turnPage() }
            let height = layout.cursor - content.minY
            let box = CGRect(x: content.minX, y: content.minY, width: content.width, height: height)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: start, length: 0), CGPath(rect: box, transform: nil), nil
            )
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                // Nothing fit even on a fresh page: one line taller than the
                // whole text block. Give up on this run rather than spin.
                if layout.cursor >= content.maxY { return }
                layout.turnPage()
                continue
            }
            CTFrameDraw(frame, layout.context)
            let used = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: start, length: visible.length),
                nil, CGSize(width: content.width, height: height), nil
            )
            layout.cursor -= max(used.height, 12) + 4
            start += visible.length
        }
    }

    /// Squares the grid off and throws away what carries nothing.
    ///
    /// Korean forms are drawn as one wide table with merged cells — the
    /// 강의계획서 above is ten columns wide with its text sitting in three of
    /// them, the rest existing only so a `colspan` has somewhere to land. Cells
    /// are stored at their real column so the columns line up; dropping the ones
    /// that stayed empty afterwards is what turns that back into the three-column
    /// table a reader sees on paper.
    static func normalize(_ rows: [[Cell]]) -> [[Cell]] {
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return [] }
        // A spacer cell usually holds a space or a stray newline rather than
        // nothing at all, so the emptiness test has to trim first — otherwise
        // every one of those columns survives and squeezes the real ones.
        let padded = rows.map { row -> [Cell] in
            var cells = row + Array(repeating: Cell(span: 0), count: width - row.count)
            for index in cells.indices {
                cells[index].text = cells[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return cells
        }
        // A column earns its place by being where some cell starts and says
        // something. One that is only ever reached over by a span disappears
        // into that span instead.
        let keep = (0 ..< width).filter { column in
            padded.contains { !$0[column].isCovered && !$0[column].isBlank }
        }
        guard !keep.isEmpty else { return [] }
        let kept = Set(keep)

        var output: [[Cell]] = []
        for row in padded {
            var cells: [Cell] = []
            for (column, cell) in row.enumerated() where !cell.isCovered {
                guard kept.contains(column) else { continue }
                // The span shrinks by however many of the columns it covered
                // were dropped.
                let covered = (column ..< min(column + cell.span, width)).count { kept.contains($0) }
                cells.append(Cell(text: cell.text, span: max(1, covered)))
                for _ in 1 ..< max(covered, 1) { cells.append(Cell(span: 0)) }
            }
            output.append(cells)
        }
        // Every row has to reach the full width or the columns stop lining up.
        // A row that stops short has its last cell reach the rest of the way,
        // rather than leaving a gap where the table's edge should be.
        let columns = output.map(\.count).max() ?? 0
        return output.filter { $0.contains { !$0.isBlank } }.map { row -> [Cell] in
            var cells = row
            let missing = columns - cells.count
            guard missing > 0 else { return cells }
            if let last = cells.lastIndex(where: { !$0.isCovered }) { cells[last].span += missing }
            return cells + Array(repeating: Cell(span: 0), count: missing)
        }
    }

    /// Draws a table as a table: proportional columns, wrapped cell text and a
    /// hairline grid, breaking to a new page between rows.
    private func drawTable(_ rows: [[Cell]], into layout: inout PageLayout) {
        let content = layout.content
        let columns = rows[0].count
        let padding: CGFloat = 5
        let available = content.width - CGFloat(columns) * padding * 2
        // Narrower than this and a column holds one syllable per line, which is
        // worse than no table at all.
        guard columns > 0, available / CGFloat(columns) >= 26 else {
            let lines = rows.map { $0.filter { !$0.isCovered }.map(\.text).joined(separator: "\t") }
            draw(Self.attributed(lines.joined(separator: "\n"), tabbed: true), into: &layout)
            return
        }

        // Column widths follow the widest thing each column holds, capped so one
        // long sentence cannot squeeze every other column to nothing. A cell
        // that spans several columns lends its width to each of them.
        var natural = [CGFloat](repeating: 0, count: columns)
        for row in rows {
            for (index, cell) in row.enumerated() where !cell.isCovered && !cell.isBlank {
                let measured = min(Self.measure(cell.text, width: .greatestFiniteMagnitude).width, content.width * 1.5)
                let share = measured / CGFloat(cell.span)
                for column in index ..< min(index + cell.span, columns) {
                    natural[column] = max(natural[column], share)
                }
            }
        }
        let sum = max(natural.reduce(0, +), 1)
        let widths = natural.map { $0 / sum * available + padding * 2 }
        // Where each column starts, so a spanning cell can be measured and drawn
        // across the ones it covers.
        var origins: [CGFloat] = [content.minX]
        for width in widths { origins.append(origins[origins.count - 1] + width) }

        func frame(at index: Int, span: Int, top: CGFloat, height: CGFloat) -> CGRect {
            let end = min(index + max(span, 1), columns)
            return CGRect(x: origins[index], y: top - height, width: origins[end] - origins[index], height: height)
        }

        let border = CGColor(gray: 0.72, alpha: 1)
        layout.context.setStrokeColor(border)
        layout.context.setLineWidth(0.5)
        for row in rows {
            var tallest: CGFloat = 0
            for (index, cell) in row.enumerated() where !cell.isCovered && !cell.isBlank {
                let width = frame(at: index, span: cell.span, top: 0, height: 0).width - padding * 2
                tallest = max(tallest, Self.measure(cell.text, width: width).height)
            }
            let height = min(tallest + padding * 2, content.height)
            if layout.cursor - height < content.minY { layout.turnPage() }

            for (index, cell) in row.enumerated() where !cell.isCovered {
                let box = frame(at: index, span: cell.span, top: layout.cursor, height: height)
                layout.context.stroke(box)
                guard !cell.isBlank else { continue }
                let framesetter = CTFramesetterCreateWithAttributedString(Self.attributed(cell.text))
                let text = CTFramesetterCreateFrame(
                    framesetter, CFRange(location: 0, length: 0),
                    CGPath(rect: box.insetBy(dx: padding, dy: padding), transform: nil), nil
                )
                CTFrameDraw(text, layout.context)
            }
            layout.cursor -= height
        }
    }

    private static func measure(_ text: String, width: CGFloat) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(text))
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
    }

    private static func attributed(_ text: String, tabbed: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping
        if tabbed {
            // Table rows read as columns rather than as one long line.
            paragraph.tabStops = (1 ... 8).map {
                NSTextTab(textAlignment: .left, location: CGFloat($0) * 78, options: [:])
            }
            paragraph.defaultTabInterval = 78
        }
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ])
    }
}
