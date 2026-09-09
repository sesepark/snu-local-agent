#if canImport(Testing)
import Testing
import Foundation
@testable import SeoulLocalAgent

/// Names and tags for the recording library.
///
/// The risk worth covering here is not the UI but the store: these labels are
/// the only thing that distinguishes fifty takes called `녹음 2026-08-25 154002`
/// from one another, they are not recoverable from the audio, and the file is
/// read with the same "a failed decode means an empty store" rule as everything
/// else the app persists.
@Suite("녹음 이름과 태그")
struct RecordingOrganizationTests {

    private func temporaryDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "recording-labels-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func recording(_ id: String, title: String, at offset: TimeInterval = 0) -> RecordingItem {
        RecordingItem(
            id: id, source: .app, title: title,
            url: URL(fileURLWithPath: "/tmp/\(id).m4a"),
            date: Date(timeIntervalSince1970: 1_800_000_000 + offset),
            duration: 600, isLocallyAvailable: true
        )
    }

    // MARK: - 태그 정규화

    /// One course, three spellings, one chip. Without this the filter bar fills
    /// up with near-duplicates that each match a different subset of the library.
    @Test("같은 태그의 여러 표기는 하나로 합쳐진다")
    func tagsNormalize() {
        #expect(RecordingTag.normalized("  회로이론  ") == "회로이론")
        #expect(RecordingTag.normalized("회로   이론") == "회로 이론")
        #expect(RecordingTag.normalized("#회로이론") == "회로이론")
        #expect(RecordingTag.normalized("   ") == nil)
        #expect(RecordingTag.key("회로 이론") == RecordingTag.key("회로이론"))
        #expect(RecordingTag.key("Physical AI") == RecordingTag.key("physicalai"))
        #expect(RecordingTag.normalized(String(repeating: "가", count: 40))?.count == RecordingTag.maxLength)
    }

    @Test("한 번에 여러 태그를 붙여도 중복은 하나만 남는다")
    func parsingAField() {
        #expect(RecordingTag.parse("회로이론, 3주차") == ["회로이론", "3주차"])
        #expect(RecordingTag.parse("회로이론, 회로 이론") == ["회로이론"])
        #expect(RecordingTag.parse("  ,  ,  ").isEmpty)
        #expect(RecordingTag.parse((1...20).map { "태그\($0)" }.joined(separator: ",")).count == RecordingTag.maxPerRecording)
    }

    // MARK: - 저장

    @Test("이름과 태그는 저장했다가 다시 읽힌다")
    func labelsRoundTrip() throws {
        let directory = temporaryDirectory()
        let store = RecordingLabelStore(directory: directory)
        #expect(store.load().isEmpty)

        try store.save([
            "app:1": RecordingLabels(title: "회로이론 3주차", tags: ["회로이론", "3주차"]),
            // Blank labels are not worth a line in the file.
            "app:2": RecordingLabels(),
        ])
        let reloaded = store.load()
        #expect(reloaded.count == 1)
        #expect(reloaded["app:1"]?.title == "회로이론 3주차")
        #expect(reloaded["app:1"]?.tags == ["회로이론", "3주차"])
    }

    /// The same protection every other store in this app has: a synthesised
    /// decoder throws on a key added later, and a throw here empties the file.
    @Test("나중에 필드가 늘어도 기존 이름과 태그는 살아남는다")
    func decodingToleratesMissingKeys() throws {
        let json = Data(#"{"app:1":{"tags":["회로이론"]}}"#.utf8)
        let decoded = try JSONDecoder().decode([String: RecordingLabels].self, from: json)
        #expect(decoded["app:1"]?.tags == ["회로이론"])
        #expect(decoded["app:1"]?.title == "")
    }

    // MARK: - 이름

    @MainActor
    @Test("이름을 붙이고 지우면 파일 이름으로 돌아간다")
    func renamingFallsBackToTheFilename() {
        let organizer = RecordingOrganizer(store: RecordingLabelStore(directory: temporaryDirectory()))
        let take = recording("app:1", title: "녹음 2026-08-25 154002")
        #expect(organizer.displayTitle(for: take) == "녹음 2026-08-25 154002")
        #expect(!organizer.hasCustomTitle(take))

        organizer.rename(take, to: "회로이론 3주차")
        #expect(organizer.displayTitle(for: take) == "회로이론 3주차")
        #expect(organizer.hasCustomTitle(take))

        organizer.rename(take, to: "  ")
        #expect(organizer.displayTitle(for: take) == "녹음 2026-08-25 154002")

        // Typing the filename back in is the same as having no custom name.
        organizer.rename(take, to: "녹음 2026-08-25 154002")
        #expect(!organizer.hasCustomTitle(take))
    }

    // MARK: - 태그와 거르기

    @MainActor
    @Test("태그로 거르면 모든 태그를 가진 녹음만 남는다")
    func filteringNarrows() {
        let organizer = RecordingOrganizer(store: RecordingLabelStore(directory: temporaryDirectory()))
        let lecture = recording("app:1", title: "녹음 1")
        let exam = recording("app:2", title: "녹음 2")
        let other = recording("app:3", title: "녹음 3")
        organizer.setTags("회로이론, 3주차", for: lecture.id)
        organizer.setTags("회로이론, 시험", for: exam.id)
        organizer.setTags("세미나", for: other.id)
        let all = [lecture, exam, other]

        #expect(!organizer.isFiltering)
        #expect(organizer.filtered(all).count == 3)

        organizer.toggleFilter("회로이론")
        #expect(organizer.filtered(all).map(\.id) == ["app:1", "app:2"])

        // Stacking chips narrows rather than widens.
        organizer.toggleFilter("시험")
        #expect(organizer.filtered(all).map(\.id) == ["app:2"])

        organizer.clearFilter()
        organizer.search = "세미나"
        #expect(organizer.filtered(all).map(\.id) == ["app:3"], "태그도 검색어에 걸린다")

        organizer.clearFilter()
        organizer.rename(lecture, to: "회로이론 3주차")
        organizer.search = "3주차"
        #expect(organizer.filtered(all).map(\.id) == ["app:1"], "붙인 이름도 검색어에 걸린다")
    }

    @MainActor
    @Test("자주 쓴 태그가 먼저 나오고 개수를 센다")
    func tagsAreOrderedByUse() {
        let organizer = RecordingOrganizer(store: RecordingLabelStore(directory: temporaryDirectory()))
        organizer.setTags("회로이론", for: "app:1")
        organizer.setTags("회로이론, 세미나", for: "app:2")
        organizer.setTags("회로이론", for: "app:3")
        #expect(organizer.allTags == ["회로이론", "세미나"])
        #expect(organizer.count(of: "회로이론") == 3)
        #expect(organizer.count(of: "세미나") == 1)
    }

    @MainActor
    @Test("한 녹음에 같은 태그가 두 번 붙지 않는다")
    func addingIsIdempotent() {
        let organizer = RecordingOrganizer(store: RecordingLabelStore(directory: temporaryDirectory()))
        organizer.addTag("회로이론", to: "app:1")
        organizer.addTag("회로 이론", to: "app:1")
        #expect(organizer.tags(for: "app:1") == ["회로이론"])

        organizer.removeTag("회로 이론", from: "app:1")
        #expect(organizer.tags(for: "app:1").isEmpty)
    }

    @MainActor
    @Test("태그별로 묶으면 태그 없는 녹음이 마지막에 온다")
    func groupingPutsUntaggedLast() {
        let organizer = RecordingOrganizer(store: RecordingLabelStore(directory: temporaryDirectory()))
        let a = recording("app:1", title: "녹음 1")
        let b = recording("app:2", title: "녹음 2")
        let c = recording("app:3", title: "녹음 3")
        organizer.setTags("회로이론", for: a.id)
        organizer.setTags("회로이론, 세미나", for: b.id)

        let groups = organizer.grouped([a, b, c])
        #expect(groups.map(\.tag) == ["회로이론", "세미나", RecordingOrganizer.untaggedGroup])
        #expect(groups.first?.recordings.count == 2)
        #expect(groups.last?.recordings.map(\.id) == ["app:3"])
    }

    @MainActor
    @Test("태그 이름을 바꾸면 쓰던 녹음 전체에 반영된다")
    func renamingATagIsGlobal() {
        let organizer = RecordingOrganizer(store: RecordingLabelStore(directory: temporaryDirectory()))
        organizer.setTags("회로이론", for: "app:1")
        organizer.setTags("회로이론, 시험", for: "app:2")
        organizer.toggleFilter("회로이론")

        organizer.renameTag("회로이론", to: "회로이론및실험")
        #expect(organizer.tags(for: "app:1") == ["회로이론및실험"])
        #expect(organizer.tags(for: "app:2") == ["회로이론및실험", "시험"])
        #expect(organizer.selectedTags == ["회로이론및실험"], "고르고 있던 태그도 따라온다")

        // Renaming onto an existing tag merges rather than duplicating.
        organizer.renameTag("시험", to: "회로이론및실험")
        #expect(organizer.tags(for: "app:2") == ["회로이론및실험"])

        organizer.deleteTag("회로이론및실험")
        #expect(organizer.tags(for: "app:1").isEmpty)
        #expect(organizer.selectedTags.isEmpty)
    }
}
#endif
