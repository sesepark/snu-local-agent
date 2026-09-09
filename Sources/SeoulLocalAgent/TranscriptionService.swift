import Foundation

struct TranscriptionService {
    struct Result {
        let text: String
        let segments: [TranscriptSegment]
        let backend: String?
    }
    private let runner = ProcessRunner()
    private let executable = ProjectRoot.resolving(".venv-transcription/bin/python")
    private let runnerScript = ProjectRoot.resolving("scripts/transcribe_runner.py")
    private static let tokenService = "kr.ac.snu.local-agent.pyannote"
    private static let tokenAccount = "speaker-diarization"

    static func saveDiarizationToken(_ token: String) throws {
        try Keychain.save(token, service: tokenService, account: tokenAccount)
    }

    func transcribe(_ fileURL: URL, asrModel: ASRModelChoice, diarization: DiarizationChoice, timestampMode: TranscriptionTimestampMode, language: TranscriptionLanguage, progress: @escaping @Sendable (String) async -> Void) async throws -> Result {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AgentError.processFailed("드롭한 녹음 파일을 찾을 수 없습니다.")
        }
        // The transcription runner lives in the project checkout, not in the app
        // bundle, so say plainly which piece is missing instead of failing with a
        // bare launch error if the folder was moved or the venv was removed.
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AgentError.processFailed("전사용 Python 환경을 찾지 못했습니다: \(executable)")
        }
        guard FileManager.default.fileExists(atPath: runnerScript) else {
            throw AgentError.processFailed("전사 실행 스크립트를 찾지 못했습니다: \(runnerScript)")
        }
        // The runner decodes anything that is not plain WAV through ffmpeg, so say so
        // in Korean up front rather than letting the library's English PATH error out.
        guard MediaImporter.ffmpegPath != nil else {
            throw AgentError.processFailed("ffmpeg를 찾지 못했습니다. 터미널에서 `brew install ffmpeg` 후 다시 시도해 주세요.")
        }
        // The quantized models are built on this machine, not downloaded, so an
        // absent folder cannot repair itself the way a Hugging Face cache does.
        // Say which command rebuilds it instead of surfacing a Python traceback.
        if let local = Self.localModelDirectory(for: asrModel),
           !FileManager.default.fileExists(atPath: local.appending(path: "weights.safetensors").path) {
            let command = Self.conversionCommand(for: asrModel) ?? ""
            throw AgentError.processFailed("‘\(asrModel.title)’ 모델이 아직 준비되지 않았습니다. 프로젝트 폴더에서 `\(command)`를 실행한 뒤 다시 시도해 주세요.")
        }
        let token = try? Keychain.string(service: Self.tokenService, account: Self.tokenAccount)
        guard !diarization.isEnabled || (token?.isEmpty == false) else {
            throw AgentError.missingCredential("화자 분리를 위해 Hugging Face의 pyannote 토큰을 설정에 저장해 주세요.")
        }
        let outputDirectory = FileManager.default.temporaryDirectory.appending(path: "SeoulLocalAgent-Transcript-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let statusURL = outputDirectory.appending(path: "status.json")

        await progress("1/4 · 전사 모델을 처음 준비하고 있습니다.")
        let monitor = Task {
            var previousBytes: Int64 = 0
            var stableTicks = 0
            while !Task.isCancelled {
                if let status = Self.readStatus(at: statusURL) {
                    await progress(Self.statusProgress(status))
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                let bytes = Self.directorySize(at: Self.modelCacheDirectory(for: asrModel))
                let expected = Self.expectedModelBytes(for: asrModel)
                let downloaded = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                if bytes >= expected, bytes == previousBytes { stableTicks += 1 } else { stableTicks = 0 }
                previousBytes = bytes
                let stage: String
                if bytes < expected {
                    stage = "1/4 · 전사 모델 다운로드·준비 중 (현재 \(downloaded))"
                } else if stableTicks < 5 {
                    stage = "2/4 · 음성 인식 중"
                } else {
                    stage = "3/4 · 화자 분리 중"
                }
                // Status file updates are authoritative once the runner starts.
                if Self.readStatus(at: statusURL) == nil { await progress(stage) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        defer { monitor.cancel() }
        var arguments = [
            runnerScript,
            fileURL.path,
            "--output-dir", outputDirectory.path,
            "--status-file", statusURL.path,
            "--asr-model", asrModel.runnerValue,
            "--diarization", diarization.runnerValue,
        ]
        if !timestampMode.includesTimestamps { arguments.append("--no-timestamps") }
        if let language = language.runnerValue { arguments += ["--language", language] }
        // The runner writes the transcript to `outputDirectory` and reports real
        // failures with a non-zero exit, so its stderr is progress noise, not an
        // error. Hugging Face's "Fetching N files" bars land there on every run.
        do {
            _ = try await runner.run(
                executable,
                arguments,
                environment: [
                    "PYANNOTE_AUTH_TOKEN": token ?? "",
                    "HF_HUB_DISABLE_PROGRESS_BARS": "1",
                    "TQDM_DISABLE": "1",
                ],
                expectsStandardOutput: false
            )
        } catch let error as AgentError {
            throw Self.readableFailure(error, fileURL: fileURL)
        }
        await progress("4/4 · 전사 결과를 정리하고 있습니다.")

        let object = try Self.transcriptObject(in: outputDirectory, excluding: statusURL)
        let segments = try parseSegments(object)
        let text = render(segments, fallbackText: object["text"] as? String, includeTimestamps: timestampMode.includesTimestamps)
        guard !text.isEmpty else {
            throw AgentError.processFailed("음성을 감지하지 못했습니다. 무음이거나 너무 짧은 녹음인지 확인해 주세요.")
        }
        return Result(text: text, segments: segments, backend: Self.readStatus(at: statusURL)?.backend)
    }

    private func parseSegments(_ object: [String: Any]) throws -> [TranscriptSegment] {
        let segments = (object["segments"] as? [[String: Any]]) ?? (object["chunks"] as? [[String: Any]]) ?? []
        guard !segments.isEmpty else {
            let text = (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else {
                throw AgentError.processFailed("음성을 감지하지 못했습니다. 무음이거나 너무 짧은 녹음인지 확인해 주세요.")
            }
            return [TranscriptSegment(id: "segment-0", start: nil, end: nil, speaker: nil, text: text)]
        }
        return segments.enumerated().compactMap { index, segment in
            let text = (segment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                id: "segment-\(index)",
                start: Self.seconds(segment["start"]),
                end: Self.seconds(segment["end"]),
                speaker: segment["speaker"] as? String,
                text: text
            )
        }
    }

    private func render(_ segments: [TranscriptSegment], fallbackText: String?, includeTimestamps: Bool) -> String {
        if segments.isEmpty { return fallbackText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        return segments.map { segment in
            if let speaker = segment.speaker {
                if includeTimestamps {
                    return "[\(Self.timeString(segment.start))–\(Self.timeString(segment.end))] \(speaker)\n\(segment.text)"
                }
                return "\(speaker)\n\(segment.text)"
            }
            if includeTimestamps {
                return "[\(Self.timeString(segment.start))–\(Self.timeString(segment.end))]\n\(segment.text)"
            }
            return segment.text
        }.joined(separator: "\n\n")
    }

    private static func seconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func timeString(_ value: Any?) -> String {
        let seconds: Double
        if let number = value as? NSNumber { seconds = number.doubleValue }
        else if let string = value as? String, let parsed = Double(string) { seconds = parsed }
        else { return "--:--" }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// The runner forwards whatever the Python side raised, and a decode failure
    /// arrives as ffmpeg's whole multi-line version banner. Say in Korean what the
    /// user can act on, and never paste a screenful of English into the UI.
    static func readableFailure(_ error: AgentError, fileURL: URL) -> AgentError {
        guard case .processFailed(let message) = error else { return error }
        if message.contains("Failed to load audio") || message.contains("moov atom not found")
            || message.contains("Invalid data found") {
            return .processFailed("녹음 파일을 읽지 못했습니다: \(fileURL.lastPathComponent). 아직 녹음 중이거나 파일이 손상된 경우입니다. 녹음을 중지한 뒤 다시 시도해 주세요.")
        }
        let lines = message.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 4 else { return error }
        return .processFailed(lines.prefix(4).joined(separator: "\n") + "\n…")
    }

    static func transcriptObject(in directory: URL, excluding statusURL: URL) throws -> [String: Any] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let statusPath = statusURL.standardizedFileURL.path

        for jsonURL in files where jsonURL.pathExtension.lowercased() == "json" {
            guard jsonURL.standardizedFileURL.path != statusPath,
                  let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any]
            else { continue }

            // Directory enumeration order is unspecified. Accept only the
            // runner's transcript schema, never status.json or unrelated JSON.
            if object["text"] != nil || object["segments"] != nil || object["chunks"] != nil {
                return object
            }
        }

        throw AgentError.processFailed("전사 결과 JSON 파일을 찾지 못했습니다.")
    }

    /// The quantized models this app builds itself, rather than downloads. Their
    /// folders are the whole model, so a missing folder is a missing model — the
    /// Hugging Face choices below can still repair themselves by downloading.
    static func localModelDirectory(for model: ASRModelChoice) -> URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        switch model {
        case .qwen06B8Bit:
            return home.appending(path: ".cache/seoul-local-agent/Qwen3-ASR-0.6B-8bit", directoryHint: .isDirectory)
        case .qwen17B:
            return home.appending(path: ".cache/seoul-local-agent/Qwen3-ASR-1.7B-8bit", directoryHint: .isDirectory)
        case .qwen06B, .qwen17BSpeculative:
            return nil
        }
    }

    /// Which conversion produces the folder above, named the way the user would
    /// type it, so a missing model is a one-line fix instead of a search.
    static func conversionCommand(for model: ASRModelChoice) -> String? {
        switch model {
        case .qwen06B8Bit: ".venv-transcription/bin/python scripts/convert-qwen3-asr-8bit.py 0.6B"
        case .qwen17B: ".venv-transcription/bin/python scripts/convert-qwen3-asr-8bit.py 1.7B"
        case .qwen06B, .qwen17BSpeculative: nil
        }
    }

    /// The pre-status progress hint must watch the cache of the model that was
    /// actually selected; a fixed 1.7B path reported 0 bytes for every other choice.
    private static func modelCacheDirectory(for model: ASRModelChoice) -> URL {
        if let local = localModelDirectory(for: model) { return local }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        switch model {
        case .qwen06B:
            return home.appending(path: ".cache/huggingface/hub/models--Qwen--Qwen3-ASR-0.6B", directoryHint: .isDirectory)
        default:
            return home.appending(path: ".cache/huggingface/hub/models--Qwen--Qwen3-ASR-1.7B", directoryHint: .isDirectory)
        }
    }

    private static func expectedModelBytes(for model: ASRModelChoice) -> Int64 {
        switch model {
        case .qwen06B8Bit: 900_000_000
        case .qwen06B: 1_700_000_000
        case .qwen17B: 2_300_000_000
        case .qwen17BSpeculative: 4_200_000_000
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return enumerator.reduce(into: Int64(0)) { total, item in
            guard let file = item as? URL,
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize else { return }
            total += Int64(size)
        }
    }

    private struct RunnerStatus: Decodable {
        let stage: String
        let detail: String
        let progress: Double?
        let backend: String?
    }

    private static func readStatus(at url: URL) -> RunnerStatus? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RunnerStatus.self, from: data)
    }

    private static func statusProgress(_ status: RunnerStatus) -> String {
        let prefix: String
        switch status.stage {
        case "asr": prefix = "2/4"
        case "diarization": prefix = "3/4"
        case "writing", "completed": prefix = "4/4"
        default: prefix = "1/4"
        }
        return "\(prefix) · \(status.detail)"
    }
}
