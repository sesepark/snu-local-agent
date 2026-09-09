import Foundation
import PDFKit
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

/// Covers reading 한글 문서 without 한컴오피스 or LibreOffice.
///
/// HWPX is exercised end to end against a real zip built here. HWP 5.x is
/// exercised at the two layers that carry its meaning — the record walk and the
/// control-character decoding — because a valid OLE compound file cannot be
/// written by hand in a test without also writing a compound file writer, and a
/// reader tested against its own writer proves less than one tested against the
/// records Hangul actually emits. Point `SEOUL_HWP_FIXTURES` at a folder of real
/// documents to run the whole path over those as well.
@Suite("한글 문서")
struct HangulTests {

    static func scratch(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SeoulLocalAgentTests-\(name)-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - 제어 문자

    /// The decoding rule that everything else rests on: control characters are
    /// eight UTF-16 units wide, not one. Reading them as one unit spills their
    /// payload back into the sentence.
    @Test("확장 제어 문자는 여덟 칸을 차지한다")
    func extendedControlCharactersAreEightUnitsWide() {
        var units: [UInt16] = Array("가".utf16)
        units.append(11)                        // 확장 제어 문자(그리기 개체)
        units.append(contentsOf: [0x6C67, 0x6469, 0, 0, 0, 0])  // 여섯 칸짜리 속내
        units.append(11)
        units.append(contentsOf: Array("나".utf16))
        var bytes = Data()
        for unit in units {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        #expect(HangulDocument.decodeHWP5Text(bytes) == "가나")
    }

    @Test("홑칸 제어 문자는 줄바꿈과 빈칸이 된다")
    func singleUnitControlCharacters() {
        var units: [UInt16] = Array("가".utf16)
        units.append(10)   // 줄 나눔
        units.append(contentsOf: Array("나".utf16))
        units.append(30)   // 묶음 빈칸
        units.append(contentsOf: Array("다".utf16))
        units.append(24)   // 하이픈
        units.append(0)    // 쓰지 않음
        var bytes = Data()
        for unit in units {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        #expect(HangulDocument.decodeHWP5Text(bytes) == "가\n나 다-")
    }

    // MARK: - HWPX

    /// Builds a real HWPX: a zip with the manifest, one section and one image.
    static func makeHWPX(in directory: URL, name: String = "시험.hwpx") throws -> URL {
        let staging = directory.appending(path: "staging", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging.appending(path: "Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging.appending(path: "BinData"), withIntermediateDirectories: true)

        try "application/hwp+zip".write(to: staging.appending(path: "mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <opf:package xmlns:opf="http://www.idpf.org/2007/opf/"><opf:manifest>
        <opf:item id="section0" href="Contents/section0.xml" media-type="application/xml"/>
        <opf:item id="image1" href="BinData/image1.png" media-type="image/png" isEmbeded="1"/>
        </opf:manifest></opf:package>
        """.write(to: staging.appending(path: "Contents/content.hpf"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <hs:sec xmlns:hs="s" xmlns:hp="p" xmlns:hc="c">
        <hp:p><hp:run><hp:t>첫 문단입니다</hp:t></hp:run></hp:p>
        <hp:p><hp:run><hp:t>둘째<hp:lineBreak/>줄</hp:t></hp:run></hp:p>
        <hp:p><hp:run><hp:tbl>
        <hp:tr><hp:tc><hp:subList><hp:p><hp:run><hp:t>주</hp:t></hp:run></hp:p></hp:subList></hp:tc>
        <hp:tc><hp:subList><hp:p><hp:run><hp:t>강의내용</hp:t></hp:run></hp:p></hp:subList></hp:tc></hp:tr>
        <hp:tr><hp:tc><hp:subList><hp:p><hp:run><hp:t>1</hp:t></hp:run></hp:p></hp:subList></hp:tc>
        <hp:tc><hp:subList><hp:p><hp:run><hp:t>Scheme</hp:t></hp:run></hp:p></hp:subList></hp:tc></hp:tr>
        </hp:tbl></hp:run></hp:p>
        <hp:p><hp:run><hp:pic><hc:img binaryItemIDRef="image1"/></hp:pic></hp:run></hp:p>
        </hs:sec>
        """.write(to: staging.appending(path: "Contents/section0.xml"), atomically: true, encoding: .utf8)

        // A 2×2 PNG, so the PDF writer has a real image to place.
        let png = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP8z4AAT\
        AxIYDhwAQAxUAGf7z1CmQAAAABJRU5ErkJggg==
        """)!
        try png.write(to: staging.appending(path: "BinData/image1.png"))

        let archive = directory.appending(path: name)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", "-X", archive.path, "mimetype", "Contents", "BinData"]
        zip.currentDirectoryURL = staging
        try zip.run()
        zip.waitUntilExit()
        return archive
    }

    @Test("HWPX에서 문단·표·그림을 읽는다")
    func readsHWPX() throws {
        let directory = try Self.scratch("hwpx")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeHWPX(in: directory)

        #expect(HangulDocument.format(of: source) == .hwpx)
        let document = try HangulDocument.read(source)
        #expect(document.format == .hwpx)
        #expect(!document.isEmpty)
        #expect(document.imageCount == 1)

        let text = document.plainText
        #expect(text.contains("첫 문단입니다"))
        #expect(text.contains("둘째\n줄"))
        // 표는 칸을 탭으로 나눈다.
        #expect(text.contains("주\t강의내용"))
        #expect(text.contains("1\tScheme"))
    }

    @Test("HWPX를 PDF로 다시 조판한다")
    func typesetsHWPXToPDF() throws {
        let directory = try Self.scratch("hwpx-pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeHWPX(in: directory)
        let destination = directory.appending(path: "결과.pdf")

        let converted = try FileConverter.hangulToPDF(source, to: destination)
        #expect(converted.images == 1)
        let pdf = try #require(PDFDocument(url: destination))
        #expect(pdf.pageCount >= 1)
        let rendered = pdf.string ?? ""
        #expect(rendered.contains("첫 문단입니다"))
        #expect(rendered.contains("Scheme"))
    }

    @Test("한글 문서는 LibreOffice 없이도 형식 변환이 받는다")
    func conversionAcceptsHangulWithoutLibreOffice() throws {
        let directory = try Self.scratch("hwpx-accept")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeHWPX(in: directory)

        #expect(ConversionTarget.officeToPDF.accepts.contains("hwp"))
        #expect(ConversionTarget.officeToPDF.accepts.contains("hwpx"))
        #expect(ConversionTarget.pdfToText.accepts.contains("hwp"))
        #expect(ConversionFamily.of(source) == .document)
        // The advisory line may mention LibreOffice, but a 한글 문서 must never
        // be blocked on it.
        #expect(ConversionTarget.officeToPDF.missingDependency(for: source) == nil)
        #expect(ConversionTarget.pdfToText.missingDependency(for: source) == nil)
        #expect(PrintPreparation.accepts(source))
    }

    @Test("한글 문서에서 글자만 꺼낸다")
    func extractsTextFromHangul() throws {
        let directory = try Self.scratch("hwpx-text")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeHWPX(in: directory)
        let destination = directory.appending(path: "결과.txt")

        let detail = try FileConverter.pdfToText(source, to: destination)
        #expect(detail.contains("HWPX"))
        let text = try String(contentsOf: destination, encoding: .utf8)
        #expect(text.contains("첫 문단입니다"))
    }

    @Test("한글 문서가 아닌 파일은 거절한다")
    func rejectsNonHangulFiles() throws {
        let directory = try Self.scratch("not-hangul")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "가짜.hwp")
        try Data("이것은 한글 문서가 아닙니다".utf8).write(to: source)

        #expect(HangulDocument.format(of: source) == nil)
        #expect(throws: AgentError.self) { try HangulDocument.read(source) }
    }

    // MARK: - HWP 5.x 레코드

    /// Encodes one record the way a section stream carries it.
    static func record(tag: Int, level: Int, payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        var size = payload.count
        var header = UInt32(tag & 0x3FF) | UInt32(level & 0x3FF) << 10
        if size >= 0xFFF {
            header |= UInt32(0xFFF) << 20
        } else {
            header |= UInt32(size) << 20
            size = -1
        }
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((header >> UInt32(shift)) & 0xFF)) }
        if size >= 0 {
            for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8((UInt32(size) >> UInt32(shift)) & 0xFF)) }
        }
        bytes.append(contentsOf: payload)
        return bytes
    }

    static func textPayload(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for unit in Array(text.utf16) {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }

    static func cellPayload(row: Int, column: Int, span: Int = 1) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[8] = UInt8(column & 0xFF)
        bytes[10] = UInt8(row & 0xFF)
        bytes[12] = UInt8(span & 0xFF)
        bytes[14] = 1
        return bytes
    }

    @Test("본문 레코드에서 문단과 표를 읽는다")
    func readsHWP5Records() {
        var stream: [UInt8] = []
        stream += Self.record(tag: 67, level: 1, payload: Self.textPayload("머리말"))
        stream += Self.record(tag: 77, level: 2, payload: [UInt8](repeating: 0, count: 60))
        stream += Self.record(tag: 72, level: 2, payload: Self.cellPayload(row: 0, column: 0))
        stream += Self.record(tag: 67, level: 3, payload: Self.textPayload("주"))
        stream += Self.record(tag: 72, level: 2, payload: Self.cellPayload(row: 0, column: 1))
        stream += Self.record(tag: 67, level: 3, payload: Self.textPayload("강의내용"))
        stream += Self.record(tag: 72, level: 2, payload: Self.cellPayload(row: 1, column: 0))
        stream += Self.record(tag: 67, level: 3, payload: Self.textPayload("1"))
        stream += Self.record(tag: 72, level: 2, payload: Self.cellPayload(row: 1, column: 1))
        stream += Self.record(tag: 67, level: 3, payload: Self.textPayload("Scheme"))
        // 표 바깥으로 나온 문단은 다시 본문이 된다.
        stream += Self.record(tag: 67, level: 1, payload: Self.textPayload("맺음말"))

        let blocks = HangulDocument.blocks(inSection: Data(stream)) { _ in nil }
        let document = HangulDocument(format: .hwp5, blocks: blocks, sectionCount: 1)
        let text = document.plainText
        #expect(text == "머리말\n주\t강의내용\n1\tScheme\n맺음말")
    }

    /// The Korean form idiom: one wide table whose text sits in a few columns,
    /// the rest existing only for the merges to land in. What comes out has to
    /// be the narrow table a reader sees, with the merged cell still spanning.
    @Test("병합된 칸은 폭을 지키고 빈 열은 사라진다")
    func mergedCellsKeepTheirSpan() {
        var stream: [UInt8] = []
        stream += Self.record(tag: 77, level: 2, payload: [UInt8](repeating: 0, count: 60))
        stream += Self.record(tag: 72, level: 2, payload: Self.cellPayload(row: 0, column: 0))
        stream += Self.record(tag: 67, level: 3, payload: Self.textPayload("강좌 키워드"))
        // 한 칸이 나머지 아홉 열을 덮는다.
        stream += Self.record(tag: 72, level: 2, payload: Self.cellPayload(row: 0, column: 1, span: 9))
        stream += Self.record(tag: 67, level: 3, payload: Self.textPayload("자료 구조, 알고리즘"))

        let blocks = HangulDocument.blocks(inSection: Data(stream)) { _ in nil }
        guard case .table(let rows)? = blocks.first(where: { if case .table = $0 { return true } else { return false } })
        else {
            Issue.record("표를 찾지 못했습니다")
            return
        }
        let grid = HangulDocument.normalize(rows)
        #expect(grid.count == 1)
        // 열 여덟 개가 사라지고 두 칸만 남되, 둘째 칸은 여전히 남은 폭을 다 쓴다.
        let visible = grid[0].filter { !$0.isCovered }
        #expect(visible.map(\.text) == ["강좌 키워드", "자료 구조, 알고리즘"])
        #expect(visible.count == 2)
        #expect(grid[0].count == 2)

        let document = HangulDocument(format: .hwp5, blocks: blocks, sectionCount: 1)
        #expect(document.plainText == "강좌 키워드\t자료 구조, 알고리즘")
    }

    @Test("빈 칸으로 끝난 줄은 표 끝까지 이어진다")
    func shortRowsReachTheTableEdge() {
        let rows: [[HangulDocument.Cell]] = [
            [.init(text: "가"), .init(text: "나"), .init(text: "다")],
            [.init(text: "라")],
        ]
        let grid = HangulDocument.normalize(rows)
        #expect(grid.count == 2)
        #expect(grid[1].count == 3)
        // 짧은 줄의 마지막 칸이 남은 열을 덮어 표의 오른쪽 변이 이어진다.
        #expect(grid[1][0].span == 3)
        #expect(grid[1][1].isCovered)
    }

    @Test("그림 레코드는 BinData를 따라간다")
    func readsHWP5Pictures() {
        var picture = [UInt8](repeating: 0, count: 91)
        picture[71] = 3   // BinData 3번
        var stream: [UInt8] = []
        stream += Self.record(tag: 67, level: 1, payload: Self.textPayload("그림 앞"))
        stream += Self.record(tag: 85, level: 3, payload: picture)

        let blocks = HangulDocument.blocks(inSection: Data(stream)) { identifier in
            identifier == 3 ? Data([0xFF, 0xD8, 0xFF]) : nil
        }
        let document = HangulDocument(format: .hwp5, blocks: blocks, sectionCount: 1)
        #expect(document.imageCount == 1)
        #expect(document.plainText == "그림 앞")
    }

    // MARK: - 진짜 문서

    /// Opt-in: `SEOUL_HWP_FIXTURES=/path/to/folder swift test`. Real documents
    /// are not committed — they are somebody's coursework — so this is the seam
    /// for pointing the same checks at a folder of them.
    @Test("진짜 한글 문서를 읽는다")
    func readsRealDocuments() throws {
        guard let folder = ProcessInfo.processInfo.environment["SEOUL_HWP_FIXTURES"] else { return }
        let root = URL(fileURLWithPath: folder)
        let files = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { HangulDocument.isHangul($0) }
        #expect(!files.isEmpty, "\(folder)에 한글 문서가 없습니다")

        let directory = try Self.scratch("real")
        defer { try? FileManager.default.removeItem(at: directory) }
        for file in files {
            let document = try HangulDocument.read(file)
            #expect(!document.isEmpty, "내용이 비었습니다: \(file.lastPathComponent)")
            let destination = directory.appending(path: "\(UUID().uuidString.prefix(6)).pdf")
            let pages = try document.write(to: destination)
            #expect(pages > 0, "쪽을 만들지 못했습니다: \(file.lastPathComponent)")
            let pdf = try #require(PDFDocument(url: destination))
            #expect(pdf.pageCount == pages)
        }
    }
}
#endif
