import Foundation
import AppKit
import CoreGraphics
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

/// Covers everything the 누끼 tab can check without Python or model weights:
/// the compositing that turns a cutout into the delivered PNG, the model
/// mapping, and the wire format shared with `scripts/matting_runner.py`.
@Suite("Background removal")
struct BackgroundRemovalTests {
    @Test("A transparent background is left alone")
    func transparentBackgroundKeepsAlpha() throws {
        let image = try #require(Self.halfTransparentImage())
        let composed = try #require(CutoutComposer.compose(image, background: nil))
        #expect(Self.alpha(of: composed, x: 0, y: 0) == 0)
        #expect(Self.alpha(of: composed, x: 3, y: 0) == 255)
    }

    @Test("A background colour fills only the transparent pixels")
    func backgroundColourFillsTransparentPixels() throws {
        let image = try #require(Self.halfTransparentImage())
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let composed = try #require(CutoutComposer.compose(image, background: white))
        #expect(Self.alpha(of: composed, x: 0, y: 0) == 255)
        // The formerly transparent half is now white...
        #expect(Self.pixel(of: composed, x: 0, y: 0) == [255, 255, 255])
        // ...and the opaque half still carries the original red subject.
        #expect(Self.pixel(of: composed, x: 3, y: 0) == [255, 0, 0])
    }

    @Test("Composing produces a real PNG")
    func encodesPNG() throws {
        let image = try #require(Self.halfTransparentImage())
        let data = try #require(CutoutComposer.pngData(from: image, background: nil))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test("Only the BiRefNet choices reach the Python runner")
    func modelChoiceMapping() {
        #expect(MattingModelChoice.highResolution.runnerValue == "hr-matting")
        #expect(MattingModelChoice.balanced.runnerValue == "matting")
        #expect(MattingModelChoice.appleVision.runnerValue == nil)
        #expect(MattingModelChoice.appleVision.usesPythonRunner == false)
    }

    @Test("Requests are newline-terminated JSON the runner can parse")
    func requestEncoding() throws {
        let data = try MattingDaemon.encode(
            identifier: 7,
            source: URL(fileURLWithPath: "/tmp/a.jpg"),
            destination: URL(fileURLWithPath: "/tmp/a.png"),
            model: "hr-matting"
        )
        #expect(data.last == 0x0A)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? Int == 7)
        #expect(object["input"] as? String == "/tmp/a.jpg")
        #expect(object["output"] as? String == "/tmp/a.png")
        #expect(object["model"] as? String == "hr-matting")
    }

    @Test("Non-image drops are rejected before any process is launched")
    func rejectsUnsupportedFiles() async {
        #expect(BackgroundRemovalService.isSupported(URL(fileURLWithPath: "/tmp/photo.HEIC")))
        #expect(BackgroundRemovalService.isSupported(URL(fileURLWithPath: "/tmp/photo.png")))
        #expect(!BackgroundRemovalService.isSupported(URL(fileURLWithPath: "/tmp/handout.pdf")))
        #expect(!BackgroundRemovalService.isSupported(URL(fileURLWithPath: "/tmp/lecture.m4a")))

        await #expect(throws: AgentError.self) {
            _ = try await BackgroundRemovalService().removeBackground(
                from: URL(fileURLWithPath: "/tmp/handout.pdf"), model: .appleVision
            ) { _ in }
        }
    }

    @Test("Saved cutouts keep the source name")
    func outputNaming() {
        let directory = URL(fileURLWithPath: "/tmp/work")
        let output = BackgroundRemovalService.outputURL(for: URL(fileURLWithPath: "/tmp/강의사진.jpg"), in: directory)
        #expect(output.lastPathComponent.hasPrefix("강의사진-누끼-"))
        #expect(output.pathExtension == "png")
    }

    @Test("Queue items report progress in Korean")
    func queueItemStatus() {
        var item = CutoutItem(source: URL(fileURLWithPath: "/tmp/a.jpg"))
        #expect(item.statusText == "대기 중")
        #expect(!item.isFinished)
        item.state = .done(milliseconds: 2_240)
        #expect(item.isFinished)
        #expect(item.statusText == "완료 · 2.2초")
        item.state = .failed("사진을 읽지 못했습니다.")
        #expect(!item.isFinished)
        #expect(item.statusText == "사진을 읽지 못했습니다.")
    }

    // MARK: 도우미

    /// 4×1 pixels: the left half fully transparent, the right half opaque red.
    private static func halfTransparentImage() -> CGImage? {
        var pixels: [UInt8] = []
        for x in 0 ..< 4 {
            let opaque = x >= 2
            // Premultiplied: a transparent pixel must carry zeroed colour too.
            pixels += opaque ? [255, 0, 0, 255] : [0, 0, 0, 0]
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: 4, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func samples(of image: CGImage, x: Int, y: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4
        return Array(buffer[offset ..< offset + 4])
    }

    private static func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
        samples(of: image, x: x, y: y).last ?? 0
    }

    private static func pixel(of image: CGImage, x: Int, y: Int) -> [UInt8] {
        Array(samples(of: image, x: x, y: y).prefix(3))
    }
}
#endif
