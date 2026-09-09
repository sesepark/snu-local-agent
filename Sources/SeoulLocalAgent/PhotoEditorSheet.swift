import SwiftUI
import AppKit

/// The large view a photo card opens into, and the only place either photo tab
/// offers editing.
///
/// It exists mostly so a result can be seen properly — a 170-point card is too
/// small to judge a cutout edge — and the two edits it offers ride along in the
/// same window rather than in a separate mode. The picture is loaded once at
/// screen size; the crop is stored as a fraction, so the export still runs at full
/// resolution.
struct PhotoEditorSheet: View {
    let title: String
    let subtitle: String
    /// The unedited image, already composited for whatever background the tab
    /// shows. Loaded off the main thread by the caller.
    let load: @Sendable () async -> CGImage?
    @Binding var edit: PhotoEdit
    /// Cutouts are transparent, so they need the grey squares behind them.
    var showsCheckerboard = false

    @Environment(\.dismiss) private var dismiss
    @State private var base: CGImage?
    /// Normalised to the displayed picture, so it survives a window resize.
    @State private var selection: CGRect?
    /// What the current drag is doing, decided once from where it started so the
    /// pointer cannot switch between resizing and drawing mid-gesture.
    @State private var dragMode: CropDrag?
    @State private var dragOriginalSelection: CGRect?
    @State private var working = PhotoEdit.identity
    /// One entry per change, so an over-tight crop costs one click to undo rather
    /// than a full reset and every step done again.
    @State private var history: [PhotoEdit] = []
    @State private var aspect: CropAspect = .free
    /// A file that cannot be decoded used to leave the spinner turning forever.
    @State private var failedToLoad = false

    private var displayed: CGImage? { base.map { working.apply(to: $0) } }

    /// The locked shape in the selection's own units, or nil while it is 자유.
    private var lockedRatio: Double? {
        guard let displayed else { return nil }
        return aspect.selectionRatio(of: CGSize(width: displayed.width, height: displayed.height))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            picture
            Divider()
            controls
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 680)
        .task {
            working = edit
            history.removeAll()
            base = await load()
            failedToLoad = base == nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(sizeText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let summary = working.summary {
                Text(summary).font(.caption).foregroundStyle(Color.snuBlueLabel)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    private var sizeText: String {
        guard let base else { return subtitle }
        let current = working.resultSize(of: CGSize(width: base.width, height: base.height))
        // While a selection is up, show what cropping to it would leave: judging a
        // crop by eye is much harder than reading the number it produces.
        if let selection, selection.width > 0.01, selection.height > 0.01 {
            let width = Int((current.width * selection.width).rounded())
            let height = Int((current.height * selection.height).rounded())
            return "선택 영역 \(width)×\(height) · 지금 \(Int(current.width))×\(Int(current.height))"
        }
        let pixels = "\(Int(current.width))×\(Int(current.height))"
        return subtitle.isEmpty ? pixels : "\(subtitle) · \(pixels)"
    }

    private var picture: some View {
        GeometryReader { geometry in
            ZStack {
                if showsCheckerboard {
                    CheckerboardBackground()
                } else {
                    Color.primary.opacity(0.04)
                }
                if let image = displayed {
                    let frame = Self.drawnRect(container: geometry.size, image: CGSize(width: image.width, height: image.height))
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                    selectionOverlay(in: frame)
                    // A transparent layer on top carries the drag. Points outside the
                    // picture are clamped into it, so a drag that starts in the
                    // letterboxing still selects a sensible rectangle.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture(in: frame))
                } else if failedToLoad {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.red)
                        Text("사진을 열지 못했습니다. 파일이 옮겨졌거나 형식을 읽을 수 없습니다.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(24)
                } else {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func selectionOverlay(in frame: CGRect) -> some View {
        if let selection, selection.width > 0.005, selection.height > 0.005 {
            let rect = CGRect(
                x: frame.minX + selection.minX * frame.width,
                y: frame.minY + selection.minY * frame.height,
                width: selection.width * frame.width,
                height: selection.height * frame.height
            )
            ZStack {
                // Dim everything the crop would throw away, which is far easier to
                // judge than a bare outline.
                Path { path in
                    path.addRect(frame)
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .background(Rectangle().strokeBorder(Color.snuBlue, lineWidth: 3).blur(radius: 1))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                // Thirds, the usual framing guide, drawn faintly so it helps without
                // competing with the picture.
                Path { path in
                    for step in 1...2 {
                        let x = rect.minX + rect.width * Double(step) / 3
                        let y = rect.minY + rect.height * Double(step) / 3
                        path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                        path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                ForEach(Array(CropHandle.all.enumerated()), id: \.offset) { _, handle in
                    let anchor = handle.anchor
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.white)
                        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Color.snuBlue, lineWidth: 1.5))
                        .frame(width: 10, height: 10)
                        .position(x: rect.minX + rect.width * anchor.x, y: rect.minY + rect.height * anchor.y)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func dragGesture(in frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let mode: CropDrag
                if let existing = dragMode {
                    mode = existing
                } else {
                    mode = Self.mode(startingAt: value.startLocation, selection: selection, in: frame)
                    dragMode = mode
                    dragOriginalSelection = selection
                }
                let delta = CGSize(
                    width: value.translation.width / max(frame.width, 1),
                    height: value.translation.height / max(frame.height, 1)
                )
                switch mode {
                case .create:
                    let drawn = PhotoEdit.clamp(Self.normalized(from: value.startLocation, to: value.location, in: frame))
                    if let ratio = lockedRatio {
                        // The corner the drag started from is the one that stays put.
                        let startedLeft = value.location.x >= value.startLocation.x
                        let startedTop = value.location.y >= value.startLocation.y
                        selection = PhotoEdit.fitted(
                            drawn, toRatio: ratio, drivenByWidth: true,
                            anchorX: startedLeft ? 0 : 1, anchorY: startedTop ? 0 : 1
                        )
                    } else {
                        selection = drawn
                    }
                case .move:
                    guard let original = dragOriginalSelection else { return }
                    selection = Self.moved(original, by: delta)
                case .resize(let handle):
                    guard let original = dragOriginalSelection else { return }
                    let resized = Self.resized(original, by: delta, handle: handle)
                    if let ratio = lockedRatio {
                        selection = PhotoEdit.fitted(
                            resized, toRatio: ratio,
                            // An edge handle drives the axis it is on; a corner uses width.
                            drivenByWidth: handle.contains(.left) || handle.contains(.right),
                            anchorX: handle.contains(.left) ? 1 : (handle.contains(.right) ? 0 : 0.5),
                            anchorY: handle.contains(.top) ? 1 : (handle.contains(.bottom) ? 0 : 0.5)
                        )
                    } else {
                        selection = resized
                    }
                }
            }
            .onEnded { _ in
                dragMode = nil
                dragOriginalSelection = nil
            }
    }

    /// Which corner or edge a point is on, if any. A drag that starts on one adjusts
    /// the selection; inside it moves the whole thing; anywhere else starts a new one.
    static func mode(startingAt point: CGPoint, selection: CGRect?, in frame: CGRect) -> CropDrag {
        guard let selection, selection.width > 0.005, selection.height > 0.005 else { return .create }
        let rect = CGRect(
            x: frame.minX + selection.minX * frame.width,
            y: frame.minY + selection.minY * frame.height,
            width: selection.width * frame.width,
            height: selection.height * frame.height
        )
        // Generous enough to grab with a trackpad, small enough that a thin
        // selection is still movable from the middle.
        let tolerance = min(12.0, max(rect.width, rect.height) / 3)
        var handle: CropHandle = []
        if abs(point.x - rect.minX) <= tolerance { handle.insert(.left) }
        if abs(point.x - rect.maxX) <= tolerance { handle.insert(.right) }
        if abs(point.y - rect.minY) <= tolerance { handle.insert(.top) }
        if abs(point.y - rect.maxY) <= tolerance { handle.insert(.bottom) }
        let nearVertically = point.y >= rect.minY - tolerance && point.y <= rect.maxY + tolerance
        let nearHorizontally = point.x >= rect.minX - tolerance && point.x <= rect.maxX + tolerance
        if !handle.isEmpty, nearVertically, nearHorizontally { return .resize(handle) }
        return rect.contains(point) ? .move : .create
    }

    /// Keeps the size and slides the rectangle, stopping at the picture's edges
    /// rather than letting it shrink against them.
    static func moved(_ selection: CGRect, by delta: CGSize) -> CGRect {
        let x = min(max(0, selection.minX + delta.width), 1 - selection.width)
        let y = min(max(0, selection.minY + delta.height), 1 - selection.height)
        return CGRect(x: x, y: y, width: selection.width, height: selection.height)
    }

    static let minimumSelection = 0.02

    static func resized(_ selection: CGRect, by delta: CGSize, handle: CropHandle) -> CGRect {
        var minX = selection.minX
        var maxX = selection.maxX
        var minY = selection.minY
        var maxY = selection.maxY
        if handle.contains(.left) { minX += delta.width }
        if handle.contains(.right) { maxX += delta.width }
        if handle.contains(.top) { minY += delta.height }
        if handle.contains(.bottom) { maxY += delta.height }
        // Dragging an edge past the opposite one flips the rectangle rather than
        // collapsing it, which is what every other crop tool does.
        let rect = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                          width: abs(maxX - minX), height: abs(maxY - minY))
        let clamped = PhotoEdit.clamp(rect)
        guard clamped.width >= minimumSelection, clamped.height >= minimumSelection else { return selection }
        return clamped
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("비율", selection: $aspect) {
                ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 110)
            .help("자르기 비율 고정")
            // Changing the lock reshapes what is already selected, anchored at its
            // centre, rather than making the user drag it again.
            .onChange(of: aspect) { _, _ in
                guard let current = selection, let ratio = lockedRatio else { return }
                selection = PhotoEdit.fitted(current, toRatio: ratio, drivenByWidth: true, anchorX: 0.5, anchorY: 0.5)
            }
            Button("자르기", systemImage: "crop") {
                guard let selection else { return }
                history.append(working)
                working.crop(toSelection: selection)
                self.selection = nil
            }
            .disabled(!hasUsableSelection)
            .keyboardShortcut("k", modifiers: .command)
            Button {
                selection = nil
            } label: {
                Image(systemName: "xmark.circle")
            }
            .disabled(!hasUsableSelection)
            .help("선택 해제")
            .accessibilityLabel("선택 해제")

            Divider().frame(height: 16)
            // The selection is drawn on the picture as shown. After a flip the same
            // rectangle covers different content, so it is cleared rather than left
            // pointing somewhere the user did not choose.
            Button {
                history.append(working)
                working.flipHorizontally()
                selection = nil
            } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("좌우 뒤집기")
            .accessibilityLabel("좌우 뒤집기")
            Button {
                history.append(working)
                working.flipVertically()
                selection = nil
            } label: {
                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
            }
            .help("상하 뒤집기")
            .accessibilityLabel("상하 뒤집기")

            Divider().frame(height: 16)
            Button {
                working = history.removeLast()
                selection = nil
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(history.isEmpty)
            .keyboardShortcut("z", modifiers: .command)
            .help("한 단계 취소 (⌘Z)")
            .accessibilityLabel("한 단계 취소")
            Button {
                history.removeAll()
                working.reset()
                selection = nil
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .disabled(working.isIdentity && selection == nil)
            .help("전체 되돌리기")
            .accessibilityLabel("전체 되돌리기")
            Spacer()
            Button("취소") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("적용") {
                edit = working
                dismiss()
            }
            .disabled(failedToLoad)
            .buttonStyle(.glassProminent)
            .tint(.snuBlue)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            if base != nil, !hasUsableSelection, !failedToLoad {
                Text(aspect == .free
                     ? "사진 위를 끌어 남길 부분을 고르세요 · 모서리와 변으로 조정하고 안쪽을 끌어 옮깁니다"
                     : "\(aspect.title) 비율로 고정되어 있습니다 · 끌면 그 모양으로 잡힙니다")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
    }

    private var hasUsableSelection: Bool {
        guard let selection else { return false }
        return selection.width > 0.01 && selection.height > 0.01
    }

    /// `scaledToFit` centres the picture and letterboxes the rest, so a point on
    /// screen only becomes a point in the picture through this rectangle.
    static func drawnRect(container: CGSize, image: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    static func normalized(from start: CGPoint, to end: CGPoint, in frame: CGRect) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        let minX = (min(start.x, end.x) - frame.minX) / frame.width
        let maxX = (max(start.x, end.x) - frame.minX) / frame.width
        let minY = (min(start.y, end.y) - frame.minY) / frame.height
        let maxY = (max(start.y, end.y) - frame.minY) / frame.height
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// The usual light/dark grey squares, so transparent regions read as
/// transparent rather than as white.
struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let square = 10.0
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(0.9)))
            for row in 0 ... Int(size.height / square) {
                for column in 0 ... Int(size.width / square) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: Double(column) * square, y: Double(row) * square, width: square, height: square)
                    context.fill(Path(rect), with: .color(.gray.opacity(0.30)))
                }
            }
        }
    }
}

/// Which sides of the selection a drag is holding. Two flags means a corner.
struct CropHandle: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let left = CropHandle(rawValue: 1 << 0)
    static let right = CropHandle(rawValue: 1 << 1)
    static let top = CropHandle(rawValue: 1 << 2)
    static let bottom = CropHandle(rawValue: 1 << 3)

    /// Where the handle sits inside the rectangle, as a 0...1 pair, for drawing.
    var anchor: CGPoint {
        CGPoint(
            x: contains(.left) ? 0 : (contains(.right) ? 1 : 0.5),
            y: contains(.top) ? 0 : (contains(.bottom) ? 1 : 0.5)
        )
    }

    static let all: [CropHandle] = [
        [.top, .left], [.top], [.top, .right],
        [.left], [.right],
        [.bottom, .left], [.bottom], [.bottom, .right],
    ]
}

enum CropDrag: Equatable {
    case create
    case move
    case resize(CropHandle)
}
