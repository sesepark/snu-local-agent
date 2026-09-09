import Foundation

/// What the reader has said about a recording: what to call it, and what it
/// belongs with.
///
/// The library had neither. Fifty takes accumulated under names the recorder
/// generated — `녹음 2026-08-25 154002` — and the only ordering was by date, so
/// finding last month's 회로이론 lecture meant opening takes one at a time and
/// listening. The file itself is never touched: Voice Memos owns its database
/// and the app's own recordings are addressed by path, so a name typed here is
/// stored beside the recording's identifier rather than written over it.
struct RecordingLabels: Codable, Equatable {
    /// Empty means "keep the filename". Stored separately so clearing the field
    /// restores the original name instead of leaving an empty card.
    var title: String = ""
    var tags: [String] = []
    var updatedAt = Date()

    var isBlank: Bool { title.isEmpty && tags.isEmpty }

    init(title: String = "", tags: [String] = []) {
        self.title = title
        self.tags = tags
    }

    /// Hand-written for the same reason `BriefingMark`'s is: a synthesised
    /// decoder throws on a key that a later version added, and `load()` answers
    /// a decode failure with an empty store — which would silently discard every
    /// name and tag the user had typed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

/// Tag text the app is willing to store.
///
/// One shape only: trimmed, internal whitespace collapsed, length-capped, and
/// compared case- and space-insensitively so `회로이론`, `회로 이론` and
/// `회로이론 ` cannot become three separate chips for one course.
enum RecordingTag {
    static let maxLength = 24
    static let maxPerRecording = 8

    static func normalized(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "#,"))
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }

    /// The key two spellings of the same tag share.
    static func key(_ tag: String) -> String {
        tag.replacingOccurrences(of: " ", with: "").lowercased()
    }

    /// Accepts a whole field at once, so a paste of "회로이론, 3주차" becomes two
    /// tags rather than one long one.
    static func parse(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in raw.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            guard let tag = normalized(String(piece)), seen.insert(key(tag)).inserted else { continue }
            result.append(tag)
            if result.count >= maxPerRecording { break }
        }
        return result
    }
}

struct RecordingLabelStore: Sendable {
    private let url: URL

    init(directory: URL? = nil) {
        let root = directory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "recording-labels.json")
    }

    func load() -> [String: RecordingLabels] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: RecordingLabels].self, from: data) else { return [:] }
        return value
    }

    func save(_ labels: [String: RecordingLabels]) throws {
        // A recording whose name and tags were both cleared is not worth a line
        // in the file.
        try LocalFileStorage.write(try JSONEncoder().encode(labels.filter { !$0.value.isBlank }), to: url)
    }
}

/// The 녹음 보관함's names, tags, filter and grouping.
@MainActor
final class RecordingOrganizer: ObservableObject {
    @Published private(set) var labels: [String: RecordingLabels] = [:]
    /// Tags the reader is filtering by. Several means "all of these", not "any":
    /// picking 회로이론 and then 시험 should narrow, which is what stacking chips
    /// looks like it does.
    @Published var selectedTags: Set<String> = []
    @Published var search = ""
    @Published var groupsByTag = false
    @Published var error: String?

    private let store: RecordingLabelStore

    init(store: RecordingLabelStore = RecordingLabelStore()) {
        self.store = store
        labels = store.load()
    }

    // MARK: - 읽기

    func labels(for id: String) -> RecordingLabels { labels[id] ?? RecordingLabels() }

    func tags(for id: String) -> [String] { labels(for: id).tags }

    /// The name to show. Falls back to whatever the recorder called the file, so
    /// an untitled recording is never a blank card.
    func displayTitle(for recording: RecordingItem) -> String {
        let custom = labels(for: recording.id).title.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? recording.title : custom
    }

    func hasCustomTitle(_ recording: RecordingItem) -> Bool {
        !labels(for: recording.id).title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Every tag in use, most-used first and alphabetical within a count, which
    /// puts the courses the reader actually records at the front of the filter
    /// bar instead of whatever sorts first.
    var allTags: [String] {
        var counts: [String: (tag: String, count: Int)] = [:]
        for labels in labels.values {
            for tag in labels.tags {
                let key = RecordingTag.key(tag)
                counts[key] = (counts[key]?.tag ?? tag, (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag
        }.map(\.tag)
    }

    func count(of tag: String) -> Int {
        let key = RecordingTag.key(tag)
        return labels.values.filter { $0.tags.contains { RecordingTag.key($0) == key } }.count
    }

    var isFiltering: Bool { !selectedTags.isEmpty || !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Untagged recordings are their own group, and deliberately last: they are
    /// the pile the feature exists to work through.
    static let untaggedGroup = "태그 없음"

    func matches(_ recording: RecordingItem) -> Bool {
        let labels = labels(for: recording.id)
        let keys = Set(labels.tags.map(RecordingTag.key))
        guard selectedTags.allSatisfy({ keys.contains(RecordingTag.key($0)) }) else { return false }
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return "\(displayTitle(for: recording)) \(recording.title) \(labels.tags.joined(separator: " "))"
            .lowercased().contains(needle)
    }

    func filtered(_ recordings: [RecordingItem]) -> [RecordingItem] {
        isFiltering ? recordings.filter(matches) : recordings
    }

    /// Grouped for display. A recording with two tags appears under both — this
    /// is a view of the library, not a partition of it.
    func grouped(_ recordings: [RecordingItem]) -> [(tag: String, recordings: [RecordingItem])] {
        var buckets: [String: [RecordingItem]] = [:]
        var untagged: [RecordingItem] = []
        for recording in recordings {
            let tags = self.tags(for: recording.id)
            if tags.isEmpty { untagged.append(recording); continue }
            for tag in tags { buckets[tag, default: []].append(recording) }
        }
        var groups = buckets.map { (tag: $0.key, recordings: $0.value) }
            .sorted { $0.recordings.count != $1.recordings.count ? $0.recordings.count > $1.recordings.count : $0.tag < $1.tag }
        if !untagged.isEmpty { groups.append((tag: Self.untaggedGroup, recordings: untagged)) }
        return groups
    }

    // MARK: - 쓰기

    func rename(_ recording: RecordingItem, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typing the filename back in is the same as having no custom name.
        mutate(recording.id) { $0.title = trimmed == recording.title ? "" : String(trimmed.prefix(120)) }
    }

    func setTags(_ raw: String, for id: String) {
        mutate(id) { $0.tags = RecordingTag.parse(raw) }
    }

    func addTag(_ raw: String, to id: String) {
        guard let tag = RecordingTag.normalized(raw) else { return }
        mutate(id) { labels in
            guard labels.tags.count < RecordingTag.maxPerRecording,
                  !labels.tags.contains(where: { RecordingTag.key($0) == RecordingTag.key(tag) }) else { return }
            labels.tags.append(tag)
        }
    }

    func removeTag(_ tag: String, from id: String) {
        mutate(id) { labels in
            labels.tags.removeAll { RecordingTag.key($0) == RecordingTag.key(tag) }
        }
    }

    func toggleFilter(_ tag: String) {
        if selectedTags.contains(tag) { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
    }

    func clearFilter() {
        selectedTags.removeAll()
        search = ""
    }

    /// Renames one tag everywhere it is used. Without this, fixing a typo means
    /// visiting every recording that carries it.
    func renameTag(_ old: String, to raw: String) {
        guard let replacement = RecordingTag.normalized(raw) else { return }
        let key = RecordingTag.key(old)
        objectWillChange.send()
        for (id, var labels) in labels {
            guard labels.tags.contains(where: { RecordingTag.key($0) == key }) else { continue }
            var rebuilt: [String] = []
            for tag in labels.tags {
                let next = RecordingTag.key(tag) == key ? replacement : tag
                if !rebuilt.contains(where: { RecordingTag.key($0) == RecordingTag.key(next) }) { rebuilt.append(next) }
            }
            labels.tags = rebuilt
            labels.updatedAt = Date()
            self.labels[id] = labels
        }
        if selectedTags.remove(old) != nil { selectedTags.insert(replacement) }
        persist()
    }

    func deleteTag(_ tag: String) {
        let key = RecordingTag.key(tag)
        objectWillChange.send()
        for (id, var labels) in labels {
            guard labels.tags.contains(where: { RecordingTag.key($0) == key }) else { continue }
            labels.tags.removeAll { RecordingTag.key($0) == key }
            labels.updatedAt = Date()
            self.labels[id] = labels
        }
        selectedTags.remove(tag)
        persist()
    }

    private func mutate(_ id: String, _ change: (inout RecordingLabels) -> Void) {
        objectWillChange.send()
        var value = labels[id] ?? RecordingLabels()
        change(&value)
        value.updatedAt = Date()
        labels[id] = value
        persist()
    }

    private func persist() {
        do {
            try store.save(labels)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
