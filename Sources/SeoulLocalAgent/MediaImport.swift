import Foundation
import AVFoundation

/// Turns a lecture recording that is not already a local audio file — a video
/// file, or a video URL such as a recorded lecture on YouTube — into an ordinary
/// entry in the recording library, so the existing transcription and AI note
/// pipeline handles it unchanged. Everything runs locally: `yt-dlp` fetches the
/// media and `ffmpeg` extracts the audio, and nothing is uploaded anywhere.
struct MediaImporter {
    struct ImportedMedia {
        let url: URL
        let title: String
    }

    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts"]
    static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "aiff", "aif", "flac", "ogg", "opus", "caf", "wma", "amr", "mp4a"]

    private let runner = ProcessRunner()

    static var ytDLPPath: String? { executable(["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]) }
    static var ffmpegPath: String? { executable(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]) }

    private static func executable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }
    static func isAudio(_ url: URL) -> Bool { audioExtensions.contains(url.pathExtension.lowercased()) }

    static func looksLikeMediaURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    // MARK: - Remote video

    func importRemoteVideo(_ address: String, progress: @escaping @Sendable (String) async -> Void) async throws -> ImportedMedia {
        guard let ytDLP = Self.ytDLPPath else {
            throw AgentError.processFailed("yt-dlp를 찾지 못했습니다. `brew install yt-dlp` 후 다시 시도해 주세요.")
        }
        guard Self.ffmpegPath != nil else {
            throw AgentError.processFailed("ffmpeg를 찾지 못했습니다. `brew install ffmpeg` 후 다시 시도해 주세요.")
        }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeMediaURL(trimmed) else {
            throw AgentError.processFailed("올바른 영상 주소가 아닙니다.")
        }

        await progress("1/3 · 영상 정보를 확인하고 있습니다.")
        let metadata = try await self.metadata(for: trimmed, ytDLP: ytDLP)

        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "SeoulLocalAgent-Media-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        await progress("2/3 · 오디오만 내려받고 있습니다.")
        try await runner.runStreamingLines(ytDLP, [
            "--no-playlist", "--no-warnings", "--newline", "--progress",
            "--format", "bestaudio/best",
            "--extract-audio", "--audio-format", "m4a",
            "--output", workspace.appending(path: "source.%(ext)s").path,
            trimmed,
        ]) { line in
            guard let percent = Self.downloadPercent(in: line) else { return }
            Task { await progress("2/3 · 오디오 내려받는 중 \(percent)") }
        }

        guard let downloaded = try Self.firstMediaFile(in: workspace) else {
            throw AgentError.processFailed("내려받은 오디오 파일을 찾지 못했습니다.")
        }
        await progress("3/3 · 전사용 오디오로 변환하고 있습니다.")
        let destination = try await convertToTranscriptionAudio(downloaded, title: metadata)
        return ImportedMedia(url: destination, title: metadata)
    }

    private func metadata(for address: String, ytDLP: String) async throws -> String {
        let data = try await runner.run(ytDLP, ["--no-playlist", "--no-warnings", "--skip-download", "--dump-single-json", address])
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.processFailed("영상 정보를 읽지 못했습니다. 주소를 확인해 주세요.")
        }
        let title = (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "영상 \(Self.timestampSuffix())" : title
    }

    // MARK: - Local video

    func importLocalVideo(_ url: URL, progress: @escaping @Sendable (String) async -> Void) async throws -> ImportedMedia {
        guard Self.ffmpegPath != nil else {
            throw AgentError.processFailed("ffmpeg를 찾지 못했습니다. `brew install ffmpeg` 후 다시 시도해 주세요.")
        }
        await progress("영상에서 오디오를 추출하고 있습니다.")
        let title = url.deletingPathExtension().lastPathComponent
        let destination = try await convertToTranscriptionAudio(url, title: title)
        return ImportedMedia(url: destination, title: title)
    }

    // MARK: - Shared conversion

    /// Mono 16 kHz matches what the app's own recorder produces and what the ASR
    /// model consumes, so a three-hour lecture stays small on disk.
    private func convertToTranscriptionAudio(_ source: URL, title: String) async throws -> URL {
        guard let ffmpeg = Self.ffmpegPath else {
            throw AgentError.processFailed("ffmpeg를 찾지 못했습니다.")
        }
        let directory = try AudioRecorder.recordingsDirectory()
        // ffmpeg를 보관함에 직접 쓰게 두지 않는다. 이것도 색인을 마지막에 쓰는 MPEG-4라,
        // 변환 도중에 앱이 끝나거나 사용자가 취소하면 열리지 않는 반쪽 파일이 녹음 보관함에
        // 그대로 남는다 — 0초짜리 녹음이 하나 생긴 것처럼 보인다. 작업 폴더에서 다 만든
        // 뒤에 옮겨 놓으면, 보관함에는 완성된 것만 나타난다.
        let workspace = FileManager.default.temporaryDirectory
            .appending(path: "SeoulLocalAgent-Media-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let staged = workspace.appending(path: "converted.m4a")
        // ffmpeg's output is the destination file; anything it prints goes to stderr.
        _ = try await runner.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", source.path,
            "-vn", "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "48k",
            staged.path,
        ], expectsStandardOutput: false)
        guard FileManager.default.fileExists(atPath: staged.path) else {
            throw AgentError.processFailed("오디오 변환 결과 파일을 만들지 못했습니다.")
        }
        // 이름은 옮기기 직전에 고른다. 변환하는 동안 같은 이름이 생겼을 수 있다.
        let destination = Self.availableURL(in: directory, title: Self.safeFileName(title))
        try FileManager.default.moveItem(at: staged, to: destination)
        return destination
    }

    // MARK: - Helpers

    static func downloadPercent(in line: String) -> String? {
        guard line.hasPrefix("[download]") else { return nil }
        guard let range = line.range(of: "[0-9]+(\\.[0-9]+)?%", options: .regularExpression) else { return nil }
        return String(line[range])
    }

    static func safeFileName(_ title: String) -> String {
        let collapsed = title
            .replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(collapsed.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "영상 \(timestampSuffix())" : trimmed
    }

    static func availableURL(in directory: URL, title: String) -> URL {
        let candidate = directory.appending(path: "\(title).m4a")
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        for index in 2...99 {
            let numbered = directory.appending(path: "\(title) (\(index)).m4a")
            if !FileManager.default.fileExists(atPath: numbered.path) { return numbered }
        }
        return directory.appending(path: "\(title) \(timestampSuffix()).m4a")
    }

    private static func firstMediaFile(in directory: URL) throws -> URL? {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { !$0.lastPathComponent.hasPrefix(".") }
    }

    private static func timestampSuffix() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: Date())
    }
}
