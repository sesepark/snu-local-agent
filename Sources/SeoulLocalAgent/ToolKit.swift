import SwiftUI
import AppKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 파일 받기

/// Each provider reports back on its own queue, so the collected list needs a
/// lock rather than a plain captured array.
final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

/// Collects every dropped provider before returning, so a multi-file drop runs
/// as one batch with one estimate rather than several rejected calls.
///
/// Async rather than a completion handler: the callers are SwiftUI views, whose
/// closures capture the view and so are not `Sendable`, and awaiting on the main
/// actor sidesteps that entirely.
@MainActor
func collectDroppedURLs(_ providers: [NSItemProvider]) async -> [URL] {
    await withCheckedContinuation { continuation in
        let group = DispatchGroup()
        let collected = DroppedURLs()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                collected.append(url)
            }
        }
        group.notify(queue: .main) { continuation.resume(returning: collected.all) }
    }
}

/// The folders a student's files actually live in. Opening the panel already
/// pointed at one of these is the difference between one click and five.
enum QuickFolder: String, CaseIterable, Identifiable {
    case downloads
    case desktop
    case pictures
    case screenshots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .downloads: "다운로드"
        case .desktop: "바탕화면"
        case .pictures: "사진"
        case .screenshots: "스크린샷"
        }
    }

    var url: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .downloads: return home.appending(path: "Downloads")
        case .desktop: return home.appending(path: "Desktop")
        case .pictures: return home.appending(path: "Pictures")
        case .screenshots: return home.appending(path: "Pictures/screen_capture")
        }
    }

    /// The screenshot folder is a personal convention, so it only appears for
    /// people who actually have one.
    static var available: [QuickFolder] {
        allCases.filter { folder in
            guard let url = folder.url else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}

/// What `PhotosPicker` hands back. Declared as a file rather than as `Data` so
/// large videos stream to disk instead of through memory.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            PickedFile(url: try PickedFile.store(received.file))
        }
        FileRepresentation(importedContentType: .movie) { received in
            PickedFile(url: try PickedFile.store(received.file))
        }
    }

    /// The picker's file is only valid for the length of the callback, so it has
    /// to be copied into our own working folder before it disappears.
    static func store(_ file: URL) throws -> URL {
        let directory = try CompressionWorkspace.directory()
        let destination = directory.appending(path: "가져온-\(UUID().uuidString.prefix(6))-\(file.lastPathComponent)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: file, to: destination)
        return destination
    }
}

// MARK: - 공통 조각

/// An error the user can put away.
///
/// These messages used to stay on screen until the next run started, so a
/// failure from ten minutes ago sat under a tab that was working fine.
struct DismissibleError: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            // 오류 문구는 실행 중에 조립되므로 `Text(String)`으로는 마크다운이 해석되지 않는다.
            // 단추 이름을 `백틱`으로 감싼 번역문이 백틱째 찍혔다. 두 표기(코드·굵게)만 그린다.
            Text(InlineMarkup.attributed(message))
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: Spacing.xs)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("메시지 닫기")
            .accessibilityLabel("오류 메시지 닫기")
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(Color.red.opacity(0.25))
        )
        .transition(.appBanner)
    }
}

/// 실행 중에 조립된 한 줄을 아이콘과 함께. `Label(String, systemImage:)`은 마크다운을
/// 해석하지 않으므로, 서버가 준 문장이나 우리가 만든 안내를 그 자리에 넣으면 백틱이 글자로
/// 찍힌다. 그 조합을 매번 손으로 펴 쓰는 대신 여기 한 번만 적는다.
///
/// 화면 이름이나 상태 이름처럼 **표기가 들어갈 리 없는 짧은 제목**에는 쓰지 않는다 —
/// `Label`이 그대로 낫다.
struct MarkupLabel: View {
    let text: String
    let symbol: String

    init(_ text: String, systemImage: String) {
        self.text = text
        self.symbol = systemImage
    }

    var body: some View {
        Label {
            Text(InlineMarkup.attributed(text))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
    }
}

/// 오류가 아닌 소식 한 줄. `DismissibleError`와 같은 모양이되 빨갛지 않다.
///
/// 뚜껑을 닫아 녹음이 끝났다는 말이 갈 자리가 필요해서 생겼다. 그것은 잘못된 일이 아니라
/// 사람이 자리에 없는 동안 일어난 일이고, 빨간 띠로 적으면 무언가 고장 난 것으로 읽힌다.
struct DismissibleNote: View {
    let message: String
    var symbol = "info.circle.fill"
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(Color.snuBlueLabel)
                .font(.caption)
            // 짝인 `DismissibleError`와 같은 규칙으로 그린다. 이 자리에 오는 문장도 실행 중에
            // 조립되고, 단추 이름과 파일 이름을 백틱으로 감싼 것이 섞여 있다.
            Text(InlineMarkup.attributed(message))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: Spacing.xs)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
            .help("메시지 닫기")
            .accessibilityLabel("알림 닫기")
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.snuBlue.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .strokeBorder(Color.snuBlue.opacity(0.25))
        )
        .transition(.appBanner)
    }
}

/// The first thing in the body of every file tool.
///
/// 용량 줄이기 and 누끼 따기 each grew their own copy of this, and the two had
/// drifted to different heights, different symbols and different wording for
/// the same state. One component means a new tool cannot drift at all.
struct ToolDropWell: View {
    let symbol: String
    let hint: String
    let busyHint: String
    let isBusy: Bool
    let onURLs: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: Spacing.s) {
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(Color.snuBlueLabel) : AnyShapeStyle(.tertiary))
            }
            Text(isBusy ? busyHint : hint)
                .font(.callout)
                .foregroundStyle(isBusy ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .multilineTextAlignment(.center)
        .padding(Spacing.l)
        .dropWell(isTargeted: isTargeted, enabled: !isBusy)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            Task { @MainActor in
                let urls = await collectDroppedURLs(providers)
                guard !urls.isEmpty else { return }
                onURLs(urls)
            }
            return true
        }
        .accessibilityLabel(hint)
    }
}

struct QuickFolderBar: View {
    let disabled: Bool
    var recent: URL?
    let choose: (URL?) -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text("빠른 폴더").font(.caption).foregroundStyle(.secondary)
            ForEach(QuickFolder.available) { folder in
                Button(folder.title) { choose(folder.url) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(disabled)
                    .help("\(folder.title) 폴더에서 바로 고릅니다")
            }
            if let recent {
                Button("최근 저장 폴더") { choose(recent) }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(disabled)
                    .help(recent.path)
            }
            Spacer()
        }
    }
}

/// The glass panel every tool puts its pickers in, so the settings block sits at
/// the same inset and reads at the same weight on all of them.
struct ToolSettingsPanel<Content: View>: View {
    var explanation: String = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            content()
            if !explanation.isEmpty {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.l)
        .glassPanel()
    }
}

/// Progress, how many are done, how long is left, and the tool's own headline
/// number on the right.
struct ToolStatusPanel: View {
    @ObservedObject var model: BatchToolModel
    var trailing: String = ""

    var body: some View {
        if model.isRunning || !model.jobs.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                if model.isRunning {
                    ProgressView(value: model.progressValue).tint(.snuBlue)
                }
                HStack(spacing: Spacing.m) {
                    Text(model.countText)
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                    if !model.etaText.isEmpty {
                        Label(model.etaText, systemImage: "clock.arrow.circlepath")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    if !trailing.isEmpty {
                        Text(trailing)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Color.snuBlueLabel)
                            .monospacedDigit()
                    }
                }
            }
            .padding(Spacing.m)
            .glassPanel(Radius.card)
            .transition(.appCard)
        }
        Text(model.status).font(.caption).foregroundStyle(.secondary)
        if let error = model.error {
            DismissibleError(message: error) { model.error = nil }
        }
    }
}

// MARK: - 결과 카드

/// One thumbnail routine for every kind of result a tool can produce, so a card
/// never has to know what it is showing.
enum ToolThumbnail {
    static func image(for url: URL, maxPixel: Int) async -> CGImage? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            // A folder of rendered pages shows its first page, which is the only
            // part of it worth looking at from a card this size.
            let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
                .filter { CompressionKind.imageExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard let first = children?.first else { return nil }
            return await image(for: first, maxPixel: maxPixel)
        }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return CompressionThumbnail.pdfFirstPage(url, maxPixel: maxPixel) }
        if CompressionKind.imageExtensions.contains(ext) {
            return CutoutComposer.preview(of: url, maxPixel: maxPixel, background: CGColor(gray: 1, alpha: 1))
        }
        if MediaImporter.videoExtensions.contains(ext) {
            return await CompressionThumbnail.videoFrame(url, maxPixel: maxPixel)
        }
        return nil
    }

    static func symbol(for url: URL) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return "folder"
        }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return "doc.richtext" }
        if ext == "txt" { return "doc.plaintext" }
        if CompressionKind.imageExtensions.contains(ext) { return "photo" }
        if MediaImporter.videoExtensions.contains(ext) { return "film" }
        if MediaImporter.audioExtensions.contains(ext) { return "waveform" }
        return "doc"
    }
}

/// The result card shared by 소리 다듬기, 화질 올리기, 스캔 보정 and 형식 변환.
///
/// Deliberately the same shape as 용량 줄이기's card — thumbnail, file name,
/// headline, detail, one menu — because a user moving between these screens
/// should not have to re-learn where the answer is.
struct ToolResultCard: View {
    @ObservedObject var model: BatchToolModel
    let job: ToolJob

    @State private var preview: CGImage?
    @State private var isHovering = false
    @Environment(\.sendToPrinter) private var sendToPrinter

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            thumbnail
            HStack(spacing: Spacing.xs) {
                Image(systemName: ToolThumbnail.symbol(for: job.output ?? job.source))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(job.source.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !job.headline.isEmpty {
                Text(job.headline)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(job.isFinished ? Color.snuBlueLabel : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if !job.detail.isEmpty {
                Text(job.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if job.isFailed || job.note != nil || !job.isFinished {
                Text(job.statusText)
                    .font(.caption2)
                    .foregroundStyle(job.isFailed ? Color.red : .secondary)
                    .lineLimit(2)
            }
            actions
        }
        .padding(Spacing.m)
        .contentCard()
        .task(id: job.output?.path ?? job.source.path) {
            preview = await ToolThumbnail.image(for: job.output ?? job.source, maxPixel: 640)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if job.isFinished {
            HStack(spacing: Spacing.s) {
                Spacer(minLength: Spacing.xs)
                Menu {
                    Button("저장…", systemImage: "square.and.arrow.down") { model.save(job) }
                    Button("복사", systemImage: "doc.on.doc") { model.copy(job) }
                    Button("Finder에서 보기", systemImage: "folder") { model.reveal(job) }
                    // 보정한 유인물이나 합친 PDF를 곧바로 집 프린터로. 프린터가 받을 수
                    // 있는 결과일 때만 나온다.
                    if let output = job.output, PrintPreparation.accepts(output) {
                        Divider()
                        Button("프린트로 보내기", systemImage: "printer") { sendToPrinter([output]) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("결과를 저장하거나 복사합니다")
                .accessibilityLabel("이 파일의 추가 동작")
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(.quaternary.opacity(0.6))
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else if job.isFailed {
                Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.red)
            } else {
                Image(systemName: ToolThumbnail.symbol(for: job.output ?? job.source))
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
            if case .working(let fraction) = job.state {
                VStack {
                    Spacer()
                    ProgressView(value: fraction).tint(.snuBlue).padding(.horizontal, 10).padding(.bottom, 8)
                }
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .onHover { isHovering = $0 }
        .scaleEffect(isHovering && job.isFinished ? 1.012 : 1)
        .animation(.appControl, value: isHovering)
        .accessibilityLabel("\(job.source.lastPathComponent) 미리보기")
    }
}

// MARK: - 화면 뼈대

/// The body of every batch tool: drop well, quick folders, settings, status,
/// then the grid. Only the settings panel differs between the four, which is
/// exactly what this leaves to the caller.
struct BatchToolScreen<Settings: View>: View {
    let section: AppSection
    @ObservedObject var model: BatchToolModel
    let dropSymbol: String
    let dropHint: String
    let busyHint: String
    let emptyMessage: String
    let onURLs: ([URL]) -> Void
    let choose: (URL?) -> Void
    var trailing: String = ""
    @ViewBuilder var settings: () -> Settings

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: Spacing.l)]

    var body: some View {
        WorkspaceScreen(title: section.title, subtitle: section.subtitle) {
            ToolDropWell(
                symbol: dropSymbol, hint: dropHint, busyHint: busyHint,
                isBusy: model.isRunning, onURLs: onURLs
            )
            QuickFolderBar(disabled: model.isRunning, recent: model.lastSaveFolder, choose: choose)
            settings()
            ToolStatusPanel(model: model, trailing: trailing)

            if model.jobs.isEmpty {
                EmptyResults(symbol: section.symbol, message: emptyMessage)
            } else {
                LazyVGrid(columns: columns, spacing: Spacing.l) {
                    ForEach(model.jobs) { job in
                        ToolResultCard(model: model, job: job)
                            .transition(.appCard)
                    }
                }
            }
        }
        .animation(.appContent, value: model.jobs.map(\.id))
        .animation(.appContent, value: model.error)
    }
}

/// The toolbar every batch tool wears.
///
/// The app's rule is that secondary actions sit at the left of the toolbar, a
/// flexible spacer follows, and the primary action is the rightmost thing in the
/// window. Putting that rule in one place is the only way five screens keep it.
struct BatchToolToolbar<Primary: View, Extra: View>: ToolbarContent {
    @ObservedObject var model: BatchToolModel
    let choose: () -> Void
    let rerun: () -> Void
    @ViewBuilder var extra: () -> Extra
    @ViewBuilder var primary: () -> Primary

    var body: some ToolbarContent {
        ToolbarItem {
            Menu("결과", systemImage: "ellipsis") {
                Button("모두 저장…", systemImage: "square.and.arrow.down.on.square") { model.saveAll() }
                    .disabled(!model.hasFinished)
                Button("목록 비우기", systemImage: "trash", role: .destructive) { model.clear() }
                    .disabled(model.jobs.isEmpty || model.isRunning)
            }
            .help("결과를 한꺼번에 저장하거나 목록을 비웁니다")
        }
        ToolbarItem {
            Button("다시 실행", systemImage: "arrow.clockwise") { rerun() }
                .disabled(!model.canRerun)
                .help("목록의 파일을 현재 설정으로 다시 처리합니다")
        }
        ToolbarItem { extra() }
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Button("파일 선택…", systemImage: "folder") { choose() }
                .disabled(model.isRunning)
                .help("처리할 파일이나 폴더를 고릅니다")
        }
        ToolbarItem {
            if model.isRunning {
                Button("중단", systemImage: "stop.fill") { model.stop() }
                    .tint(.red)
                    .toolbarKeepsTitle()
                    .help("남은 파일 처리를 중단합니다")
            } else {
                primary()
            }
        }
    }
}

extension BatchToolToolbar where Extra == EmptyView {
    init(
        model: BatchToolModel,
        choose: @escaping () -> Void,
        rerun: @escaping () -> Void,
        @ViewBuilder primary: @escaping () -> Primary
    ) {
        self.init(model: model, choose: choose, rerun: rerun, extra: { EmptyView() }, primary: primary)
    }
}

/// Opens the standard "pick files or folders" panel, pointed wherever the caller
/// says. One function so the title and the multi-selection behaviour match.
@MainActor
func chooseFiles(title: String, startingAt directory: URL?, then handler: ([URL]) -> Void) {
    let panel = NSOpenPanel()
    panel.title = title
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.directoryURL = directory
    guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
    handler(panel.urls)
}

/// The "사진 앱에서" primary action, shared by every tool that takes pictures.
///
/// `PhotosPicker` runs out of process, so this reaches the library without
/// asking for photo permission and without adding anything to Info.plist. Items
/// arrive as files rather than as `Data` so a two-gigabyte recording never has
/// to sit in memory.
struct PhotosImportButton: View {
    let filter: PHPickerFilter
    @ObservedObject var model: BatchToolModel
    let onURLs: ([URL]) -> Void

    @State private var selection: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $selection, matching: filter) {
            Label("사진 앱에서", systemImage: "photo.stack")
        }
        .buttonStyle(.glassProminent)
        .tint(.snuBlue)
        .toolbarKeepsTitle()
        .help("사진 보관함에서 직접 고릅니다 · 사진 권한 없이 동작합니다")
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            selection = []
            Task { @MainActor in
                model.report("사진 앱에서 \(items.count)개를 가져오는 중")
                var urls: [URL] = []
                for item in items {
                    if let picked = try? await item.loadTransferable(type: PickedFile.self) {
                        urls.append(picked.url)
                    }
                }
                guard !urls.isEmpty else {
                    model.error = "사진 앱에서 파일을 가져오지 못했습니다."
                    return
                }
                onURLs(urls)
            }
        }
    }
}
