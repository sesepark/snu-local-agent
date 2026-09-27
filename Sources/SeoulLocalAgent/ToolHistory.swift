import SwiftUI
import AppKit

struct ToolHistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var date = Date()
    var tool: String
    var source: URL
    var output: URL?
    var savedURL: URL?
    var saveName: String
    var settings: String
    var detail: String
    var succeeded: Bool

    var availableOutput: URL? {
        [savedURL, output].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

enum ProcessingResults {
    static func directory(_ name: String) throws -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SeoulLocalAgent/ProcessingResults", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }
}

@MainActor
final class ToolHistory: ObservableObject {
    static let shared = ToolHistory()
    @Published private(set) var entries: [ToolHistoryEntry] = []
    @Published var error: String?
    private let url: URL
    private var archiveUnreadable = false

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SeoulLocalAgent", directoryHint: .isDirectory)
        url = root.appending(path: "tool-history.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { entries = try JSONDecoder().decode([ToolHistoryEntry].self, from: Data(contentsOf: url)) }
            catch { archiveUnreadable = true; self.error = "지난 내역을 읽지 못했습니다. 기존 기록 파일은 보존했습니다: \(error.localizedDescription)" }
        }
    }

    func record(_ entry: ToolHistoryEntry) {
        record([entry])
    }

    func record(_ batch: [ToolHistoryEntry]) {
        // Do not overwrite an unreadable archive with an empty one.
        guard !archiveUnreadable else { return }
        let previous = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = batch.map { entry in
            var value = entry
            if let existing = previous[entry.id] {
                value.savedURL = value.savedURL ?? existing.savedURL
                value.date = existing.date
            }
            return value
        }
        let identifiers = Set(batch.map(\.id))
        entries.removeAll { identifiers.contains($0.id) }
        entries.insert(contentsOf: updated.reversed(), at: 0)
        persist()
    }

    func markSaved(id: UUID, at target: URL) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].savedURL = target
        persist()
    }

    func removeRecords(tool: String) {
        guard !archiveUnreadable else { return }
        entries.removeAll { $0.tool == tool }
        persist() // Metadata only. Never deletes result files or user exports.
    }

    private func persist() {
        do { try LocalFileStorage.write(try JSONEncoder().encode(entries), to: url) }
        catch { self.error = "내역을 저장하지 못했습니다: \(error.localizedDescription)" }
    }

    func export(_ entry: ToolHistoryEntry) {
        guard let output = entry.availableOutput else { error = "결과 파일이 이동되었거나 없습니다."; return }
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory)
        let target: URL
        if isDirectory.boolValue {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false
            panel.allowsMultipleSelection = false; panel.prompt = "저장"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            target = CompressionWorkspace.uniqueURL(in: folder, name: entry.saveName)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = entry.saveName
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            target = selected
        }
        do {
            try LocalFileStorage.copyPreservingDestination(output, to: target)
            markSaved(id: entry.id, at: target)
        } catch { self.error = "저장하지 못했습니다: \(error.localizedDescription)" }
    }
}

struct ToolHistoryPanel: View {
    let tool: String
    let isBusy: Bool
    let retry: ([URL]) -> Void
    @ObservedObject var history: ToolHistory
    @State private var expanded: Bool
    @State private var search = ""
    @State private var failuresOnly = false
    @State private var limit = 50
    @State private var confirmClear = false

    init(tool: String, isBusy: Bool, history: ToolHistory = .shared, expanded: Bool = false, retry: @escaping ([URL]) -> Void) {
        self.tool = tool; self.isBusy = isBusy; self.retry = retry
        _history = ObservedObject(wrappedValue: history)
        _expanded = State(initialValue: expanded)
    }

    private var entries: [ToolHistoryEntry] {
        history.entries.filter {
            $0.tool == tool && (!failuresOnly || !$0.succeeded)
                && (search.isEmpty || "\($0.source.lastPathComponent) \($0.settings) \($0.detail)"
                    .localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        DisclosureGroup("지난 내역 (\(history.entries.filter { $0.tool == tool }.count))", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("새 작업을 넣거나 현재 목록을 비워도 내역과 결과 파일은 유지됩니다. 재시도는 현재 설정을 사용합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("파일명·설정·결과 검색", text: $search)
                    Toggle("실패만", isOn: $failuresOnly).toggleStyle(.checkbox)
                    Button("내역 비우기…") { confirmClear = true }
                        .disabled(history.entries.allSatisfy { $0.tool != tool })
                }
                if let error = history.error { Text(error).font(.caption).foregroundStyle(.red) }
                if entries.isEmpty { Text("표시할 내역이 없습니다.").foregroundStyle(.secondary) }
                ForEach(Array(entries.prefix(limit))) { entry in
                    HStack(alignment: .top) {
                        Image(systemName: entry.succeeded ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(entry.succeeded ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.source.lastPathComponent).lineLimit(2).textSelection(.enabled)
                            Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(entry.settings)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.detail).font(.caption).textSelection(.enabled)
                            if let saved = entry.savedURL {
                                Text("저장: \(saved.path)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                            if entry.succeeded, entry.availableOutput == nil {
                                Text("결과 파일 없음").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if let output = entry.availableOutput {
                            Menu("결과") {
                                Button("열기") { NSWorkspace.shared.open(output) }
                                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                                Button("다시 저장…") { history.export(entry) }
                                Button("파일 복사") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.writeObjects([output as NSURL])
                                }
                            }
                        }
                        Button("재시도") { retry([entry.source]) }
                            .disabled(isBusy || !FileManager.default.fileExists(atPath: entry.source.path))
                    }
                    Divider()
                }
                if entries.count > limit { Button("더 보기") { limit += 50 } }
            }.padding(.top, Spacing.s)
        }
        .confirmationDialog("이 도구의 내역만 비울까요? 결과 파일과 저장한 파일은 삭제하지 않습니다.", isPresented: $confirmClear) {
            Button("내역만 비우기", role: .destructive) { history.removeRecords(tool: tool) }
        }
    }
}
