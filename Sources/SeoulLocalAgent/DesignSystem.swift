import SwiftUI
import AppKit
import CoreImage

// MARK: - 색

/// The brand blue, split into the two jobs it was previously doing at once.
///
/// The single value it used to be — a very dark navy — reads at roughly 1.6:1
/// against the dark-mode window background, which is a third of the 4.5:1 floor.
/// Every screen title used it as a foreground colour, so in dark mode the titles
/// were nearly invisible. Splitting it also fixes the other half of the problem:
/// a colour light enough to read *as text* on a dark background is too light to
/// put white button labels on, so the fill and the label need different values.
extension NSColor {
    /// Behind white text: prominent buttons, progress bars, selection.
    static var snuBlueFill: NSColor {
        AppAccent.saved.fillColor
    }

    /// Coloured text and icons sitting directly on the window background.
    static var snuBlueLabel: NSColor {
        AppAccent.saved.labelColor
    }
}

extension AppAccent {
    var color: Color { Color(nsColor: fillColor) }
    var label: Color { Color(nsColor: labelColor) }

    fileprivate var fillColor: NSColor {
        switch self {
        case .blue: NSColor(name: "appAccentBlueFill") { $0.isDark ? .init(srgbRed: 0.20, green: 0.45, blue: 0.85, alpha: 1) : .init(srgbRed: 0.05, green: 0.24, blue: 0.54, alpha: 1) }
        case .teal: NSColor(name: "appAccentTealFill") { $0.isDark ? .init(srgbRed: 0.10, green: 0.58, blue: 0.62, alpha: 1) : .init(srgbRed: 0.00, green: 0.40, blue: 0.43, alpha: 1) }
        case .green: NSColor(name: "appAccentGreenFill") { $0.isDark ? .init(srgbRed: 0.24, green: 0.62, blue: 0.34, alpha: 1) : .init(srgbRed: 0.08, green: 0.43, blue: 0.18, alpha: 1) }
        case .purple: NSColor(name: "appAccentPurpleFill") { $0.isDark ? .init(srgbRed: 0.57, green: 0.39, blue: 0.84, alpha: 1) : .init(srgbRed: 0.36, green: 0.18, blue: 0.62, alpha: 1) }
        case .orange: NSColor(name: "appAccentOrangeFill") { $0.isDark ? .init(srgbRed: 0.88, green: 0.43, blue: 0.12, alpha: 1) : .init(srgbRed: 0.68, green: 0.27, blue: 0.02, alpha: 1) }
        case .pink: NSColor(name: "appAccentPinkFill") { $0.isDark ? .init(srgbRed: 0.88, green: 0.34, blue: 0.58, alpha: 1) : .init(srgbRed: 0.67, green: 0.16, blue: 0.39, alpha: 1) }
        }
    }

    fileprivate var labelColor: NSColor {
        switch self {
        case .blue: NSColor(name: "appAccentBlueLabel") { $0.isDark ? .init(srgbRed: 0.45, green: 0.68, blue: 1.00, alpha: 1) : .init(srgbRed: 0.05, green: 0.24, blue: 0.54, alpha: 1) }
        case .teal: NSColor(name: "appAccentTealLabel") { $0.isDark ? .init(srgbRed: 0.35, green: 0.82, blue: 0.83, alpha: 1) : .init(srgbRed: 0.00, green: 0.35, blue: 0.38, alpha: 1) }
        case .green: NSColor(name: "appAccentGreenLabel") { $0.isDark ? .init(srgbRed: 0.45, green: 0.82, blue: 0.52, alpha: 1) : .init(srgbRed: 0.06, green: 0.38, blue: 0.15, alpha: 1) }
        case .purple: NSColor(name: "appAccentPurpleLabel") { $0.isDark ? .init(srgbRed: 0.75, green: 0.62, blue: 1.00, alpha: 1) : .init(srgbRed: 0.34, green: 0.16, blue: 0.58, alpha: 1) }
        case .orange: NSColor(name: "appAccentOrangeLabel") { $0.isDark ? .init(srgbRed: 1.00, green: 0.64, blue: 0.32, alpha: 1) : .init(srgbRed: 0.61, green: 0.22, blue: 0.00, alpha: 1) }
        case .pink: NSColor(name: "appAccentPinkLabel") { $0.isDark ? .init(srgbRed: 1.00, green: 0.60, blue: 0.76, alpha: 1) : .init(srgbRed: 0.61, green: 0.12, blue: 0.34, alpha: 1) }
        }
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension Color {
    /// Fill colour — use with `.tint`, never as `foregroundStyle` on a plain
    /// background, where it is too dark to read in dark mode.
    static var snuBlue: Color { Color(nsColor: .snuBlueFill) }
    /// Foreground colour for coloured text and icons.
    static var snuBlueLabel: Color { Color(nsColor: .snuBlueLabel) }
}

// MARK: - 간격과 모서리

/// Four steps instead of the eight ad-hoc numbers the screens had grown, so
/// panels line up with each other without anyone having to remember which
/// screen used 14 and which used 18.
enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

/// Three steps instead of six. `ConcentricRectangle` handles the nested cases,
/// where a fixed inner radius never looks right against the containing shape.
enum Radius {
    static let small: CGFloat = 8
    static let card: CGFloat = 12
    static let panel: CGFloat = 16
}

// MARK: - 표면

extension View {
    /// The floating control layer: queues, progress, playback, status. This is
    /// what Liquid Glass is for — a surface that sits *above* the content and
    /// borrows what is behind it.
    func glassPanel(_ radius: CGFloat = Radius.panel) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: radius))
    }

    /// The content layer: result cards holding a photo or a video frame. These
    /// deliberately stay opaque — glass behind a picture makes the picture
    /// harder to judge, which is the one thing these cards exist for.
    func contentCard(_ radius: CGFloat = Radius.card, selected: Bool = false) -> some View {
        background(
            selected ? AnyShapeStyle(Color.snuBlue.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(0.5)),
            in: RoundedRectangle(cornerRadius: radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(selected ? Color.snuBlue.opacity(0.55) : Color.primary.opacity(0.06))
        )
    }

    /// A drop well, which is a target rather than a surface: dashed while idle so
    /// it reads as "put something here", filled while a drag is over it.
    func dropWell(isTargeted: Bool, enabled: Bool = true) -> some View {
        background(
            isTargeted ? Color.snuBlue.opacity(0.14) : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.snuBlue : Color.secondary.opacity(enabled ? 0.35 : 0.18),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: isTargeted ? [] : [6, 4])
                )
        )
        .animation(.smooth(duration: 0.18), value: isTargeted)
    }

    /// A toolbar button that keeps its word.
    ///
    /// macOS draws `Button("이름", systemImage:)` in a window toolbar as the icon
    /// alone; the name survives only as a tooltip that has to be hunted for with
    /// the pointer. For the utilities — 새로고침, 열기, 내보내기 — that is the right
    /// trade: the toolbar stays quiet and pressing one is never a decision.
    ///
    /// It is the wrong trade for the two kinds of button this app leans on. The
    /// screen's main action is the reason the screen exists, and the button that
    /// stops something is the one that has to be found *fast* — 원격 텔레옵's 정지
    /// was a red hand and nothing else, which is not what you want to be reading
    /// icons for while the arm is moving.
    func toolbarKeepsTitle() -> some View {
        labelStyle(.titleAndIcon)
    }
}

// MARK: - 움직임

/// One vocabulary for the whole app, so a card appearing in 누끼 moves the same
/// way as a row appearing in the queue.
extension Animation {
    /// Content arriving or leaving: cards, rows, banners.
    static let appContent = Animation.smooth(duration: 0.28)
    /// Controls reacting to a click: a button swapping, a section expanding.
    static let appControl = Animation.snappy(duration: 0.2)
}

extension AnyTransition {
    /// What a card or a row does when it joins or leaves a list.
    ///
    /// Computed rather than stored: `AnyTransition` is not `Sendable`, so a
    /// `static let` would be a shared-mutable-state error under Swift 6.
    static var appCard: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
        )
    }

    /// What a banner does, sliding out of the edge it is attached to.
    static var appBanner: AnyTransition { .opacity.combined(with: .move(edge: .top)) }
}

// MARK: - 상징

/// The university crest, set very faintly into the bottom-right corner of every
/// workspace screen.
///
/// The asset is an alpha-only silhouette derived from the crest: white pixels
/// with the coverage baked into the alpha channel, so it can be tinted as a
/// template image and the lettering inside the shield reads as cut-out rather
/// than as a white blob. It is decorative and never interactive.
struct CrestWatermark: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var appearance = AppearanceModel.shared

    /// Loaded once. The file is 1280 points square, so decoding it per redraw
    /// would be a real cost on a screen that repaints while a job runs.
    private static let bundledImages: [WatermarkPreferences.Mode: NSImage] = {
        var result: [WatermarkPreferences.Mode: NSImage] = [:]
        for mode in WatermarkPreferences.Mode.allCases {
            guard let name = mode.bundledResource,
                  let url = Bundle.module.url(forResource: name, withExtension: "png"),
                  let image = NSImage(contentsOf: url) else { continue }
            // The public MIT Brand Guide preview is an RGBA thumbnail with an
            // opaque pale canvas rather than a transparent download (the latter
            // requires an MIT login). Turn only its dark official mark into the
            // template mask so a watermark never paints a faint rectangle.
            result[mode] = mode == .mit ? darkInkTemplate(image) ?? image : image
        }
        return result
    }()

    private static func darkInkTemplate(_ image: NSImage) -> NSImage? {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let source = bitmap.cgImage else { return nil }
        // The preview includes the Brand Guide's generous demonstration canvas.
        // Crop that canvas, not the mark, so the configured width means roughly
        // the same visual size as the SNU and KAIST choices.
        let width = CGFloat(source.width), height = CGFloat(source.height)
        let crop = CGRect(x: width * 0.28, y: height * 0.28, width: width * 0.48, height: height * 0.44)
        guard let cropped = source.cropping(to: crop) else { return nil }
        let input = CIImage(cgImage: cropped)
        let mask = input
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
            .applyingFilter("CIMaskToAlpha")
        guard let output = CIContext(options: [.cacheIntermediates: false]).createCGImage(mask, from: mask.extent) else { return nil }
        return NSImage(cgImage: output, size: image.size)
    }

    var body: some View {
        let preferences = appearance.preferences
        let image = preferences.mode == .custom
            ? appearance.customImage ?? Self.bundledImages[.crest]
            : Self.bundledImages[preferences.mode]
        if preferences.mode != .none, let image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(preferences.mode.isInstitutional || preferences.monochrome ? .template : .original)
                .scaledToFit()
                .frame(maxWidth: min(800, max(180, preferences.width)), maxHeight: min(800, max(180, preferences.width)))
                .foregroundStyle(appearance.accent.label)
                // Centred and large, so it reads as a watermark pressed into the
                // page. Text sits on top of it, so the value has to stay low
                // enough that a caption over the crest is still comfortable —
                // a little stronger in dark mode, where the same number all but
                // disappears.
                .opacity(min(0.3, max(0.01, preferences.opacity)) * (colorScheme == .dark ? 1.25 : 0.8))
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: preferences.position.alignment)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 화면 뼈대

/// Every workspace screen, laid out the same way.
///
/// The title used to be re-stated inside the content in three different styles —
/// `largeTitle` on two screens, a `title2` blue `Label` on four, and nothing at
/// all on 설정 — while the window title bar always said the app's name. This puts
/// the name where macOS puts it and gives the body one shape.
struct WorkspaceScreen<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.xl)
        }
        .background { CrestWatermark() }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle(title)
    }
}

/// The "nothing here yet" state every result grid was missing. An empty tab used
/// to simply end, leaving the reader to guess whether it was broken or idle.
struct EmptyResults: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            // 여기 오는 문장에는 화면 이름을 백틱으로 감싼 것과, 서버가 준 실패 사유가
            // 섞인다(`수집 데이터`가 연결 실패를 이 자리에 적는다). `Text(String)`은
            // 마크다운을 해석하지 않으므로 백틱이 글자로 찍혔다.
            Text(InlineMarkup.attributed(message))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}
