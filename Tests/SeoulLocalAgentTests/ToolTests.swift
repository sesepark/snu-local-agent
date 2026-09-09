import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers
#if canImport(Testing)
import Testing
@testable import SeoulLocalAgent

/// Covers the five tools added alongside 용량 줄이기 — PDF 편집, 소리 다듬기,
/// 화질 올리기, 스캔 보정 and 형식 변환 — everywhere that is possible without a
/// network or a downloaded model. Real PDFs are built and edited, real audio is
/// synthesised and denoised, real images are enlarged and corrected.
@Suite("Tools")
struct ToolTests {

    // MARK: - 만들어 쓰는 재료

    static func scratch(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SeoulLocalAgentTests-\(name)-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// A PDF whose pages are distinguishable, so a reorder that silently did
    /// nothing would still fail the test.
    static func makePDF(pages: Int, in directory: URL, name: String = "문서.pdf") throws -> URL {
        let url = directory.appending(path: name)
        let document = PDFDocument()
        for index in 0 ..< pages {
            let size = CGSize(width: 200, height: 300)
            guard let context = CGContext(
                data: nil, width: 200, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { throw AgentError.processFailed("context") }
            // A different grey per page: the value survives a round trip through
            // PDF and can be read back to prove which page ended up where.
            let grey = 0.1 + Double(index) * 0.15
            context.setFillColor(CGColor(gray: grey, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            guard let image = context.makeImage() else { throw AgentError.processFailed("image") }
            guard let page = PDFPage(image: NSImage(cgImage: image, size: size)) else {
                throw AgentError.processFailed("page")
            }
            document.insert(page, at: index)
        }
        #expect(document.write(to: url))
        return url
    }

    /// The mean grey of a page, used as its identity.
    static func grey(of document: PDFDocument, page index: Int) -> Double? {
        guard let page = document.page(at: index) else { return nil }
        let thumbnail = page.thumbnail(of: CGSize(width: 8, height: 8), for: .mediaBox)
        guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cgImage.dataProvider?.data as Data?
        else { return nil }
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }
        return Double(bytes.reduce(0) { $0 + Int($1) }) / Double(bytes.count) / 255
    }

    static func makeImage(width: Int, height: Int, in directory: URL, name: String = "사진.png") throws -> URL {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw AgentError.processFailed("context") }
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 8))
        guard let image = context.makeImage() else { throw AgentError.processFailed("image") }
        let url = directory.appending(path: name)
        try UpscaleWorker.write(image, to: url, format: .png)
        return url
    }

    /// A tone plus steady noise, written as a WAV. Steady is the point: it is
    /// what the gate is built for and what a lecture hall actually sounds like.
    static func makeNoisyWAV(seconds: Double, sampleRate: Double, noise: Float, in directory: URL, name: String = "소리.wav") throws -> URL {
        let frames = Int(seconds * sampleRate)
        var samples = [Float](repeating: 0, count: frames)
        var seed: UInt64 = 12345
        for index in 0 ..< frames {
            let t = Double(index) / sampleRate
            // A gated "voice": loud for half a second, silent for half a second.
            let speaking = Int(t * 2) % 2 == 0
            let tone = speaking ? Float(sin(2 * .pi * 440 * t)) * 0.35 : 0
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let white = Float(Int32(truncatingIfNeeded: seed >> 33)) / Float(Int32.max)
            samples[index] = tone + white * noise
        }
        let url = directory.appending(path: name)
        let writer = try AudioStreamWriter.intermediate(url: url, sampleRate: sampleRate, channelCount: 1)
        try writer.write(samples)
        return url
    }

    // MARK: - PDF 편집

    @Test("Merging keeps every page and leaves the sources alone")
    func pdfMerge() throws {
        let directory = try Self.scratch("pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try PDFToolbox.load(Self.makePDF(pages: 2, in: directory, name: "a.pdf"))
        let second = try PDFToolbox.load(Self.makePDF(pages: 3, in: directory, name: "b.pdf"))
        let merged = PDFToolbox.merge([first, second])
        #expect(merged.pageCount == 5)
        // Pages are copied, not moved: inserting the live object would empty the
        // source, which is the bug this asserts against.
        #expect(first.pageCount == 2)
        #expect(second.pageCount == 3)
    }

    @Test("Deleting and extracting pick the right pages")
    func pdfSelection() throws {
        let directory = try Self.scratch("pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try PDFToolbox.load(Self.makePDF(pages: 5, in: directory))
        let greys = (0 ..< 5).compactMap { Self.grey(of: document, page: $0) }
        #expect(greys.count == 5)

        let removed = PDFToolbox.removing([1, 3], from: document)
        #expect(removed.pageCount == 3)
        #expect(Self.grey(of: removed, page: 1).map { abs($0 - greys[2]) < 0.02 } == true)

        let extracted = PDFToolbox.extracting([4, 0], from: document)
        #expect(extracted.pageCount == 2)
        #expect(Self.grey(of: extracted, page: 0).map { abs($0 - greys[4]) < 0.02 } == true)
        #expect(Self.grey(of: extracted, page: 1).map { abs($0 - greys[0]) < 0.02 } == true)
    }

    @Test("Moving pages keeps their order and reports where they landed")
    func pdfMove() throws {
        let directory = try Self.scratch("pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try PDFToolbox.load(Self.makePDF(pages: 5, in: directory))
        let greys = (0 ..< 5).compactMap { Self.grey(of: document, page: $0) }

        let moved = PDFToolbox.moving([3, 4], to: 0, in: document)
        #expect(moved.document.pageCount == 5)
        #expect(moved.selection == [0, 1])
        #expect(Self.grey(of: moved.document, page: 0).map { abs($0 - greys[3]) < 0.02 } == true)
        #expect(Self.grey(of: moved.document, page: 1).map { abs($0 - greys[4]) < 0.02 } == true)
        #expect(Self.grey(of: moved.document, page: 2).map { abs($0 - greys[0]) < 0.02 } == true)
    }

    @Test("Rotation accumulates and stays inside one turn")
    func pdfRotation() throws {
        let directory = try Self.scratch("pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try PDFToolbox.load(Self.makePDF(pages: 2, in: directory))
        _ = PDFToolbox.rotating([0], by: 90, in: document)
        #expect(document.page(at: 0)?.rotation == 90)
        _ = PDFToolbox.rotating([0], by: 90, in: document)
        #expect(document.page(at: 0)?.rotation == 180)
        // Turning left past zero must not leave a negative rotation behind.
        _ = PDFToolbox.rotating([1], by: -90, in: document)
        #expect(document.page(at: 1)?.rotation == 270)
    }

    @Test("저장이 실패해도 그 자리에 있던 PDF는 그대로다")
    func pdfSaveNeverDamagesWhatIsAlreadyThere() throws {
        let directory = try Self.scratch("pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        // 사용자가 저장 창에서 이미 있는 파일을 고른 상황.
        let existing = try Self.makePDF(pages: 7, in: directory, name: "기존.pdf")
        let before = try Data(contentsOf: existing)
        let replacement = try PDFToolbox.load(Self.makePDF(pages: 1, in: directory, name: "새것.pdf"))

        // 실패하는 저장 하나(한글 암호는 PDF 표준이 담지 못한다)로 불변식을 붙들어 둔다:
        // **저장이 끝나지 못하면 그 자리는 손대지 않은 채여야 한다.** 쓰다 만 채로 끊기는
        // 경우까지 이 시험이 만들어 낼 수는 없고, 그것을 막는 것은 옆에서 다 쓴 뒤에
        // 바꿔치기하는 `write`의 구조다 — 여기서는 그 구조가 남기는 자취를 확인한다.
        #expect(throws: (any Error).self) {
            try PDFToolbox.write(replacement, to: existing, userPassword: "한글암호")
        }
        #expect(try Data(contentsOf: existing) == before)
        #expect(PDFDocument(url: existing)?.pageCount == 7)

        // 성공하면 물론 바뀌고, 쓰다 만 임시 파일은 남지 않는다.
        try PDFToolbox.write(replacement, to: existing)
        #expect(PDFDocument(url: existing)?.pageCount == 1)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix("쓰는중") }
        #expect(leftovers.isEmpty)
    }

    @Test("A password-protected PDF needs the password to reopen")
    func pdfPassword() throws {
        let directory = try Self.scratch("pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try PDFToolbox.load(Self.makePDF(pages: 1, in: directory))
        let locked = directory.appending(path: "잠금.pdf")
        try PDFToolbox.write(document, to: locked, userPassword: "secret-1234")

        #expect(PDFDocument(url: locked)?.isLocked == true)
        #expect(throws: (any Error).self) { try PDFToolbox.load(locked) }
        let unlocked = try PDFToolbox.load(locked, password: "secret-1234")
        #expect(unlocked.pageCount == 1)

        // A Korean password is refused with a sentence that explains why, rather
        // than writing a file that silently is not protected.
        #expect(throws: (any Error).self) {
            try PDFToolbox.write(document, to: directory.appending(path: "한글.pdf"), userPassword: "비밀번호")
        }
    }

    @Test("A watermark reaches only the pages it was asked for")
    func pdfWatermark() throws {
        let directory = try Self.scratch("pdf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try PDFToolbox.load(Self.makePDF(pages: 3, in: directory))
        let before = (0 ..< 3).compactMap { Self.grey(of: document, page: $0) }
        let output = directory.appending(path: "워터마크.pdf")
        let stamped = try PDFToolbox.watermarked(
            document, watermark: PDFWatermark(text: "대외비", opacity: 0.9, angleDegrees: 0, size: 0.3),
            pages: [1], into: output
        )
        #expect(stamped.pageCount == 3)
        let after = (0 ..< 3).compactMap { Self.grey(of: stamped, page: $0) }
        #expect(after.count == 3)
        // The untouched pages come back the same shade; the stamped one darkens.
        #expect(abs(after[0] - before[0]) < 0.02)
        #expect(abs(after[2] - before[2]) < 0.02)
        #expect(after[1] < before[1] - 0.005)
    }

    @Test("Page ranges are parsed the way people type them")
    func pageRanges() {
        #expect(PDFToolbox.parseRanges("1-3", pageCount: 10) == [0, 1, 2])
        #expect(PDFToolbox.parseRanges("1, 5, 3", pageCount: 10) == [0, 4, 2])
        #expect(PDFToolbox.parseRanges("2-4, 3", pageCount: 10) == [1, 2, 3])
        // Beyond the end clamps rather than crashing or silently returning
        // nothing, which is what someone typing "10-" means.
        #expect(PDFToolbox.parseRanges("8-99", pageCount: 10) == [7, 8, 9])
        #expect(PDFToolbox.parseRanges("", pageCount: 10).isEmpty)
        #expect(PDFToolbox.parseRanges("없음", pageCount: 10).isEmpty)
        #expect(PDFToolbox.parseRanges("3", pageCount: 0).isEmpty)
    }

    @Test("Stamp scopes resolve to real page numbers")
    func stampScopes() {
        #expect(PDFStampScope.first.indexes(pageCount: 5, selected: [2]) == [0])
        #expect(PDFStampScope.last.indexes(pageCount: 5, selected: [2]) == [4])
        #expect(PDFStampScope.all.indexes(pageCount: 3, selected: []) == [0, 1, 2])
        #expect(PDFStampScope.selected.indexes(pageCount: 5, selected: [1, 3]) == [1, 3])
        #expect(PDFStampScope.last.indexes(pageCount: 0, selected: []).isEmpty)
    }

    // MARK: - 소리 다듬기

    @Test("The spectral gate lowers the noise floor and keeps the signal")
    func spectralGate() async throws {
        let directory = try Self.scratch("audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeNoisyWAV(seconds: 6, sampleRate: 16_000, noise: 0.06, in: directory)

        let worker = AudioCleanupWorker(request: AudioCleanupRequest(
            method: .gate, strength: .standard, normalisesLoudness: false, format: .wav
        ))
        let destination = directory.appending(path: "정리.wav")
        let outcome = try await worker.run(source, to: destination) { _ in }
        #expect(FileManager.default.fileExists(atPath: outcome.output.path))

        let before = try await Self.measure(source)
        let after = try await Self.measure(destination)
        // The floor between phrases has to drop by a real margin…
        let beforeFloor = try #require(before.floor)
        let afterFloor = try #require(after.floor)
        #expect(afterFloor < beforeFloor * 0.6)
        // …while the tone itself survives. Losing both would also "reduce noise".
        #expect(after.peak > before.peak * 0.5)
    }

    @Test("The cleaned file is the same length as the original")
    func gateLength() async throws {
        let directory = try Self.scratch("audio")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeNoisyWAV(seconds: 3, sampleRate: 16_000, noise: 0.04, in: directory)
        let worker = AudioCleanupWorker(request: AudioCleanupRequest(
            method: .gate, strength: .light, normalisesLoudness: false, format: .wav
        ))
        let destination = directory.appending(path: "정리.wav")
        _ = try await worker.run(source, to: destination) { _ in }
        let sourceLength = try await AVURLAsset(url: source).load(.duration).seconds
        let outputLength = try await AVURLAsset(url: destination).load(.duration).seconds
        // The overlap-add adds a frame of latency at the head and a frame of
        // padding at the tail; both are trimmed, so this must stay within a
        // single hop rather than drifting by the window size.
        #expect(abs(sourceLength - outputLength) < 0.05)
    }

    @Test("Loudness gain lifts a quiet take without letting it clip")
    func loudnessGain() {
        // Quiet recording: lifted towards the target.
        #expect(AudioCleanupWorker.loudnessGain(rms: 0.01, peak: 0.05) > 1)
        // Already loud: pulled back rather than pushed past full scale.
        #expect(AudioCleanupWorker.loudnessGain(rms: 0.4, peak: 0.99) < 1)
        // A peak near full scale caps the gain whatever the RMS says.
        #expect(AudioCleanupWorker.loudnessGain(rms: 0.01, peak: 0.99) * 0.99 <= 0.98)
        // Silence is left alone rather than multiplied by infinity.
        #expect(AudioCleanupWorker.loudnessGain(rms: 0, peak: 0) == 1)
    }

    @Test("Cleanup takes audio and video but not documents")
    func cleanupAccepts() {
        let worker = AudioCleanupWorker(request: AudioCleanupRequest())
        #expect(worker.accepts.contains("m4a"))
        #expect(worker.accepts.contains("mp4"))
        #expect(worker.accepts.contains("wav"))
        #expect(!worker.accepts.contains("pdf"))
        #expect(worker.outputExtension(for: URL(fileURLWithPath: "/tmp/a.mov")) == "m4a")
    }

    private static func measure(_ url: URL) async throws -> (floor: Float?, peak: Float) {
        let reader = try await AudioStreamReader(url: url)
        var meter = NoiseFloorMeter(sampleRate: reader.sampleRate)
        while let block = try reader.next() { meter.add(block) }
        return (meter.noiseFloor, meter.peak)
    }

    // MARK: - 화질 올리기

    @Test("Lanczos doubles the picture and writes the chosen format")
    func lanczosUpscale() async throws {
        let directory = try Self.scratch("upscale")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeImage(width: 320, height: 240, in: directory)
        let worker = UpscaleWorker(request: UpscaleRequest(model: .lanczos, format: .jpeg))
        let destination = directory.appending(path: "확대.jpg")
        let outcome = try await worker.run(source, to: destination) { _ in }
        let size = try #require(UpscaleWorker.pixelSize(of: outcome.output))
        #expect(size.width == 640)
        #expect(size.height == 480)
        #expect(outcome.detail.contains("320×240"))
    }

    @Test("An enlargement that would be enormous is capped")
    func upscaleCap() {
        // Well inside the cap: the full multiplication happens.
        #expect(UpscaleWorker.targetSize(for: (800, 600), scale: 2, cap: 6000) == (1600, 1200))
        // Past it: scaled back with the aspect ratio kept.
        let capped = UpscaleWorker.targetSize(for: (4000, 3000), scale: 4, cap: 6000)
        #expect(capped.width == 6000)
        #expect(capped.height == 4500)
    }

    @Test("Portrait photos are described the way they look")
    func orientationAwareSize() throws {
        let directory = try Self.scratch("upscale")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeImage(width: 400, height: 200, in: directory)
        let size = try #require(UpscaleWorker.pixelSize(of: source))
        #expect(size.width == 400)
        #expect(size.height == 200)
    }

    // MARK: - 스캔 보정

    @Test("The document finish flattens uneven lighting to a bright page")
    func scanFinish() throws {
        // A page lit from one side: white paper that fades to grey across the
        // frame, which is what a phone photo of a handout actually looks like.
        let width = 400, height = 300
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw AgentError.processFailed("context") }
        for x in 0 ..< width {
            let brightness = 0.95 - 0.5 * Double(x) / Double(width)
            context.setFillColor(CGColor(gray: brightness, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        // A line of "text" in the darkest corner, which must survive.
        context.setFillColor(CGColor(gray: 0.05, alpha: 1))
        context.fill(CGRect(x: 300, y: 140, width: 60, height: 20))
        let image = try #require(context.makeImage())

        let corrected = ScanCorrectionWorker.applyFinish(CIImage(cgImage: image), finish: .bright)
        let rendered = try #require(CIContext().createCGImage(corrected, from: corrected.extent))
        let bright = Self.averageBrightness(rendered)
        let original = Self.averageBrightness(image)
        // The page as a whole gets brighter…
        #expect(bright > original)
        // …and the shaded end is no longer noticeably darker than the lit end.
        let left = Self.averageBrightness(rendered, region: CGRect(x: 20, y: 20, width: 60, height: 60))
        let right = Self.averageBrightness(rendered, region: CGRect(x: 320, y: 20, width: 60, height: 60))
        #expect(abs(left - right) < abs(
            Self.averageBrightness(image, region: CGRect(x: 20, y: 20, width: 60, height: 60))
                - Self.averageBrightness(image, region: CGRect(x: 320, y: 20, width: 60, height: 60))
        ))
    }

    @Test("A page seen at an angle gets its real proportions back")
    func scanAspectRatio() throws {
        // Corners as Vision reported them for a 1400×1100 render of an 850×1100
        // page, projected through a real pinhole camera (f = 1500) rotated 32°
        // and 24° away from the lens. Bottom-left origin, as Vision uses.
        let ratio = try #require(ScanCorrectionWorker.aspectRatio(
            topLeft: CGPoint(x: 301.39, y: 1052.73),
            topRight: CGPoint(x: 1127.78, y: 1091.41),
            bottomLeft: CGPoint(x: 495.83, y: 244.92),
            bottomRight: CGPoint(x: 1118.06, y: 120.31),
            imageSize: CGSize(width: 1400, height: 1100)
        ))
        // Without this the page comes back the shape of its own foreshortened
        // outline — 967 by 1249 rather than the near-square the edge lengths
        // alone would give.
        #expect(abs(ratio - 850.0 / 1100.0) < 0.02)
    }

    @Test("A quad no real camera could have produced is refused")
    func scanAspectRefusal() {
        // A hand-built homography rather than a projection: the two vanishing
        // directions imply a negative focal length, so the honest answer is that
        // the ratio cannot be recovered — not a confident wrong number.
        #expect(ScanCorrectionWorker.aspectRatio(
            topLeft: CGPoint(x: 301.39, y: 975.39),
            topRight: CGPoint(x: 1176.39, y: 867.97),
            bottomLeft: CGPoint(x: 204.17, y: 219.14),
            bottomRight: CGPoint(x: 1088.89, y: 98.83),
            imageSize: CGSize(width: 1400, height: 1100)
        ) == nil)
        // A degenerate quad must not divide by zero either.
        #expect(ScanCorrectionWorker.aspectRatio(
            topLeft: .zero, topRight: .zero, bottomLeft: .zero, bottomRight: .zero,
            imageSize: CGSize(width: 100, height: 100)
        ) == nil)
    }

    @Test("The document finish keeps the text while removing the shading")
    func scanKeepsText() throws {
        // A page lit from one side with a dark bar of "text" in the shaded half:
        // an illumination estimate built from a plain blur divides the text away
        // along with the shadow, which is the failure this guards.
        let width = 600, height = 400
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw AgentError.processFailed("context") }
        for x in 0 ..< width {
            context.setFillColor(CGColor(gray: 0.95 - 0.55 * Double(x) / Double(width), alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        context.setFillColor(CGColor(gray: 0.02, alpha: 1))
        context.fill(CGRect(x: 430, y: 180, width: 90, height: 8))
        let image = try #require(context.makeImage())

        let corrected = ScanCorrectionWorker.applyFinish(CIImage(cgImage: image), finish: .bright)
        let rendered = try #require(CIContext().createCGImage(corrected, from: corrected.extent))
        // `CGImage.cropping` measures from the top left while `CGContext.fill`
        // measured from the bottom left, so the bar drawn at y = 180 is read
        // back at 400 − 188.
        let paper = Self.averageBrightness(rendered, region: CGRect(x: 430, y: 60, width: 90, height: 60))
        let text = Self.averageBrightness(rendered, region: CGRect(x: 440, y: 213, width: 70, height: 6))
        // Paper in the shaded half comes out white…
        #expect(paper > 0.85)
        // …and the text in that same half stays dark rather than dissolving.
        #expect(text < 0.35)
    }

    @Test("Scan correction writes each of its three formats")
    func scanFormats() async throws {
        let directory = try Self.scratch("scan")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeImage(width: 600, height: 800, in: directory)
        for format in ScanOutputFormat.allCases {
            let worker = ScanCorrectionWorker(request: ScanRequest(
                finish: .bright, resolution: .screen, format: format, detectsEdges: false
            ))
            let destination = directory.appending(path: "결과.\(format.fileExtension)")
            let outcome = try await worker.run(source, to: destination) { _ in }
            #expect(FileManager.default.fileExists(atPath: outcome.output.path))
            if format == .pdf {
                #expect(PDFDocument(url: outcome.output)?.pageCount == 1)
            } else {
                let size = try #require(UpscaleWorker.pixelSize(of: outcome.output))
                // Capped, never enlarged: a scan smaller than the target comes
                // back at its own size rather than being blown up for nothing.
                #expect(max(size.width, size.height) == min(800, ScanResolution.screen.longEdge))
            }
            try? FileManager.default.removeItem(at: destination)
        }
    }

    /// Mean luminance of a rectangle, in top-left coordinates.
    ///
    /// Redrawn into a small grey context rather than read through
    /// `CGImage.cropping(to:)`: a cropped image keeps the *original* data
    /// provider, so reading its bytes hands back the whole picture and every
    /// region measures the same. Grey also drops the alpha byte, which would
    /// otherwise pull every average a quarter of the way to white.
    static func averageBrightness(_ image: CGImage, region: CGRect? = nil) -> Double {
        let rect = region ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let width = max(1, Int(rect.width)), height = max(1, Int(rect.height))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(
            x: -rect.minX, y: -(CGFloat(image.height) - rect.maxY),
            width: CGFloat(image.width), height: CGFloat(image.height)
        ))
        guard let data = context.data else { return 0 }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        var total = 0
        for index in 0 ..< width * height { total += Int(bytes[index]) }
        return Double(total) / Double(width * height) / 255
    }

    // MARK: - 형식 변환

    @Test("Each target accepts only what it can actually handle")
    func conversionAccepts() {
        #expect(ConversionTarget.jpeg.accepts.contains("png"))
        #expect(!ConversionTarget.jpeg.accepts.contains("mp3"))
        // 텍스트로 also reads 한글 문서, which the app parses itself.
        #expect(ConversionTarget.pdfToText.accepts == ["pdf", "hwp", "hwpx"])
        #expect(ConversionTarget.pdfToImages.accepts == ["pdf"])
        #expect(ConversionTarget.gif.accepts.contains("mov"))
        #expect(!ConversionTarget.gif.accepts.contains("jpg"))
        // Audio conversions take video too, because "이 영상 소리만 mp3로" is the
        // request people actually have.
        #expect(ConversionTarget.mp3.accepts.contains("mp4"))
    }

    @Test("A dropped file picks its own family")
    func conversionFamilyDetection() {
        #expect(ConversionFamily.of(URL(fileURLWithPath: "/tmp/a.HEIC")) == .image)
        #expect(ConversionFamily.of(URL(fileURLWithPath: "/tmp/a.mov")) == .video)
        #expect(ConversionFamily.of(URL(fileURLWithPath: "/tmp/a.m4a")) == .audio)
        #expect(ConversionFamily.of(URL(fileURLWithPath: "/tmp/a.docx")) == .document)
        #expect(ConversionFamily.of(URL(fileURLWithPath: "/tmp/a.zip")) == nil)
        // Every target belongs to exactly one family and every family has some.
        for family in ConversionFamily.allCases {
            #expect(!family.targets.isEmpty)
            #expect(family.targets.allSatisfy { $0.family == family })
        }
    }

    @Test("Images convert between formats and keep their size")
    func imageConversion() async throws {
        let directory = try Self.scratch("convert")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeImage(width: 320, height: 200, in: directory)
        for target in [ConversionTarget.jpeg, .heic, .tiff] {
            let worker = FileConverter(request: ConversionRequest(target: target, quality: 0.9))
            let destination = directory.appending(path: "결과.\(target.fileExtension)")
            let outcome = try await worker.run(source, to: destination) { _ in }
            let size = try #require(UpscaleWorker.pixelSize(of: outcome.output))
            #expect(size.width == 320)
            #expect(size.height == 200)
            try? FileManager.default.removeItem(at: destination)
        }
    }

    @Test("A photo becomes a one-page PDF and a PDF becomes page images")
    func documentConversions() async throws {
        let directory = try Self.scratch("convert")
        defer { try? FileManager.default.removeItem(at: directory) }
        let photo = try Self.makeImage(width: 300, height: 400, in: directory)
        let asPDF = directory.appending(path: "사진.pdf")
        _ = try await FileConverter(request: ConversionRequest(target: .imageToPDF))
            .run(photo, to: asPDF) { _ in }
        #expect(PDFDocument(url: asPDF)?.pageCount == 1)

        let multiPage = try Self.makePDF(pages: 3, in: directory, name: "여러쪽.pdf")
        let folder = directory.appending(path: "쪽이미지")
        let outcome = try await FileConverter(request: ConversionRequest(target: .pdfToImages))
            .run(multiPage, to: folder) { _ in }
        let files = try FileManager.default.contentsOfDirectory(at: outcome.output, includingPropertiesForKeys: nil)
        #expect(files.count == 3)
        #expect(outcome.detail.contains("3"))
    }

    @Test("Audio converts to every format macOS can encode by itself")
    func audioConversion() async throws {
        let directory = try Self.scratch("convert")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try Self.makeNoisyWAV(seconds: 1, sampleRate: 16_000, noise: 0.02, in: directory)
        for target in [ConversionTarget.m4a, .wav, .aiff, .flac] {
            let worker = FileConverter(request: ConversionRequest(target: target))
            let destination = directory.appending(path: "결과.\(target.fileExtension)")
            let outcome = try await worker.run(source, to: destination) { _ in }
            #expect(FileManager.default.fileExists(atPath: outcome.output.path))
            // Readable again, which a wrong endianness or a bad settings dict
            // would not be.
            let duration = try await AVURLAsset(url: outcome.output).load(.duration).seconds
            // AAC pads to a frame boundary and adds encoder priming, so an m4a
            // of a one-second source legitimately reports a fraction longer; the
            // lossless formats have no excuse.
            // AAC pads to a frame boundary and adds encoder priming, and Apple's
            // FLAC encoder pads to a whole block, so both legitimately report a
            // fraction longer than the source. WAV and AIFF have no excuse.
            let slack = (target == .m4a || target == .flac) ? 0.25 : 0.02
            #expect(abs(duration - 1) < slack, "\(target.rawValue) 길이 \(duration)")
            try? FileManager.default.removeItem(at: destination)
        }
    }

    @Test("Missing dependencies are reported before a batch is queued")
    func missingDependencies() {
        // These four are the only ones that can be missing, and each one names
        // the command that fixes it rather than failing halfway through a batch.
        for target in [ConversionTarget.webp, .mp3, .officeToPDF] {
            if let message = target.missingDependency {
                #expect(message.contains("brew") || message.contains("LibreOffice"))
            }
        }
        // Nothing outside macOS is needed for these.
        #expect(ConversionTarget.jpeg.missingDependency == nil)
        #expect(ConversionTarget.pdfToText.missingDependency == nil)
        #expect(ConversionTarget.extractAudio.missingDependency == nil)
    }

    // MARK: - 배치 엔진

    @Test("Folder expansion keeps only what the tool accepts")
    func expansion() throws {
        let directory = try Self.scratch("expand")
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try Self.makeImage(width: 10, height: 10, in: directory, name: "a.png")
        _ = try Self.makePDF(pages: 1, in: directory, name: "b.pdf")
        let nested = directory.appending(path: "안쪽")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try Self.makeImage(width: 10, height: 10, in: nested, name: "c.png")

        let images = ToolWorkspace.expand([directory], accepting: CompressionKind.imageExtensions)
        #expect(images.files.count == 2)
        #expect(!images.truncated)
        let pdfs = ToolWorkspace.expand([directory], accepting: ["pdf"])
        #expect(pdfs.files.count == 1)
    }

    @Test("A folder result is named without a trailing dot")
    func folderOutputNaming() throws {
        let directory = try Self.scratch("naming")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = URL(fileURLWithPath: "/tmp/강의자료.pdf")
        let asFolder = ToolWorkspace.outputURL(for: source, extension: "", in: directory)
        #expect(!asFolder.lastPathComponent.hasSuffix("."))
        let asFile = ToolWorkspace.outputURL(for: source, extension: "png", in: directory)
        #expect(asFile.pathExtension == "png")
    }

    @Test("The estimate learns from what actually happened")
    func etaCalibration() {
        var eta = ToolETA()
        #expect(eta.isEmpty)
        let first = UUID(), second = UUID()
        eta.add(id: first, bucket: "jpg", estimate: 1)
        eta.add(id: second, bucket: "jpg", estimate: 1)
        #expect(abs(eta.remainingSeconds - 2) < 0.01)
        // The first file took four times as long as predicted, so what is left
        // has to be revised upwards rather than staying at one second.
        eta.finish(id: first, actual: 4)
        #expect(eta.remainingSeconds > 1.5)
        eta.drop(id: second)
        #expect(eta.isEmpty)
        #expect(ToolETA.text(0.1).isEmpty)
        #expect(ToolETA.text(90).contains("분"))
    }

    // MARK: - 화면 구성

    @Test("Every screen has a shortcut, a group and a symbol of its own")
    func sections() {
        let all = AppSection.allCases
        #expect(all.count == 15)
        // No two screens may claim the same key *and* the same modifiers, or the
        // menu silently wins one. 자동 브리핑 and 브리핑 보관함 deliberately share
        // the letter and differ by ⇧.
        let keys = all.map { "\($0.shortcut.character)\($0.shortcutModifiers.rawValue)" }
        #expect(Set(keys).count == all.count)
        #expect(Set(all.map(\.symbol)).count == all.count)
        #expect(Set(all.map(\.title)).count == all.count)
        // Sidebar order is declaration order, and every case belongs to exactly
        // one group.
        let grouped = AppSection.Group.allCases.flatMap(\.members)
        #expect(grouped == all)
        #expect(all.allSatisfy { !$0.subtitle.isEmpty })
    }
}
#endif
