import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 서버가 말해 주는 것

/// 집 서버 CUPS에 등록된 프린터 하나.
///
/// 이 앱은 프린터를 직접 알지 못한다. USB로 서버에 붙어 있는 것은 서버가 쥐고 있고, 여기
/// 있는 값은 전부 `lpstat`이 방금 말해 준 것을 옮겨 적은 것이다. 같은
/// 규칙이다 — 앱이 낙관적으로 먼저 상태를 그리면, 그 낙관이 틀렸을 때 화면이 종이를 물고
/// 멈춰 있는 기계에 대해 거짓말을 한다.
struct RemotePrinter: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case idle
        case printing
        case stopped

        var title: String {
            switch self {
            case .idle: "대기 중"
            case .printing: "인쇄 중"
            case .stopped: "멈춰 있음"
            }
        }

        var symbol: String {
            switch self {
            case .idle: "printer"
            case .printing: "printer.filled.and.paper"
            case .stopped: "exclamationmark.triangle.fill"
            }
        }
    }

    let name: String
    var state: State = .idle
    /// CUPS가 덧붙인 한 줄. `media-empty-warning` 같은 기계 말이라도 그대로 싣는다 —
    /// 옮겨 적으면서 잃는 것이, 읽기 어려워서 잃는 것보다 크다.
    var reason = ""
    /// `printer-state-reasons`. 종이가 없다·토너가 없다·덮개가 열렸다를 말해 주는 자리다.
    ///
    /// 이것이 화면에 없으면 사람은 **프린터 앞까지 걸어가서야** 종이가 없다는 것을 안다.
    /// 집 밖에서는 걸어갈 수도 없다.
    var reasons: [String] = []
    var isDefault = false

    var id: String { name }

    /// 큐 이름은 `Samsung_C48x`처럼 밑줄이 그대로 보인다. 사람이 읽는 자리에서만 고친다.
    var displayName: String { name.replacingOccurrences(of: "_", with: " ") }

    /// 사람이 읽을 수 있게 옮긴 사유들. 아는 것은 우리말로, 모르는 것은 원문 그대로.
    var troubles: [PrinterTrouble] { reasons.compactMap(PrinterTrouble.init(keyword:)) }

    /// 지금 인쇄를 눌러도 종이가 나오지 않을 상태인가.
    var isBlocked: Bool { state == .stopped || troubles.contains { $0.severity == .error } }
}

/// `printer-state-reasons` 하나를 사람이 읽는 말로.
///
/// CUPS는 `media-empty-error`처럼 `사유-심각도` 꼴로 말한다. 심각도는 세 가지다 —
/// `-error`는 지금 못 찍는다는 뜻이고, `-warning`은 곧 못 찍게 된다는 뜻이며,
/// `-report`는 알아 두라는 뜻이다. 접미사가 없으면 그냥 사유다.
struct PrinterTrouble: Identifiable, Equatable, Sendable {
    enum Severity: Sendable, Equatable {
        case error, warning, report

        var symbol: String {
            switch self {
            case .error: "exclamationmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .report: "info.circle"
            }
        }
    }

    let keyword: String
    let severity: Severity
    let text: String

    var id: String { keyword }

    init?(keyword raw: String) {
        let keyword = raw.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty, keyword != "none" else { return nil }
        self.keyword = keyword
        var stem = keyword
        var severity = Severity.report
        for (suffix, value) in [("-error", Severity.error), ("-warning", .warning), ("-report", .report)]
        where stem.hasSuffix(suffix) {
            stem = String(stem.dropLast(suffix.count))
            severity = value
            break
        }
        self.severity = severity
        self.text = Self.korean[stem] ?? keyword
    }

    /// 실제로 마주치는 것들만 옮긴다. 없는 것은 원문을 그대로 보여 준다 — 지어낸 우리말보다
    /// 검색할 수 있는 원문이 낫다.
    static let korean: [String: String] = [
        "media-empty": "종이가 없습니다. 트레이에 넣어 주세요",
        "media-needed": "이 작업에 맞는 종이가 트레이에 없습니다",
        "media-low": "종이가 얼마 남지 않았습니다",
        "media-jam": "종이가 걸렸습니다",
        "input-tray-missing": "트레이가 빠져 있습니다",
        "output-area-almost-full": "출력함이 거의 찼습니다",
        "output-area-full": "출력함이 가득 찼습니다",
        "toner-empty": "토너가 비었습니다",
        "toner-low": "토너가 얼마 남지 않았습니다",
        "marker-supply-empty": "토너가 비었습니다",
        "marker-supply-low": "토너가 얼마 남지 않았습니다",
        "marker-waste-full": "폐토너통이 가득 찼습니다",
        "cover-open": "덮개가 열려 있습니다",
        "door-open": "문이 열려 있습니다",
        "interpreter-resource-unavailable": "프린터가 이 작업을 처리하지 못했습니다",
        "offline": "프린터가 꺼져 있거나 연결이 끊겼습니다",
        "shutdown": "프린터가 꺼져 있습니다",
        "connecting-to-device": "프린터에 연결하는 중입니다",
        "timed-out": "프린터가 대답하지 않습니다",
        "paused": "큐가 멈춰 있습니다",
        "spool-area-full": "서버의 스풀 공간이 가득 찼습니다",
        "other": "프린터가 이유를 밝히지 않은 문제를 알렸습니다",
    ]
}

/// PPD가 실제로 내주는 선택지. 화면의 픽커는 이것으로만 만든다.
///
/// 고정된 목록을 쓰지 않는 이유가 있다. 이 집 프린터는 양면 장치가 **달려 있지 않고**
/// (`Option1/Duplexer: *False`), 컬러/흑백을 고르는 항목이 PPD에 아예 없다. 앱이 "양면"
/// 스위치를 그려 놓으면 눌러도 아무 일이 일어나지 않는 스위치가 되고, 그것은 없는 것보다
/// 나쁘다. 프린터가 바뀌어도 같은 규칙으로 따라간다.
struct PrinterCapabilities: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let keyword: String
        let label: String
        var choices: [String]
        /// `*`가 붙어 있던 값. 없으면 빈 문자열.
        var current: String
    }

    var options: [Option] = []
    /// `ipptool`이 말해 준 것들. 같은 질문에 PPD와 IPP가 다르게 답하면 **IPP를 믿는다** —
    /// 실제로 작업을 받아 주는 쪽이 CUPS이고, `-o` 옵션을 해석하는 것도 CUPS다.
    var sidesSupported: [String] = []
    var colorModesSupported: [String] = []
    /// 트레이에 지금 들어 있다고 프린터가 말하는 용지.
    var mediaReady: [String] = []

    func option(_ keyword: String) -> Option? { options.first { $0.keyword == keyword } }

    /// 넣을 수 있는 용지. PPD 순서 그대로이되, 학생이 실제로 쓰는 것부터 앞으로 당긴다.
    var pageSizes: [String] {
        let all = option("PageSize")?.choices ?? []
        guard !all.isEmpty else { return ["A4"] }
        let preferred = ["A4", "Letter", "A5", "B5", "Legal", "A3"]
        let front = preferred.filter(all.contains)
        return front + all.filter { !front.contains($0) }
    }

    var defaultPageSize: String {
        let current = option("PageSize")?.current ?? ""
        if !current.isEmpty, current != "Default" { return current }
        return pageSizes.contains("A4") ? "A4" : (pageSizes.first ?? "A4")
    }

    /// 양면을 걸 수 있는가. 선택지가 있는 것과 **장치가 달려 있는 것**은 다르다.
    ///
    /// PPD에는 `Duplex` 항목이 언제나 들어 있지만, 그 옆의 설치 옵션(`Option1/Duplexer`)이
    /// `False`이면 그 프린터에는 양면 장치가 없다. 그 상태에서 `sides=two-sided-…`를 보내면
    /// 한 면만 찍히거나 그냥 무시된다.
    var supportsDuplex: Bool {
        // CUPS가 직접 답해 준 것이 있으면 그것이 끝이다. 이 프린터는 `sides-supported`가
        // `one-sided` 하나뿐이라고 말한다.
        if !sidesSupported.isEmpty { return sidesSupported.contains { $0.hasPrefix("two-sided") } }
        guard let duplex = option("Duplex"), duplex.choices.count > 1 else { return false }
        guard let installed = installableDuplexer else { return true }
        return installed
    }

    /// 흑백으로 보낼 수 있는가.
    ///
    /// PPD에 `ColorModel`이 없어도 CUPS가 `print-color-mode`를 받아 주면 흑백이 된다.
    /// 이 집 프린터가 정확히 그 경우다 — PPD에는 컬러 항목이 없지만 CUPS는
    /// `print-color-mode-supported = monochrome,color`라고 답한다.
    var supportsMonochrome: Bool {
        if !colorModesSupported.isEmpty { return colorModesSupported.contains("monochrome") }
        return supportsColorModel
    }

    /// 트레이에 든 종이를 사람이 읽는 이름으로. `iso_a4_210x297mm` → `A4`.
    var readyPaperNames: [String] {
        mediaReady.compactMap { keyword in
            guard let middle = keyword.split(separator: "_").dropFirst().first else { return nil }
            let name = String(middle)
            if name == "a3" || name == "a4" || name == "a5" { return name.uppercased() }
            if name == "b5" { return "B5" }
            if name == "letter" { return "Letter" }
            if name == "legal" { return "Legal" }
            return name.uppercased()
        }
    }

    private var installableDuplexer: Bool? {
        guard let option = options.first(where: {
            $0.label.localizedCaseInsensitiveContains("duplex")
                && Set($0.choices) == ["True", "False"]
        }) else { return nil }
        return option.current == "True"
    }

    /// PPD가 컬러/흑백을 고르게 해 주는가. 이 집 프린터는 해 주지 않는다.
    var supportsColorModel: Bool { (option("ColorModel")?.choices.count ?? 0) > 1 }
}

/// 서버 큐에 들어 있는 작업 하나.
struct PrintQueueEntry: Identifiable, Equatable, Sendable {
    let id: String
    var owner: String
    var bytes: Int
    var submitted: String
}

// MARK: - lpstat·lpoptions 읽기

/// CUPS 명령들이 내놓는 사람용 출력을 값으로 바꾼다.
///
/// 전부 순수 함수다. 서버 없이 시험할 수 있어야 하고, 여기가 틀리면 화면 전체가 조용히
/// 틀린 것을 말하게 되므로 시험이 붙는 자리는 여기다.
enum CUPSOutput {
    /// `lpstat -p -d`.
    static func printers(_ text: String) -> [RemotePrinter] {
        var found: [RemotePrinter] = []
        var defaultName = ""
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("printer ") {
                let rest = line.dropFirst("printer ".count)
                guard let name = rest.split(separator: " ", maxSplits: 1).first.map(String.init) else { continue }
                var printer = RemotePrinter(name: name)
                if line.contains("now printing") {
                    printer.state = .printing
                } else if line.contains("disabled since") || line.contains("is stopped") {
                    printer.state = .stopped
                } else {
                    printer.state = .idle
                }
                // `… disabled since <날짜> - 종이 없음` 의 꼬리.
                if let dash = line.range(of: " - ", options: .backwards) {
                    printer.reason = String(line[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                found.append(printer)
            } else if line.hasPrefix("\t") || line.hasPrefix("    ") {
                // 앞 줄에 딸린 사유. 빈 것이면 채운다.
                let detail = line.trimmingCharacters(in: .whitespaces)
                if !detail.isEmpty, !found.isEmpty, found[found.count - 1].reason.isEmpty {
                    found[found.count - 1].reason = detail
                }
            } else if let range = line.range(of: "system default destination: ") {
                defaultName = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return found.map { printer in
            var printer = printer
            printer.isDefault = printer.name == defaultName
            return printer
        }
    }

    /// `lpoptions -p 이름 -l`.
    ///
    /// 한 줄이 `키워드/사람이 읽는 이름: 선택지 선택지 …`이고, 지금 값에 `*`가 붙는다.
    static func capabilities(_ text: String) -> PrinterCapabilities {
        var options: [PrinterCapabilities.Option] = []
        for rawLine in text.split(separator: "\n") {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[line.startIndex..<colon])
            guard let slash = head.firstIndex(of: "/") else { continue }
            let keyword = String(head[head.startIndex..<slash])
            let label = String(head[head.index(after: slash)...])
            var choices: [String] = []
            var current = ""
            for token in line[line.index(after: colon)...].split(separator: " ") {
                if token.hasPrefix("*") {
                    let value = String(token.dropFirst())
                    current = value
                    choices.append(value)
                } else {
                    choices.append(String(token))
                }
            }
            guard !choices.isEmpty else { continue }
            options.append(.init(keyword: keyword, label: label, choices: choices, current: current))
        }
        return PrinterCapabilities(options: options)
    }

    /// `lpstat -l -p`의 `Alerts:` 줄. `none`은 사유가 없다는 뜻이지 사유의 이름이 아니다.
    static func alerts(_ text: String) -> [String] {
        text.split(separator: "\n")
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "none" }
    }

    /// `ipptool`이 내놓은 줄들에서 우리가 묻고 싶었던 것만.
    ///
    /// PPD는 프린터 제조사가 적어 둔 문서이고, 이쪽은 **작업을 실제로 받는 CUPS가 지금
    /// 답한 것**이다. 둘이 다르면 이쪽이 맞다.
    struct IPPFacts: Equatable, Sendable {
        var sidesSupported: [String] = []
        var colorModesSupported: [String] = []
        var mediaReady: [String] = []
        var stateReasons: [String] = []
        /// 토너 이름과 남은 비율. 이 프린터는 내주지 않지만, 내주는 프린터를 붙였을 때
        /// 화면이 그것을 말할 수 있어야 한다.
        var markerNames: [String] = []
        var markerLevels: [Int] = []
    }

    static func ippFacts(_ text: String) -> IPPFacts {
        var facts = IPPFacts()
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let equals = line.range(of: " = ") else { continue }
            let name = line[line.startIndex..<equals.lowerBound]
                .split(separator: " ").first.map(String.init) ?? ""
            let values = line[equals.upperBound...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            switch name {
            case "sides-supported": facts.sidesSupported = values
            case "print-color-mode-supported": facts.colorModesSupported = values
            case "media-ready": facts.mediaReady = values
            case "printer-state-reasons": facts.stateReasons = values.filter { $0 != "none" }
            case "marker-names": facts.markerNames = values
            case "marker-levels": facts.markerLevels = values.compactMap(Int.init)
            default: continue
            }
        }
        return facts
    }

    /// `lpstat -o`.
    static func queue(_ text: String) -> [PrintQueueEntry] {
        text.split(separator: "\n").compactMap { rawLine in
            let fields = rawLine.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let bytes = Int(fields[2]) else { return nil }
            let id = String(fields[0])
            // 작업 번호는 `큐이름-번호` 꼴이다. 아닌 줄은 큐 목록이 아니다.
            guard id.contains("-"), Int(id.split(separator: "-").last ?? "") != nil else { return nil }
            return PrintQueueEntry(
                id: id,
                owner: String(fields[1]),
                bytes: bytes,
                submitted: fields.dropFirst(3).joined(separator: " ")
            )
        }
    }

    /// `lp`가 성공했을 때의 한 줄: `request id is Samsung_C48x-12 (1 file(s))`.
    static func jobID(_ text: String) -> String? {
        guard let range = text.range(of: "request id is ") else { return nil }
        let rest = text[range.upperBound...]
        let id = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return id.isEmpty ? nil : id
    }
}

// MARK: - 보내는 방법

/// 한 번의 인쇄에 붙는 선택들.
///
/// 값은 IPP 이름(`sides`, `media`, `number-up`)으로 적는다. PPD마다 다른 이름(`Duplex`,
/// `PageSize`)을 쓰면 프린터를 바꾼 날 조용히 무시되기 시작한다.
struct PrintOptions: Equatable, Sendable, Codable {
    enum Sides: String, CaseIterable, Identifiable, Sendable, Codable {
        case oneSided = "one-sided"
        case twoSidedLongEdge = "two-sided-long-edge"
        case twoSidedShortEdge = "two-sided-short-edge"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .oneSided: "단면"
            case .twoSidedLongEdge: "양면 (긴 쪽으로 넘김)"
            case .twoSidedShortEdge: "양면 (짧은 쪽으로 넘김)"
            }
        }
    }

    /// 쪽을 종이 위에서 돌린다. 0·90·180·270만 뜻이 있다.
    ///
    /// 서버의 `orientation-requested`에 맡기지 않는 이유는 미리보기 때문이다. 여기서 돌려
    /// 파일에 넣으면 화면이 보여 주는 것과 종이에 나오는 것이 같은 파일이 된다. 가로로 긴
    /// 슬라이드를 세로 종이에 넣을 때 90°가 답이고, 그 결과는 눌러 보기 전에 보여야 한다.
    enum Rotation: Int, CaseIterable, Identifiable, Sendable, Codable {
        case none = 0
        case right = 90
        case upsideDown = 180
        case left = 270

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .none: "세로 그대로"
            case .right: "오른쪽으로 90°"
            case .upsideDown: "180°"
            case .left: "왼쪽으로 90°"
            }
        }

        /// 90°와 270°는 가로세로를 바꾼다. 칸을 나눌 때 이것을 셈에 넣지 않으면 눕힌 쪽이
        /// 칸에 맞지 않아 작게 들어간다.
        var swapsAxes: Bool { self == .right || self == .left }
    }

    var copies = 1
    /// 비어 있으면 전부. `1-4,8,11-` 꼴.
    var pageRange = ""
    var paper = "A4"
    var rotation: Rotation = .none
    var sides: Sides = .oneSided
    var numberUp = 1
    /// 서버에서 회색조 PDF로 바꿔 보낸다. PPD에 컬러 항목이 없는 프린터에서 흑백으로
    /// 찍을 수 있는 유일한 길이다.
    var grayscale = false
    var fitToPage = true

    /// 사람이 적은 쪽 범위가 CUPS가 받아들이는 꼴인가.
    static func isValidRange(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        // 빈 조각을 버리면 `1,,2`가 통과한다. CUPS는 그것을 받지 않는다.
        for part in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let piece = part.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { return false }
            let bounds = piece.split(separator: "-", omittingEmptySubsequences: false)
            switch bounds.count {
            case 1:
                guard let value = Int(bounds[0]), value > 0 else { return false }
            case 2:
                let low = bounds[0].isEmpty ? 1 : Int(bounds[0]) ?? 0
                let high = bounds[1].isEmpty ? Int.max : Int(bounds[1]) ?? 0
                guard low > 0, high >= low else { return false }
            default:
                return false
            }
        }
        return true
    }

    /// 이 설정으로 몇 장의 종이가 나오는가.
    ///
    /// 쪽수가 아니라 **종이 수**를 세는 이유는, 트레이에 남은 종이와 비교할 수 있는 숫자가
    /// 그것뿐이기 때문이다. 모아찍기와 양면은 둘 다 종이를 줄인다.
    func sheets(forPages pages: Int) -> Int {
        guard pages > 0 else { return 0 }
        return sheets(forImposedSides: PrintComposition.sheetCount(pages: pages, numberUp: numberUp))
    }

    /// 모아찍기까지 적용해 만들어 둔 면 수를 이미 알고 있을 때. 미리보기를 만들고 나면
    /// 짐작할 필요가 없다 — 그 파일의 쪽 수가 곧 나올 면 수다.
    func sheets(forImposedSides sides: Int) -> Int {
        guard sides > 0 else { return 0 }
        var count = sides
        if self.sides != .oneSided { count = Int(ceil(Double(count) / 2)) }
        return count * max(1, copies)
    }

    /// 미리보기가 다시 만들어져야 하는 변화만 모은 표. 매수는 여기 없다 — 열 부를 찍어도
    /// 종이 한 장의 모습은 같다.
    var previewSignature: String {
        "\(paper)|\(numberUp)|\(pageRange.trimmingCharacters(in: .whitespaces))|\(grayscale)|\(rotation.rawValue)"
    }

    func lpArguments(printer: String, title: String, monochrome: Bool, composedLocally: Bool) -> [String] {
        var arguments = ["lp"]
        if !printer.isEmpty { arguments += ["-d", printer] }
        arguments += ["-n", String(max(1, copies))]
        arguments += ["-t", title]
        arguments += ["-o", "media=\(paper)"]
        arguments += ["-o", "sides=\(sides.rawValue)"]
        if monochrome { arguments += ["-o", "print-color-mode=monochrome"] }
        // 이 둘은 이 Mac에서 이미 적용했으면 보내지 않는다. 미리보기가 보여 준 것과
        // 종이에 나오는 것이 같아야 하고, 그 둘이 같은 유일한 방법은 **같은 파일**이다.
        if !composedLocally {
            if numberUp > 1 { arguments += ["-o", "number-up=\(numberUp)"] }
            let range = pageRange.trimmingCharacters(in: .whitespaces)
            if !range.isEmpty { arguments += ["-o", "page-ranges=\(range)"] }
        }
        if fitToPage { arguments += ["-o", "fit-to-page"] }
        if copies > 1 { arguments += ["-o", "collate=true"] }
        arguments += ["--", "-"]
        return arguments
    }
}

// MARK: - 서버로 가는 길

enum PrintError: LocalizedError, Equatable {
    case notConfigured
    case unreachable(String)
    case commandFailed(String)
    case noPrinter

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "집 서버 주소가 설정되어 있지 않습니다. 설정 › 프린터에서 넣어 주세요."
        case .unreachable(let detail):
            detail
        case .commandFailed(let detail):
            detail
        case .noPrinter:
            "서버에 등록된 프린터가 없습니다. 서버에서 `lpstat -p`로 확인해 주세요."
        }
    }
}

/// 마지막으로 실제로 열린 주소를 앱이 도는 동안만 기억한다.
///
/// 이 길은 SSH 포워딩을 쓰지 않는다(터널이 필요 없고,
/// 명령 하나를 돌리고 끝난다) 기억도 따로 둔다. 집과 밖을 오갈 때 매번 닿지 않는 주소의
/// 시간 초과를 먼저 기다릴 이유가 없다는 것이 이 기억의 전부다.
private final class PrinterHostMemory: @unchecked Sendable {
    static let shared = PrinterHostMemory()
    private let lock = NSLock()
    private var host: String?

    var remembered: String? {
        lock.lock()
        defer { lock.unlock() }
        return host
    }

    func remember(_ value: String) {
        lock.lock()
        host = value
        lock.unlock()
    }

    func forget() {
        lock.lock()
        host = nil
        lock.unlock()
    }
}

/// 집 서버에 명령 하나를 보내고 그 대답을 받아 온다.
///
/// ## 집에서도 밖에서도
///
/// 이 맥은 집에도 있고 밖에도 있다. 그래서 주소를 두 개 두고
/// (`host` = 집 LAN, `alternateHost` = Tailscale) 먼저 열리는 쪽을 쓴다. 주소를 하나로
/// 합치자는 이야기는 하지 않는다 — tailnet 주소만 남기면 Tailscale이 꺼진 날 집에서도
/// 못 닿고, LAN 주소만 남기면 밖에서 아무것도 못 한다. 두 길은 서로의 대비책이다.
///
/// ## 프로세스는 반드시 죽는다
///
/// `ActiveProcessRegistry`에 등록하고, 명령줄에 표식을 심어 두고, 시간 초과에서는 신호를
/// 보낸 뒤 죽인다. 앱이 끝날 때 남아 있는 ssh가 없어야 한다.
struct PrinterLink: Sendable {
    /// 원격에서는 셸 주석이고, 로컬 `ps` 출력에는 남는다.
    static let marker = "seoul-local-agent-print"

    struct Reply: Sendable {
        var output: String
        /// 실제로 대답한 주소. 화면이 "집에서 붙었는지 밖에서 붙었는지"를 말할 수 있게 한다.
        var host: String
    }

    let server: HomeServer
    var key = HomeServerKey()

    static func arguments(server: HomeServer, host: String, key: HomeServerKey, command: String) -> [String] {
        [
            "-T",
            "-o", "BatchMode=yes",
            // 주소가 둘이면 짧게 끊는다. 밖에 있을 때 집 주소는 대답하지 않고 시간만 쓰는데,
            // 그 시간이 길면 화면이 그만큼 비어 있다.
            "-o", "ConnectTimeout=\(server.candidateHosts.count > 1 ? 4 : 8)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            // `~/.ssh`는 샌드박스 밖의 보호 폴더라 앱이 읽지 못한다. 이 앱 전용 열쇠만 쓴다.
            "-i", key.privateKey.path,
            "-o", "IdentitiesOnly=yes",
            "-o", "UserKnownHostsFile=\(key.knownHosts.path)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", String(server.sshPort),
            server.sshTarget(host: host),
            "\(command) # \(marker)",
        ]
    }

    /// 시도할 주소 순서. 지난번에 열린 것이 맨 앞으로 온다.
    private var hosts: [String] {
        let all = server.sanitised().candidateHosts
        guard let remembered = PrinterHostMemory.shared.remembered, all.contains(remembered) else { return all }
        return [remembered] + all.filter { $0 != remembered }
    }

    /// - Parameters:
    ///   - sending: stdin으로 흘려보낼 파일. 서버에 임시 파일을 만들지 않기 위한 것이다 —
    ///     `lp`가 스풀로 복사해 가므로 남길 것이 없고, 지울 것도 없다.
    ///   - progress: 보낸 비율. 밖에서 모바일 데이터로 큰 PDF를 보낼 때 이것이 없으면
    ///     화면이 멈춘 것처럼 보인다.
    func run(
        _ command: String,
        sending file: URL? = nil,
        timeout: Double = 20,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Reply {
        let server = server.sanitised()
        guard server.isConfigured else { throw PrintError.notConfigured }
        try key.ensureExists()

        var failures: [(host: String, reason: String)] = []
        for host in hosts {
            do {
                let output = try await execute(
                    command, host: host, server: server, file: file, timeout: timeout, progress: progress
                )
                PrinterHostMemory.shared.remember(host)
                return Reply(output: output, host: host)
            } catch let error as PrintError {
                guard case .unreachable(let reason) = error else { throw error }
                failures.append((host, reason))
            }
        }
        PrinterHostMemory.shared.forget()
        throw PrintError.unreachable(
            HomeServer.failureText(failures, server: server, key: key)
        )
    }

    /// ssh 하나를 돌리고 stdout을 돌려준다.
    ///
    /// 연결이 안 된 것(`.unreachable`)과 원격 명령이 실패한 것(`.commandFailed`)을 가른다.
    /// 앞의 것만 다음 주소로 넘어갈 이유가 되고, 뒤의 것은 어느 주소로 가도 같은 답이 온다.
    /// ssh는 자기 문제일 때 255로 끝나므로 그것이 경계선이다.
    private func execute(
        _ command: String, host: String, server: HomeServer, file: URL?,
        timeout: Double, progress: (@Sendable (Double) -> Void)?
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(server: server, host: host, key: key, command: command)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let input = file == nil ? nil : Pipe()
        if let input {
            process.standardInput = input
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            throw PrintError.unreachable("ssh를 실행하지 못했습니다: \(error.localizedDescription)")
        }
        ActiveProcessRegistry.shared.add(process)
        defer { ActiveProcessRegistry.shared.remove(process) }

        if let input, let file {
            Self.feed(file, into: input, progress: progress)
        }
        // 파이프는 자식이 도는 동안 비워 줘야 한다. 끝난 뒤에 읽으면 출력이 버퍼보다 클 때
        // 서로를 기다리며 멈춘다.
        let outputReader = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
        let errorReader = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Task.isCancelled { break }
            if Date() > deadline {
                timedOut = true
                break
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let stdout = String(decoding: await outputReader.value, as: UTF8.self)
        let stderr = String(decoding: await errorReader.value, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("Permanently added") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if Task.isCancelled { throw CancellationError() }
        if timedOut {
            throw PrintError.unreachable("\(host): \(Int(timeout))초 안에 대답하지 않았습니다")
        }
        let status = process.terminationStatus
        guard status != 0 else { return stdout }
        if status == 255 {
            throw PrintError.unreachable(stderr.isEmpty ? "연결하지 못했습니다" : stderr)
        }
        let detail = stderr.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : stderr
        throw PrintError.commandFailed(detail.isEmpty ? "서버에서 명령이 \(status)로 끝났습니다." : detail)
    }

    /// 파일을 stdin으로 흘려보낸다.
    ///
    /// 협력 스레드가 아니라 별도 큐인 이유: 파이프가 가득 차면 쓰기가 **막힌다.** 그 막힘이
    /// Swift 동시성의 스레드에서 일어나면 다른 작업들까지 함께 서 버린다.
    private static func feed(_ file: URL, into pipe: Pipe, progress: (@Sendable (Double) -> Void)?) {
        let handle = pipe.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            defer { try? handle.close() }
            guard let reader = try? FileHandle(forReadingFrom: file) else { return }
            defer { try? reader.close() }
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let total = (attributes?[.size] as? Int) ?? 0
            var sent = 0
            while true {
                guard let chunk = try? reader.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                do {
                    try handle.write(contentsOf: chunk)
                } catch {
                    // 원격이 먼저 끝났다. 종료 상태가 이유를 말해 줄 것이므로 여기서는 조용히 그만둔다.
                    return
                }
                sent += chunk.count
                if total > 0 { progress?(min(1, Double(sent) / Double(total))) }
            }
            progress?(1)
        }
    }
}

// MARK: - 명령 만들기

/// 서버에서 돌릴 셸 한 줄을 만든다.
enum PrintCommand {
    /// 작은따옴표로 감싼다. 파일 이름에 공백·따옴표·한글이 들어와도 셸이 쪼개지 않는다.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 상태·선택지·큐를 **한 번의 왕복으로** 모두 읽어 온다.
    ///
    /// 셋으로 나누면 밖에서 쓸 때 왕복 지연이 세 배가 된다. 집 안에서는 티가 안 나지만
    /// 모바일 데이터로 붙어 있을 때는 화면이 눈에 띄게 늦게 찬다.
    static func inspect(printer: String) -> String {
        // 프린터를 아직 고르지 않았으면 서버의 기본 프린터를 쓴다. 그 이름을 알아내려고
        // 왕복을 한 번 더 하지 않고, 셸이 그 자리에서 알아내게 한다.
        [
            "P=\(quote(printer))",
            "if [ -z \"$P\" ]; then P=\"$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')\"; fi",
            "printf '@@PRINTERS@@\\n'; lpstat -p -d 2>&1",
            // 종이가 없다·토너가 없다는 여기로 온다. `lpstat -l -p`가 `printer-state-reasons`를
            // `Alerts:` 한 줄로 내놓는다.
            "printf '@@ALERTS@@\\n'; [ -n \"$P\" ] && lpstat -l -p \"$P\" 2>&1 | sed -n 's/^[[:space:]]*Alerts: //p'",
            "printf '@@OPTIONS@@\\n'; lpoptions ${P:+-p \"$P\"} -l 2>&1",
            "printf '@@QUEUE@@\\n'; lpstat -o 2>&1",
            // PPD가 말하지 않는 것을 CUPS에게 직접 묻는다: 양면이 되는지, 흑백이 되는지,
            // 트레이에 무엇이 들어 있는지.
            "printf '@@IPP@@\\n'; [ -n \"$P\" ] && ipptool -tv \"ipp://localhost/printers/$P\" /usr/share/cups/ipptool/get-printer-attributes.test 2>/dev/null | grep -E 'print-color-mode-supported|sides-supported|printer-state-reasons|media-ready \\(|marker-names|marker-levels' || true",
        ].joined(separator: "; ")
    }

    /// 멈춘 큐를 다시 켠다. 종이를 채운 뒤 눌러야 하는 버튼이 이것이다 — CUPS는 종이가
    /// 없어 실패한 큐를 스스로 끄고, 채워 넣었다고 저절로 켜 주지 않는다.
    static func enable(printer: String) -> String {
        "cupsenable \(quote(printer)) 2>&1 && lpstat -p \(quote(printer)) 2>&1"
    }

    /// stdin으로 들어온 PDF를 큐에 넣는 한 줄.
    ///
    /// 서버에 임시 파일을 만들지 않는다. `lp`는 받은 것을 그 자리에서 스풀로 복사하므로
    /// 남는 것이 없고, 지울 것도 없고, 중간에 끊겨도 서버에 조각이 남지 않는다.
    /// - Parameter composedLocally: 쪽 범위와 모아찍기를 이 Mac에서 이미 적용했는가.
    ///   그랬다면 서버에 다시 시키지 않는다 — 두 번 적용되면 고른 쪽의 고른 쪽이 나간다.
    static func send(
        options: PrintOptions, printer: String, title: String,
        grayscaleAvailable: Bool, composedLocally: Bool
    ) -> String {
        options.lpArguments(
            printer: printer, title: title,
            monochrome: options.grayscale && grayscaleAvailable,
            composedLocally: composedLocally
        ).map(quote).joined(separator: " ")
    }

    static func cancel(_ job: String) -> String { "cancel \(quote(job))" }

    /// 제목은 서버 큐와 작업 목록에 그대로 보인다. 줄바꿈과 따옴표만 걷어 내고 길이를 자른다.
    static func title(for name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let prefix = String(cleaned.prefix(80))
        return prefix.isEmpty ? "SeoulLocalAgent" : prefix
    }
}

// MARK: - 창 없이 확인하기

/// `--printer-check`. 창을 열지 않고 프린터까지 가는 길을 확인한다.
///
/// `--connection-check`와 같은 자리의 도구다. 그런데 이쪽은 **주소를 하나씩 따로** 두드린다.
/// 이 맥은 집에도 있고 밖에도 있으므로, "닿았다"는 한 줄로는 집 주소가 살아 있는지 밖에서
/// 쓸 주소가 살아 있는지 알 수 없다. 실제로 필요한 답은 그 두 줄이다.
enum PrintConnectionCheck {
    static func run() async -> Bool {
        let server = HomeServerStore().load()
        guard server.isConfigured else {
            print("❌ 집 서버 주소가 없습니다. 설정 › 프린터에서 주소와 계정을 넣으세요.")
            print("   설정 파일: \(HomeServerStore().debugURL.path)")
            return false
        }
        let key = HomeServerKey()
        guard key.exists else {
            print("❌ 이 앱 전용 SSH 열쇠가 없습니다: \(key.privateKey.path)")
            return false
        }
        print("• 대상 \(server.user)@[\(server.candidateHosts.joined(separator: ", "))]")

        var reachable: [String] = []
        for host in server.candidateHosts {
            var single = server
            single.host = host
            single.alternateHost = ""
            let link = PrinterLink(server: single)
            do {
                let reply = try await link.run("lpstat -p -d 2>&1", timeout: 15)
                let printers = CUPSOutput.printers(reply.output)
                let label = host == server.host ? "집 주소" : "집 밖에서 쓸 주소"
                if printers.isEmpty {
                    print("⚠️  \(label) \(host): 닿았지만 등록된 프린터가 없습니다")
                } else {
                    let summary = printers
                        .map { "\($0.name) \($0.state.title)\($0.isDefault ? " (기본)" : "")" }
                        .joined(separator: ", ")
                    print("✅ \(label) \(host): \(summary)")
                }
                reachable.append(host)
            } catch {
                let label = host == server.host ? "집 주소" : "집 밖에서 쓸 주소"
                print("❌ \(label) \(host): \(error.localizedDescription.split(separator: "\n").first ?? "")")
            }
        }
        guard let working = reachable.first else {
            print("❌ 어느 주소로도 닿지 못했습니다. 집 안이라면 서버가 켜져 있는지, 밖이라면 Tailscale이 양쪽에서 도는지 보세요.")
            return false
        }
        if reachable.count < server.candidateHosts.count {
            print("⚠️  한쪽 길만 열려 있습니다. 지금 위치에서는 문제가 없지만, 다른 곳으로 옮기면 닿지 않을 수 있습니다.")
        }

        var single = server
        single.host = working
        single.alternateHost = ""
        do {
            let reply = try await PrinterLink(server: single).run(PrintCommand.inspect(printer: ""), timeout: 25)
            let sections = reply.output.components(separatedBy: "@@")
            func section(_ name: String) -> String {
                guard let index = sections.firstIndex(of: name), index + 1 < sections.count else { return "" }
                return sections[index + 1]
            }
            let facts = CUPSOutput.ippFacts(section("IPP"))
            var capabilities = CUPSOutput.capabilities(section("OPTIONS"))
            capabilities.sidesSupported = facts.sidesSupported
            capabilities.colorModesSupported = facts.colorModesSupported
            capabilities.mediaReady = facts.mediaReady
            print("• 용지 \(capabilities.pageSizes.prefix(6).joined(separator: ", "))")
            if !capabilities.readyPaperNames.isEmpty {
                print("• 물릴 수 있는 용지 \(capabilities.readyPaperNames.joined(separator: ", ")) (트레이에 실제로 들어 있는지는 알려 주지 않습니다)")
            }
            print("• 양면 \(capabilities.supportsDuplex ? "가능" : "장치 없음") · 흑백 \(capabilities.supportsMonochrome ? "가능" : "불가")")
            let troubles = CUPSOutput.alerts(section("ALERTS")).compactMap(PrinterTrouble.init(keyword:))
            if troubles.isEmpty {
                print("• 프린터가 알리는 문제 없음")
            } else {
                troubles.forEach { print("\($0.severity == .error ? "❌" : "⚠️ ") \($0.text)") }
            }
        } catch {
            print("⚠️  프린터 선택지를 읽지 못했습니다: \(error.localizedDescription)")
        }
        return true
    }
}

/// `--print <경로…>`. 창을 열지 않고 인쇄한다.
///
/// 터미널에서 한 장 보내고 싶을 때 쓰는 길이면서, **화면이 하는 일과 같은 길**이다 —
/// 같은 준비, 같은 미리보기용 조판, 같은 명령, 같은 지켜보기. 화면 없이 확인할 수 있는
/// 경로를 따로 두면 그 경로가 조용히 달라지므로, 여기서도 `PrintPreparation` →
/// `PrintComposition` → `PrinterLink`를 그대로 부른다.
enum PrintCommandLine {
    /// 종이 위의 길이가 파일에 적힌 길이와 **같아야** 하는 인쇄물의 설정.
    ///
    /// 캘리브레이션 표적이 그런 인쇄물이다. `fit-to-page`는 쪽을 종이의 인쇄 가능 영역에
    /// 맞춰 다시 재는데, 그러면 25mm로 그린 사각형이 24.6mm로 나온다. 그 1.6%는 나중에
    /// 카메라가 재는 **거리 전체에 1.6%로 실린다** — 200mm에서 3mm이고, 잡으려는 오차
    /// 예산(5mm)의 절반이 인쇄 한 번에 사라진다.
    ///
    /// 모아찍기·쪽 범위·회전도 모두 끈다. 셋 다 쪽을 다시 그리는 일이고, 다시 그리는
    /// 순간 배율이 우리 손을 떠난다. 흑백 변환도 하지 않는다 — 서버에서 PDF를 다시 굽는
    /// 길이라 같은 이유로 위험하고, 표적은 어차피 흑백이다.
    static var exactScale: PrintOptions {
        var options = PrintOptions()
        options.fitToPage = false
        options.numberUp = 1
        options.pageRange = ""
        options.rotation = .none
        options.sides = .oneSided
        options.grayscale = false
        options.copies = 1
        return options
    }

    static func run(paths: [String], holding: Bool = false, exact: Bool = false) async -> Bool {
        let server = HomeServerStore().load()
        guard server.isConfigured else {
            print("❌ 집 서버 주소가 없습니다. 설정 › 프린터에서 주소와 계정을 넣으세요.")
            return false
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            print("❌ 보낼 파일을 찾지 못했습니다.")
            return false
        }

        var options = PrintOptions()
        if exact {
            // 저장해 둔 설정을 **읽지 않는다.** 화면에서 무엇을 골라 두었든 배율이 어긋나면
            // 이 인쇄물은 쓸모가 없다. 사람의 설정을 덮어쓰지도 않는다.
            options = exactScale
            print("• 정확한 배율로 보냅니다 — fit-to-page 없음 · 모아찍기 없음 · 회전 없음 · A4 단면 1부")
        } else if let data = UserDefaults.standard.data(forKey: "printOptions"),
                  let saved = try? JSONDecoder().decode(PrintOptions.self, from: data) {
            options = saved
        }
        let printer = UserDefaults.standard.string(forKey: "printSelectedPrinter") ?? ""
        let link = PrinterLink(server: server)

        // 프린터가 지금 어떤 상태인지 먼저 본다. 종이가 없다면 보내기 전에 말해 주는 편이
        // 낫다 — 보낸 뒤에 알면 큐에서 지우는 일이 하나 더 생긴다.
        var target = printer
        var grayscaleAvailable = false
        do {
            let reply = try await link.run(PrintCommand.inspect(printer: printer), timeout: 25)
            let sections = reply.output.components(separatedBy: "@@")
            func section(_ name: String) -> String {
                guard let index = sections.firstIndex(of: name), index + 1 < sections.count else { return "" }
                return sections[index + 1]
            }
            let printers = CUPSOutput.printers(section("PRINTERS"))
            let facts = CUPSOutput.ippFacts(section("IPP"))
            var capabilities = CUPSOutput.capabilities(section("OPTIONS"))
            capabilities.colorModesSupported = facts.colorModesSupported
            grayscaleAvailable = capabilities.supportsMonochrome
            let chosen = printers.first { $0.name == printer } ?? printers.first { $0.isDefault } ?? printers.first
            guard let chosen else {
                print("❌ 서버에 등록된 프린터가 없습니다.")
                return false
            }
            target = chosen.name
            print("• \(reply.host) · \(chosen.displayName) · \(chosen.state.title)")
            let reasons = Array(Set(CUPSOutput.alerts(section("ALERTS")) + facts.stateReasons)).sorted()
            for trouble in reasons.compactMap(PrinterTrouble.init(keyword:)) {
                print("\(trouble.severity == .error ? "❌" : "⚠️ ") \(trouble.text)")
            }
        } catch {
            print("❌ \(error.localizedDescription)")
            return false
        }

        var jobs: [(name: String, id: String)] = []
        for url in urls {
            do {
                let prepared = try await PrintPreparation.prepare(url, paper: options.paper, rotation: options.rotation)
                let composed = try PrintComposition.compose(prepared.pdf, options: options)
                defer {
                    if composed.isTemporary { try? FileManager.default.removeItem(at: composed.url) }
                    if prepared.isTemporary { try? FileManager.default.removeItem(at: prepared.pdf) }
                }
                let sheets = options.sheets(forImposedSides: composed.sheets)
                print("• \(url.lastPathComponent) · \(prepared.note) → 종이 \(sheets)장 · \(PrintPreparation.byteText(PrintPreparation.fileSize(composed.url)))")
                var command = PrintCommand.send(
                    options: options, printer: target,
                    title: PrintCommand.title(for: url.lastPathComponent),
                    grayscaleAvailable: grayscaleAvailable, composedLocally: composed.appliedLocally
                )
                // 종이를 쓰지 않고 이 길 전체를 확인하고 싶을 때. 큐에 잡아 둔 채로 넣는다.
                if holding { command = command.replacingOccurrences(of: "'lp'", with: "'lp' '-H' 'hold'") }
                let reply = try await link.run(command, sending: composed.url, timeout: 300)
                guard let job = CUPSOutput.jobID(reply.output) else {
                    print("❌ \(url.lastPathComponent): 서버가 작업 번호를 돌려주지 않았습니다 — \(reply.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                    continue
                }
                print("✅ 큐에 넣었습니다 · \(job)")
                jobs.append((url.lastPathComponent, job))
            } catch {
                print("❌ \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        guard !jobs.isEmpty else { return false }
        if holding {
            print("• `-H hold`로 넣었으므로 종이는 나오지 않습니다. 지우려면: cancel \(jobs.map(\.id).joined(separator: " "))")
            return true
        }
        return await watch(jobs, link: link, printer: target)
    }

    /// 큐에서 사라질 때까지 지켜본다. `lp`가 돌려준 번호는 접수증이지 영수증이 아니다.
    private static func watch(
        _ jobs: [(name: String, id: String)], link: PrinterLink, printer: String
    ) async -> Bool {
        var pending = Set(jobs.map(\.id))
        for round in 0..<40 {
            try? await Task.sleep(for: .seconds(round < 6 ? 3 : 6))
            guard let reply = try? await link.run(
                "lpstat -o 2>&1; printf '@@ALERTS@@\\n'; lpstat -l -p \(PrintCommand.quote(printer)) 2>&1 | sed -n 's/^[[:space:]]*Alerts: //p'",
                timeout: 20
            ) else { continue }
            let parts = reply.output.components(separatedBy: "@@ALERTS@@")
            let queued = Set(CUPSOutput.queue(parts.first ?? "").map(\.id))
            let troubles = CUPSOutput.alerts(parts.count > 1 ? parts[1] : "")
                .compactMap(PrinterTrouble.init(keyword:))
            for job in pending.subtracting(queued).sorted() {
                let name = jobs.first { $0.id == job }?.name ?? job
                // "인쇄를 마쳤다"가 아니라 "다 보냈다"이다. CUPS가 아는 것은 거기까지다.
                print("🖨  \(name): 프린터로 다 보냈습니다 · \(job)")
            }
            pending.formIntersection(queued)
            if let blocking = troubles.first(where: { $0.severity == .error }) {
                print("❌ \(blocking.text)")
                print("   기다리는 작업: \(pending.sorted().joined(separator: ", "))")
                print("   해결한 뒤 `cupsenable \(printer)`로 큐를 다시 켜세요. 지우려면 `cancel \(pending.sorted().joined(separator: " "))`.")
                return false
            }
            for trouble in troubles where trouble.severity != .error {
                print("⚠️  \(trouble.text)")
            }
            if pending.isEmpty { return true }
        }
        print("⚠️  아직 큐에 남아 있습니다: \(pending.sorted().joined(separator: ", "))")
        return false
    }
}

/// `--print-preview <입력> <출력.png> [장 번호]`.
///
/// 화면의 미리보기가 그리는 것과 **글자 하나 다르지 않은** 그림을 파일로 꺼낸다. 같은
/// 준비, 같은 조판, 같은 렌더러를 부르므로 이 PNG가 곧 그 화면이다. 미리보기가 실제와
/// 같은지 확인하려면 이 파일과 서버가 받은 파일을 맞대 보면 된다.
enum PrintPreviewCommandLine {
    static func run(input: String, output: String, sheet: Int) async -> Bool {
        var options = PrintOptions()
        if let data = UserDefaults.standard.data(forKey: "printOptions"),
           let saved = try? JSONDecoder().decode(PrintOptions.self, from: data) {
            options = saved
        }
        // 실행 인자로 덮어쓸 수 있어야 화면을 열지 않고 여러 설정을 확인할 수 있다.
        let arguments = CommandLine.arguments
        func value(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let paper = value("--paper") { options.paper = paper }
        if let up = value("--number-up").flatMap(Int.init) { options.numberUp = up }
        if let range = value("--range") { options.pageRange = range }
        if let rotation = value("--rotate").flatMap(Int.init).flatMap(PrintOptions.Rotation.init(rawValue:)) {
            options.rotation = rotation
        }
        if arguments.contains("--gray") { options.grayscale = true }

        do {
            let prepared = try await PrintPreparation.prepare(URL(fileURLWithPath: input), paper: options.paper, rotation: options.rotation)
            let composed = try PrintComposition.compose(prepared.pdf, options: options)
            defer {
                if prepared.isTemporary, prepared.pdf != composed.url {
                    try? FileManager.default.removeItem(at: prepared.pdf)
                }
            }
            print("• \(prepared.note) → 종이 \(options.sheets(forImposedSides: composed.sheets))장 · 면 \(composed.sheets)개")
            guard let image = PrintPreviewRenderer.render(
                composed.url, sheet: sheet, grayscale: options.grayscale, maxPixel: 1400
            ) else {
                print("❌ \(sheet + 1)번째 장을 그리지 못했습니다.")
                return false
            }
            guard let destination = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: output) as CFURL, "public.png" as CFString, 1, nil
            ) else {
                print("❌ PNG를 만들지 못했습니다.")
                return false
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                print("❌ PNG를 쓰지 못했습니다.")
                return false
            }
            // 보낼 파일을 그대로 남겨 둔다. 미리보기와 실제가 같은지 대조하려면 이 파일이
            // 필요하고, 같은 파일이라는 것이 이 기능의 요점이다.
            let kept = URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("pdf")
            try? FileManager.default.removeItem(at: kept)
            try FileManager.default.copyItem(at: composed.url, to: kept)
            if composed.isTemporary { try? FileManager.default.removeItem(at: composed.url) }
            print("✅ 미리보기 \(image.width)×\(image.height) → \(output)")
            print("✅ 서버로 갈 파일 → \(kept.path)")
            return true
        } catch {
            print("❌ \(error.localizedDescription)")
            return false
        }
    }
}
