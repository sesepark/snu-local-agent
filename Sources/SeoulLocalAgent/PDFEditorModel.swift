import Foundation
import AppKit
import PDFKit

/// The state behind the PDF 편집 screen.
///
/// Not a `BatchToolModel`: every other file tool in this app is "files in,
/// files out", but this one is a single document being worked on, with a
/// selection, an undo stack and no queue at all. Sharing the batch engine would
/// have meant bending both.
@MainActor
final class PDFEditorModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var sourceName = ""
    @Published private(set) var summary = ""
    // Deliberately terse: the empty state below already spells out what to do,
    // and saying it twice on one screen reads as a stutter.
    @Published private(set) var status = "PDF를 열면 쪽을 고르고 정리할 수 있습니다."
    @Published var selection: Set<Int> = []
    @Published var error: String?
    @Published private(set) var isBusy = false
    /// Bumped on every change. `PDFDocument` is a reference type whose pages
    /// mutate in place, so nothing else would tell SwiftUI to redraw a thumbnail
    /// after a rotation.
    @Published private(set) var revision = 0
    /// Set when a dropped file turned out to be locked; the view puts up a sheet.
    @Published var passwordPrompt: URL?

    private var undoStack: [Data] = []
    /// Eight steps, and nothing over 120 MB is kept: a snapshot is the whole
    /// file, and a scanned textbook would otherwise fill memory with history.
    private static let undoLimit = 8
    private static let undoSizeLimit = 120 * 1024 * 1024

    var pageCount: Int { document?.pageCount ?? 0 }
    var isEmpty: Bool { document == nil }
    var canUndo: Bool { !undoStack.isEmpty }
    var hasSelection: Bool { !selection.isEmpty }

    var selectionText: String {
        guard !selection.isEmpty else { return "고른 쪽 없음" }
        return "\(selection.count)쪽 선택"
    }

    // MARK: 열기

    func open(_ urls: [URL], password: String? = nil) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else {
            error = "PDF 파일만 넣을 수 있습니다."
            return
        }
        do {
            var documents: [PDFDocument] = []
            for url in pdfs {
                do {
                    documents.append(try PDFToolbox.load(url, password: password))
                } catch {
                    // A locked file is a question, not a failure: the sheet asks
                    // for the password and calls back in here.
                    if PDFDocument(url: url)?.isLocked == true, password == nil {
                        passwordPrompt = url
                        return
                    }
                    throw error
                }
            }
            let merged = documents.count == 1 ? documents[0] : PDFToolbox.merge(documents)
            adopt(merged, name: pdfs.count == 1 ? pdfs[0].lastPathComponent : "합친 문서 \(pdfs.count)개")
            status = pdfs.count == 1
                ? "\(pdfs[0].lastPathComponent)을(를) 열었습니다."
                : "\(pdfs.count)개를 순서대로 합쳤습니다."
        } catch {
            self.error = Self.message(for: error)
        }
    }

    /// Adds more pages to what is already open, which is the other half of
    /// "합치기" — the first drop opens, every drop after appends.
    func append(_ urls: [URL]) {
        guard let current = document else {
            open(urls)
            return
        }
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfs.isEmpty else {
            error = "PDF 파일만 붙일 수 있습니다."
            return
        }
        do {
            let added = try pdfs.map { try PDFToolbox.load($0) }
            let before = current.pageCount
            snapshot()
            adopt(PDFToolbox.merge([current] + added), name: sourceName)
            selection = Set(before ..< pageCount)
            status = "\(added.reduce(0) { $0 + $1.pageCount })쪽을 뒤에 붙였습니다."
        } catch {
            self.error = Self.message(for: error)
        }
    }

    private func adopt(_ new: PDFDocument, name: String) {
        document = new
        sourceName = name
        summary = PDFToolbox.describe(new)
        selection = selection.filter { $0 < new.pageCount }
        revision += 1
        error = nil
    }

    func close() {
        document = nil
        sourceName = ""
        summary = ""
        selection = []
        undoStack = []
        revision += 1
        status = "PDF를 열면 쪽을 고르고 정리할 수 있습니다."
    }

    // MARK: 되돌리기

    private func snapshot() {
        guard let data = document?.dataRepresentation(), data.count <= Self.undoSizeLimit else { return }
        undoStack.append(data)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
    }

    func undo() {
        guard let data = undoStack.popLast(), let restored = PDFDocument(data: data) else { return }
        adopt(restored, name: sourceName)
        status = "한 단계 되돌렸습니다."
    }

    // MARK: 쪽 정리

    func selectAll() {
        guard pageCount > 0 else { return }
        selection = Set(0 ..< pageCount)
    }

    func clearSelection() { selection = [] }

    func toggle(_ index: Int) {
        if selection.contains(index) { selection.remove(index) } else { selection.insert(index) }
    }

    func deleteSelected() {
        guard let current = document, !selection.isEmpty else { return }
        guard selection.count < current.pageCount else {
            error = "모든 쪽을 지울 수는 없습니다."
            return
        }
        snapshot()
        let removed = selection.count
        adopt(PDFToolbox.removing(selection, from: current), name: sourceName)
        selection = []
        status = "\(removed)쪽을 지웠습니다."
    }

    func rotateSelected(by degrees: Int) {
        guard let current = document else { return }
        let targets = selection.isEmpty ? Set(0 ..< current.pageCount) : selection
        snapshot()
        adopt(PDFToolbox.rotating(targets, by: degrees, in: current), name: sourceName)
        status = "\(targets.count)쪽을 \(degrees > 0 ? "오른쪽" : "왼쪽")으로 돌렸습니다."
    }

    func moveSelected(by offset: Int) {
        guard let current = document, !selection.isEmpty else { return }
        let first = selection.min() ?? 0
        let destination = max(0, min(current.pageCount - selection.count, first + offset))
        guard destination != first else { return }
        snapshot()
        let moved = PDFToolbox.moving(selection, to: destination, in: current)
        adopt(moved.document, name: sourceName)
        selection = moved.selection
        status = "고른 쪽을 옮겼습니다."
    }

    func keepOnlySelected() {
        guard let current = document, !selection.isEmpty else { return }
        snapshot()
        adopt(PDFToolbox.extracting(selection.sorted(), from: current), name: sourceName)
        selection = []
        status = "고른 쪽만 남겼습니다."
    }

    func selectRanges(_ text: String) {
        guard pageCount > 0 else { return }
        let indexes = PDFToolbox.parseRanges(text, pageCount: pageCount)
        guard !indexes.isEmpty else {
            error = "쪽 번호를 알아보지 못했습니다. `1-3, 7`처럼 적어 주세요."
            return
        }
        selection = Set(indexes)
        status = "\(indexes.count)쪽을 골랐습니다."
    }

    // MARK: 도장·워터마크

    func stamp(image url: URL, stamp: PDFStamp, scope: PDFStampScope) {
        guard let current = document else { return }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            error = "서명 이미지를 읽지 못했습니다."
            return
        }
        let pages = scope.indexes(pageCount: current.pageCount, selected: selection)
        guard !pages.isEmpty else {
            error = "넣을 쪽을 먼저 골라 주세요."
            return
        }
        run("서명을 넣고 있습니다.") { scratch in
            try PDFToolbox.stamped(current, image: image, stamp: stamp, pages: pages, into: scratch)
        } finished: { [weak self] in
            self?.status = "\(pages.count)쪽에 서명을 넣었습니다."
        }
    }

    func watermark(_ watermark: PDFWatermark, scope: PDFStampScope) {
        guard let current = document else { return }
        let pages = scope.indexes(pageCount: current.pageCount, selected: selection)
        guard !pages.isEmpty else {
            error = "넣을 쪽을 먼저 골라 주세요."
            return
        }
        run("워터마크를 넣고 있습니다.") { scratch in
            try PDFToolbox.watermarked(current, watermark: watermark, pages: pages, into: scratch)
        } finished: { [weak self] in
            self?.status = "\(pages.count)쪽에 워터마크를 넣었습니다."
        }
    }

    /// Both overlay operations write a whole new file, which on a big scan takes
    /// long enough that the screen has to say so.
    private func run(
        _ message: String,
        work: @escaping (URL) throws -> PDFDocument,
        finished: @escaping () -> Void
    ) {
        isBusy = true
        status = message
        snapshot()
        let scratch: URL
        do {
            scratch = try ToolWorkspace.directory("PDFEdit").appending(path: "작업-\(UUID().uuidString.prefix(6)).pdf")
        } catch {
            self.error = "작업 폴더를 만들지 못했습니다: \(error.localizedDescription)"
            isBusy = false
            return
        }
        do {
            let result = try work(scratch)
            adopt(result, name: sourceName)
            finished()
        } catch {
            undoStack.removeLast()
            self.error = Self.message(for: error)
        }
        isBusy = false
    }

    // MARK: 저장

    func save(userPassword: String? = nil) {
        guard let current = document else { return }
        let panel = NSSavePanel()
        panel.title = userPassword == nil ? "PDF 저장" : "암호를 건 PDF 저장"
        panel.nameFieldStringValue = Self.saveName(sourceName, suffix: userPassword == nil ? "편집" : "암호")
        panel.allowedContentTypes = [.pdf]
        if let folder = lastSaveFolder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDFToolbox.write(current, to: url, userPassword: userPassword)
            lastSaveFolder = url.deletingLastPathComponent()
            status = "저장했습니다: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            self.error = Self.message(for: error)
        }
    }

    /// 지금 편집한 것을 프린트 탭에 넘길 수 있는 파일 하나로 꺼낸다.
    ///
    /// 저장 창을 띄우지 않는다. 인쇄하려고 저장 위치를 정하게 하는 것은 한 단계를 더
    /// 시키는 일이고, 인쇄한 뒤에 그 파일이 남기를 바라는 사람도 별로 없다. 고른 쪽이
    /// 있으면 그 쪽만 나간다 — 화면에서 고른 것이 곧 인쇄할 것이라는 뜻이다.
    func fileForPrinting() -> URL? {
        guard let current = document else { return nil }
        let source = selection.isEmpty ? current : PDFToolbox.extracting(selection.sorted(), from: current)
        do {
            let directory = try ToolWorkspace.directory("Print")
            let stem = Self.saveName(sourceName, suffix: selection.isEmpty ? "인쇄" : "발췌")
            let url = directory.appending(path: stem.hasSuffix(".pdf") ? stem : "\(stem).pdf")
            try PDFToolbox.write(source, to: url)
            status = selection.isEmpty
                ? "\(current.pageCount)쪽을 프린트로 보냈습니다."
                : "고른 \(selection.count)쪽을 프린트로 보냈습니다."
            return url
        } catch {
            self.error = Self.message(for: error)
            return nil
        }
    }

    func saveSelected() {
        guard let current = document, !selection.isEmpty else { return }
        let extracted = PDFToolbox.extracting(selection.sorted(), from: current)
        let panel = NSSavePanel()
        panel.title = "고른 쪽만 저장"
        panel.nameFieldStringValue = Self.saveName(sourceName, suffix: "발췌")
        panel.allowedContentTypes = [.pdf]
        if let folder = lastSaveFolder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDFToolbox.write(extracted, to: url)
            lastSaveFolder = url.deletingLastPathComponent()
            status = "\(selection.count)쪽을 저장했습니다: \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            self.error = Self.message(for: error)
        }
    }

    /// One file per page, into a folder. What people mean by "나누기" when they
    /// have a scan of twelve separate receipts.
    func saveEachPage() {
        guard let current = document else { return }
        let panel = NSOpenPanel()
        panel.title = "쪽마다 저장할 폴더 선택"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "저장"
        if let folder = lastSaveFolder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let stem = (sourceName as NSString).deletingPathExtension
        var saved = 0
        for index in 0 ..< current.pageCount {
            let single = PDFToolbox.extracting([index], from: current)
            let target = CompressionWorkspace.uniqueURL(in: directory, name: "\(stem) \(index + 1).pdf")
            if (try? PDFToolbox.write(single, to: target)) != nil { saved += 1 }
        }
        lastSaveFolder = directory
        status = "\(saved)개 파일로 나눠 저장했습니다."
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    var lastSaveFolder: URL? {
        get { UserDefaults.standard.string(forKey: "pdfEditSaveFolder").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "pdfEditSaveFolder") }
    }

    static func saveName(_ source: String, suffix: String) -> String {
        let stem = (source as NSString).deletingPathExtension
        return "\(stem.isEmpty ? "문서" : stem)-\(suffix).pdf"
    }

    private static func message(for error: any Error) -> String {
        if let agent = error as? AgentError { return agent.errorDescription ?? "처리하지 못했습니다." }
        return error.localizedDescription
    }
}
