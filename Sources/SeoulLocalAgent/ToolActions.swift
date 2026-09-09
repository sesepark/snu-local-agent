import Foundation
import AppKit
import PDFKit

/// What the four new file tools do when their buttons are pressed.
///
/// An extension rather than more of `AutomationController`'s body: the class is
/// already sixteen hundred lines, and none of this is anything but "build the
/// worker from the current settings and hand it to the queue".
@MainActor
extension AutomationController {

    // MARK: - 소리 다듬기

    var audioCleanupWorker: AudioCleanupWorker {
        AudioCleanupWorker(request: AudioCleanupRequest(
            method: audioCleanupMethod,
            strength: audioCleanupStrength,
            normalisesLoudness: audioCleanupNormalises,
            format: audioCleanupFormat
        ))
    }

    func cleanAudio(_ urls: [URL]) {
        audioCleanup.load(urls, worker: audioCleanupWorker)
    }

    func rerunAudioCleanup() {
        audioCleanup.rerun(audioCleanupWorker)
    }

    func chooseAudioForCleanup(startingAt directory: URL?) {
        chooseFiles(title: "다듬을 녹음 선택", startingAt: directory) { cleanAudio($0) }
    }

    // MARK: - 화질 올리기

    var upscaleWorker: UpscaleWorker {
        UpscaleWorker(request: UpscaleRequest(model: upscaleModel, format: upscaleFormat))
    }

    func upscalePhotos(_ urls: [URL]) {
        upscale.load(urls, worker: upscaleWorker)
    }

    func rerunUpscale() {
        upscale.rerun(upscaleWorker)
    }

    func choosePhotosForUpscale(startingAt directory: URL?) {
        chooseFiles(title: "키울 사진 선택", startingAt: directory) { upscalePhotos($0) }
    }

    // MARK: - 스캔 보정

    var scanWorker: ScanCorrectionWorker {
        ScanCorrectionWorker(request: ScanRequest(
            finish: scanFinish,
            resolution: scanResolution,
            format: scanFormat,
            detectsEdges: scanDetectsEdges
        ))
    }

    func correctScans(_ urls: [URL]) {
        scan.load(urls, worker: scanWorker)
    }

    func rerunScan() {
        scan.rerun(scanWorker)
    }

    func choosePhotosForScan(startingAt directory: URL?) {
        chooseFiles(title: "보정할 사진 선택", startingAt: directory) { correctScans($0) }
    }

    /// Twelve photographed pages are one handout, not twelve files, so the tool
    /// that made them also offers to bind them.
    func saveScansAsOnePDF() {
        let finished = scan.jobs.filter(\.isFinished).compactMap(\.output)
        let pages = finished.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pages.isEmpty else {
            scan.error = "묶을 PDF가 없습니다. 저장 형식을 PDF로 두고 다시 실행해 주세요."
            return
        }
        let documents = pages.compactMap { PDFDocument(url: $0) }
        guard !documents.isEmpty else {
            scan.error = "보정한 PDF를 읽지 못했습니다."
            return
        }
        let merged = PDFToolbox.merge(documents)
        let panel = NSSavePanel()
        panel.title = "보정한 쪽을 한 PDF로 저장"
        panel.nameFieldStringValue = "스캔 \(merged.pageCount)쪽.pdf"
        panel.allowedContentTypes = [.pdf]
        if let folder = scan.lastSaveFolder { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDFToolbox.write(merged, to: url)
            scan.lastSaveFolder = url.deletingLastPathComponent()
            scan.report("\(merged.pageCount)쪽을 한 PDF로 저장했습니다: \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            scan.error = (error as? AgentError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - 형식 변환

    var conversionWorker: FileConverter {
        FileConverter(request: ConversionRequest(target: conversionTarget, quality: conversionQuality))
    }

    /// Follows what was actually dropped. Someone who drags a video in while the
    /// picker says 사진 meant to convert the video, and making them notice a
    /// segmented control first would be the app being pedantic.
    ///
    /// The format has to follow as well, not just the family. Dropping a PDF
    /// selected 문서 but left the format on `PDF로`, which takes Word and
    /// PowerPoint and refuses PDFs — so the drop came back as "이 도구가 다룰 수
    /// 있는 파일이 없습니다" for a file the tool handles perfectly well.
    ///
    /// Only ever changed when the current choice accepts *none* of what was
    /// dropped: quietly overriding a format the user deliberately picked would
    /// be worse than the error it avoids.
    func convertFiles(_ urls: [URL]) {
        let extensions = Set(urls.map { $0.pathExtension.lowercased() })
        if !extensions.contains(where: { conversionTarget.accepts.contains($0) }) {
            if let family = urls.compactMap(ConversionFamily.of).first, family != conversionFamily {
                conversionFamily = family
            }
            if let match = conversionFamily.targets.first(where: { target in
                extensions.contains(where: { target.accepts.contains($0) })
            }) {
                conversionTarget = match
            }
        }
        convert.load(urls, worker: conversionWorker)
    }

    func rerunConversion() {
        convert.rerun(conversionWorker)
    }

    func chooseFilesForConversion(startingAt directory: URL?) {
        chooseFiles(title: "바꿀 파일 선택", startingAt: directory) { convertFiles($0) }
    }

    // MARK: - 프린트

    func chooseFilesToPrint(startingAt directory: URL?) {
        chooseFiles(title: "인쇄할 파일 선택", startingAt: directory) { printing.add($0) }
    }

    /// 다른 화면의 결과를 프린터로 넘긴다. 화면도 함께 옮기는 이유는, 넘긴 뒤에 무엇이
    /// 몇 장 나갈지 보고 인쇄를 누르는 자리가 거기이기 때문이다. 여기서 저절로 인쇄하지는
    /// 않는다 — 종이가 나가는 일은 사람이 누른 뒤에 일어난다.
    func sendToPrinter(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        section = .print
        printing.add(urls)
    }

    // MARK: - 개발용 실행 인자

    /// `--open <path>…` hands files straight to whichever screen `--section`
    /// selected.
    ///
    /// The sibling of `--section`, and there for the same reason: reviewing a
    /// screen that has results on it should not mean driving the window with
    /// synthetic clicks and keystrokes, which land in whatever happens to be
    /// frontmost if the timing is off.
    func openLaunchFiles() {
        let arguments = CommandLine.arguments
        guard let start = arguments.firstIndex(of: "--open") else { return }
        let paths = arguments[(start + 1)...].prefix { !$0.hasPrefix("--") }
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        switch section {
        case .audioCleanup: cleanAudio(urls)
        case .upscale: upscalePhotos(urls)
        case .scan: correctScans(urls)
        case .convert: convertFiles(urls)
        case .compression: compress(fileURLs: urls)
        case .cutout: removeBackground(fileURLs: urls)
        case .pdf: pdfEditor.open(urls)
        case .print: printing.add(urls)
        default: break
        }
    }

    // MARK: - 개요

    /// What the 개요 screen reports for the tool row: how many things are being
    /// worked on right now across all of them.
    var busyToolCount: Int {
        [audioCleanup, upscale, scan, convert].filter(\.isRunning).count
            + (isCompressing ? 1 : 0)
            + (isRemovingBackground ? 1 : 0)
    }
}
