import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

// MARK: - 화면

/// PDF 편집.
///
/// The odd one out among the file tools: there is no queue and no batch, just
/// one document and a selection. What it keeps from the others is the shape —
/// the name in the title bar, the drop well first in the body, the controls in
/// one glass panel, and the primary action at the right of the toolbar.
struct PDFEditorView: View {
    @ObservedObject var controller: AutomationController

    @State private var rangeText = ""
    @State private var password = ""
    @State private var newPassword = ""
    @State private var showsPasswordEntry = false
    @State private var showsStampSheet = false
    @State private var showsWatermarkSheet = false
    @State private var stamp = PDFStamp.identity
    @State private var stampScope = PDFStampScope.last
    @State private var stampImage: URL?
    @State private var watermark = PDFWatermark()
    @State private var watermarkScope = PDFStampScope.all

    private var model: PDFEditorModel { controller.pdfEditor }
    private let columns = [GridItem(.adaptive(minimum: 130), spacing: Spacing.l)]

    var body: some View {
        WorkspaceScreen(title: AppSection.pdf.title, subtitle: AppSection.pdf.subtitle) {
            ToolDropWell(
                symbol: "doc.on.doc",
                hint: model.isEmpty
                    ? "여기로 PDF를 드롭하세요 · 여러 개를 넣으면 순서대로 합칩니다"
                    : "여기로 PDF를 더 드롭하면 뒤에 붙습니다",
                busyHint: "처리하는 중입니다",
                isBusy: model.isBusy,
                onURLs: { model.isEmpty ? model.open($0) : model.append($0) }
            )

            if !model.isEmpty {
                pageTools
            }

            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if let error = model.error {
                DismissibleError(message: error) { model.error = nil }
            }

            if model.isEmpty {
                EmptyResults(
                    symbol: AppSection.pdf.symbol,
                    message: "아직 열린 PDF가 없습니다.\n위에 PDF를 드롭하거나 툴바에서 열어 주세요."
                )
            } else {
                pageGrid
            }
        }
        .animation(.appContent, value: model.revision)
        .animation(.appContent, value: model.error)
        .toolbar { toolbar }
        .sheet(isPresented: $showsPasswordEntry) { passwordSheet }
        .sheet(item: Binding(get: { model.passwordPrompt.map(LockedFile.init) }, set: { _ in model.passwordPrompt = nil })) { locked in
            unlockSheet(locked.url)
        }
        .sheet(isPresented: $showsStampSheet) { stampSheet }
        .sheet(isPresented: $showsWatermarkSheet) { watermarkSheet }
    }

    // MARK: 툴바

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button("되돌리기", systemImage: "arrow.uturn.backward") { model.undo() }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("마지막 편집을 한 단계 되돌립니다 (⌘Z)")
        }
        ToolbarItem {
            Menu("넣기", systemImage: "signature") {
                Button("서명·도장 이미지…", systemImage: "signature") { chooseStampImage() }
                    .disabled(model.isEmpty)
                Button("워터마크…", systemImage: "seal") { showsWatermarkSheet = true }
                    .disabled(model.isEmpty)
            }
            .help("고른 쪽에 서명 이미지나 워터마크를 얹습니다")
        }
        ToolbarItem {
            // 편집을 끝낸 뒤 가장 흔히 이어지는 일이 인쇄다. 고른 쪽이 있으면 그 쪽만 간다.
            Button("프린트로 보내기", systemImage: "printer") {
                if let url = model.fileForPrinting() { controller.sendToPrinter([url]) }
            }
            .disabled(model.isEmpty)
            .help("편집한 PDF를 프린트 탭으로 넘깁니다. 고른 쪽이 있으면 그 쪽만 넘어갑니다")
        }
        ToolbarItem {
            Menu("저장", systemImage: "square.and.arrow.down") {
                Button("고른 쪽만 저장…", systemImage: "doc.badge.plus") { model.saveSelected() }
                    .disabled(!model.hasSelection)
                Button("쪽마다 나눠 저장…", systemImage: "square.split.2x1") { model.saveEachPage() }
                    .disabled(model.isEmpty)
                Divider()
                Button("암호를 걸어 저장…", systemImage: "lock") { showsPasswordEntry = true }
                    .disabled(model.isEmpty)
                Divider()
                Button("닫기", systemImage: "xmark.circle", role: .destructive) { model.close() }
                    .disabled(model.isEmpty)
            }
            .help("일부만 저장하거나, 나눠 저장하거나, 암호를 걸어 저장합니다")
        }
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Button("PDF 열기…", systemImage: "folder") {
                chooseFiles(title: "PDF 선택", startingAt: model.lastSaveFolder) { urls in
                    model.isEmpty ? model.open(urls) : model.append(urls)
                }
            }
            .help("PDF를 고릅니다. 이미 열려 있으면 뒤에 붙입니다")
        }
        ToolbarItem {
            Button("저장…", systemImage: "square.and.arrow.down") { model.save() }
                .buttonStyle(.glassProminent)
                .tint(.snuBlue)
                .toolbarKeepsTitle()
                .disabled(model.isEmpty)
                .help("편집한 PDF를 새 파일로 저장합니다. 원본은 그대로 둡니다")
        }
    }

    // MARK: 쪽 조작

    private var pageTools: some View {
        ToolSettingsPanel(explanation: "쪽을 눌러 고르고, 아래 단추로 정리합니다. 저장하기 전까지 원본 파일은 바뀌지 않습니다.") {
            HStack(spacing: Spacing.m) {
                Label("\(model.sourceName) · \(model.summary)", systemImage: "doc.richtext")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(model.selectionText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }

            HStack(spacing: Spacing.s) {
                Button("전체 선택") { model.selectAll() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("모든 쪽을 고릅니다")
                Button("선택 해제") { model.clearSelection() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.hasSelection)
                    .help("고른 쪽을 모두 해제합니다")
                TextField("1-3, 7", text: $rangeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit { model.selectRanges(rangeText) }
                    .help("쪽 번호나 범위를 적고 Return을 누르면 그 쪽이 선택됩니다")
                    .accessibilityLabel("선택할 쪽 범위")
                Button("범위 선택") { model.selectRanges(rangeText) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(rangeText.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }

            HStack(spacing: Spacing.s) {
                Button("왼쪽으로 돌리기", systemImage: "rotate.left") { model.rotateSelected(by: -90) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("고른 쪽이 없으면 모든 쪽을 돌립니다")
                Button("오른쪽으로 돌리기", systemImage: "rotate.right") { model.rotateSelected(by: 90) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("고른 쪽이 없으면 모든 쪽을 돌립니다")
                Divider().frame(height: 16)
                Button("앞으로", systemImage: "arrow.up.to.line") { model.moveSelected(by: -1) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.hasSelection)
                    .help("고른 쪽을 한 칸 앞으로 옮깁니다")
                Button("뒤로", systemImage: "arrow.down.to.line") { model.moveSelected(by: 1) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.hasSelection)
                    .help("고른 쪽을 한 칸 뒤로 옮깁니다")
                Divider().frame(height: 16)
                Button("고른 쪽만 남기기", systemImage: "scissors") { model.keepOnlySelected() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.hasSelection)
                    .help("고르지 않은 쪽을 모두 지웁니다")
                Button("지우기", systemImage: "trash", role: .destructive) { model.deleteSelected() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!model.hasSelection)
                    .help("고른 쪽을 지웁니다")
                Spacer()
            }
        }
        .disabled(model.isBusy)
    }

    private var pageGrid: some View {
        LazyVGrid(columns: columns, spacing: Spacing.l) {
            ForEach(0 ..< model.pageCount, id: \.self) { index in
                PDFPageCell(
                    document: model.document,
                    index: index,
                    revision: model.revision,
                    isSelected: model.selection.contains(index)
                ) { model.toggle(index) }
            }
        }
    }

    // MARK: 시트

    /// `sheet(item:)` needs something `Identifiable`; the URL itself is not.
    private struct LockedFile: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private func unlockSheet(_ url: URL) -> some View {
        SheetForm(title: "암호가 걸린 PDF", subtitle: url.lastPathComponent, confirm: "열기") {
            SecureField("암호", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        } cancel: {
            model.passwordPrompt = nil
            password = ""
        } apply: {
            let entered = password
            let target = url
            model.passwordPrompt = nil
            password = ""
            model.open([target], password: entered)
        }
    }

    private var passwordSheet: some View {
        SheetForm(title: "암호를 걸어 저장", subtitle: "이 암호를 입력해야 PDF가 열립니다. 잊으면 되돌릴 방법이 없습니다.", confirm: "저장…") {
            SecureField("새 암호", text: $newPassword)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
        } cancel: {
            showsPasswordEntry = false
            newPassword = ""
        } apply: {
            let entered = newPassword
            showsPasswordEntry = false
            newPassword = ""
            model.save(userPassword: entered)
        }
        .disabled(newPassword.isEmpty)
    }

    private var watermarkSheet: some View {
        SheetForm(title: "워터마크 넣기", subtitle: "쪽 가운데를 가로질러 옅게 씁니다.", confirm: "넣기") {
            VStack(alignment: .leading, spacing: Spacing.m) {
                LabeledContent("글자") {
                    TextField("대외비", text: $watermark.text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                LabeledContent("넣을 쪽") {
                    Picker("넣을 쪽", selection: $watermarkScope) {
                        ForEach(PDFStampScope.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
                LabeledContent("진하기") {
                    Slider(value: $watermark.opacity, in: 0.05 ... 0.6).frame(width: 200).tint(.snuBlue)
                }
                LabeledContent("크기") {
                    Slider(value: $watermark.size, in: 0.05 ... 0.25).frame(width: 200).tint(.snuBlue)
                }
                LabeledContent("기울기") {
                    Slider(value: $watermark.angleDegrees, in: 0 ... 90).frame(width: 200).tint(.snuBlue)
                }
            }
        } cancel: {
            showsWatermarkSheet = false
        } apply: {
            showsWatermarkSheet = false
            model.watermark(watermark, scope: watermarkScope)
        }
    }

    @ViewBuilder
    private var stampSheet: some View {
        if let stampImage, let document = model.document {
            PDFStampSheet(
                document: document,
                imageURL: stampImage,
                stamp: $stamp,
                scope: $stampScope,
                selectionCount: model.selection.count
            ) {
                showsStampSheet = false
            } apply: {
                showsStampSheet = false
                model.stamp(image: stampImage, stamp: stamp, scope: stampScope)
            }
        }
    }

    private func chooseStampImage() {
        let panel = NSOpenPanel()
        panel.title = "서명·도장 이미지 선택"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stampImage = url
        stampScope = model.hasSelection ? .selected : .last
        showsStampSheet = true
    }
}

// MARK: - 쪽 카드

/// One page thumbnail. Rendered off the main thread and only when the page or
/// the document actually changes, because a fifty-page scan re-rendering on
/// every redraw makes the grid stutter.
private struct PDFPageCell: View {
    let document: PDFDocument?
    let index: Int
    let revision: Int
    let isSelected: Bool
    let toggle: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: Spacing.xs) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(Color.white)
                        .overlay {
                            if let thumbnail {
                                Image(nsImage: thumbnail).resizable().scaledToFit().padding(3)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(height: 150)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.snuBlue)
                            .padding(6)
                    }
                }
                Text("\(index + 1)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.snuBlueLabel : .secondary)
            }
            .padding(Spacing.s)
            .contentCard(Radius.card, selected: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: "\(revision)-\(index)") { await render() }
        .help("\(index + 1)쪽 · 눌러서 고르거나 해제합니다")
        .accessibilityLabel("\(index + 1)쪽")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Rendered on the main actor because `PDFPage` is not `Sendable`, and made
    /// tolerable by the grid being lazy: only the dozen cells actually on screen
    /// ever ask for a thumbnail, and the yield lets each one land on its own
    /// frame instead of all of them on one.
    private func render() async {
        guard let page = document?.page(at: index) else { return }
        await Task.yield()
        thumbnail = page.thumbnail(of: CGSize(width: 240, height: 320), for: .mediaBox)
    }
}

// MARK: - 서명 놓기

/// Drag the signature onto the page.
///
/// A nine-position grid would have been less code, but a signature belongs on
/// the line it is signing, and no fixed grid ever lands on that line. The page
/// is shown at whatever size the sheet allows and the position is stored as a
/// fraction, so it survives a different page size on the next document.
private struct PDFStampSheet: View {
    let document: PDFDocument
    let imageURL: URL
    @Binding var stamp: PDFStamp
    @Binding var scope: PDFStampScope
    let selectionCount: Int
    let cancel: () -> Void
    let apply: () -> Void

    @State private var pageImage: NSImage?
    @State private var signature: NSImage?

    private var previewIndex: Int {
        switch scope {
        case .first, .all: 0
        case .last: max(0, document.pageCount - 1)
        case .selected: 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("서명·도장 넣기").font(.title3.weight(.semibold))
                Text("이미지를 끌어 원하는 자리에 놓고 크기를 맞추세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            page
                .frame(maxWidth: .infinity, maxHeight: 420)

            HStack(spacing: Spacing.l) {
                LabeledContent("넣을 쪽") {
                    Picker("넣을 쪽", selection: $scope) {
                        ForEach(PDFStampScope.allCases) { option in
                            Text(option == .selected ? "고른 쪽 (\(selectionCount))" : option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                LabeledContent("크기") {
                    Slider(value: $stamp.width, in: 0.05 ... 0.6).frame(width: 150).tint(.snuBlue)
                }
                LabeledContent("진하기") {
                    Slider(value: $stamp.opacity, in: 0.2 ... 1).frame(width: 130).tint(.snuBlue)
                }
                Spacer()
            }

            HStack {
                Text("고른 쪽 \(scope == .selected ? selectionCount : (scope == .all ? document.pageCount : 1))쪽에 들어갑니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("취소", action: cancel).keyboardShortcut(.cancelAction)
                Button("넣기", action: apply)
                    .buttonStyle(.glassProminent)
                    .tint(.snuBlue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(scope == .selected && selectionCount == 0)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 620)
        .task(id: previewIndex) { await loadPage() }
        .task { signature = NSImage(contentsOf: imageURL) }
    }

    private var page: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let pageImage {
                    let box = Self.fit(pageImage.size, into: proxy.size)
                    Image(nsImage: pageImage)
                        .resizable()
                        .frame(width: box.width, height: box.height)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        .shadow(radius: 3, y: 1)

                    if let signature {
                        let width = box.width * stamp.width
                        let height = width * (signature.size.height / max(1, signature.size.width))
                        let originX = (proxy.size.width - box.width) / 2
                        let originY = (proxy.size.height - box.height) / 2
                        Image(nsImage: signature)
                            .resizable()
                            .scaledToFit()
                            .frame(width: width, height: height)
                            .opacity(stamp.opacity)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.snuBlue.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            )
                            // The stamp's y is measured from the bottom, the way
                            // PDF space does; the view's grows downwards.
                            .position(
                                x: originX + box.width * stamp.centre.x,
                                y: originY + box.height * (1 - stamp.centre.y)
                            )
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        let x = (value.location.x - originX) / max(1, box.width)
                                        let y = 1 - (value.location.y - originY) / max(1, box.height)
                                        stamp.centre = CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
                                    }
                            )
                            .help("끌어서 자리를 옮깁니다")
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(height: 380)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    static func fit(_ size: CGSize, into bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func loadPage() async {
        guard let page = document.page(at: previewIndex) else { return }
        await Task.yield()
        pageImage = page.thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox)
    }
}

// MARK: - 시트 뼈대

/// The shape every small sheet in this screen wears: a title, a subtitle, the
/// fields, and the cancel/confirm pair at the bottom right.
private struct SheetForm<Content: View>: View {
    let title: String
    let subtitle: String
    let confirm: String
    @ViewBuilder var content: () -> Content
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
            HStack {
                Spacer()
                Button("취소", action: cancel).keyboardShortcut(.cancelAction)
                Button(confirm, action: apply)
                    .buttonStyle(.glassProminent)
                    .tint(.snuBlue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420)
    }
}
