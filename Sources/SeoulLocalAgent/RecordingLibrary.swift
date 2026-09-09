import Foundation
import SQLite3
import AVFoundation

enum RecordingSource: String, Codable { case app = "이 앱", voiceMemos = "음성 메모", file = "외부 파일" }

struct RecordingItem: Identifiable, Hashable {
    let id: String
    let source: RecordingSource
    let title: String
    let url: URL
    let date: Date
    let duration: TimeInterval
    let isLocallyAvailable: Bool
}

struct TranscriptSegment: Codable, Hashable, Identifiable {
    var id: String
    var start: Double?
    var end: Double?
    var speaker: String?
    var text: String
}

struct TranscriptionSettingsSnapshot: Codable, Hashable {
    var asrModel: ASRModelChoice?
    var diarization: DiarizationChoice?
    var timestampMode: TranscriptionTimestampMode?
    var language: TranscriptionLanguage?

    var displayName: String {
        let model = asrModel?.title ?? "이전 버전"
        let time = timestampMode?.title ?? "시간 설정 미상"
        let speaker = diarization?.title ?? "화자 설정 미상"
        return "\(model) · \(time) · \(speaker)"
    }
}

struct TranscriptRun: Codable, Identifiable, Hashable {
    var id: UUID
    var recordingID: String
    var createdAt: Date
    var completedAt: Date
    var duration: TimeInterval
    var settings: TranscriptionSettingsSnapshot
    var backend: String?
    var text: String
    var segments: [TranscriptSegment]
    var engineVersion: String
    var isLegacy: Bool
}

enum TranscriptOrganizationKind: String, Codable, CaseIterable, Identifiable {
    case lecture, meeting, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lecture: "수업"
        case .meeting: "회의"
        case .general: "일반"
        }
    }
}

enum TranscriptOrganizationDetail: String, Codable, CaseIterable, Identifiable {
    case sourcePreserving, balanced, concise
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sourcePreserving: "원문 보존 · 권장"
        case .balanced: "균형"
        case .concise: "간략"
        }
    }
}

struct TranscriptOrganizationRun: Codable, Identifiable, Hashable {
    var id: UUID
    var transcriptRunID: UUID
    var createdAt: Date
    var completedAt: Date
    var duration: TimeInterval
    var kind: TranscriptOrganizationKind
    var detail: TranscriptOrganizationDetail
    var model: String
    var promptSnapshot: String
    var text: String
}

struct ArchivedRecordingMetadata: Codable, Hashable {
    var id: String
    var title: String
    var path: String
    var date: Date
    var duration: TimeInterval

    var item: RecordingItem? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return RecordingItem(id: id, source: .file, title: title, url: url, date: date, duration: duration, isLocallyAvailable: true)
    }
}

struct TranscriptArchive: Codable {
    var schemaVersion = 2
    var runsByRecording: [String: [TranscriptRun]] = [:]
    var organizationsByTranscript: [String: [TranscriptOrganizationRun]] = [:]
    var externalRecordings: [String: ArchivedRecordingMetadata] = [:]
    /// Not persisted; set only while decoding a pre-v2 archive.
    var didMigrateLegacyText = false

    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "SeoulLocalAgent/transcripts.json")

    private enum CodingKeys: String, CodingKey { case schemaVersion, runsByRecording, organizationsByTranscript, externalRecordings, texts }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        runsByRecording = try container.decodeIfPresent([String: [TranscriptRun]].self, forKey: .runsByRecording) ?? [:]
        organizationsByTranscript = try container.decodeIfPresent([String: [TranscriptOrganizationRun]].self, forKey: .organizationsByTranscript) ?? [:]
        externalRecordings = try container.decodeIfPresent([String: ArchivedRecordingMetadata].self, forKey: .externalRecordings) ?? [:]
        if let legacy = try container.decodeIfPresent([String: String].self, forKey: .texts), !legacy.isEmpty {
            didMigrateLegacyText = true
            for (recordingID, text) in legacy where !text.isEmpty && text != "음성을 인식하지 못했습니다." {
                let run = TranscriptRun(
                    id: UUID(), recordingID: recordingID, createdAt: .distantPast, completedAt: .distantPast,
                    duration: 0, settings: .init(), backend: nil, text: text, segments: [],
                    engineVersion: "legacy", isLegacy: true
                )
                runsByRecording[recordingID, default: []].append(run)
            }
        }
        schemaVersion = 2
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(runsByRecording, forKey: .runsByRecording)
        try container.encode(organizationsByTranscript, forKey: .organizationsByTranscript)
        try container.encode(externalRecordings, forKey: .externalRecordings)
    }

    static func load(url: URL = Self.url) -> Self {
        guard let data = try? Data(contentsOf: url), var archive = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        // Rewrite on launch only when the legacy shape actually had to be migrated,
        // instead of rewriting the whole archive every single time the app starts.
        if archive.didMigrateLegacyText {
            archive.didMigrateLegacyText = false
            archive.save(url: url)
        }
        return archive
    }

    func save(url: URL = Self.url) {
        _ = saveReportingFailure(url: url)
    }

    /// Returns a message instead of swallowing the error: losing a transcript that
    /// took minutes of local inference must never be silent.
    func saveReportingFailure(url: URL = Self.url) -> String? {
        do {
            try LocalFileStorage.write(try JSONEncoder().encode(self), to: url)
            return nil
        } catch {
            return "전사 기록을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func runs(for recordingID: String) -> [TranscriptRun] {
        (runsByRecording[recordingID] ?? []).sorted { $0.completedAt > $1.completedAt }
    }

    func organizations(for transcriptID: UUID) -> [TranscriptOrganizationRun] {
        (organizationsByTranscript[transcriptID.uuidString] ?? []).sorted { $0.completedAt > $1.completedAt }
    }
}

enum RecordingLibrary {
    static let selectedVoiceMemosFolderKey = "selectedVoiceMemosFolder"

    /// - Parameters:
    ///   - recording: the take the microphone is writing right now, if any. It is
    ///     the one file here that is *supposed* to have no index yet, so the repair
    ///     pass has to leave it alone.
    ///   - status: what to show on the library's status line. Rebuilding a take that
    ///     was cut off takes seconds, and a list that simply sits there for that long
    ///     looks like a hang.
    static func load(skipping recording: URL? = nil, status: (@Sendable (String) -> Void)? = nil) -> [RecordingItem] {
        appRecordings(skipping: recording, status: status) + voiceMemoRecordings()
    }

    private static func appRecordings(skipping recording: URL?, status: (@Sendable (String) -> Void)?) -> [RecordingItem] {
        guard let directory = try? AudioRecorder.recordingsDirectory(), let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        // 마이크가 지금 쓰고 있는 파일은 아예 목록에 넣지 않는다. 아래의 `recording`은
        // 훑기를 시작하기 전에 찍은 사진이라 그 사이에 시작된 녹음을 모르지만, 이 등록은
        // 지금을 말한다. 자라고 있는 녹음은 아직 재생할 수 없으므로, 보관함에 들어가면
        // 열 때마다 실패하는 0초짜리 한 줄이 된다.
        let takes = urls.filter { $0.pathExtension.lowercased() == "m4a" && !LiveTakes.shared.contains($0) }
        // A take left unfinished by a quit or a crash is rebuilt here, before anything
        // measures it, so it enters the library with its real length instead of as a
        // 0초 entry that only ever produces an error when played.
        for url in takes where url.standardizedFileURL != recording?.standardizedFileURL {
            guard RecordingRepair.isUnfinished(url) else { continue }
            status?("중단된 녹음을 복구하는 중: \(url.deletingPathExtension().lastPathComponent)")
            RecordingRepair.repairIfUnfinished(url)
        }
        return takes.compactMap { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return RecordingItem(id: "app:\(url.path)", source: .app, title: url.deletingPathExtension().lastPathComponent, url: url, date: date, duration: duration(of: url), isLocallyAvailable: true)
        }
    }

    private static func voiceMemoRecordings() -> [RecordingItem] {
        guard let root = voiceMemosDirectory() else { return [] }
        let database = root.appending(path: "CloudRecordings.db")
        if let records = voiceMemoDatabaseRecords(database: database, root: root), !records.isEmpty { return records }
        return voiceMemoFileRecords(root: root)
    }

    private static func voiceMemoDatabaseRecords(database: URL, root: URL) -> [RecordingItem]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        let query = "SELECT ZPATH, ZDATE, ZDURATION, ZCUSTOMLABEL, ZUNIQUEID FROM ZCLOUDRECORDING WHERE ZPATH IS NOT NULL ORDER BY ZDATE DESC;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var items: [RecordingItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pathPointer = sqlite3_column_text(statement, 0) else { continue }
            let relativePath = String(cString: pathPointer)
            let url = root.appending(path: relativePath)
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 1))
            let databaseDuration = sqlite3_column_double(statement, 2)
            let label = sqlite3_column_text(statement, 3).map { String(cString: $0) }
            let uniqueID = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? relativePath
            let playableDuration = duration(of: url)
            let title = usableVoiceMemoTitle(label) ?? url.deletingPathExtension().lastPathComponent
            items.append(RecordingItem(id: "voice:\(uniqueID)", source: .voiceMemos, title: title, url: url, date: date, duration: databaseDuration > 0 ? databaseDuration : playableDuration, isLocallyAvailable: playableDuration > 0))
        }
        return items
    }

    private static func voiceMemoFileRecords(root: URL) -> [RecordingItem] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let extensions = Set(["m4a", "qta"])
        return enumerator.compactMap { item -> RecordingItem? in
            guard let url = item as? URL, extensions.contains(url.pathExtension.lowercased()) else { return nil }
            let playableDuration = duration(of: url)
            let date = dateFromVoiceMemoFilename(url.lastPathComponent) ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return RecordingItem(id: "voice:file:\(url.path)", source: .voiceMemos, title: url.deletingPathExtension().lastPathComponent, url: url, date: date, duration: playableDuration, isLocallyAvailable: playableDuration > 0)
        }
    }

    private static func usableVoiceMemoTitle(_ label: String?) -> String? {
        guard let label, !label.isEmpty, ISO8601DateFormatter().date(from: label) == nil else { return nil }
        return label
    }

    static func dateFromVoiceMemoFilename(_ filename: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd HHmmss"
        return formatter.date(from: String(filename.prefix(15)))
    }

    static func saveVoiceMemosDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: selectedVoiceMemosFolderKey)
    }

    static func configuredVoiceMemosDirectory() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: selectedVoiceMemosFolderKey) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func voiceMemosDirectory() -> URL? {
        if let configured = configuredVoiceMemosDirectory(), FileManager.default.fileExists(atPath: configured.path) { return configured }
        let defaultDirectory = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: defaultDirectory.path) ? defaultDirectory : nil
    }

    /// Opening every recording with `AVAudioPlayer` on each refresh made the
    /// library reload cost grow with the size of the Voice Memos folder. The result
    /// is cached per file identity so only new or changed files are decoded.
    private static func duration(of url: URL) -> TimeInterval {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.path)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? -1)"
        if let cached = DurationCache.shared.value(for: key) { return cached }
        let measured = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
        DurationCache.shared.store(measured, for: key)
        return measured
    }
}

private final class DurationCache: @unchecked Sendable {
    static let shared = DurationCache()
    private let lock = NSLock()
    private var values: [String: TimeInterval] = [:]

    func value(for key: String) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func store(_ value: TimeInterval, for key: String) {
        lock.lock()
        // A recording that is still downloading from iCloud measures as zero;
        // caching that would keep it looking unavailable after it arrives.
        if value > 0 { values[key] = value }
        if values.count > 2_000 { values.removeAll() }
        lock.unlock()
    }
}
