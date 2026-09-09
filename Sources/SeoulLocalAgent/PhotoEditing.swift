import CoreGraphics
import Foundation

/// The small edits both photo tabs offer: keep a part of the picture, and mirror it.
///
/// The crop is stored as a fraction of the *original* image rather than in pixels,
/// so the same value survives the 누끼 tab's transparent PNG, the compression tab's
/// downscaled decode, and the thumbnail preview without being rescaled by hand at
/// each step. Flips are applied after the crop, which is what lets a selection made
/// on a mirrored preview be converted back with one reflection.
struct PhotoEdit: Codable, Hashable, Sendable {
    /// Fraction of the original image to keep, origin at the top-left.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var flippedHorizontally = false
    var flippedVertically = false

    static let identity = PhotoEdit()

    var isIdentity: Bool { self == .identity }

    var isCropped: Bool { crop != CGRect(x: 0, y: 0, width: 1, height: 1) }

    /// A short line for the card, so a card that carries an edit says so without
    /// the user having to open it again.
    var summary: String? {
        var parts: [String] = []
        if isCropped { parts.append("잘라냄 \(Int((crop.width * 100).rounded()))×\(Int((crop.height * 100).rounded()))%") }
        if flippedHorizontally { parts.append("좌우 뒤집음") }
        if flippedVertically { parts.append("상하 뒤집음") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Narrows the kept area by a selection the user dragged on the *displayed*
    /// image. The selection arrives in the preview's own coordinates, which are
    /// already cropped and possibly mirrored, so it is reflected back before being
    /// folded into the stored rectangle.
    mutating func crop(toSelection selection: CGRect) {
        let clamped = Self.clamp(selection)
        guard clamped.width > 0.01, clamped.height > 0.01 else { return }
        var unflipped = clamped
        if flippedHorizontally { unflipped.origin.x = 1 - clamped.maxX }
        if flippedVertically { unflipped.origin.y = 1 - clamped.maxY }
        crop = CGRect(
            x: crop.minX + unflipped.minX * crop.width,
            y: crop.minY + unflipped.minY * crop.height,
            width: unflipped.width * crop.width,
            height: unflipped.height * crop.height
        )
    }

    mutating func flipHorizontally() { flippedHorizontally.toggle() }
    mutating func flipVertically() { flippedVertically.toggle() }

    mutating func reset() { self = .identity }

    /// Returns the image the user is asking for. The original is handed straight
    /// back when nothing was changed, so an untouched photo is never re-encoded
    /// through a redraw it does not need.
    func apply(to image: CGImage) -> CGImage {
        guard !isIdentity else { return image }
        var result = image
        if isCropped {
            let rect = CGRect(
                x: (crop.minX * CGFloat(image.width)).rounded(.down),
                y: (crop.minY * CGFloat(image.height)).rounded(.down),
                width: max(1, (crop.width * CGFloat(image.width)).rounded()),
                height: max(1, (crop.height * CGFloat(image.height)).rounded())
            ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let cropped = image.cropping(to: rect) { result = cropped }
        }
        guard flippedHorizontally || flippedVertically else { return result }
        return Self.mirrored(result, horizontally: flippedHorizontally, vertically: flippedVertically) ?? result
    }

    private static func mirrored(_ image: CGImage, horizontally: Bool, vertically: Bool) -> CGImage? {
        // Premultiplied RGBA, not the image's own format: a cutout carries an alpha
        // channel that a mirrored copy has to keep.
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(
            x: horizontally ? CGFloat(image.width) : 0,
            y: vertically ? CGFloat(image.height) : 0
        )
        context.scaleBy(x: horizontally ? -1 : 1, y: vertically ? -1 : 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// A drag can start outside the picture or run past its edge; the stored
    /// fraction must stay inside it either way.
    static func clamp(_ rect: CGRect) -> CGRect {
        let minX = min(max(0, rect.minX), 1)
        let minY = min(max(0, rect.minY), 1)
        let maxX = min(max(0, rect.maxX), 1)
        let maxY = min(max(0, rect.maxY), 1)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// The pixel size the edited image will have, for the size line on a card.
    func resultSize(of size: CGSize) -> CGSize {
        CGSize(
            width: max(1, (size.width * crop.width).rounded()),
            height: max(1, (size.height * crop.height).rounded())
        )
    }
}

/// The fixed shapes the crop can be locked to.
///
/// The stored selection is a fraction of the picture, so a 1:1 crop is *not* a
/// square in those numbers — it is square in pixels. Everything here converts the
/// pixel ratio the user asked for into the fraction ratio the selection uses.
enum CropAspect: String, CaseIterable, Identifiable, Sendable {
    case free, original, square, fourThree, threeFour, threeTwo, sixteenNine, nineSixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "자유"
        case .original: "원본 비율"
        case .square: "1:1"
        case .fourThree: "4:3"
        case .threeFour: "3:4"
        case .threeTwo: "3:2"
        case .sixteenNine: "16:9"
        case .nineSixteen: "9:16"
        }
    }

    /// Width over height, in pixels.
    func pixelRatio(of image: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original: image.height > 0 ? image.width / image.height : nil
        case .square: 1
        case .fourThree: 4.0 / 3
        case .threeFour: 3.0 / 4
        case .threeTwo: 3.0 / 2
        case .sixteenNine: 16.0 / 9
        case .nineSixteen: 9.0 / 16
        }
    }

    /// The same shape expressed in the selection's own units, where the picture is
    /// one unit wide and one unit tall however long its sides really are.
    func selectionRatio(of image: CGSize) -> Double? {
        guard let pixels = pixelRatio(of: image), image.width > 0 else { return nil }
        return pixels * image.height / image.width
    }
}

extension PhotoEdit {
    /// Reshapes a selection to a locked ratio while holding one side, corner, or
    /// centre still, then shrinks it if that pushed it off the picture.
    ///
    /// `anchorX` and `anchorY` are 0 for "the left/top edge stays", 1 for "the
    /// right/bottom edge stays", and 0.5 for "the centre stays" — which is what an
    /// edge handle needs on the axis it is not dragging.
    static func fitted(
        _ rect: CGRect, toRatio ratio: Double, drivenByWidth: Bool,
        anchorX: Double, anchorY: Double
    ) -> CGRect {
        guard ratio > 0 else { return rect }
        var width = drivenByWidth ? rect.width : rect.height * ratio
        var height = width / ratio

        // How large the shape may grow before it leaves the picture, given which
        // side is pinned.
        func room(fixed: Double, anchor: Double) -> Double {
            switch anchor {
            case 0: 1 - fixed
            case 1: fixed
            default: 2 * min(fixed, 1 - fixed)
            }
        }
        let roomX = room(fixed: anchorX == 1 ? rect.maxX : (anchorX == 0 ? rect.minX : rect.midX), anchor: anchorX)
        let roomY = room(fixed: anchorY == 1 ? rect.maxY : (anchorY == 0 ? rect.minY : rect.midY), anchor: anchorY)
        width = min(width, max(0, roomX), max(0, roomY) * ratio)
        height = width / ratio

        let x: Double
        switch anchorX {
        case 0: x = rect.minX
        case 1: x = rect.maxX - width
        default: x = rect.midX - width / 2
        }
        let y: Double
        switch anchorY {
        case 0: y = rect.minY
        case 1: y = rect.maxY - height
        default: y = rect.midY - height / 2
        }
        return clamp(CGRect(x: x, y: y, width: width, height: height))
    }
}
