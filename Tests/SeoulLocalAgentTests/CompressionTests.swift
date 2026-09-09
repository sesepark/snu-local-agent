import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

/// Covers the 용량 줄이기 tab end to end wherever that is possible without a
/// network or a model: real photos are encoded into real JPEG/PNG/HEIC/AVIF
/// bytes, real PDFs are built and shrunk, and the parts of the video path that
/// do not need ffmpeg (argument assembly, bitrate arithmetic, progress parsing)
/// are checked directly.
@Suite("File compression")
struct CompressionTests {

    // MARK: 파일 종류와 단계

    @Test("Dropped files are routed by extension")
    func kindRouting() {
        #expect(CompressionKind.of(URL(fileURLWithPath: "/tmp/a.HEIC")) == .image)
        #expect(CompressionKind.of(URL(fileURLWithPath: "/tmp/a.png")) == .image)
        #expect(CompressionKind.of(URL(fileURLWithPath: "/tmp/유인물.pdf")) == .pdf)
        #expect(CompressionKind.of(URL(fileURLWithPath: "/tmp/강의.mp4")) == .video)
        #expect(CompressionKind.of(URL(fileURLWithPath: "/tmp/녹음.m4a")) == nil)
        #expect(CompressionKind.of(URL(fileURLWithPath: "/tmp/보고서.docx")) == nil)
    }

    @Test("Each level shrinks harder than the one before it")
    func levelOrdering() {
        // Resolution is the lever that actually moves file size, so it has to
        // fall monotonically across all three kinds.
        #expect(CompressionLevel.light.imageMaxPixel == nil)
        #expect(CompressionLevel.standard.imageMaxPixel! > CompressionLevel.strong.imageMaxPixel!)
        #expect(CompressionLevel.light.pdfMaxPixel > CompressionLevel.standard.pdfMaxPixel)
        #expect(CompressionLevel.standard.pdfMaxPixel > CompressionLevel.strong.pdfMaxPixel)
        #expect(CompressionLevel.light.videoMaxPixel! > CompressionLevel.standard.videoMaxPixel!)
        #expect(CompressionLevel.standard.videoMaxPixel! > CompressionLevel.strong.videoMaxPixel!)
        #expect(CompressionLevel.light.audioBitrateKbps > CompressionLevel.strong.audioBitrateKbps)
    }

    @Test("Quality is per format, because 0.4 does not mean the same thing twice")
    func qualityIsPerFormat() {
        #expect(ImageOutputFormat.jpeg.quality(for: .strong) > ImageOutputFormat.avif.quality(for: .strong))
        for format in [ImageOutputFormat.jpeg, .heic, .avif, .webp] {
            #expect(format.quality(for: .light) > format.quality(for: .standard))
            #expect(format.quality(for: .standard) > format.quality(for: .strong))
        }
        // PNG has no dial at all; a level can only change its resolution.
        #expect(ImageOutputFormat.png.isLossless)
    }

    @Test("원본 유지 resolves to something that can actually be written")
    func originalFormatResolution() {
        #expect(ImageOutputFormat.resolved(.original, for: URL(fileURLWithPath: "/tmp/a.png")) == .png)
        #expect(ImageOutputFormat.resolved(.original, for: URL(fileURLWithPath: "/tmp/a.HEIC")) == .heic)
        #expect(ImageOutputFormat.resolved(.original, for: URL(fileURLWithPath: "/tmp/a.avif")) == .avif)
        // BMP and TIFF have no lossy mode worth offering, so they become JPEG.
        #expect(ImageOutputFormat.resolved(.original, for: URL(fileURLWithPath: "/tmp/a.bmp")) == .jpeg)
        #expect(ImageOutputFormat.resolved(.jpeg, for: URL(fileURLWithPath: "/tmp/a.png")) == .jpeg)
    }

    // MARK: 사진

    @Test("Every offered format really produces that format")
    func imageFormatsAreReal() async throws {
        let source = try Self.writeImage(width: 600, height: 400)
        defer { try? FileManager.default.removeItem(at: source) }

        let expectations: [(ImageOutputFormat, (Data) -> Bool)] = [
            (.jpeg, { $0.starts(with: [0xFF, 0xD8]) }),
            (.png, { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) }),
            (.heic, { Self.brand(of: $0)?.hasPrefix("heic") == true || Self.brand(of: $0)?.hasPrefix("mif1") == true }),
            (.avif, { Self.brand(of: $0) == "avif" }),
        ]
        for (format, check) in expectations {
            let output = try await Self.compressImage(source, format: format, level: .standard)
            defer { try? FileManager.default.removeItem(at: output.output) }
            let data = try Data(contentsOf: output.output)
            #expect(check(data), "\(format.title) 헤더가 맞지 않습니다")
        }
    }

    @Test("A level caps the long edge and keeps the shape")
    func downscaleRespectsLongEdge() async throws {
        let source = try Self.writeImage(width: 4000, height: 2000)
        defer { try? FileManager.default.removeItem(at: source) }

        let outcome = try await Self.compressImage(source, format: .jpeg, level: .strong)
        defer { try? FileManager.default.removeItem(at: outcome.output) }
        let size = try #require(ImageCompressor.pixelSize(of: outcome.output))
        #expect(max(size.width, size.height) == 1600)
        // 2:1 in, 2:1 out.
        #expect(abs(Double(size.width) / Double(size.height) - 2) < 0.02)
        #expect(outcome.detail == "1600×800")
    }

    @Test("자르기와 뒤집기는 줄이기와 같은 인코딩 패스에서 적용된다")
    func editIsAppliedWhileCompressing() async throws {
        let source = try Self.writeImage(width: 800, height: 400)
        defer { try? FileManager.default.removeItem(at: source) }

        var edit = PhotoEdit.identity
        edit.crop(toSelection: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        edit.flipHorizontally()
        let outcome = try await Self.compressImage(source, format: .jpeg, level: .light, edit: edit)
        defer { try? FileManager.default.removeItem(at: outcome.output) }

        let size = try #require(ImageCompressor.pixelSize(of: outcome.output))
        #expect(size.width == 400 && size.height == 400)
        #expect(outcome.detail == "400×400")
    }

    /// Handing the untouched original back when it is already smaller is right for
    /// an unedited photo and wrong for an edited one: it would drop the crop.
    @Test("편집한 사진은 원본이 더 작아도 원본으로 대체되지 않는다")
    func editedPhotoIsNeverReplacedByTheOriginal() async throws {
        let source = try Self.writeImage(width: 500, height: 500)
        defer { try? FileManager.default.removeItem(at: source) }

        var edit = PhotoEdit.identity
        edit.crop(toSelection: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let outcome = try await Self.compressImage(source, format: .original, level: .light, edit: edit)
        defer { try? FileManager.default.removeItem(at: outcome.output) }

        let size = try #require(ImageCompressor.pixelSize(of: outcome.output))
        #expect(size.width == 250 && size.height == 250)
        #expect(outcome.note != "원본이 이미 더 작습니다")
    }

    @Test("한 폴더에 같은 이름이 있으면 덮어쓰지 않고 번호를 붙인다")
    func batchSaveNeverOverwrites() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = CompressionWorkspace.uniqueURL(in: directory, name: "IMG_1234-누끼.png")
        #expect(first.lastPathComponent == "IMG_1234-누끼.png")
        try Data("첫 번째".utf8).write(to: first)

        // 다른 폴더에서 온 같은 이름의 사진. 예전에는 이 시점에 첫 번째가 사라졌다.
        let second = CompressionWorkspace.uniqueURL(in: directory, name: "IMG_1234-누끼.png")
        #expect(second.lastPathComponent == "IMG_1234-누끼 2.png")
        try Data("두 번째".utf8).write(to: second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "첫 번째")

        let third = CompressionWorkspace.uniqueURL(in: directory, name: "IMG_1234-누끼.png")
        #expect(third.lastPathComponent == "IMG_1234-누끼 3.png")
    }

    @Test("A photo already smaller than the cap is not enlarged")
    func neverUpscales() async throws {
        let source = try Self.writeImage(width: 300, height: 200)
        defer { try? FileManager.default.removeItem(at: source) }
        let outcome = try await Self.compressImage(source, format: .jpeg, level: .strong)
        defer { try? FileManager.default.removeItem(at: outcome.output) }
        let size = try #require(ImageCompressor.pixelSize(of: outcome.output))
        #expect(size.width == 300 && size.height == 200)
    }

    /// The trap in the whole feature: the fast downscaling decode bakes the EXIF
    /// rotation into the pixels, so leaving the tag alone rotates every portrait
    /// photo a second time.
    @Test("A rotated photo comes out upright exactly once")
    func rotationIsAppliedOnlyOnce() async throws {
        // 40×20 with a red block in the stored top-left corner, tagged 6, which
        // means "rotate 90° clockwise to display". Displayed, the red belongs in
        // the top-right of a 20×40 frame.
        let source = try Self.writeImage(width: 40, height: 20, markCorner: true, orientation: 6)
        defer { try? FileManager.default.removeItem(at: source) }

        #expect(ImageCompressor.pixelSize(of: source)?.width == 20, "표시 크기는 회전을 반영해야 합니다")

        let outcome = try await Self.compressImage(source, format: .png, level: .standard)
        defer { try? FileManager.default.removeItem(at: outcome.output) }

        let size = try #require(ImageCompressor.pixelSize(of: outcome.output))
        #expect(size.width == 20 && size.height == 40)

        let properties = try #require(Self.properties(of: outcome.output))
        #expect(properties[kCGImagePropertyOrientation] as? Int == 1, "픽셀에 구운 회전을 태그로 또 걸면 안 됩니다")
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            #expect(tiff[kCGImagePropertyTIFFOrientation] as? Int == 1)
        }

        let image = try #require(CutoutComposer.load(outcome.output))
        #expect(Self.isRed(image, x: image.width - 3, y: 2), "빨간 모서리가 오른쪽 위에 있어야 합니다")
        #expect(!Self.isRed(image, x: 2, y: 2))
    }

    @Test("Shot information and location survive the round trip")
    func metadataSurvives() async throws {
        let source = try Self.writeImage(width: 800, height: 600, exif: true)
        defer { try? FileManager.default.removeItem(at: source) }

        let outcome = try await Self.compressImage(source, format: .jpeg, level: .standard)
        defer { try? FileManager.default.removeItem(at: outcome.output) }

        let properties = try #require(Self.properties(of: outcome.output))
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:08:28 09:41:00")
        let gps = try #require(properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])
        #expect(abs((gps[kCGImagePropertyGPSLatitude] as? Double ?? 0) - 37.4602) < 0.001)
    }

    @Test("Transparency is flattened for JPEG instead of going black")
    func alphaIsFlattenedForJPEG() async throws {
        let source = try Self.writeTransparentPNG()
        defer { try? FileManager.default.removeItem(at: source) }

        let outcome = try await Self.compressImage(source, format: .jpeg, level: .light)
        defer { try? FileManager.default.removeItem(at: outcome.output) }

        let image = try #require(CutoutComposer.load(outcome.output))
        #expect(!ImageCompressor.hasAlpha(image))
        let pixel = Self.pixel(image, x: 2, y: 2)
        #expect(pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240, "투명했던 부분은 흰색이어야 합니다")
    }

    @Test("목표 용량 lands under the target")
    func targetSizeConverges() async throws {
        let source = try Self.writeImage(width: 3000, height: 2000)
        defer { try? FileManager.default.removeItem(at: source) }

        let target = 120_000
        var request = CompressionRequest(mode: .targetSize, level: .light, imageFormat: .jpeg)
        request.targetBytes = target
        let destination = try Self.destination(extension: "jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        let outcome = try await ImageCompressor().compress(source, to: destination, request: request) { _, _ in }
        #expect(outcome.bytes <= target)
        // Not so far under that the search gave up on quality entirely.
        #expect(outcome.bytes > target / 8)
    }

    @Test("A file that cannot be improved is handed back untouched")
    func alreadySmallFilesAreLeftAlone() async throws {
        // A tiny JPEG that is already about as small as this pipeline can make
        // it: re-encoding would only add bytes.
        let source = try Self.writeImage(width: 24, height: 24, quality: 0.2)
        defer { try? FileManager.default.removeItem(at: source) }
        let originalBytes = CompressionWorkspace.fileSize(of: source)

        let request = CompressionRequest(mode: .level, level: .light, imageFormat: .original)
        let destination = try Self.destination(extension: "jpg")
        let outcome = try await ImageCompressor().compress(source, to: destination, request: request) { _, _ in }
        defer { try? FileManager.default.removeItem(at: outcome.output) }

        #expect(outcome.bytes <= originalBytes)
        if outcome.bytes == originalBytes {
            #expect(outcome.note == "원본이 이미 더 작습니다")
        }
    }

    @Test("Reading a photo's size never needs the pixels")
    func inspectIsCheap() async throws {
        let source = try Self.writeImage(width: 1234, height: 567)
        defer { try? FileManager.default.removeItem(at: source) }
        let info = try await ImageCompressor().inspect(source, request: CompressionRequest())
        #expect(info.detail == "1234×567")
        #expect(info.bytes > 0)
        #expect(info.estimatedSeconds > 0)
    }

    // MARK: PDF

    @Test("A PDF shrinks and stays readable")
    func pdfKeepsItsText() async throws {
        let source = try Self.writePDF(pages: 3, includeText: true, imagePixels: 1_800)
        defer { try? FileManager.default.removeItem(at: source) }
        let originalBytes = CompressionWorkspace.fileSize(of: source)

        let destination = try Self.destination(extension: "pdf")
        let request = CompressionRequest(mode: .level, level: .strong)
        let outcome = try await PDFCompressor().compress(source, to: destination, request: request) { _, _ in }
        defer { try? FileManager.default.removeItem(at: outcome.output) }

        #expect(outcome.bytes < originalBytes)
        let document = try #require(PDFDocument(url: outcome.output))
        #expect(document.pageCount == 3)
        let text = (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
        #expect(text.contains("Seoul National University"), "글자는 글자로 남아 있어야 합니다")
    }

    @Test("A PDF's page count seeds the estimate without opening every page")
    func pdfInspect() async throws {
        let source = try Self.writePDF(pages: 5, includeText: true, imagePixels: 400)
        defer { try? FileManager.default.removeItem(at: source) }
        let info = try await PDFCompressor().inspect(source, request: CompressionRequest())
        #expect(info.detail == "5쪽")
        #expect(info.estimatedSeconds > 0)
    }

    @Test("Text density is what decides whether rasterising is allowed")
    func textDensityGuardsRasterising() throws {
        let textual = try Self.writePDF(pages: 2, includeText: true, imagePixels: 300)
        let graphic = try Self.writePDF(pages: 2, includeText: false, imagePixels: 300)
        defer {
            try? FileManager.default.removeItem(at: textual)
            try? FileManager.default.removeItem(at: graphic)
        }
        let withText = try #require(PDFDocument(url: textual))
        let withoutText = try #require(PDFDocument(url: graphic))
        #expect(PDFCompressor.textDensity(of: withText) >= PDFCompressor.textPerPageThreshold)
        #expect(PDFCompressor.textDensity(of: withoutText) < PDFCompressor.textPerPageThreshold)
    }

    @Test("Rasterising keeps every page")
    func rasterisingKeepsPages() throws {
        let source = try Self.writePDF(pages: 4, includeText: false, imagePixels: 800)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = try Self.destination(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: destination) }

        let document = try #require(PDFDocument(url: source))
        #expect(PDFCompressor.rasterize(document, to: destination, dpi: 96, quality: 0.45))
        #expect(PDFDocument(url: destination)?.pageCount == 4)
    }

    @Test("The filter dictionary matches the shape macOS expects")
    func filterProperties() throws {
        let properties = PDFCompressor.filterProperties(quality: 0.6, maxPixel: 2000, resolution: 144)
        let data = try #require(properties["FilterData"] as? [String: Any])
        let colour = try #require(data["ColorSettings"] as? [String: Any])
        let image = try #require(colour["ImageSettings"] as? [String: Any])
        #expect(image["ImageCompression"] as? String == "ImageJPEGCompress")
        #expect(image["Compression Quality"] as? Double == 0.6)
        let scale = try #require(image["ImageScaleSettings"] as? [String: Any])
        #expect(scale["ImageSizeMax"] as? Int == 2000)
        #expect(scale["ImageResolution"] as? Int == 144)
    }

    @Test("The target ladder only ever gets more aggressive")
    func pdfTargetLadder() {
        let ladder = PDFCompressor.targetLadder()
        #expect(ladder.count > 1)
        for (earlier, later) in zip(ladder, ladder.dropFirst()) {
            #expect(later.maxPixel < earlier.maxPixel)
            #expect(later.quality < earlier.quality)
        }
    }

    // MARK: 영상

    @Test("The ffmpeg command says what it should")
    func videoArguments() {
        let spec = VideoCompressor.SourceSpec(duration: 60, width: 3840, height: 2160, hasAudio: true, isHEVC: false)
        let request = CompressionRequest(mode: .level, level: .standard, videoCodec: .hevc)
        let arguments = VideoCompressor.arguments(
            input: URL(fileURLWithPath: "/tmp/in.mp4"), output: URL(fileURLWithPath: "/tmp/out.mp4"),
            request: request, spec: spec, codec: .hevc, encoder: "hevc_videotoolbox"
        )
        let line = arguments.joined(separator: " ")
        #expect(line.contains("-c:v hevc_videotoolbox"))
        #expect(line.contains("min(1920,iw)"))
        #expect(line.contains("force_divisible_by=2"))
        // Without this tag QuickTime and iOS refuse to open the result.
        #expect(line.contains("-tag:v hvc1"))
        #expect(line.contains("-q:v 50"))
        #expect(line.contains("-b:a 128k"))
        #expect(line.contains("-progress pipe:1"))
        #expect(arguments.last == "/tmp/out.mp4")
    }

    @Test("A video already below the cap is not scaled at all")
    func videoSkipsPointlessScaling() {
        let spec = VideoCompressor.SourceSpec(duration: 30, width: 1280, height: 720, hasAudio: false, isHEVC: false)
        let arguments = VideoCompressor.arguments(
            input: URL(fileURLWithPath: "/tmp/in.mov"), output: URL(fileURLWithPath: "/tmp/out.mp4"),
            request: CompressionRequest(mode: .level, level: .standard), spec: spec,
            codec: .h264, encoder: "h264_videotoolbox"
        )
        #expect(!arguments.contains("-vf"))
        // No audio track means no audio encoder, or ffmpeg fails outright.
        #expect(arguments.contains("-an"))
    }

    @Test("Software fallback uses CRF, not the hardware quality scale")
    func videoSoftwareFallback() {
        let spec = VideoCompressor.SourceSpec(duration: 10, width: 1920, height: 1080, hasAudio: true, isHEVC: false)
        let arguments = VideoCompressor.arguments(
            input: URL(fileURLWithPath: "/tmp/in.mp4"), output: URL(fileURLWithPath: "/tmp/out.mp4"),
            request: CompressionRequest(mode: .level, level: .strong), spec: spec,
            codec: .h264, encoder: "libx264"
        )
        #expect(arguments.contains("-crf"))
        #expect(!arguments.contains("-q:v"))
    }

    @Test("목표 용량 becomes a bitrate rather than a search")
    func videoTargetBitrate() {
        // 10 MB over 100 seconds is 800 kbps of everything; take the audio out.
        let kbps = VideoCompressor.bitrateKbps(targetBytes: 10_000_000, duration: 100, audioKbps: 128)
        #expect(kbps > 600 && kbps < 700)
        // Never a bitrate that cannot encode anything at all.
        #expect(VideoCompressor.bitrateKbps(targetBytes: 1_000, duration: 3_600, audioKbps: 128) == 100)
        #expect(VideoCompressor.bitrateKbps(targetBytes: 1_000_000, duration: 0, audioKbps: 0) == 1_000)
    }

    @Test("원본 코덱 유지 follows the source")
    func videoCodecResolution() {
        #expect(VideoOutputCodec.resolved(.original, sourceIsHEVC: true) == .hevc)
        #expect(VideoOutputCodec.resolved(.original, sourceIsHEVC: false) == .h264)
        #expect(VideoOutputCodec.resolved(.h264, sourceIsHEVC: true) == .h264)
    }

    @Test("ffmpeg's progress stream turns into a real remaining time")
    func ffmpegProgressParsing() {
        var progress = FFmpegProgress()
        for line in ["frame=100", "out_time_us=20000000", "speed=10.0x", "progress=continue"] {
            FFmpegProgress.apply(line, to: &progress)
        }
        #expect(progress.outSeconds == 20)
        #expect(progress.speed == 10)
        #expect(!progress.finished)
        // 100 seconds of video, 20 done, at 10x realtime: 8 seconds left.
        #expect(abs((progress.remaining(of: 100) ?? 0) - 8) < 0.001)
        #expect(abs(progress.fraction(of: 100) - 0.2) < 0.001)

        FFmpegProgress.apply("progress=end", to: &progress)
        #expect(progress.finished)

        // Nothing to say yet, and nothing to divide by.
        var empty = FFmpegProgress()
        #expect(empty.remaining(of: 100) == nil)
        FFmpegProgress.apply("speed=0x", to: &empty)
        FFmpegProgress.apply("out_time_us=1000000", to: &empty)
        #expect(empty.remaining(of: 100) == nil)
        #expect(empty.fraction(of: 0) == 0)
    }

    // MARK: 남은 시간

    @Test("A mixed batch is estimated by work, not by file count")
    func estimatorAddsUpWork() {
        var estimator = CompressionProgressEstimator()
        #expect(estimator.isEmpty)
        let photo = UUID(), scan = UUID(), lecture = UUID()
        estimator.add(id: photo, kind: .image, estimate: 0.1)
        estimator.add(id: scan, kind: .pdf, estimate: 0.4)
        estimator.add(id: lecture, kind: .video, estimate: 60)
        // One ten-minute video outweighs any number of screenshots, which is the
        // whole reason the unit is seconds rather than files.
        #expect(abs(estimator.remainingSeconds - 60.5) < 0.001)

        estimator.finish(id: photo, actual: 0.1)
        #expect(abs(estimator.remainingSeconds - 60.4) < 0.001)
        estimator.drop(id: scan)
        #expect(abs(estimator.remainingSeconds - 60) < 0.001)
        estimator.finish(id: lecture, actual: 60)
        #expect(estimator.isEmpty)
        #expect(estimator.remainingSeconds == 0)
    }

    @Test("Being wrong once corrects the rest of the batch")
    func estimatorCalibrates() {
        var estimator = CompressionProgressEstimator()
        let first = UUID(), second = UUID()
        estimator.add(id: first, kind: .image, estimate: 1)
        estimator.add(id: second, kind: .image, estimate: 1)
        // The first photo took four times as long as predicted, so the one still
        // waiting should now be expected to take longer too.
        estimator.finish(id: first, actual: 4)
        #expect(estimator.remainingSeconds > 1.5)
        #expect(estimator.remainingSeconds <= 4)
    }

    @Test("A measurement from ffmpeg beats the estimate")
    func liveRemainingWins() {
        var estimator = CompressionProgressEstimator()
        let lecture = UUID()
        estimator.add(id: lecture, kind: .video, estimate: 600)
        estimator.note(id: lecture, remaining: 12)
        #expect(abs(estimator.remainingSeconds - 12) < 0.001)
    }

    @Test("The remaining time reads the way the briefing screen's does")
    func estimatorWording() {
        #expect(CompressionProgressEstimator.text(0) == "")
        #expect(CompressionProgressEstimator.text(12) == "예상 남은 시간 약 12초")
        #expect(CompressionProgressEstimator.text(59) == "예상 남은 시간 약 59초")
        #expect(CompressionProgressEstimator.text(200) == "예상 남은 시간 약 3분")
    }

    // MARK: 표시와 파일 다루기

    @Test("A card states what was gained")
    func itemStatusText() {
        var item = CompressionItem(
            source: URL(fileURLWithPath: "/tmp/여행사진.heic"), kind: .image,
            originalBytes: 5_242_880, originalDetail: "4032×3024"
        )
        #expect(item.statusText == "대기 중")
        item.state = .working(0.5)
        #expect(item.statusText == "처리 중 50%")

        item.compressedBytes = 524_288
        item.outputDetail = "2560×1920"
        item.state = .done
        #expect(item.isFinished)
        #expect(item.sizeText == "5.0 MB → 512 KB (−90%)")
        #expect(item.specText == "4032×3024 → 2560×1920")

        item.state = .failed("사진을 읽지 못했습니다.")
        #expect(item.isFailed)
        #expect(item.statusText == "사진을 읽지 못했습니다.")
    }

    @Test("Sizes and durations read in the units people use")
    func formatting() {
        #expect(CompressionFormat.bytes(512) == "512 B")
        #expect(CompressionFormat.bytes(2_048) == "2 KB")
        #expect(CompressionFormat.bytes(5_242_880) == "5.0 MB")
        #expect(CompressionFormat.duration(45) == "45초")
        #expect(CompressionFormat.duration(192) == "3분 12초")
    }

    @Test("Saved files keep the source name and the new extension")
    func saveNaming() {
        var item = CompressionItem(
            source: URL(fileURLWithPath: "/tmp/강의 슬라이드.png"), kind: .image,
            originalBytes: 100, originalDetail: ""
        )
        item.output = URL(fileURLWithPath: "/tmp/work/강의 슬라이드-압축-ab12cd.jpg")
        #expect(CompressionWorkspace.saveName(for: item) == "강의 슬라이드-압축.jpg")
    }

    @Test("A dropped folder is walked, bounded, and filtered")
    func folderExpansion() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(path: "안쪽")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.pdf", "메모.txt", "c.mp4"] {
            try Data("x".utf8).write(to: root.appending(path: name))
        }
        try Data("x".utf8).write(to: nested.appending(path: "d.png"))

        let (files, truncated) = CompressionWorkspace.expand([root])
        #expect(!truncated)
        #expect(files.count == 4, "지원하지 않는 파일은 빠져야 합니다")
        #expect(files.contains { $0.lastPathComponent == "d.png" }, "하위 폴더도 봐야 합니다")
        #expect(!files.contains { $0.lastPathComponent == "메모.txt" })

        let (limited, wasTruncated) = CompressionWorkspace.expand([root], limit: 2)
        #expect(limited.count <= 2)
        #expect(wasTruncated)
    }

    @Test("Missing Homebrew tools are reported, not crashed on")
    func missingToolsAreHandled() async throws {
        // Whether these are installed depends on the machine; what must hold is
        // that asking never throws and the answer matches the filesystem.
        #expect(ImageOutputFormat.isWebPAvailable == (ImageOutputFormat.cwebpPath != nil))
        if let path = ImageOutputFormat.cwebpPath {
            #expect(FileManager.default.isExecutableFile(atPath: path))
        }
        if MediaImporter.ffmpegPath == nil {
            await #expect(throws: AgentError.self) {
                _ = try await VideoCompressor().inspect(
                    URL(fileURLWithPath: "/tmp/none.mp4"), request: CompressionRequest()
                )
            }
        }
    }

    // MARK: 도우미

    private static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CompressionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func destination(extension fileExtension: String) throws -> URL {
        try CompressionWorkspace.directory()
            .appending(path: "test-\(UUID().uuidString.prefix(8)).\(fileExtension)")
    }

    private static func compressImage(
        _ source: URL, format: ImageOutputFormat, level: CompressionLevel, edit: PhotoEdit = .identity
    ) async throws -> CompressionOutcome {
        var request = CompressionRequest(mode: .level, level: level, imageFormat: format)
        request.edit = edit
        let destination = try destination(extension: format.fileExtension)
        return try await ImageCompressor().compress(source, to: destination, request: request) { _, _ in }
    }

    /// A photo-like source: smooth gradient plus fine noise, so it neither
    /// compresses to nothing nor stays incompressible.
    private static func gradient(width: Int, height: Int, markCorner: Bool) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        var generator = SystemRandomNumberGenerator()
        for y in 0 ..< height {
            for x in stride(from: 0, to: width, by: 4) {
                let base = Double(x) / Double(width)
                let noise = Double(UInt8.random(in: 0 ... 40, using: &generator)) / 255
                context.setFillColor(red: base, green: Double(y) / Double(height), blue: noise, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 4, height: 1))
            }
        }
        if markCorner {
            // Stored top-left. CoreGraphics draws from the bottom, so the rect
            // has to sit at the top of the box.
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: height - height / 2, width: width / 2, height: height / 2))
        }
        return context.makeImage()
    }

    private static func writeImage(
        width: Int, height: Int, markCorner: Bool = false,
        orientation: Int? = nil, exif: Bool = false, quality: Double = 0.9
    ) throws -> URL {
        let image = try #require(gradient(width: width, height: height, markCorner: markCorner))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        if exif {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:28 09:41:00",
                kCGImagePropertyExifLensModel: "Test Lens",
            ] as [CFString: Any]
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 37.4602,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 126.9520,
                kCGImagePropertyGPSLongitudeRef: "E",
            ] as [CFString: Any]
        }
        let url = try destination(extension: "jpg")
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        return url
    }

    /// 8×8, transparent everywhere except an opaque blue square on the right.
    private static func writeTransparentPNG() throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 8, height: 8))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 5, y: 0, width: 3, height: 8))
        let image = try #require(context.makeImage())
        let url = try destination(extension: "png")
        let data = try #require(CutoutComposer.pngData(from: image, background: nil))
        try data.write(to: url)
        return url
    }

    /// A PDF with real text operators and a real embedded photo, which is what
    /// the Quartz filter has something to work on.
    private static func writePDF(pages: Int, includeText: Bool, imagePixels: Int) throws -> URL {
        let url = try destination(extension: "pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &mediaBox, nil))
        let photo = try #require(gradient(width: imagePixels, height: imagePixels, markCorner: false))
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for page in 1 ... pages {
            context.beginPage(mediaBox: &mediaBox)
            context.draw(photo, in: CGRect(x: 56, y: 300, width: 500, height: 400))
            if includeText {
                let text = NSAttributedString(
                    string: "Seoul National University local agent page \(page). "
                        + String(repeating: "compression test line. ", count: 4),
                    attributes: [.font: font]
                )
                let line = CTLineCreateWithAttributedString(text)
                context.textPosition = CGPoint(x: 56, y: 200)
                CTLineDraw(line, context)
            }
            context.endPage()
        }
        context.closePDF()
        return url
    }

    private static func properties(of url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    /// The ISO-BMFF brand at offset 4, which is how HEIC and AVIF identify
    /// themselves.
    private static func brand(of data: Data) -> String? {
        guard data.count > 12 else { return nil }
        return String(decoding: data[8 ..< 12], as: UTF8.self)
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let offset = (y * image.width + x) * 4
        guard offset + 2 < buffer.count else { return [0, 0, 0] }
        return Array(buffer[offset ... offset + 2])
    }

    private static func isRed(_ image: CGImage, x: Int, y: Int) -> Bool {
        let sample = pixel(image, x: x, y: y)
        return sample[0] > 180 && sample[1] < 90 && sample[2] < 90
    }
}

/// The two paths that leave the process. Both are enabled only when the tool
/// they need is installed, so a machine without Homebrew still runs a green
/// suite — the point is that when the tools *are* there, the whole path works,
/// not just the arguments we hand it.
@Suite("File compression · 외부 도구", .serialized)
struct CompressionToolTests {

    @Test("cwebp really produces a WebP, with the shot information intact",
          .enabled(if: ImageOutputFormat.isWebPAvailable))
    func webPRoundTrip() async throws {
        let source = try Self.photo(width: 1_200, height: 800)
        defer { try? FileManager.default.removeItem(at: source) }

        let request = CompressionRequest(mode: .level, level: .standard, imageFormat: .webp)
        let destination = try CompressionWorkspace.directory()
            .appending(path: "webp-\(UUID().uuidString.prefix(6)).webp")
        let outcome = try await ImageCompressor().compress(source, to: destination, request: request) { _, _ in }
        defer { try? FileManager.default.removeItem(at: outcome.output) }

        let data = try Data(contentsOf: outcome.output)
        #expect(data.starts(with: Array("RIFF".utf8)))
        #expect(String(decoding: data[8 ..< 12], as: UTF8.self) == "WEBP")
        #expect(outcome.bytes < CompressionWorkspace.fileSize(of: source))

        let size = try #require(ImageCompressor.pixelSize(of: outcome.output))
        #expect(max(size.width, size.height) == 1_200)

        // The PNG intermediate exists precisely so this survives; cwebp cannot
        // read EXIF out of a TIFF, so swapping the carrier drops it silently.
        let properties = try #require(Self.properties(of: outcome.output))
        let exif = try #require(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:08:28 09:41:00")

        // Nothing is left behind in the working folder.
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: CompressionWorkspace.directory(), includingPropertiesForKeys: nil
        )
        #expect(
            !leftovers.contains { $0.lastPathComponent.hasSuffix(".png") && $0.lastPathComponent.count < 20 },
            "중간 PNG가 남으면 안 됩니다"
        )
    }

    @Test("A real video encodes, reports progress, and lands under the cap",
          .enabled(if: MediaImporter.ffmpegPath != nil), .timeLimit(.minutes(2)))
    func videoRoundTrip() async throws {
        let source = try await Self.clip(seconds: 3, width: 1_920, height: 1_080)
        defer { try? FileManager.default.removeItem(at: source) }

        let info = try await VideoCompressor().inspect(source, request: CompressionRequest())
        #expect(info.detail.hasPrefix("1920×1080"))
        #expect(info.estimatedSeconds > 0)

        let request = CompressionRequest(mode: .level, level: .strong, videoCodec: .h264)
        let destination = try CompressionWorkspace.directory()
            .appending(path: "clip-\(UUID().uuidString.prefix(6)).mp4")
        let reports = ProgressLog()
        let outcome = try await VideoCompressor().compress(source, to: destination, request: request) { fraction, _ in
            reports.record(fraction)
        }
        defer { try? FileManager.default.removeItem(at: outcome.output) }

        #expect(outcome.bytes > 0)
        #expect(reports.count > 0, "-progress 출력이 읽혀야 합니다")
        #expect(reports.highest > 0)

        let spec = try await VideoCompressor.probe(outcome.output)
        #expect(max(spec.width, spec.height) == 1_280, "강하게는 긴 변을 720p로 맞춥니다")
        #expect(abs(spec.duration - 3) < 0.5)
    }

    @Test("Cancelling an encode leaves no ffmpeg behind",
          .enabled(if: MediaImporter.ffmpegPath != nil), .timeLimit(.minutes(2)))
    func cancellationLeavesNothingRunning() async throws {
        let source = try await Self.clip(seconds: 30, width: 1_920, height: 1_080)
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = try CompressionWorkspace.directory()
            .appending(path: "cancel-\(UUID().uuidString.prefix(6)).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }

        let task = Task {
            try await VideoCompressor().compress(
                source, to: destination,
                request: CompressionRequest(mode: .level, level: .light, videoCodec: .hevc)
            ) { _, _ in }
        }
        try await Task.sleep(for: .milliseconds(700))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }

        // The registry is the app's guarantee that quitting cleans up; a child
        // still listed here after cancellation is exactly the leak it exists to
        // prevent.
        try await Task.sleep(for: .milliseconds(600))
        #expect(!Self.isEncodingOurClip(destination))
    }

    // MARK: 도우미

    private static func isEncodingOurClip(_ destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Ao", "args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains(destination.lastPathComponent)
    }

    private static func photo(width: Int, height: Int) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        for y in stride(from: 0, to: height, by: 2) {
            context.setFillColor(red: Double(y) / Double(height), green: 0.4, blue: 0.7, alpha: 1)
            context.fill(CGRect(x: 0, y: y, width: width, height: 2))
        }
        let image = try #require(context.makeImage())
        let url = try CompressionWorkspace.directory()
            .appending(path: "source-\(UUID().uuidString.prefix(6)).jpg")
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:28 09:41:00",
            ] as [CFString: Any],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        return url
    }

    /// ffmpeg's own test pattern, so the fixture needs no checked-in media.
    private static func clip(seconds: Int, width: Int, height: Int) async throws -> URL {
        let ffmpeg = try #require(MediaImporter.ffmpegPath)
        let url = try CompressionWorkspace.directory()
            .appending(path: "fixture-\(UUID().uuidString.prefix(6)).mp4")
        _ = try await ProcessRunner().run(ffmpeg, [
            "-hide_banner", "-nostdin", "-y",
            "-f", "lavfi", "-i", "testsrc=size=\(width)x\(height):rate=30:duration=\(seconds)",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "18",
            "-c:a", "aac", "-pix_fmt", "yuv420p", url.path,
        ], expectsStandardOutput: false)
        return url
    }

    private static func properties(of url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }
}

/// The progress callback arrives on ffmpeg's reader thread.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    var highest: Double {
        lock.lock()
        defer { lock.unlock() }
        return values.max() ?? 0
    }
}
#endif
