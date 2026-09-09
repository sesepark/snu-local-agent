import Foundation
#if canImport(Testing)
import Testing
import PDFKit
@testable import SeoulLocalAgent

@Suite("프린트")
struct PrintingTests {

    // MARK: 서버가 하는 말 읽기

    /// 집 서버가 실제로 내놓은 출력. 손으로 다듬지 않고 그대로 둔다 — 이 시험이 지켜야 하는
    /// 것은 "우리가 상상한 형식"이 아니라 저 기계가 내놓는 형식이다.
    static let realPrinterOutput = """
    printer Samsung_C48x is idle.  enabled since Fri Sep  4 10:31:01 2026
    system default destination: Samsung_C48x
    """

    static let realOptionsOutput = """
    PageSize/Media Size: Letter Legal Executive Tabloid A3 A4 A5 B5 EnvISOB5 Env10 EnvC5 EnvDL EnvMonarch
    InputSlot/Media Source: *Default Upper Manual
    Duplex/2-Sided Printing: *None DuplexNoTumble DuplexTumble
    Option1/Duplexer: *False True
    """

    @Test("대기 중인 프린터와 기본 프린터를 읽는다")
    func readsIdlePrinter() throws {
        let printers = CUPSOutput.printers(Self.realPrinterOutput)
        #expect(printers.count == 1)
        let printer = try #require(printers.first)
        #expect(printer.name == "Samsung_C48x")
        #expect(printer.state == .idle)
        #expect(printer.isDefault)
        // 큐 이름의 밑줄은 사람이 읽는 자리에서만 사라진다.
        #expect(printer.displayName == "Samsung C48x")
    }

    @Test("멈춘 프린터는 멈춘 것으로, 이유와 함께 읽는다")
    func readsStoppedPrinter() throws {
        let text = """
        printer Samsung_C48x disabled since Fri Sep  4 11:00:00 2026 -
        \tMedia tray empty
        printer Office_MFP is idle.  enabled since Fri Sep  4 09:00:00 2026
        system default destination: Office_MFP
        """
        let printers = CUPSOutput.printers(text)
        #expect(printers.count == 2)
        #expect(printers[0].state == .stopped)
        // 이유가 없으면 사람은 프린터 앞까지 걸어가서야 종이가 없다는 것을 안다.
        #expect(printers[0].reason == "Media tray empty")
        #expect(printers[0].isDefault == false)
        #expect(printers[1].isDefault)
    }

    @Test("인쇄 중인 프린터를 대기 중으로 읽지 않는다")
    func readsPrintingState() throws {
        let printers = CUPSOutput.printers("printer Samsung_C48x now printing Samsung_C48x-7.  enabled since Fri Sep  4 10:31:01 2026")
        #expect(printers.first?.state == .printing)
    }

    @Test("PPD가 내주는 선택지를 그대로 읽는다")
    func readsCapabilities() throws {
        let capabilities = CUPSOutput.capabilities(Self.realOptionsOutput)
        #expect(capabilities.option("PageSize")?.choices.contains("A4") == true)
        #expect(capabilities.option("Duplex")?.current == "None")
        // 학생이 실제로 쓰는 용지가 앞으로 온다. 봉투가 첫 줄에 있으면 픽커가 쓸모없다.
        #expect(capabilities.pageSizes.first == "A4")
        #expect(capabilities.pageSizes.contains("EnvDL"))
        #expect(capabilities.defaultPageSize == "A4")
    }

    @Test("양면 장치가 없으면 양면을 걸 수 있다고 말하지 않는다")
    func duplexNeedsTheHardware() {
        // 이 집 프린터가 정확히 그 상태다. `Duplex` 항목은 PPD에 있지만 `Option1/Duplexer`가
        // `False`이므로 양면 장치가 달려 있지 않다. 스위치를 그려 놓으면 눌러도 아무 일도
        // 일어나지 않는 스위치가 된다.
        #expect(CUPSOutput.capabilities(Self.realOptionsOutput).supportsDuplex == false)

        let withDuplexer = """
        Duplex/2-Sided Printing: *None DuplexNoTumble DuplexTumble
        Option1/Duplexer: False *True
        """
        #expect(CUPSOutput.capabilities(withDuplexer).supportsDuplex)
    }

    @Test("컬러 항목이 없는 프린터는 컬러를 고를 수 없다고 말한다")
    func colourNeedsThePPDOption() {
        #expect(CUPSOutput.capabilities(Self.realOptionsOutput).supportsColorModel == false)
        let colour = "ColorModel/Color Mode: *RGB Gray"
        #expect(CUPSOutput.capabilities(colour).supportsColorModel)
    }

    @Test("큐 목록에서 작업만 골라 읽는다")
    func readsQueue() throws {
        let text = """
        Samsung_C48x-2          deploy            1024   Fri Sep  4 10:37:35 2026
        Samsung_C48x-3          deploy            8192   Fri Sep  4 10:37:35 2026
        """
        let queue = CUPSOutput.queue(text)
        #expect(queue.count == 2)
        #expect(queue[0].id == "Samsung_C48x-2")
        #expect(queue[1].bytes == 8192)
        // 큐가 비면 `lpstat -o`는 아무것도 내놓지 않는다.
        #expect(CUPSOutput.queue("").isEmpty)
        // 작업 줄이 아닌 것을 작업으로 세면 화면이 없는 대기열을 그린다.
        #expect(CUPSOutput.queue("lpstat: Transport endpoint is not connected").isEmpty)
    }

    @Test("lp가 돌려준 작업 번호를 읽는다")
    func readsJobID() {
        #expect(CUPSOutput.jobID("request id is Samsung_C48x-12 (1 file(s))") == "Samsung_C48x-12")
        // stdin으로 보내면 파일 수가 0이라고 적힌다. 그것은 실패가 아니다.
        #expect(CUPSOutput.jobID("request id is Samsung_C48x-4 (0 file(s))") == "Samsung_C48x-4")
        #expect(CUPSOutput.jobID("lp: Error - unknown destination") == nil)
    }

    // MARK: 보내는 명령

    @Test("따옴표와 공백이 든 이름이 셸에서 쪼개지지 않는다")
    func quotesAwkwardNames() {
        let quoted = PrintCommand.quote("전자기학 '중간' 요약.pdf")
        #expect(quoted.hasPrefix("'") && quoted.hasSuffix("'"))
        #expect(quoted.contains("'\\''"))
    }

    @Test("고른 설정이 IPP 이름으로 명령에 실린다")
    func buildsLPCommand() {
        var options = PrintOptions()
        options.copies = 3
        options.paper = "A4"
        options.numberUp = 2
        options.pageRange = "1-4,8"
        options.sides = .twoSidedLongEdge
        let command = PrintCommand.send(
            options: options, printer: "Samsung_C48x", title: "요약",
            grayscaleAvailable: false, composedLocally: false
        )
        // PPD마다 다른 이름(`Duplex`, `PageSize`)이 아니라 IPP 이름으로 적는다. 그래야
        // 프린터를 바꾼 날 조용히 무시되지 않는다.
        #expect(command.contains("'sides=two-sided-long-edge'"))
        #expect(command.contains("'media=A4'"))
        #expect(command.contains("'number-up=2'"))
        #expect(command.contains("'page-ranges=1-4,8'"))
        #expect(command.contains("'-n' '3'"))
        // 여러 부를 찍을 때 한 부씩 모이지 않으면 사람이 손으로 나눠야 한다.
        #expect(command.contains("'collate=true'"))
        #expect(command.contains("print-color-mode") == false)
    }

    @Test("이 Mac에서 이미 앉힌 것을 서버가 또 앉히지 않는다")
    func doesNotImposeTwice() {
        var options = PrintOptions()
        options.numberUp = 4
        options.pageRange = "1-8"
        // 미리보기를 만들면서 모아찍기와 범위가 이미 파일 안에 들어갔다. 그것을 다시
        // 보내면 고른 쪽의 고른 쪽이, 모아찍기의 모아찍기가 나간다.
        let composed = PrintCommand.send(
            options: options, printer: "P", title: "t", grayscaleAvailable: true, composedLocally: true
        )
        #expect(composed.contains("number-up") == false)
        #expect(composed.contains("page-ranges") == false)
        // 용지·매수·양면은 여전히 서버가 한다.
        #expect(composed.contains("'media=A4'"))

        let notComposed = PrintCommand.send(
            options: options, printer: "P", title: "t", grayscaleAvailable: true, composedLocally: false
        )
        #expect(notComposed.contains("'number-up=4'"))
        #expect(notComposed.contains("'page-ranges=1-8'"))
    }

    @Test("흑백은 CUPS가 받아 준다고 말할 때만 붙인다")
    func grayscaleUsesIPPColourMode() {
        var options = PrintOptions()
        options.grayscale = true
        let supported = PrintCommand.send(
            options: options, printer: "P", title: "t", grayscaleAvailable: true, composedLocally: false
        )
        // PPD에 컬러 항목이 없는 프린터에서도 CUPS는 `print-color-mode`를 해석한다.
        // ghostscript를 서버에 두고 파이프로 굽던 예전 방법보다 의존성이 하나 적다.
        #expect(supported.contains("'print-color-mode=monochrome'"))
        #expect(supported.contains("gs ") == false)

        let unsupported = PrintCommand.send(
            options: options, printer: "P", title: "t", grayscaleAvailable: false, composedLocally: false
        )
        // 받아 주지 않는 프린터에 보내 봐야 무시된다. 눌러도 아무 일 없는 스위치는 만들지 않는다.
        #expect(unsupported.contains("print-color-mode") == false)
    }

    @Test("제목은 한 줄로 줄이고 길이를 자른다")
    func sanitisesTitle() {
        #expect(PrintCommand.title(for: "강의\n노트.pdf") == "강의 노트.pdf")
        #expect(PrintCommand.title(for: String(repeating: "가", count: 200)).count == 80)
        #expect(PrintCommand.title(for: "   ") == "SeoulLocalAgent")
    }

    @Test("상태·선택지·큐·경보를 한 번의 왕복으로 묻는다")
    func inspectsInOneRoundTrip() {
        // 나누면 집 밖에서 쓸 때 왕복 지연이 그만큼 곱해진다.
        let command = PrintCommand.inspect(printer: "Samsung_C48x")
        #expect(command.contains("lpstat -p -d"))
        #expect(command.contains("lpoptions ${P:+-p \"$P\"} -l"))
        #expect(command.contains("lpstat -o"))
        #expect(command.contains("Alerts: "))
        // `-t`만 주면 ipptool은 통과/실패 한 줄만 찍고 속성은 내놓지 않는다. 그러면 화면은
        // 흑백도 양면도 "불가"로 굳는다 — 실제로 그렇게 굳어 있었다.
        #expect(command.contains("ipptool -tv"))
        // 프린터를 아직 고르지 않았으면 서버가 자기 기본 프린터를 알아낸다. 그것 때문에
        // 왕복을 한 번 더 하지 않는다.
        #expect(PrintCommand.inspect(printer: "").contains("system default destination"))
    }

    // MARK: 쪽 범위와 종이 수

    @Test("쪽 범위는 CUPS가 받는 꼴만 통과시킨다")
    func validatesPageRanges() {
        #expect(PrintOptions.isValidRange(""))
        #expect(PrintOptions.isValidRange("1-4,8"))
        #expect(PrintOptions.isValidRange("2-"))
        #expect(PrintOptions.isValidRange("가나다") == false)
        #expect(PrintOptions.isValidRange("4-1") == false)
        #expect(PrintOptions.isValidRange("0") == false)
        #expect(PrintOptions.isValidRange("1,,2") == false)
    }

    @Test("종이 수는 모아찍기와 양면을 함께 센다")
    func countsSheetsNotPages() {
        var options = PrintOptions()
        #expect(options.sheets(forPages: 10) == 10)
        options.numberUp = 2
        #expect(options.sheets(forPages: 10) == 5)
        options.sides = .twoSidedLongEdge
        // 한 쪽에 2장씩, 그것을 앞뒤로 → 10쪽이 종이 3장.
        #expect(options.sheets(forPages: 10) == 3)
        options.copies = 2
        #expect(options.sheets(forPages: 10) == 6)
        #expect(options.sheets(forPages: 0) == 0)
    }

    // MARK: 보내기 전에 PDF로

    @Test("한글 텍스트가 여러 쪽 PDF로 앉는다")
    func rendersKoreanTextToPDF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "print-text-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "강의 정리.txt")
        let body = (1...400).map { "\($0)번째 줄 · 전자기학 정리 노트" }.joined(separator: "\n")
        try body.write(to: source, atomically: true, encoding: .utf8)

        let prepared = try await PrintPreparation.prepare(source, paper: "A4")
        #expect(prepared.pageCount > 1)
        #expect(prepared.isTemporary)
        let document = try #require(PDFDocument(url: prepared.pdf))
        #expect(document.pageCount == prepared.pageCount)
        // 서버 필터가 아니라 여기서 앉히는 이유가 이것이다: 글자가 글자로 남는다.
        #expect(document.page(at: 0)?.string?.contains("전자기학") == true)
        try? FileManager.default.removeItem(at: prepared.pdf)
    }

    @Test("사진은 고른 용지 한 쪽에 앉는다")
    func fitsPhotoOntoOnePage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "print-image-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "슬라이드.png")
        let context = try #require(CGContext(
            data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            source as CFURL, "public.png" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let prepared = try await PrintPreparation.prepare(source, paper: "A4")
        #expect(prepared.pageCount == 1)
        let pdf = try #require(PDFDocument(url: prepared.pdf))
        let bounds = try #require(pdf.page(at: 0)?.bounds(for: .mediaBox))
        // 픽셀 크기 그대로의 쪽을 만들면 무엇이 어떻게 잘릴지 드라이버가 정하게 된다.
        #expect(abs(bounds.width - PaperGeometry.size(for: "A4").width) < 1)
        #expect(abs(bounds.height - PaperGeometry.size(for: "A4").height) < 1)
        try? FileManager.default.removeItem(at: prepared.pdf)
    }

    @Test("회전을 고르면 그 방향의 쪽에 앉힌다")
    func laysOutOnTheRotatedPage() async throws {
        // 세로 A4에 앉혀 놓고 나중에 돌리면 0.707배로 작아진다. 가로로 긴 슬라이드를 눕혀
        // 크게 뽑으려던 것이 오히려 작아지는 것이라, 처음부터 가로 쪽에 앉혀야 한다.
        let upright = PrintPreparation.pageSize(paper: "A4", rotation: .none)
        let turned = PrintPreparation.pageSize(paper: "A4", rotation: .right)
        #expect(upright.width < upright.height)
        #expect(turned.width > turned.height)
        #expect(turned.width == upright.height)
        #expect(PrintPreparation.pageSize(paper: "A4", rotation: .upsideDown) == upright)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "print-rotate-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "메모.txt")
        try "가나다라마바사".write(to: source, atomically: true, encoding: .utf8)
        let prepared = try await PrintPreparation.prepare(source, paper: "A4", rotation: .right)
        let page = try #require(PDFDocument(url: prepared.pdf)?.page(at: 0)?.bounds(for: .mediaBox))
        #expect(page.width > page.height)
        // 돌려서 종이에 앉히면 다시 세로가 된다. 그 사이에 줄어드는 곳이 없어야 한다.
        var options = PrintOptions()
        options.rotation = .right
        let composed = try PrintComposition.compose(prepared.pdf, options: options)
        defer { try? FileManager.default.removeItem(at: composed.url) }
        let sheet = try #require(PDFDocument(url: composed.url)?.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(sheet.width - PaperGeometry.size(for: "A4").width) < 1)
        try? FileManager.default.removeItem(at: prepared.pdf)
    }

    @Test("PDF는 다시 만들지 않고 그대로 보낸다")
    func passesPDFThrough() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "print-pdf-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "원본.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(source as CFURL, mediaBox: &box, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()

        let prepared = try await PrintPreparation.prepare(source, paper: "A4")
        #expect(prepared.pageCount == 3)
        // 원본을 다시 구우면 용량만 늘고 얻는 것이 없다. 그리고 원본은 지울 대상이 아니다.
        #expect(prepared.pdf == source)
        #expect(prepared.isTemporary == false)
    }

    @Test("보낼 수 없는 형식은 목록에 들어가기 전에 거절한다")
    func rejectsUnsupportedFiles() {
        #expect(PrintPreparation.accepts(URL(fileURLWithPath: "/tmp/보고서.pdf")))
        #expect(PrintPreparation.accepts(URL(fileURLWithPath: "/tmp/사진.HEIC")))
        #expect(PrintPreparation.accepts(URL(fileURLWithPath: "/tmp/과제.docx")))
        #expect(PrintPreparation.accepts(URL(fileURLWithPath: "/tmp/제출.hwp")))
        #expect(PrintPreparation.accepts(URL(fileURLWithPath: "/tmp/강의.mp4")) == false)
    }

    @Test("모르는 용지 이름에도 그릴 크기가 있다")
    func fallsBackToA4() {
        #expect(PaperGeometry.size(for: "A4") == PaperGeometry.size(for: "EnvMonarch"))
        #expect(PaperGeometry.size(for: "Letter").width == 612)
    }

    // MARK: 프린터가 알리는 문제

    @Test("종이가 없다는 말을 사람이 읽는 말로 옮긴다")
    func translatesStateReasons() throws {
        let empty = try #require(PrinterTrouble(keyword: "media-empty-error"))
        #expect(empty.severity == .error)
        #expect(empty.text.contains("종이"))
        let low = try #require(PrinterTrouble(keyword: "toner-low-warning"))
        #expect(low.severity == .warning)
        // 모르는 사유는 지어내지 않고 원문을 그대로 보여 준다 — 검색할 수 있는 말이 낫다.
        let unknown = try #require(PrinterTrouble(keyword: "vendor-specific-thing"))
        #expect(unknown.text == "vendor-specific-thing")
        // `none`은 사유가 없다는 뜻이지 사유의 이름이 아니다.
        #expect(PrinterTrouble(keyword: "none") == nil)
        #expect(PrinterTrouble(keyword: "") == nil)
    }

    @Test("경보 줄에서 사유만 읽는다")
    func readsAlerts() {
        #expect(CUPSOutput.alerts("none").isEmpty)
        #expect(CUPSOutput.alerts("").isEmpty)
        #expect(CUPSOutput.alerts("media-empty-error, toner-low-warning") == ["media-empty-error", "toner-low-warning"])
    }

    @Test("종이가 없으면 지금 눌러도 안 된다고 표시한다")
    func blockedWhenOutOfPaper() {
        var printer = RemotePrinter(name: "Samsung_C48x")
        printer.reasons = ["media-empty-error"]
        #expect(printer.isBlocked)
        #expect(printer.troubles.count == 1)

        var warning = RemotePrinter(name: "Samsung_C48x")
        warning.reasons = ["toner-low-warning"]
        // 곧 문제가 된다는 것과 지금 못 찍는다는 것은 다르다.
        #expect(warning.isBlocked == false)
    }

    @Test("CUPS가 직접 답한 것이 PPD보다 우선한다")
    func ippBeatsPPD() {
        let ipp = """
                sides-supported (keyword) = one-sided
                print-color-mode-supported (1setOf keyword) = monochrome,color
                media-ready (1setOf keyword) = iso_a3_297x420mm,iso_a4_210x297mm,iso_dl_110x220mm
                printer-state-reasons (keyword) = none
        """
        let facts = CUPSOutput.ippFacts(ipp)
        #expect(facts.sidesSupported == ["one-sided"])
        #expect(facts.colorModesSupported == ["monochrome", "color"])
        #expect(facts.stateReasons.isEmpty)

        var capabilities = CUPSOutput.capabilities(Self.realOptionsOutput)
        capabilities.sidesSupported = facts.sidesSupported
        capabilities.colorModesSupported = facts.colorModesSupported
        capabilities.mediaReady = facts.mediaReady
        #expect(capabilities.supportsDuplex == false)
        // PPD에는 컬러 항목이 없지만 CUPS는 흑백을 받아 준다. PPD만 보면 이 스위치를
        // 잠갔을 것이고, 그러면 이 프린터에서는 흑백으로 찍을 방법이 없어진다.
        #expect(capabilities.supportsColorModel == false)
        #expect(capabilities.supportsMonochrome)
        #expect(capabilities.readyPaperNames == ["A3", "A4", "DL"])
    }

    // MARK: 미리보기 = 실제로 나갈 파일

    @Test("쪽 범위를 실제 쪽 번호로 편다")
    func expandsPageRanges() {
        #expect(PrintComposition.selectedPages(count: 10, range: "") == Array(0..<10))
        #expect(PrintComposition.selectedPages(count: 10, range: "1-3,7") == [0, 1, 2, 6])
        // 끝을 비우면 문서 끝까지.
        #expect(PrintComposition.selectedPages(count: 5, range: "3-") == [2, 3, 4])
        // 문서 밖의 번호는 조용히 빠진다. 3쪽짜리에 `1-100`을 적었다고 실패할 이유가 없다.
        #expect(PrintComposition.selectedPages(count: 3, range: "1-100") == [0, 1, 2])
        // 같은 쪽을 두 번 적어도 두 번 찍지 않는다.
        #expect(PrintComposition.selectedPages(count: 5, range: "2,2,2") == [1])
    }

    @Test("모아찍기 칸은 쪽 모양에 맞춰 나눈다")
    func choosesGridByShape() {
        let a4 = PaperGeometry.size(for: "A4")
        let portrait = CGSize(width: 595, height: 842)
        let landscape = CGSize(width: 842, height: 595)
        // 세로로 긴 쪽 두 장은 나란히 놓아야 크게 나온다.
        #expect(PrintComposition.grid(numberUp: 2, paper: a4, page: portrait) == (2, 1))
        // 가로로 긴 쪽 두 장은 위아래로 쌓아야 크게 나온다. 슬라이드가 이 경우다.
        #expect(PrintComposition.grid(numberUp: 2, paper: a4, page: landscape) == (1, 2))
        #expect(PrintComposition.grid(numberUp: 4, paper: a4, page: portrait) == (2, 2))
        #expect(PrintComposition.grid(numberUp: 1, paper: a4, page: portrait) == (1, 1))
    }

    @Test("바꿀 것이 없으면 원본을 다시 굽지 않는다")
    func leavesUntouchedPDFAlone() throws {
        let pdf = try Self.makePDF(pages: 4)
        defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
        let composed = try PrintComposition.compose(pdf, options: PrintOptions())
        // 멀쩡한 PDF를 다시 만드는 것은 시간과 용량만 쓰고, 원본이 지닌 것을 잃을 위험만 더한다.
        #expect(composed.url == pdf)
        #expect(composed.isTemporary == false)
        #expect(composed.appliedLocally == false)
        #expect(composed.sheets == 4)
    }

    @Test("모아찍기와 쪽 범위가 실제 파일에 들어간다")
    func composesWhatWillBeSent() throws {
        let pdf = try Self.makePDF(pages: 9)
        defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
        var options = PrintOptions()
        options.numberUp = 4
        let composed = try PrintComposition.compose(pdf, options: options)
        defer { try? FileManager.default.removeItem(at: composed.url) }
        // 9쪽을 넉 장씩 → 종이 세 장. 화면이 세 장을 보여 주고 세 장이 나가야 한다.
        #expect(composed.sheets == 3)
        #expect(composed.appliedLocally)
        #expect(composed.isTemporary)
        #expect(PrintPreviewRenderer.pageCount(of: composed.url) == 3)

        options.numberUp = 1
        options.pageRange = "2-3"
        let subset = try PrintComposition.compose(pdf, options: options)
        defer { try? FileManager.default.removeItem(at: subset.url) }
        #expect(subset.sheets == 2)
        #expect(subset.appliedLocally)
    }

    @Test("범위가 문서 밖이면 종이를 내보내기 전에 막는다")
    func refusesEmptySelection() throws {
        let pdf = try Self.makePDF(pages: 3)
        defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
        var options = PrintOptions()
        options.pageRange = "50-60"
        #expect(throws: (any Error).self) { try PrintComposition.compose(pdf, options: options) }
    }

    @Test("미리보기는 그 파일을 그대로 그린다")
    func rendersTheFileItWillSend() throws {
        let pdf = try Self.makePDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
        let colour = try #require(PrintPreviewRenderer.render(pdf, sheet: 0, grayscale: false, maxPixel: 200))
        #expect(max(colour.width, colour.height) == 200)
        let gray = try #require(PrintPreviewRenderer.render(pdf, sheet: 0, grayscale: true, maxPixel: 200))
        // 흑백으로 보낼 때 화면만 컬러면, 정작 확인해야 할 것(글자가 배경에 묻히는가)을
        // 확인할 수 없다.
        #expect(gray.colorSpace?.model == .monochrome)
        #expect(PrintPreviewRenderer.render(pdf, sheet: 9, grayscale: false, maxPixel: 200) == nil)
    }

    @Test("자리가 쪽보다 크면 줄이지 않고 키운다")
    func scalesUpToFillTheSheet() throws {
        // 이것이 실제로 있었던 버그다. `CGPDFPage.getDrawingTransform`은 자리가 쪽보다
        // 클 때 **키우지 않는다.** 미리보기는 화면 크기(쪽보다 큰 캔버스)로 그리므로,
        // 화면에는 작게 그려지고 종이에는 크게 나왔다. 서버가 같은 파일을 그린 것과
        // 맞대 보고서야 드러났다.
        let pdf = try Self.makePDF(pages: 1)
        defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
        let document = try #require(CGPDFDocument(pdf as CFURL))
        let page = try #require(document.page(at: 1))
        let doubled = CGRect(x: 0, y: 0, width: 1190, height: 1684)

        let upright = PrintComposition.transform(for: page, into: doubled, rotation: 0)
        #expect(abs(upright.a - 2) < 0.02)

        // 90°는 가로세로를 바꾼다. 회전한 행렬에서는 대각이 아니라 반대각이 배율을 쥔다.
        let turned = PrintComposition.transform(for: page, into: doubled, rotation: 90)
        #expect(abs(turned.a) < 0.02)
        #expect(abs(abs(turned.b) - 1190.0 / 842.0) < 0.05)
    }

    @Test("미리보기는 종이를 가득 채운다")
    func previewFillsTheCanvas() throws {
        let pdf = try Self.makePDF(pages: 1)
        defer { try? FileManager.default.removeItem(at: pdf.deletingLastPathComponent()) }
        let image = try #require(PrintPreviewRenderer.render(pdf, sheet: 0, grayscale: true, maxPixel: 600))
        // 시험용 PDF는 A4의 가운데 475×722pt를 칠해 둔다. 제대로 키워 그렸다면 그 칠은
        // 그림 넓이의 8할쯤을 차지한다. 키우지 않으면 절반도 되지 않는다.
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
            context?.setFillColor(gray: 1, alpha: 1)
            context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, maxX = -1
        for y in 0..<height {
            for x in 0..<width where bytes[y * width + x] < 200 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        #expect(maxX > 0)
        let inkWidth = Double(maxX - minX + 1) / Double(width)
        #expect(inkWidth > 0.7)
    }

    @Test("종이 수는 만들어 둔 면 수로 세고, 매수와 양면을 곱한다")
    func countsSheetsFromTheComposedFile() {
        var options = PrintOptions()
        options.copies = 3
        #expect(options.sheets(forImposedSides: 4) == 12)
        options.sides = .twoSidedLongEdge
        #expect(options.sheets(forImposedSides: 4) == 6)
        #expect(options.sheets(forImposedSides: 0) == 0)
    }

    @Test("매수를 바꿔도 미리보기를 다시 만들지 않는다")
    func previewSignatureIgnoresCopies() {
        var options = PrintOptions()
        let before = options.previewSignature
        options.copies = 9
        #expect(options.previewSignature == before)
        options.numberUp = 2
        #expect(options.previewSignature != before)
    }

    // MARK: 무엇을 받아 주는가

    @Test("이 Mac이 열 수 있는 사진 형식은 전부 받는다")
    func acceptsEveryImageFormatTheMacKnows() {
        // 목록을 손으로 적어 두면 그 목록이 곧 낡는다. 시스템에 물어보므로 HEIC도 RAW도
        // 자동으로 들어온다.
        #expect(PrintPreparation.imageExtensions.contains("heic"))
        #expect(PrintPreparation.imageExtensions.contains("png"))
        #expect(PrintPreparation.imageExtensions.count > 20)
    }

    @Test("글처럼 생긴 것과 아닌 것을 가른다")
    func sniffsText() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "print-sniff-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = directory.appending(path: "메모")
        try "가나다 abc".write(to: text, atomically: true, encoding: .utf8)
        #expect(PrintPreparation.looksLikeText(text))

        let binary = directory.appending(path: "덩어리")
        try Data([0x00, 0x01, 0x02, 0xFF, 0x00]).write(to: binary)
        // 0바이트가 섞인 것을 글로 앉히면 종이 몇 십 장에 깨진 기호가 찍힌다.
        #expect(PrintPreparation.looksLikeText(binary) == false)
    }

    // MARK: 집에서도 밖에서도

    @Test("적어 둔 두 주소를 순서대로 시도한다")
    func triesBothAddresses() {
        // 이 맥은 집에도 있고 밖에도 있다. 주소가 하나뿐이면 나머지 한쪽에서는 아무것도
        // 되지 않고, 그것은 절반만 만든 기능이다.
        let server = HomeServer(host: "192.168.1.50", alternateHost: "100.64.0.9", user: "deploy")
        #expect(server.candidateHosts == ["192.168.1.50", "100.64.0.9"])

        let arguments = PrinterLink.arguments(
            server: server, host: "100.64.0.9", key: HomeServerKey(), command: "lpstat -p"
        )
        // 주소가 둘이면 닿지 않는 쪽에서 오래 기다리지 않는다. 그 시간만큼 화면이 비어 있다.
        #expect(arguments.contains("ConnectTimeout=4"))
        #expect(arguments.contains("deploy@100.64.0.9"))
        // 앱은 암호를 물을 창이 없다. 물으며 멈추는 대신 즉시 실패해야 한다.
        #expect(arguments.contains("BatchMode=yes"))
        // 강제 종료 뒤 남은 ssh를 다음 실행이 찾아 죽이기 위한 표식.
        #expect(arguments.last?.contains(PrinterLink.marker) == true)

        let homeOnly = HomeServer(host: "192.168.1.50", user: "deploy")
        let single = PrinterLink.arguments(
            server: homeOnly, host: "192.168.1.50", key: HomeServerKey(), command: "lpstat -p"
        )
        #expect(single.contains("ConnectTimeout=8"))
    }

    /// 쪽마다 다른 회색 사각형을 그린 PDF 하나. 쪽이 실제로 몇 개인지 세는 시험에 쓴다.
    static func makePDF(pages: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "print-compose-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "원본.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw AgentError.processFailed("시험용 PDF를 만들지 못했습니다.")
        }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(gray: CGFloat(page) / CGFloat(max(2, pages * 2)), alpha: 1)
            context.fill(CGRect(x: 60, y: 60, width: 475, height: 722))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    // MARK: 배율이 살아 있어야 하는 인쇄물

    @Test("정확한 배율로 보낼 때는 fit-to-page가 붙지 않는다")
    func exactScaleNeverScalesThePage() {
        let options = PrintCommandLine.exactScale
        let arguments = options.lpArguments(
            printer: "Samsung_C48x", title: "charuco-board", monochrome: false, composedLocally: false
        )
        // `fit-to-page`는 쪽을 종이의 인쇄 가능 영역에 맞춰 다시 잰다. 25mm로 그린 사각형이
        // 24.6mm로 나오고, 그 1.6%가 나중에 카메라가 재는 거리 전체에 실린다 — 200mm에서
        // 3mm이고 오차 예산의 절반이다.
        #expect(!arguments.contains("fit-to-page"))
        // 쪽을 다시 그리는 항목은 하나도 켜져 있으면 안 된다. 다시 그리는 순간 배율이
        // 우리 손을 떠난다.
        #expect(!arguments.contains { $0.hasPrefix("number-up") })
        #expect(!arguments.contains { $0.hasPrefix("page-ranges") })
        #expect(options.rotation == .none)
        #expect(arguments.contains("media=A4"))
        #expect(arguments.contains("sides=one-sided"))
    }

    @Test("기본 설정은 여전히 종이에 맞춘다")
    func theOrdinaryDefaultStillFits() {
        // 보통 인쇄물은 잘리지 않는 것이 중요하다. 정확한 배율은 예외이지 새 기본값이 아니다.
        let arguments = PrintOptions().lpArguments(
            printer: "p", title: "t", monochrome: false, composedLocally: false
        )
        #expect(arguments.contains("fit-to-page"))
    }

}
#endif
