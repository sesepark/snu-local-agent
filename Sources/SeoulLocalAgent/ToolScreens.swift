import SwiftUI
import PhotosUI

// MARK: - 소리 다듬기

/// Cleans up a recording, and is deliberately built from the same pieces as
/// 용량 줄이기: the name in the title bar, a drop well first in the body, the
/// settings in one glass panel, and the primary action at the right of the
/// toolbar.
struct AudioCleanupView: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        BatchToolScreen(
            section: .audioCleanup,
            model: controller.audioCleanup,
            dropSymbol: "waveform.path.badge.minus",
            dropHint: "여기로 녹음이나 영상을 드롭하세요 · M4A · MP3 · WAV · MOV · MP4",
            busyHint: "소리를 다듬는 중입니다 · 끝나거나 중단한 뒤에 넣어 주세요",
            emptyMessage: "아직 다듬은 녹음이 없습니다.\n위에 파일을 드롭하거나 툴바에서 녹음 보관함을 여세요.",
            onURLs: { controller.cleanAudio($0) },
            choose: { controller.chooseAudioForCleanup(startingAt: $0) }
        ) {
            settings
        }
        .toolbar {
            BatchToolToolbar(
                model: controller.audioCleanup,
                choose: { controller.chooseAudioForCleanup(startingAt: nil) },
                rerun: { controller.rerunAudioCleanup() }
            ) {
                Button("녹음 보관함에서…", systemImage: "waveform") {
                    controller.chooseAudioForCleanup(startingAt: try? AudioRecorder.recordingsDirectory())
                }
                .buttonStyle(.glassProminent)
                .tint(.snuBlue)
                .help("이 앱으로 녹음한 파일에서 바로 고릅니다")
                .toolbarKeepsTitle()
            }
        }
    }

    private var settings: some View {
        ToolSettingsPanel(explanation: explanation) {
            HStack(spacing: Spacing.l) {
                LabeledContent("방식") {
                    Picker("방식", selection: $controller.audioCleanupMethod) {
                        ForEach(AudioCleanupMethod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
                .fixedSize()

                LabeledContent("정도") {
                    Picker("정도", selection: $controller.audioCleanupStrength) {
                        ForEach(AudioCleanupStrength.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                }
                .fixedSize()
                // The strength dial belongs to the gate; the model decides for
                // itself how much to remove, so showing it there would be a
                // control that does nothing.
                .disabled(controller.audioCleanupMethod == .model)
                .opacity(controller.audioCleanupMethod == .model ? 0.4 : 1)

                Spacer()
            }
            .animation(.appControl, value: controller.audioCleanupMethod)

            HStack(spacing: Spacing.l) {
                Picker("저장 형식", selection: $controller.audioCleanupFormat) {
                    ForEach(AudioOutputFormat.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 260)

                Toggle("음량을 고르게 맞추기", isOn: $controller.audioCleanupNormalises)
                    .help("전체를 편안한 크기로 올리되 찢어지지 않게 제한합니다")
                Spacer()
            }
        }
        .disabled(controller.audioCleanup.isRunning)
    }

    private var explanation: String {
        var lines = [controller.audioCleanupMethod.detail]
        if controller.audioCleanupMethod == .gate {
            lines.append(controller.audioCleanupStrength.detail)
        } else if !MediaDaemon.isInstalled {
            lines.append("정밀 모드를 쓰려면 터미널에서 `scripts/setup-media-env.sh`를 먼저 실행해 주세요.")
        }
        return lines.joined(separator: " ")
    }
}

// MARK: - 화질 올리기

struct UpscaleView: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        BatchToolScreen(
            section: .upscale,
            model: controller.upscale,
            dropSymbol: "arrow.up.left.and.arrow.down.right",
            dropHint: "여기로 사진이나 폴더를 드롭하세요 · JPEG · PNG · HEIC",
            busyHint: "사진을 키우는 중입니다 · 끝나거나 중단한 뒤에 넣어 주세요",
            emptyMessage: "아직 키운 사진이 없습니다.\n위에 사진을 드롭하거나 툴바에서 사진 앱을 여세요.",
            onURLs: { controller.upscalePhotos($0) },
            choose: { controller.choosePhotosForUpscale(startingAt: $0) }
        ) {
            settings
        }
        .toolbar {
            BatchToolToolbar(
                model: controller.upscale,
                choose: { controller.choosePhotosForUpscale(startingAt: nil) },
                rerun: { controller.rerunUpscale() }
            ) {
                PhotosImportButton(filter: .images, model: controller.upscale) {
                    controller.upscalePhotos($0)
                }
            }
        }
    }

    private var settings: some View {
        ToolSettingsPanel(explanation: explanation) {
            HStack(spacing: Spacing.l) {
                Picker("방식", selection: $controller.upscaleModel) {
                    ForEach(UpscaleModel.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 300)

                Picker("저장 형식", selection: $controller.upscaleFormat) {
                    ForEach(UpscaleFormat.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 220)
                Spacer()
            }
        }
        .disabled(controller.upscale.isRunning)
    }

    private var explanation: String {
        var lines = [controller.upscaleModel.detail]
        lines.append("긴 변이 \(UpscaleRequest().maximumLongEdge)px을 넘으면 그 크기에 맞춰 줄입니다.")
        if controller.upscaleModel.usesRunner, !MediaDaemon.isInstalled {
            lines.append("이 방식을 쓰려면 터미널에서 `scripts/setup-media-env.sh`를 먼저 실행해 주세요.")
        }
        return lines.joined(separator: " ")
    }
}

// MARK: - 스캔 보정

struct ScanCorrectionView: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        BatchToolScreen(
            section: .scan,
            model: controller.scan,
            dropSymbol: "doc.viewfinder",
            dropHint: "여기로 찍은 유인물 사진을 드롭하세요 · 여러 장을 한 번에 넣어도 됩니다",
            busyHint: "보정하는 중입니다 · 끝나거나 중단한 뒤에 넣어 주세요",
            emptyMessage: "아직 보정한 문서가 없습니다.\n위에 사진을 드롭하거나 툴바에서 사진 앱을 여세요.",
            onURLs: { controller.correctScans($0) },
            choose: { controller.choosePhotosForScan(startingAt: $0) }
        ) {
            settings
        }
        .toolbar {
            BatchToolToolbar(
                model: controller.scan,
                choose: { controller.choosePhotosForScan(startingAt: nil) },
                rerun: { controller.rerunScan() },
                extra: {
                    Button("한 PDF로 저장…", systemImage: "doc.on.doc") { controller.saveScansAsOnePDF() }
                        .disabled(!controller.scan.hasFinished || controller.scanFormat != .pdf)
                        .help(controller.scanFormat == .pdf
                              ? "보정한 쪽을 순서대로 묶어 PDF 한 개로 저장합니다"
                              : "PDF로 내보낼 때만 묶을 수 있습니다")
                }
            ) {
                PhotosImportButton(filter: .images, model: controller.scan) {
                    controller.correctScans($0)
                }
            }
        }
    }

    private var settings: some View {
        ToolSettingsPanel(explanation: controller.scanFinish.detail + " " + controller.scanResolution.detail) {
            HStack(spacing: Spacing.l) {
                LabeledContent("마무리") {
                    Picker("마무리", selection: $controller.scanFinish) {
                        ForEach(ScanFinish.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 250)
                }
                .fixedSize()

                LabeledContent("해상도") {
                    Picker("해상도", selection: $controller.scanResolution) {
                        ForEach(ScanResolution.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 210)
                }
                .fixedSize()
                Spacer()
            }

            HStack(spacing: Spacing.l) {
                Picker("저장 형식", selection: $controller.scanFormat) {
                    ForEach(ScanOutputFormat.allCases) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 220)

                Toggle("문서 테두리를 찾아 반듯하게 자르기", isOn: $controller.scanDetectsEdges)
                    .help("끄면 자르지 않고 밝기와 그늘만 보정합니다")
                Spacer()
            }
        }
        .disabled(controller.scan.isRunning)
    }
}

// MARK: - 형식 변환

struct FileConversionView: View {
    @ObservedObject var controller: AutomationController

    var body: some View {
        BatchToolScreen(
            section: .convert,
            model: controller.convert,
            dropSymbol: "arrow.triangle.2.circlepath",
            dropHint: "여기로 파일이나 폴더를 드롭하세요 · 넣은 것에 맞춰 종류가 바뀝니다",
            busyHint: "변환하는 중입니다 · 끝나거나 중단한 뒤에 넣어 주세요",
            emptyMessage: "아직 변환한 파일이 없습니다.\n바꿀 종류와 형식을 고르고 파일을 넣어 주세요.",
            onURLs: { controller.convertFiles($0) },
            choose: { controller.chooseFilesForConversion(startingAt: $0) }
        ) {
            settings
        }
        .toolbar {
            BatchToolToolbar(
                model: controller.convert,
                choose: { controller.chooseFilesForConversion(startingAt: nil) },
                rerun: { controller.rerunConversion() }
            ) {
                PhotosImportButton(filter: .any(of: [.images, .videos]), model: controller.convert) {
                    controller.convertFiles($0)
                }
            }
        }
    }

    private var settings: some View {
        ToolSettingsPanel(explanation: explanation) {
            HStack(spacing: Spacing.l) {
                LabeledContent("종류") {
                    Picker("종류", selection: $controller.conversionFamily) {
                        ForEach(ConversionFamily.allCases) { family in
                            Label(family.title, systemImage: family.symbol).tag(family)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320)
                }
                .fixedSize()

                Picker("바꿀 형식", selection: $controller.conversionTarget) {
                    ForEach(controller.conversionFamily.targets) { Text($0.title).tag($0) }
                }
                .frame(maxWidth: 260)
                Spacer()
            }
            .animation(.appControl, value: controller.conversionFamily)

            if controller.conversionTarget.family == .image, controller.conversionTarget != .png {
                HStack(spacing: Spacing.s) {
                    Text("화질").font(.callout)
                    Slider(value: $controller.conversionQuality, in: 0.4 ... 1, step: 0.05)
                        .frame(maxWidth: 220)
                        .tint(.snuBlue)
                    Text("\(Int(controller.conversionQuality * 100))")
                        .font(.callout)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                    Spacer()
                }
            }
        }
        .disabled(controller.convert.isRunning)
    }

    private var explanation: String {
        var lines: [String] = []
        let detail = controller.conversionTarget.detail
        if !detail.isEmpty { lines.append(detail) }
        if let missing = controller.conversionTarget.missingDependency { lines.append(missing) }
        if lines.isEmpty {
            lines.append("\(controller.conversionFamily.title) 파일을 \(controller.conversionTarget.title)로 바꿉니다. 원본은 그대로 남습니다.")
        }
        return lines.joined(separator: " ")
    }
}
