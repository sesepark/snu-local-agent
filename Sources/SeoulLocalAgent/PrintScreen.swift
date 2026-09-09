import SwiftUI
import AppKit
import Combine
import PhotosUI

// MARK: - 모델

/// 프린트 탭이 들고 있는 상태 전부.
///
/// 서버가 진실의 원본이다. 프린터가 대기 중인지, 어떤 용지를 물릴 수 있는지, 큐에 무엇이
/// 남아 있는지는 전부 방금 `lpstat`이 말해 준 것이고, 이 타입은 그것을 되비춘다. 로봇
/// 화면과 같은 규칙이다.
@MainActor
final class PrintModel: ObservableObject {
    struct Document: Identifiable, Sendable {
        enum State: Equatable, Sendable {
            case preparing
            case ready
            case sending(Double)
            /// 서버 큐에 들어갔다. 아직 종이는 나오지 않았다.
            case sent(String)
            /// 큐에서 사라졌다 — 서버가 프린터로 다 보냈다.
            ///
            /// **종이가 나왔다는 뜻은 아니다.** CUPS가 아는 것은 자기가 데이터를 다
            /// 넘겼다는 것까지이고, 그 뒤는 프린터가 상태를 되돌려 줄 때만 알 수 있다.
            /// 집 프린터(Samsung C48x)는 되돌려 주지 않는다 — 트레이가 비어 있어도 작업은
            /// 그대로 완료로 처리되고 프린터가 데이터를 물고 기다린다. 그래서 이 상태의
            /// 이름은 "인쇄 완료"가 아니다.
            case printed(String)
            case failed(String)
        }

        let id = UUID()
        let source: URL
        var state: State = .preparing
        var pageCount = 0
        var bytes = 0
        var note = ""
        var pdf: URL?
        var isTemporary = false
        /// 실제로 서버로 갈 파일. 쪽 범위와 모아찍기가 이미 적용되어 있다.
        var composed: PrintComposition.Composed?
        /// 그 파일이 어떤 설정으로 만들어졌는가. 설정이 바뀌면 다시 만든다.
        var previewSignature = ""
        /// 첫 장을 작게 그린 것. 목록에서 무엇을 보내는지 눈으로 확인하는 자리다.
        var thumbnail: CGImage?
        /// 나올 종이의 면 수(매수·양면 전). 아직 만들지 않았으면 쪽수로 짐작한다.
        var imposedSides: Int?

        var isReady: Bool { state == .ready }
        var isSent: Bool { if case .sent = state { true } else { false } }
        var isPrinted: Bool { if case .printed = state { true } else { false } }
        /// 서버 큐에서 이 문서를 가리키는 작업 번호.
        var jobID: String? {
            switch state {
            case .sent(let job), .printed(let job): job
            default: nil
            }
        }

        var statusText: String {
            switch state {
            case .preparing: "준비 중…"
            case .ready: note
            case .sending(let fraction): fraction > 0 ? "보내는 중 \(Int(fraction * 100))%" : "보내는 중"
            case .sent(let job): "인쇄를 기다리는 중 · \(job)"
            case .printed(let job): "프린터로 다 보냈습니다 · \(job)"
            case .failed(let message): message
            }
        }
    }

    struct PreviewTarget: Identifiable, Equatable {
        let id: UUID
    }

    enum Status: Equatable {
        case idle
        case checking
        case ready
        case failed(String)
    }

    @Published private(set) var documents: [Document] = []
    @Published private(set) var printers: [RemotePrinter] = []
    @Published private(set) var capabilities = PrinterCapabilities()
    @Published private(set) var queue: [PrintQueueEntry] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var isSending = false
    /// 크게 열어 둔 미리보기. 시트 하나를 띄우는 데 쓴다.
    @Published var previewing: PreviewTarget?
    /// 보낸 직후 잠깐 지켜보는 중인가. 종이가 없으면 그 사실은 **작업이 시작된 뒤에야**
    /// 서버에 나타나므로, 보내고 한 번 새로고침하는 것만으로는 알 수 없다.
    @Published private(set) var isWatching = false
    /// 마지막으로 실제로 대답한 주소. 집 안인지 밖인지를 화면이 말할 수 있게 한다.
    @Published private(set) var lastHost = ""
    @Published private(set) var lastCheckedAt: Date?
    /// 서버에 ghostscript가 있는가. 없으면 흑백 스위치를 걸지 않는다 — 이 프린터의 PPD에는
    /// 컬러 항목이 없어서, 흑백은 문서 자체를 바꾸는 방법으로만 가능하다.
    @Published private(set) var grayscaleAvailable = false
    @Published var errorMessage: String?

    @Published var selectedPrinter: String {
        didSet {
            guard selectedPrinter != oldValue else { return }
            UserDefaults.standard.set(selectedPrinter, forKey: Self.printerKey)
            // 서버의 대답을 받아 적는 중에 고른 값이 바뀐 것이라면 다시 물어볼 것이 없다.
            // 그 왕복은 집 밖에서 그대로 데이터 요금이 된다.
            guard !isApplying else { return }
            Task { await refresh() }
        }
    }

    @Published var options: PrintOptions {
        didSet {
            guard options != oldValue else { return }
            saveOptions()
            guard !isApplying else { return }
            // 용지와 회전은 **쪽을 만드는 단계**에 걸린다. 사진과 글은 고른 종이·방향에
            // 맞춰 앉힌 것이므로, 그 둘이 바뀌면 다시 앉혀야 화면이 말한 대로 나온다.
            guard options.previewSignature != oldValue.previewSignature else { return }
            // 용지와 회전은 쪽을 만드는 단계에 걸리므로 변환본은 다시 앉혀야 한다. 원본
            // PDF는 다시 앉힐 것이 없지만 **조판은 다시 해야 한다** — 그래서 아래 줄은
            // 어느 경우에도 부른다. 예전에는 변환본이 하나도 없으면(PDF만 있는 목록)
            // 아무것도 다시 만들지 않아 미리보기가 낡은 채로 남았다.
            if options.paper != oldValue.paper || options.rotation != oldValue.rotation {
                reprepareConvertedDocuments()
            }
            refreshPreviews(restart: true)
        }
    }

    /// 서버의 대답을 받아 적는 동안 참. 그때의 값 변경은 사람이 고른 것이 아니다.
    private var isApplying = false

    private static let printerKey = "printSelectedPrinter"
    private static let optionsKey = "printOptions"

    private let store: HomeServerStore
    private var server: HomeServer
    private var refreshTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Never>?
    /// `applicationWillTerminate`에서 닿기 위한 참조. 만들어 둔 임시 PDF를 치운다.
    private(set) static weak var current: PrintModel?

    /// 설정 화면이 직접 고치는 사본.
    ///
    /// `server`는 실제로 명령을 보낼 때 쓰는 값이고 이쪽은 사람이 타이핑하는 중인 값이다.
    /// 둘을 가르지 않으면 주소를 한 글자 지운 순간 그 상태로 접속을 시도하게 된다.
    @Published var serverDraft = HomeServer()

    /// 이 앱 전용 SSH 열쇠. 앱은 `~/.ssh`를 읽지 않으므로, 터미널에서 되는 접속이
    /// 여기서는 되지 않는다. 사용자가 이 열쇠를 서버에 한 번 등록해야 한다.
    let serverKey = HomeServerKey()

    init(store: HomeServerStore = HomeServerStore()) {
        self.store = store
        server = store.load()
        serverDraft = server
        selectedPrinter = UserDefaults.standard.string(forKey: Self.printerKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: Self.optionsKey),
           let saved = try? JSONDecoder().decode(PrintOptions.self, from: data) {
            options = saved
        } else {
            options = PrintOptions()
        }
        Self.current = self
    }

    private func saveOptions() {
        guard let data = try? JSONEncoder().encode(options) else { return }
        UserDefaults.standard.set(data, forKey: Self.optionsKey)
    }

    // MARK: 서버

    var isConfigured: Bool { server.sanitised().isConfigured }

    /// 고칠 때마다 저장한다. 파일 하나뿐이라 값이 싸고, 미뤄 두면 앱이 끝날 때
    /// 마지막 변경이 사라진다 — 설정 창에는 `onDisappear`가 오지 않는다.
    func saveServerDraft() {
        let value = serverDraft.sanitised()
        try? store.save(value)
        server = value
    }

    /// 서버에 이 앱의 공개키를 등록하는 명령. 열쇠가 없으면 먼저 만든다.
    func authorizationCommand() -> String {
        try? serverKey.ensureExists()
        return serverKey.authorizationCommand(for: serverDraft.sanitised())
    }

    /// 지금 어느 길로 붙어 있는가. 이 맥은 집에도 있고 밖에도 있으므로, 붙었다는 사실만으로는
    /// 부족하다 — 밖에서 붙어 있다면 지금 보내는 것이 모바일 데이터일 수 있다.
    var routeText: String {
        guard !lastHost.isEmpty else { return "" }
        let server = server.sanitised()
        if lastHost == server.host { return "집 주소 · \(lastHost)" }
        if lastHost == server.alternateHost { return "집 밖에서 쓰는 주소 · \(lastHost)" }
        return lastHost
    }

    var isOutsideHome: Bool {
        let server = server.sanitised()
        return !lastHost.isEmpty && lastHost == server.alternateHost && lastHost != server.host
    }

    var printer: RemotePrinter? {
        printers.first { $0.name == selectedPrinter } ?? printers.first { $0.isDefault } ?? printers.first
    }

    private var link: PrinterLink { PrinterLink(server: server) }

    /// 화면이 열릴 때와 새로고침 버튼에서만 부른다. 저절로 도는 폴링은 두지 않는다 —
    /// 밖에서 쓸 때 배경에서 계속 서버를 두드리는 것은 데이터를 쓰는 일이다.
    func refresh() async {
        refreshTask?.cancel()
        server = store.load()
        guard isConfigured else {
            status = .failed("집 서버 주소가 설정되어 있지 않습니다.")
            return
        }
        status = .checking
        let target = selectedPrinter
        let link = link
        let task = Task { [weak self] in
            do {
                let reply = try await link.run(PrintCommand.inspect(printer: target), timeout: 25)
                guard !Task.isCancelled else { return }
                self?.apply(reply)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.failed(error)
            }
        }
        refreshTask = task
        await task.value
    }

    private func apply(_ reply: PrinterLink.Reply) {
        isApplying = true
        defer { isApplying = false }
        lastHost = reply.host
        lastCheckedAt = Date()
        let sections = Self.split(reply.output)
        let facts = CUPSOutput.ippFacts(sections["IPP"] ?? "")
        var capabilities = CUPSOutput.capabilities(sections["OPTIONS"] ?? "")
        capabilities.sidesSupported = facts.sidesSupported
        capabilities.colorModesSupported = facts.colorModesSupported
        capabilities.mediaReady = facts.mediaReady
        self.capabilities = capabilities
        queue = CUPSOutput.queue(sections["QUEUE"] ?? "")
        grayscaleAvailable = capabilities.supportsMonochrome
        // 상태 사유는 두 곳에서 온다. `lpstat`의 `Alerts:`와 IPP의 `printer-state-reasons`는
        // 같은 것을 말하지만 한쪽만 채워질 때가 있어 합쳐 둔다.
        let reasons = Array(Set(CUPSOutput.alerts(sections["ALERTS"] ?? "") + facts.stateReasons)).sorted()
        printers = CUPSOutput.printers(sections["PRINTERS"] ?? "").map { printer in
            var printer = printer
            if printer.name == (selectedPrinter.isEmpty ? printer.name : selectedPrinter) {
                printer.reasons = reasons
            }
            return printer
        }
        if selectedPrinter.isEmpty || !printers.contains(where: { $0.name == selectedPrinter }) {
            selectedPrinter = printer?.name ?? ""
        }
        // 프린터가 물릴 수 없는 용지가 설정에 남아 있으면 조용히 실패한다. 지금 고를 수 있는
        // 것으로 되돌린다.
        if !capabilities.pageSizes.contains(options.paper) {
            options.paper = capabilities.defaultPageSize
        }
        if !capabilities.supportsDuplex, options.sides != .oneSided {
            options.sides = .oneSided
        }
        if !grayscaleAvailable, options.grayscale {
            options.grayscale = false
        }
        status = printers.isEmpty ? .failed(PrintError.noPrinter.localizedDescription) : .ready
        markFinishedJobs()
    }

    /// 큐에서 사라진 작업은 서버가 끝낸 것이다.
    ///
    /// 이것이 "출력 완료"를 말할 수 있는 유일하게 정직한 근거다. `lp`가 돌려준 작업 번호는
    /// **접수증**이지 영수증이 아니다 — 종이가 없으면 그 번호는 큐에 그대로 남아 있고,
    /// 그 상태에서 완료라고 적는 화면은 거짓말을 한다.
    private func markFinishedJobs() {
        let waiting = Set(queue.map(\.id))
        let blocked = printer?.isBlocked == true
        for index in documents.indices {
            guard case .sent(let job) = documents[index].state, !waiting.contains(job) else { continue }
            // 큐에서 사라졌는데 프린터가 문제를 알리고 있으면 끝난 것이 아니라 실패한 것이다.
            if blocked {
                let trouble = printer?.troubles.first(where: { $0.severity == .error })?.text ?? "프린터가 작업을 끝내지 못했습니다"
                documents[index].state = .failed(trouble)
            } else {
                documents[index].state = .printed(job)
            }
        }
    }

    private func failed(_ error: Error) {
        status = .failed(error.localizedDescription)
    }

    private static func split(_ output: String) -> [String: String] {
        var sections: [String: String] = [:]
        var key = ""
        var lines: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@"), line.hasSuffix("@@") {
                if !key.isEmpty { sections[key] = lines.joined(separator: "\n") }
                key = String(line.dropFirst(2).dropLast(2))
                lines = []
            } else {
                lines.append(String(line))
            }
        }
        if !key.isEmpty { sections[key] = lines.joined(separator: "\n") }
        return sections
    }

    // MARK: 문서

    func add(_ urls: [URL]) {
        // 폴더는 아는 형식만 골라 훑고, **직접 넣은 파일은 그대로 받는다.** 확장자가 낯설다는
        // 이유로 조용히 사라지면 사용자는 자기가 무엇을 잘못했는지 알 수 없다. 준비 단계가
        // 내용을 보고 판단하고, 정말 안 되는 것이면 그 파일 줄에 이유가 적힌다.
        var direct: [URL] = []
        var folders: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { folders.append(url) } else { direct.append(url) }
        }
        let (walked, truncated) = folders.isEmpty
            ? ([URL](), false)
            : ToolWorkspace.expand(folders, accepting: PrintPreparation.acceptedExtensions)
        var seen = Set<String>()
        let files = (direct + walked).filter { seen.insert($0.standardizedFileURL.path).inserted }
        guard !files.isEmpty else {
            errorMessage = folders.isEmpty
                ? "보낼 수 있는 파일이 없습니다. \(PrintPreparation.dropHint)"
                : "그 폴더 안에서 보낼 수 있는 파일을 찾지 못했습니다."
            return
        }
        if truncated { errorMessage = "한 번에 500개까지만 받습니다. 나머지는 다시 넣어 주세요." }
        let added = files.map { Document(source: $0) }
        documents.append(contentsOf: added)
        prepare(added.map(\.id))
    }

    private func prepare(_ ids: [UUID]) {
        let paper = options.paper
        let rotation = options.rotation
        prepareTask = Task { [weak self] in
            guard let model = self else { return }
            for id in ids {
                guard !Task.isCancelled else { return }
                guard let source = model.source(of: id) else { continue }
                do {
                    let prepared = try await PrintPreparation.prepare(source, paper: paper, rotation: rotation)
                    model.finishPreparing(id, with: prepared)
                } catch {
                    model.failPreparing(id, message: error.localizedDescription)
                }
            }
        }
    }

    /// 용지가 바뀌었다. 우리가 만든 PDF만 다시 만든다 — 원본 PDF는 손댈 것이 없다.
    private func reprepareConvertedDocuments() {
        let ids = documents.filter(\.isTemporary).map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids {
            discardComposed(id)
            guard let index = documents.firstIndex(where: { $0.id == id }) else { continue }
            if let pdf = documents[index].pdf { try? FileManager.default.removeItem(at: pdf) }
            documents[index].pdf = nil
            documents[index].previewSignature = ""
            documents[index].thumbnail = nil
            documents[index].imposedSides = nil
            documents[index].state = .preparing
        }
        prepare(ids)
    }

    private func source(of id: UUID) -> URL? {
        documents.first { $0.id == id }?.source
    }

    private func finishPreparing(_ id: UUID, with prepared: PreparedPrintDocument) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].pdf = prepared.pdf
        documents[index].pageCount = prepared.pageCount
        documents[index].bytes = prepared.bytes
        documents[index].note = prepared.note
        documents[index].isTemporary = prepared.isTemporary
        documents[index].state = .ready
        refreshPreviews()
    }

    // MARK: 미리보기

    /// 설정이 바뀐 문서만 다시 만든다.
    ///
    /// 여기서 만든 파일이 **그대로 서버로 간다.** 화면이 보여 주는 것과 종이에 나오는 것을
    /// 같게 하는 방법은 그 둘을 같은 파일로 두는 것뿐이다.
    /// 설정과 어긋난 문서가 없어질 때까지 하나씩 다시 만든다.
    ///
    /// 대상을 미리 목록으로 굳히지 않고 매번 다시 찾는 이유가 있다. 파일 여러 개를 한꺼번에
    /// 넣으면 준비가 하나씩 끝나면서 이 함수도 그때마다 불리는데, 그때 돌던 작업을 취소하고
    /// 새 목록으로 다시 시작하면 앞의 것이 끝나기 전에 계속 엎어진다. 고리 하나가 남은 것을
    /// 마저 처리하게 두고, **설정이 바뀐 경우에만** 끊고 새로 시작한다.
    ///
    /// - Parameter restart: 사람이 설정을 바꿨다. 지금 만들던 것은 이미 낡았으므로 끊는다.
    private func refreshPreviews(restart: Bool = false) {
        if restart {
            previewTask?.cancel()
            previewTask = nil
        }
        guard previewTask == nil else { return }
        previewTask = Task { [weak self] in
            guard let model = self else { return }
            while !Task.isCancelled {
                let signature = model.options.previewSignature
                let options = model.options
                guard let stale = model.documents.first(where: {
                    $0.pdf != nil && $0.previewSignature != signature
                }) else { break }
                let id = stale.id
                guard let pdf = stale.pdf else { break }
                model.discardComposed(id)
                let composed: PrintComposition.Composed
                do {
                    composed = try await Task.detached(priority: .userInitiated) {
                        try PrintComposition.compose(pdf, options: options)
                    }.value
                } catch {
                    // 실패한 문서에도 표를 남긴다. 남기지 않으면 이 고리가 같은 문서를
                    // 영원히 다시 시도한다.
                    model.finishPreview(id, composed: nil, signature: signature, thumbnail: nil)
                    model.failPreparing(id, message: error.localizedDescription)
                    continue
                }
                guard !Task.isCancelled else { break }
                let url = composed.url
                let grayscale = options.grayscale
                let thumbnail = await Task.detached(priority: .utility) {
                    PrintPreviewRenderer.render(url, sheet: 0, grayscale: grayscale, maxPixel: 240)
                }.value
                guard !Task.isCancelled else { break }
                model.finishPreview(id, composed: composed, signature: signature, thumbnail: thumbnail)
            }
            model.previewTask = nil
        }
    }

    private func discardComposed(_ id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }),
              let composed = documents[index].composed, composed.isTemporary else { return }
        try? FileManager.default.removeItem(at: composed.url)
        documents[index].composed = nil
    }

    /// 미리보기 시트를 눌러야만 볼 수 있는 상태로 두지 않기 위한 실행 인자.
    ///
    /// `--calendar-expand`와 같은 자리다. 화면을 확인할 때 창을 앞으로
    /// 끌어와 마우스로 누르는 대신, 처음부터 그 상태로 뜨게 한다.
    private static let opensPreviewOnLaunch = CommandLine.arguments.contains("--print-open-preview")

    private func finishPreview(_ id: UUID, composed: PrintComposition.Composed?, signature: String, thumbnail: CGImage?) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].composed = composed
        documents[index].previewSignature = signature
        documents[index].thumbnail = thumbnail
        documents[index].imposedSides = composed?.sheets
        guard composed != nil else { return }
        // 범위를 잘못 적어 실패했던 문서도 범위를 고치면 다시 보낼 수 있어야 한다.
        if case .failed = documents[index].state { documents[index].state = .ready }
        if Self.opensPreviewOnLaunch, previewing == nil { previewing = .init(id: id) }
    }

    /// 미리보기 시트가 그릴 한 장. 시트에서만 부르므로 캐시하지 않는다 — 넘길 때마다
    /// 그리는 편이, 200쪽짜리를 통째로 그려 두는 것보다 눈에 띄게 빠르고 가볍다.
    func previewImage(for id: UUID, sheet index: Int, maxPixel: CGFloat) async -> CGImage? {
        guard let document = documents.first(where: { $0.id == id }),
              let url = document.composed?.url else { return nil }
        let grayscale = options.grayscale
        return await Task.detached(priority: .userInitiated) {
            PrintPreviewRenderer.render(url, sheet: index, grayscale: grayscale, maxPixel: maxPixel)
        }.value
    }

    // MARK: 끝난 것

    var hasFinished: Bool { documents.contains { $0.isPrinted } }

    /// 다 나온 것만 목록에서 뺀다. 실패한 것은 남는다 — 무엇이 안 됐는지 보여야 하고,
    /// 범위를 고쳐 다시 보낼 수도 있어야 한다.
    func clearFinished() {
        for document in documents where document.isPrinted {
            if let composed = document.composed, composed.isTemporary {
                try? FileManager.default.removeItem(at: composed.url)
            }
            if document.isTemporary, let pdf = document.pdf { try? FileManager.default.removeItem(at: pdf) }
        }
        documents.removeAll { $0.isPrinted }
    }

    /// 끝난 사실을 화면 맨 위에서 한 줄로. 문서 목록까지 내려다보지 않아도 알 수 있어야 한다.
    var finishedSummary: String? {
        let printed = documents.filter(\.isPrinted).count
        let waiting = documents.filter(\.isSent).count
        guard printed > 0 else { return nil }
        if waiting > 0 { return "\(printed)개를 프린터로 보냈습니다 · \(waiting)개는 큐에서 기다리는 중" }
        return printed == 1 ? "프린터로 다 보냈습니다" : "\(printed)개 모두 프린터로 보냈습니다"
    }

    /// 이 문서가 실제로 낼 종이 수. 미리보기를 만들어 두었으면 짐작이 아니라 사실이다.
    func sheetCount(of document: Document) -> Int {
        if let sides = document.imposedSides { return options.sheets(forImposedSides: sides) }
        return options.sheets(forPages: document.pageCount)
    }

    private func failPreparing(_ id: UUID, message: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].state = .failed(message)
    }

    func remove(_ document: Document) {
        discardComposed(document.id)
        if document.isTemporary, let pdf = document.pdf { try? FileManager.default.removeItem(at: pdf) }
        if previewing?.id == document.id { previewing = nil }
        documents.removeAll { $0.id == document.id }
    }

    func clear() {
        previewing = nil
        for document in documents {
            if let composed = document.composed, composed.isTemporary {
                try? FileManager.default.removeItem(at: composed.url)
            }
            if document.isTemporary, let pdf = document.pdf { try? FileManager.default.removeItem(at: pdf) }
        }
        documents.removeAll()
    }

    /// 앱이 끝날 때. 만들어 둔 임시 PDF를 남기지 않는다.
    nonisolated static func cleanUpOnQuit() {
        guard let directory = try? ToolWorkspace.directory("Print") else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: 보내기

    var readyDocuments: [Document] { documents.filter(\.isReady) }

    var totalPages: Int { readyDocuments.reduce(0) { $0 + $1.pageCount } }

    var totalBytes: Int { readyDocuments.reduce(0) { $0 + $1.bytes } }

    var totalSheets: Int { readyDocuments.reduce(0) { $0 + sheetCount(of: $1) } }

    /// 보낼 준비가 끝난 것만. 미리보기를 아직 만드는 중이면 아직 보낼 수 없다 — 그때
    /// 보내면 화면이 보여 준 것과 다른 것이 나간다.
    var isPreparingPreviews: Bool {
        documents.contains { $0.isReady && $0.previewSignature != options.previewSignature }
    }

    var canPrint: Bool {
        !isSending && !isPreparingPreviews && !readyDocuments.isEmpty && status == .ready
            && PrintOptions.isValidRange(options.pageRange)
    }

    func printAll() {
        guard canPrint else { return }
        let documents = readyDocuments
        let options = options
        let printerName = selectedPrinter
        let grayscale = grayscaleAvailable
        let link = link
        // 보내기 전의 큐. 중간에 끊겼을 때 **우리가 만든** 잘린 작업만 골라내는 기준이 된다.
        let queueBefore = Set(queue.map(\.id))
        isSending = true
        sendTask = Task { [weak self] in
            guard let model = self else { return }
            var interrupted = false
            for document in documents {
                guard !Task.isCancelled else { break }
                let id = document.id
                model.mark(id, .sending(0))
                do {
                    // 미리보기가 그린 바로 그 파일을 보낸다. 다른 파일을 보내는 순간
                    // 미리보기는 거짓말이 된다.
                    guard let composed = document.composed else {
                        throw AgentError.processFailed("미리보기를 아직 만들지 못했습니다.")
                    }
                    let command = PrintCommand.send(
                        options: options, printer: printerName,
                        title: PrintCommand.title(for: document.source.lastPathComponent),
                        grayscaleAvailable: grayscale, composedLocally: composed.appliedLocally
                    )
                    let reply = try await link.run(command, sending: composed.url, timeout: 300) { [weak model] fraction in
                        Task { @MainActor in model?.mark(id, .sending(fraction)) }
                    }
                    let job = CUPSOutput.jobID(reply.output) ?? "접수됨"
                    model.mark(id, .sent(job), host: reply.host)
                } catch is CancellationError {
                    interrupted = true
                    model.mark(id, .failed("중단했습니다."))
                } catch {
                    model.mark(id, .failed(error.localizedDescription))
                }
            }
            // 올리는 도중에 끊으면 원격 `lp`는 **거기까지 받은 것**을 한 작업으로 만든다.
            // 그대로 두면 종이를 채우는 순간 잘린 문서가 인쇄된다. 우리가 만든 것만 지운다.
            if interrupted { await model.cancelOrphanJobs(knownBefore: queueBefore) }
            await model.finishSending()
        }
    }

    /// 보내기 전에는 없었고, 우리가 번호를 받아 두지도 않은 작업 = 끊긴 전송이 남긴 것.
    private func cancelOrphanJobs(knownBefore: Set<String>) async {
        let claimed = Set(documents.compactMap(\.jobID))
        let link = link
        guard let reply = try? await link.run("lpstat -o 2>&1", timeout: 20) else { return }
        let orphans = CUPSOutput.queue(reply.output)
            .map(\.id)
            .filter { !knownBefore.contains($0) && !claimed.contains($0) }
        guard !orphans.isEmpty else { return }
        let command = orphans.map { PrintCommand.cancel($0) }.joined(separator: "; ")
        _ = try? await link.run(command, timeout: 25)
        errorMessage = "중단했습니다. 올리다 만 작업 \(orphans.count)건을 서버 큐에서 지웠습니다."
    }

    func stop() {
        sendTask?.cancel()
    }

    private func mark(_ id: UUID, _ state: Document.State, host: String = "") {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].state = state
        if !host.isEmpty { lastHost = host }
    }

    private func finishSending() async {
        isSending = false
        await refresh()
        watchAfterSending()
    }

    /// 보낸 뒤 잠깐만 지켜본다.
    ///
    /// 종이가 없다는 것을 CUPS는 **작업이 시작되기 전까지 모른다.** 큐에 넣은 직후의
    /// 상태는 여전히 `대기 중 · 이상 없음`이고, 프린터가 종이를 물려고 해 봐야 비로소
    /// `media-empty`가 나타난다. 그래서 보낸 뒤 30초 동안 몇 번 더 물어본다. 배경에서
    /// 상시로 도는 폴링이 아니라, 방금 시작한 일이 어떻게 되는지 보는 것이다.
    private func watchAfterSending() {
        guard documents.contains(where: \.isSent) else { return }
        watchTask?.cancel()
        isWatching = true
        watchTask = Task { [weak self] in
            guard let model = self else { return }
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await model.refresh()
                // 문제가 드러났거나 큐가 비었으면 더 볼 것이 없다.
                if model.printer?.isBlocked == true { break }
                if model.queue.isEmpty { break }
            }
            model.stopWatching()
        }
    }

    private func stopWatching() { isWatching = false }

    /// 종이를 채운 뒤 큐를 다시 켠다. CUPS는 종이가 없어 실패한 큐를 스스로 끄고,
    /// 채워 넣었다고 저절로 켜지 않는다 — 그 한 번을 여기서 누른다.
    func enablePrinter() {
        let name = selectedPrinter
        guard !name.isEmpty else { return }
        let link = link
        Task { [weak self] in
            do {
                _ = try await link.run(PrintCommand.enable(printer: name), timeout: 20)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
            await self?.refresh()
        }
    }

    func cancel(_ entry: PrintQueueEntry) {
        let link = link
        Task { [weak self] in
            do {
                _ = try await link.run(PrintCommand.cancel(entry.id), timeout: 20)
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }
            await self?.refresh()
        }
    }

    /// 종이 한 장으로 길이 열려 있는지 확인한다. 버튼 한 번이 곧 실행이다.
    func printTestPage() {
        guard !isSending else { return }
        let options = options
        let printerName = selectedPrinter
        let grayscale = grayscaleAvailable
        let link = link
        isSending = true
        sendTask = Task { [weak self] in
            do {
                let page = try PrintPreparation.testPage(paper: options.paper)
                var single = PrintOptions()
                single.paper = options.paper
                let command = PrintCommand.send(
                    options: single, printer: printerName, title: "테스트 페이지",
                    grayscaleAvailable: grayscale, composedLocally: false
                )
                let reply = try await link.run(command, sending: page, timeout: 120)
                try? FileManager.default.removeItem(at: page)
                await MainActor.run {
                    self?.lastHost = reply.host
                    self?.errorMessage = "테스트 페이지를 큐에 넣었습니다 · \(CUPSOutput.jobID(reply.output) ?? "접수됨")"
                }
            } catch {
                await MainActor.run { self?.errorMessage = error.localizedDescription }
            }
            await self?.finishSending()
        }
    }

    // MARK: 개요 타일

    var overviewValue: String {
        switch status {
        case .idle: return "확인 전"
        case .checking: return "확인 중…"
        case .ready:
            if printer?.isBlocked == true { return "손봐야 합니다" }
            return printer?.state.title ?? "대기 중"
        case .failed: return "닿지 않음"
        }
    }

    var overviewDetail: String {
        switch status {
        case .idle: return "열면 서버에 한 번 물어봅니다"
        case .checking: return routeText.isEmpty ? "집 서버를 부르는 중" : routeText
        case .ready:
            if let trouble = printer?.troubles.first(where: { $0.severity != .report }) { return trouble.text }
            let name = printer?.displayName ?? "프린터"
            let waiting = queue.isEmpty ? "" : " · 큐 \(queue.count)건"
            return "\(name)\(waiting)"
        case .failed(let message): return message
        }
    }
}

// MARK: - 다른 화면에서 넘기기

/// 결과 하나를 프린터로 넘기는 길.
///
/// 환경 값인 이유: 결과 카드(`ToolResultCard`)는 자기 도구의 모델만 알고 컨트롤러를 모른다.
/// 프린트 하나 때문에 다섯 도구의 뷰에 컨트롤러를 끌어들이면, 그 다섯 자리가 모두 프린트를
/// 아는 코드가 된다. 환경으로 내려 주면 아는 곳은 창의 뿌리 한 군데뿐이다.
private struct SendToPrinterKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable ([URL]) -> Void = { _ in }
}

extension EnvironmentValues {
    var sendToPrinter: @MainActor @Sendable ([URL]) -> Void {
        get { self[SendToPrinterKey.self] }
        set { self[SendToPrinterKey.self] = newValue }
    }
}

// MARK: - 화면

struct PrintView: View {
    @ObservedObject var controller: AutomationController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        PrintWorkspace(model: controller.printing, openSettings: { openSettings() }) { directory in
            controller.chooseFilesToPrint(startingAt: directory)
        }
    }
}
private struct PrintWorkspace: View {
    @ObservedObject var model: PrintModel
    let openSettings: () -> Void
    let choose: (URL?) -> Void

    var body: some View {
        WorkspaceScreen(title: AppSection.print.title, subtitle: AppSection.print.subtitle) {
            ToolDropWell(
                symbol: "printer",
                hint: PrintPreparation.dropHint,
                busyHint: "보내는 중입니다 · 끝나거나 중단한 뒤에 넣어 주세요",
                isBusy: model.isSending,
                onURLs: { model.add($0) }
            )
            QuickFolderBar(disabled: model.isSending, choose: choose)
            PrinterStatusPanel(model: model, openSettings: openSettings)
            // 한 번 알아낸 뒤에는 계속 보여 준다. `status == .ready`로 걸어 두었더니
            // 새로고침할 때마다(`.checking`) 설정 패널이 통째로 사라졌다 — 보낸 뒤
            // 지켜보는 30초 동안 다섯 번 그런다.
            if !model.printers.isEmpty { PrintOptionsPanel(model: model) }
            PrintDocumentList(model: model)
            PrintQueuePanel(model: model)
        }
        .task { if model.status == .idle { await model.refresh() } }
        .sheet(item: $model.previewing) { target in
            PrintPreviewSheet(model: model, documentID: target.id)
        }
        .alert("프린트", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("확인") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .toolbar {
            ToolbarItem {
                Button("새로고침", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.status == .checking)
                    .help("프린터 상태와 큐를 서버에 다시 물어봅니다")
            }
            ToolbarItem {
                Menu("목록", systemImage: "ellipsis") {
                    Button("보낸 것 지우기", systemImage: "checkmark.circle") { model.clearFinished() }
                        .disabled(!model.hasFinished)
                    Button("목록 비우기", systemImage: "trash", role: .destructive) { model.clear() }
                        .disabled(model.documents.isEmpty || model.isSending)
                }
                .help("보낼 목록을 정리합니다")
            }
            ToolbarItem { PhotosPrintButton(model: model) }
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button("파일 선택…", systemImage: "folder") { choose(nil) }
                    .disabled(model.isSending)
                    .help("인쇄할 파일이나 폴더를 고릅니다")
            }
            ToolbarItem {
                if model.isSending {
                    Button("중단", systemImage: "stop.fill") { model.stop() }
                        .tint(.red)
                        .toolbarKeepsTitle()
                        .help("남은 문서 보내기를 중단합니다")
                } else {
                    Button("인쇄", systemImage: "printer.fill") { model.printAll() }
                        .buttonStyle(.glassProminent)
                        .tint(.snuBlue)
                        .disabled(!model.canPrint)
                        .toolbarKeepsTitle()
                        .help("목록의 문서를 집 서버의 프린터로 보냅니다")
                }
            }
        }
        .animation(.appContent, value: model.documents.map(\.id))
        .animation(.appControl, value: model.status)
    }
}

/// 사진 앱에서 바로 인쇄. 다른 도구들과 같은 시스템 피커라 사진 권한을 요구하지 않는다.
private struct PhotosPrintButton: View {
    @ObservedObject var model: PrintModel
    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $selection, matching: .images) {
            Label("사진 앱에서…", systemImage: "photo.on.rectangle")
        }
        .buttonStyle(.glass)
        .disabled(model.isSending)
        .help("사진 앱에서 골라 바로 인쇄합니다")
        .toolbarKeepsTitle()
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            selection = []
            Task { @MainActor in
                var urls: [URL] = []
                for item in items {
                    if let picked = try? await item.loadTransferable(type: PickedFile.self) {
                        urls.append(picked.url)
                    }
                }
                guard !urls.isEmpty else {
                    model.errorMessage = "사진 앱에서 파일을 가져오지 못했습니다."
                    return
                }
                model.add(urls)
            }
        }
    }
}

/// 프린터가 지금 어떤 상태이고, 어느 길로 닿았는가.
private struct PrinterStatusPanel: View {
    @ObservedObject var model: PrintModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(headline).font(.headline)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if model.status == .checking || model.isWatching { ProgressView().controlSize(.small) }
                if model.printer?.state == .stopped {
                    // 종이를 채운 뒤 눌러야 하는 버튼. CUPS는 스스로 켜지 않는다.
                    Button("다시 켜기") { model.enablePrinter() }
                        .buttonStyle(.glassProminent)
                        .tint(.snuBlue)
                        .help("멈춘 큐를 다시 켭니다. 종이를 채운 뒤 누르세요")
                }
                if !model.isConfigured {
                    Button("설정 열기") { openSettings() }
                        .buttonStyle(.glass)
                }
            }

            // 종이가 없다·토너가 없다는 여기 있어야 한다. 프린터 앞까지 걸어가서 알게 되는
            // 것은 집 안에서도 늦고, 집 밖에서는 알 방법 자체가 없다.
            ForEach(model.printer?.troubles ?? []) { trouble in
                Label(trouble.text, systemImage: trouble.severity.symbol)
                    .font(.callout)
                    .foregroundStyle(trouble.severity == .error ? Color.orange : .secondary)
            }

            if model.printers.count > 1 {
                Picker("프린터", selection: $model.selectedPrinter) {
                    ForEach(model.printers) { printer in
                        Text(printer.displayName).tag(printer.name)
                    }
                }
                .frame(maxWidth: 320)
            }

            HStack(spacing: Spacing.l) {
                if !model.routeText.isEmpty {
                    Label(model.routeText, systemImage: model.isOutsideHome ? "antenna.radiowaves.left.and.right" : "house")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !model.capabilities.readyPaperNames.isEmpty {
                    Label("물릴 수 있는 용지: \(model.capabilities.readyPaperNames.joined(separator: ", "))", systemImage: "tray")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("프린터가 물릴 수 있다고 말하는 규격입니다. 트레이에 종이가 실제로 들어 있는지는 알려 주지 않습니다")
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .glassPanel()
    }

    private var symbol: String {
        switch model.status {
        case .ready: model.printer?.isBlocked == true ? "exclamationmark.triangle.fill" : (model.printer?.state.symbol ?? "printer")
        case .failed: "exclamationmark.triangle.fill"
        default: "printer"
        }
    }

    private var tint: Color {
        switch model.status {
        case .failed: .orange
        case .ready: model.printer?.isBlocked == true ? .orange : .snuBlueLabel
        default: .secondary
        }
    }

    private var headline: String {
        switch model.status {
        case .idle: return "아직 확인하지 않았습니다"
        case .checking: return "집 서버에 물어보는 중…"
        case .ready:
            guard let printer = model.printer else { return "프린터가 없습니다" }
            if let finished = model.finishedSummary { return finished }
            return "\(printer.displayName) · \(printer.state.title)"
        case .failed: return "프린터에 닿지 못했습니다"
        }
    }

    private var detail: String {
        switch model.status {
        case .idle: return "새로고침을 누르면 프린터 상태와 큐를 읽어 옵니다."
        case .checking: return "적어 둔 주소를 순서대로 시도합니다 — 집 주소가 먼저, 안 되면 밖에서 쓰는 주소."
        case .ready:
            var lines: [String] = []
            if model.isWatching { lines.append("보낸 작업이 큐에서 빠지는지 지켜보는 중입니다.") }
            // 이 프린터는 종이가 없다는 것을 서버에 알려 주지 않는다. 그것을 말하지 않으면
            // 사람은 "다 보냈습니다"를 "종이가 나왔습니다"로 읽는다.
            if model.hasFinished, model.printer?.troubles.isEmpty == true {
                lines.append("서버가 프린터로 다 넘겼다는 뜻입니다. 종이가 실제로 나왔는지는 프린터만 압니다 — 트레이가 비어 있으면 프린터가 데이터를 물고 기다립니다.")
            }
            if let reason = model.printer?.reason, !reason.isEmpty, model.printer?.troubles.isEmpty == true {
                lines.append(reason)
            }
            if model.isOutsideHome {
                lines.append("집 밖에서 붙어 있습니다. 보내는 만큼 모바일 데이터를 씁니다.")
            }
            return lines.joined(separator: " ")
        case .failed(let message): return message
        }
    }
}

private struct PrintOptionsPanel: View {
    @ObservedObject var model: PrintModel

    private var rangeIsValid: Bool { PrintOptions.isValidRange(model.options.pageRange) }

    var body: some View {
        ToolSettingsPanel(explanation: explanation) {
            HStack(spacing: Spacing.l) {
                LabeledContent("매수") {
                    Stepper(value: $model.options.copies, in: 1...99) {
                        Text("\(model.options.copies)부").monospacedDigit()
                    }
                    .fixedSize()
                }
                .fixedSize()

                Picker("용지", selection: $model.options.paper) {
                    ForEach(model.capabilities.pageSizes, id: \.self) { size in
                        Text(PaperGeometry.title(for: size)).tag(size)
                    }
                }
                .frame(maxWidth: 220)

                Picker("모아찍기", selection: $model.options.numberUp) {
                    Text("한 쪽에 1장").tag(1)
                    Text("2장").tag(2)
                    Text("4장").tag(4)
                    Text("6장").tag(6)
                    Text("9장").tag(9)
                }
                .frame(maxWidth: 200)

                Picker("회전", selection: $model.options.rotation) {
                    ForEach(PrintOptions.Rotation.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 200)
                .help("가로로 긴 슬라이드를 세로 종이에 채울 때 90°를 고르세요. 미리보기가 돌아간 모습으로 바뀝니다")
                Spacer()
            }

            HStack(spacing: Spacing.l) {
                Picker("인쇄 면", selection: $model.options.sides) {
                    ForEach(PrintOptions.Sides.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 300)
                .disabled(!model.capabilities.supportsDuplex)
                .opacity(model.capabilities.supportsDuplex ? 1 : 0.4)
                .help(model.capabilities.supportsDuplex ? "" : "이 프린터에는 양면 장치가 달려 있지 않습니다")

                Toggle("흑백으로 보내기", isOn: $model.options.grayscale)
                    .disabled(!model.grayscaleAvailable)
                    .help("컬러 토너를 쓰지 않습니다. 미리보기도 함께 흑백으로 바뀝니다")
                Toggle("용지에 맞추기", isOn: $model.options.fitToPage)
                Spacer()
            }

            HStack(spacing: Spacing.s) {
                Text("쪽 범위").font(.callout)
                TextField("전체", text: $model.options.pageRange)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                if !rangeIsValid {
                    Label("1-4, 8 처럼 적어 주세요", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .disabled(model.isSending)
    }

    private var explanation: String {
        var lines: [String] = []
        if model.isPreparingPreviews {
            lines.append("미리보기를 다시 만드는 중입니다.")
        } else if model.totalPages > 0 {
            // `Text(변수)`는 `**`를 굵게 만들지 않는다 — 문자열 리터럴일 때만 마크다운으로
            // 읽힌다. 화면에 별표가 그대로 찍혀 있었다. 각 줄은 마침표로 끝난다. 끝맺지
            // 않으면 다음 문장과 이어 붙어 한 문장처럼 읽힌다.
            lines.append("문서 \(model.readyDocuments.count)개 · \(model.totalPages)쪽 → 종이 \(model.totalSheets)장 · 보낼 용량 \(PrintPreparation.byteText(model.totalBytes))입니다.")
        }
        if model.totalSheets > 30 {
            lines.append("종이가 \(model.totalSheets)장 나갑니다. 트레이에 그만큼 들어 있는지 보고 누르세요.")
        }
        if model.isOutsideHome, model.totalBytes > 20 * 1024 * 1024 {
            lines.append("집 밖에서 \(PrintPreparation.byteText(model.totalBytes))를 올려 보냅니다.")
        }
        if !model.capabilities.supportsDuplex {
            lines.append("양면 장치가 없어 단면으로만 나갑니다.")
        }
        return lines.joined(separator: " ")
    }
}

private struct PrintDocumentList: View {
    @ObservedObject var model: PrintModel

    var body: some View {
        if model.documents.isEmpty {
            EmptyResults(
                symbol: "printer",
                message: "아직 보낼 문서가 없습니다.\n위에 파일을 드롭하거나 툴바에서 파일을 고르세요."
            )
        } else {
            VStack(spacing: Spacing.s) {
                ForEach(model.documents) { document in
                    PrintDocumentRow(model: model, document: document)
                }
            }
        }
    }
}

private struct PrintDocumentRow: View {
    @ObservedObject var model: PrintModel
    let document: PrintModel.Document

    var body: some View {
        HStack(spacing: Spacing.m) {
            // 목록에서 이미 무엇이 나갈지 보인다. 종이 한 장의 모습을 그대로 줄인 것이라
            // 모아찍기를 골랐으면 여기부터 네 쪽이 한 장에 들어간 모습으로 바뀐다.
            Button { model.previewing = .init(id: document.id) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(.quaternary.opacity(0.6))
                    if let thumbnail = document.thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .padding(3)
                    } else if document.state == .preparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol).foregroundStyle(colour)
                    }
                }
                .frame(width: 46, height: 60)
            }
            .buttonStyle(.plain)
            .disabled(document.thumbnail == nil)
            .help(document.thumbnail == nil ? "" : "크게 보기")

            VStack(alignment: .leading, spacing: 2) {
                Text(document.source.lastPathComponent)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(document.statusText)
                    .font(.caption)
                    .foregroundStyle(colour == .red ? Color.red : .secondary)
                    .lineLimit(2)
                if document.isReady, document.bytes > 0 {
                    Text(PrintPreparation.byteText(document.bytes))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if case .sending(let fraction) = document.state {
                ProgressView(value: fraction)
                    .tint(.snuBlue)
                    .frame(width: 90)
            } else if document.isReady, document.pageCount > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("종이 \(model.sheetCount(of: document))장")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("미리보기") { model.previewing = .init(id: document.id) }
                        // `.borderless`는 회색 글씨로 그려져 옆의 `종이 3장`과 구별되지
                        // 않는다. 빠른 폴더 줄이 쓰는 것과 같은 링크 모양으로 둔다.
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(document.composed == nil)
                }
            } else if document.isPrinted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.snuBlueLabel)
            }
            Button("빼기", systemImage: "xmark.circle.fill") { model.remove(document) }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
                .foregroundStyle(.tertiary)
                .disabled(model.isSending)
                .help("이 문서를 목록에서 뺍니다")
        }
        .padding(Spacing.m)
        .contentCard()
    }

    private var symbol: String {
        switch document.state {
        case .preparing: "hourglass"
        case .ready: "doc"
        case .sending: "arrow.up.doc"
        case .sent: "clock"
        case .printed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var colour: Color {
        switch document.state {
        case .failed: .red
        case .printed: .snuBlueLabel
        default: .secondary
        }
    }
}

/// 나올 종이를 한 장씩 크게.
///
/// 그리는 대상은 **서버로 보낼 바로 그 파일**이다. 모아찍기와 쪽 범위는 이미 그 안에
/// 들어가 있으므로, 여기 보이는 것과 종이에 나오는 것이 어긋날 자리가 없다.
private struct PrintPreviewSheet: View {
    @ObservedObject var model: PrintModel
    let documentID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var image: CGImage?
    @State private var isRendering = false

    private var document: PrintModel.Document? {
        model.documents.first { $0.id == documentID }
    }

    private var sheets: Int { document?.composed?.sheets ?? 0 }

    var body: some View {
        VStack(spacing: Spacing.m) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(document?.source.lastPathComponent ?? "미리보기")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(.quaternary.opacity(0.4))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(Spacing.m)
                        .shadow(radius: 3, y: 1)
                } else if isRendering {
                    ProgressView()
                } else {
                    EmptyResults(symbol: "doc", message: "이 장을 그리지 못했습니다.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: Spacing.l) {
                Button("이전 장", systemImage: "chevron.left") { index = max(0, index - 1) }
                    .disabled(index <= 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .labelStyle(.iconOnly)
                Text("\(index + 1) / \(max(1, sheets))")
                    .font(.callout.monospacedDigit())
                    .frame(minWidth: 70)
                Button("다음 장", systemImage: "chevron.right") { index = min(sheets - 1, index + 1) }
                    .disabled(index >= sheets - 1)
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .labelStyle(.iconOnly)
                Spacer()
                Button("인쇄") {
                    dismiss()
                    model.printAll()
                }
                .buttonStyle(.glassProminent)
                .tint(.snuBlue)
                .disabled(!model.canPrint)
            }
        }
        .padding(Spacing.l)
        .frame(minWidth: 620, minHeight: 700)
        .task(id: renderKey) { await render() }
    }

    /// 장을 넘기거나 설정을 바꾸면 다시 그린다.
    private var renderKey: String { "\(documentID)|\(index)|\(document?.previewSignature ?? "")" }

    private var caption: String {
        guard let document else { return "" }
        var parts = [model.options.paper]
        if model.options.rotation != .none { parts.append(model.options.rotation.title) }
        if model.options.numberUp > 1 { parts.append("모아찍기 \(model.options.numberUp)장") }
        if model.options.grayscale { parts.append("흑백") }
        let range = model.options.pageRange.trimmingCharacters(in: .whitespaces)
        parts.append(range.isEmpty ? "\(document.pageCount)쪽 전체" : "\(range)쪽")
        if model.options.copies > 1 { parts.append("\(model.options.copies)부") }
        parts.append("종이 \(model.sheetCount(of: document))장")
        return parts.joined(separator: " · ")
    }

    private func render() async {
        guard sheets > 0 else { image = nil; return }
        isRendering = true
        image = await model.previewImage(for: documentID, sheet: min(index, sheets - 1), maxPixel: 1400)
        isRendering = false
    }
}

private struct PrintQueuePanel: View {
    @ObservedObject var model: PrintModel

    var body: some View {
        if !model.queue.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("서버 큐 \(model.queue.count)건").font(.headline)
                ForEach(model.queue) { entry in
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                        Text(entry.id).font(.callout).monospaced()
                        Text(PrintPreparation.byteText(entry.bytes))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(entry.submitted).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        Button("취소") { model.cancel(entry) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("이 작업을 서버 큐에서 지웁니다")
                    }
                }
                Text("여기 남아 있다는 것은 아직 종이가 나오지 않았다는 뜻입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.l)
            .glassPanel()
        }
    }
}
// MARK: - 개요 타일

struct PrintOverviewTile: View {
    @ObservedObject var model: PrintModel
    let open: () -> Void

    var body: some View {
        StatusTile(
            title: AppSection.print.title,
            value: model.overviewValue,
            detail: model.overviewDetail,
            symbol: AppSection.print.symbol,
            isBusy: model.isSending || model.status == .checking,
            isAlarming: model.printer?.state == .stopped,
            open: open
        )
    }
}

// MARK: - 설정 › 프린터

struct PrintSettingsTab: View {
    @ObservedObject var model: PrintModel

    var body: some View {
        Form {
            Section("프린터") {
                if model.printers.isEmpty {
                    Text("아직 프린터를 읽지 못했습니다. 프린트 탭에서 새로고침을 눌러 주세요.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("기본 프린터", selection: $model.selectedPrinter) {
                        ForEach(model.printers) { printer in
                            Text(printer.displayName).tag(printer.name)
                        }
                    }
                }
                Picker("기본 용지", selection: $model.options.paper) {
                    ForEach(model.capabilities.pageSizes, id: \.self) { size in
                        Text(PaperGeometry.title(for: size)).tag(size)
                    }
                }
                Button("테스트 페이지 인쇄") { model.printTestPage() }
                    .disabled(model.isSending || model.status != .ready)
                Text("종이 한 장이 나옵니다. 이 Mac에서 집 서버의 프린터까지 길이 열려 있는지 확인하는 용도입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("서버") {
                TextField("집에서 쓸 주소", text: $model.serverDraft.host, prompt: Text("192.168.0.x"))
                TextField("집 밖에서 쓸 주소", text: $model.serverDraft.alternateHost, prompt: Text("비워 두어도 됩니다"))
                TextField("계정", text: $model.serverDraft.user, prompt: Text("서버에 로그인하는 이름"))
                Stepper("SSH 포트: \(model.serverDraft.sshPort)", value: $model.serverDraft.sshPort, in: 1...65535)
                LabeledContent("지금 붙은 주소", value: model.routeText.isEmpty ? "아직 붙지 않았습니다" : model.routeText)
                Text("프린터는 집에 둔 서버(라즈베리파이 같은 것이면 충분합니다)에 USB로 붙어 있고, 이 앱은 SSH로 명령만 보냅니다. 집 주소와 집 밖에서 쓸 주소를 모두 적어 두면 어디에 있든 같은 화면이 그대로 뜹니다. **비워 두면 프린트 화면은 아무것도 하지 않습니다** — 서버가 없어도 나머지 기능은 그대로 씁니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("이 앱의 열쇠") {
                Text("앱은 `~/.ssh`를 읽지 않습니다. 터미널에서 되는 접속이 여기서는 되지 않는 이유이고, 그래서 이 앱만 쓰는 열쇠를 따로 만들어 서버에 한 번 등록합니다. 아래를 복사해 터미널에서 한 번 실행하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("등록 명령 복사") {
                    let command = model.authorizationCommand()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .disabled(!model.serverDraft.sanitised().isConfigured)
                Text("이 열쇠는 서버의 `authorized_keys`에서 언제든 지울 수 있습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { if model.status == .idle { await model.refresh() } }
        .onChange(of: model.serverDraft) { model.saveServerDraft() }
    }
}
