import Foundation

struct StateStore {
    private let directory: URL
    private let url: URL

    init(directory customDirectory: URL? = nil) {
        directory = customDirectory ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Application Support/SeoulLocalAgent", directoryHint: .isDirectory)
        url = directory.appending(path: "state.json")
    }

    var debugPath: String { url.path }

    func load() -> PersistentState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(PersistentState.self, from: data) else { return PersistentState() }
        return state
    }

    func save(_ state: PersistentState) throws {
        var stored = state
        // The state file is a checkpoint, not an archive: keep it bounded and
        // never let it accumulate the raw message bodies it was summarising.
        stored.dailyBriefings = PersistentState.pruned(state.dailyBriefings)
            .mapValues { $0.withoutSourceBodies() }
        stored.lastError = state.lastError.map { String($0.prefix(400)) }
        try LocalFileStorage.write(try JSONEncoder().encode(stored), to: url)
    }
}

enum NotionParentPolicy {
    static let allowedParentID = "3b8b3e65-af46-8037-aa2f-e625ef9f5662"

    static func allowsWrite(parentID: String) -> Bool {
        parentID.lowercased() == allowedParentID
    }
}

struct NotionWriter {
    private let runner = ProcessRunner()

    func write(_ briefing: DailyBriefing) async throws -> URL {
        guard NotionParentPolicy.allowsWrite(parentID: AppConfig.notionParentID) else { throw AgentError.invalidNotionParent }
        let content = render(briefing)
        if let pageID = try await findChildPage(named: briefing.dateKey) {
            // A page ID discovered from this exact parent's children is the only editable target.
            _ = try await runner.run("/opt/homebrew/bin/ntn", ["pages", "edit", "--content=\(content)", "--allow-deleting-content", pageID])
            return try notionURL(pageID)
        }
        // `ntn pages create` uses frontmatter for its title. Parsing the page
        // ID avoids racing Notion's asynchronous child-block indexing.
        let createContent = "---\ntitle: \(briefing.dateKey)\n---\n\n\(content)"
        let data = try await runner.run("/opt/homebrew/bin/ntn", [
            "pages", "create", "--parent", "page:\(AppConfig.notionParentID)", "--content=\(createContent)", "--json",
        ])
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pageID = (root["id"] as? String) ?? ((root["page"] as? [String: Any])?["id"] as? String) else {
            throw AgentError.processFailed("Notion 날짜 페이지 생성 응답에서 페이지 ID를 읽지 못했습니다.")
        }
        return try notionURL(pageID)
    }

    func preview(_ briefing: DailyBriefing) -> String { render(briefing) }

    private func notionURL(_ pageID: String) throws -> URL {
        let compact = pageID.replacingOccurrences(of: "-", with: "")
        guard !compact.isEmpty, let url = URL(string: "https://www.notion.so/\(compact)") else {
            throw AgentError.processFailed("Notion 페이지 주소를 만들지 못했습니다: \(pageID)")
        }
        return url
    }

    private func findChildPage(named title: String) async throws -> String? {
        guard NotionParentPolicy.allowsWrite(parentID: AppConfig.notionParentID) else { throw AgentError.invalidNotionParent }
        var cursor: String?
        repeat {
            // `ntn api` already emits JSON; unlike `ntn pages`, this subcommand has no --json flag.
            var arguments = ["api", "v1/blocks/\(AppConfig.notionParentID)/children"]
            if let cursor { arguments += ["start_cursor=\(cursor)"] }
            let data = try await runner.run("/opt/homebrew/bin/ntn", arguments)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AgentError.processFailed("Notion children 응답 형식이 올바르지 않습니다.") }
            let results = root["results"] as? [[String: Any]] ?? []
            for block in results where (block["type"] as? String) == "child_page" {
                let page = block["child_page"] as? [String: Any]
                if page?["title"] as? String == title { return block["id"] as? String }
            }
            cursor = (root["has_more"] as? Bool) == true ? root["next_cursor"] as? String : nil
        } while cursor != nil
        return nil
    }

    private func render(_ briefing: DailyBriefing) -> String {
        let visible = BriefingQualityGate.normalized(briefing.items)
        let actions = visible.filter { $0.category == .action }.sorted { $0.importance > $1.importance }
        let references = visible.filter { $0.category == .reference }.sorted { $0.importance > $1.importance }
        let excluded = briefing.items.filter { $0.category == .excluded }
        func entry(_ item: ClassifiedItem, checkbox: Bool) -> String {
            let source = "\(item.sourceItem.source) · \(item.sourceItem.timestamp.formatted(date: .abbreviated, time: .shortened))"
            let prefix = checkbox ? "- [ ]" : "-"
            let summary = BriefPresentation.summary(for: item)
            return "\(prefix) **\(BriefPresentation.todoTitle(for: item))**\n  - \(summary)\n  - [출처 열기 · \(source)](\(item.sourceItem.link.absoluteString))"
        }
        let actionLines = actions.prefix(AppConfig.briefingMaxActions)
            .map { entry($0, checkbox: true) }.joined(separator: "\n").ifEmpty("- 새로 처리할 일이 없습니다.")
        let referenceLines = references.prefix(AppConfig.briefingMaxReferences)
            .map { entry($0, checkbox: false) }.joined(separator: "\n").ifEmpty("- 확인할 새 항목이 없습니다.")
        let counts = briefing.sourceCounts.map { "\($0.key) \($0.value)개" }.sorted().joined(separator: ", ")
        let failures = briefing.failures.isEmpty ? "없음" : briefing.failures.joined(separator: " / ")
        // Every line must start at column zero. Markdown treats four or more
        // leading spaces as a code block, which silently turned the headings and
        // the collection-status section into text that Notion never rendered.
        return """
# 오늘 꼭 할 일

\(actionLines)

# 확인해야 할 것

\(referenceLines)

# 기타

- 자동 제외/낮은 우선순위: \(excluded.count)개
- 화면에서 생략한 확인 항목: \(max(0, references.count - AppConfig.briefingMaxReferences))개
- 마감이 지나 이월하지 않은 미완료 항목: \(briefing.expiredCarryOverCount ?? 0)개
- 마감 없이 \(CarryForwardPolicy.staleAfterDays)일을 넘겨 이월하지 않은 항목: \(briefing.staleCarryOverCount ?? 0)개

# 수집 상태

- 수집 기간: \(briefing.collectionRange ?? "설정된 범위")
- 소스별 수집 건수: \(counts)
- 생성 시각: \(briefing.updatedAt.formatted(date: .abbreviated, time: .shortened))
- 실패한 소스 또는 권한 오류: \(failures)
"""
    }
}

struct BriefingService {
    private let gmail = GmailSource()
    private let slack = SlackSource()
    private let iMessage = IMessageSource()
    private let calendar = CalendarSource()
    private let classifier = LocalClassifier()
    private let writer = NotionWriter()
    private let store = StateStore()
    private let archiveStore = BriefingArchiveStore()
    private let preferenceStore = BriefingPreferencesStore()

    func markdownPreview(_ briefing: DailyBriefing) -> String { writer.preview(briefing) }

    /// Notion is an export now, not a step of the run. Nothing calls this unless
    /// the reader presses the button, and the parent-page allowlist inside
    /// `NotionWriter` still applies.
    func exportToNotion(_ briefing: DailyBriefing) async throws -> URL {
        let url = try await writer.write(briefing)
        var state = store.load()
        state.dailyBriefings[briefing.dateKey]?.notionURL = url
        state.lastNotionURL = url
        try store.save(state)
        return url
    }

    private struct SourceCollection {
        let checkpointKey: String
        let sourceName: String
        let items: [SourceItem]
        var warnings: [String] = []
        let errorMessage: String?

        /// A source that only partially succeeded must not advance its checkpoint,
        /// or the items it failed to read would never be collected again.
        var isComplete: Bool { errorMessage == nil && warnings.isEmpty }
    }

    private func collectSafely(
        checkpointKey: String,
        sourceName: String,
        operation: @escaping @Sendable () async throws -> SourceHarvest
    ) async -> SourceCollection {
        do {
            let harvest = try await operation()
            return SourceCollection(checkpointKey: checkpointKey, sourceName: sourceName, items: harvest.items, warnings: harvest.warnings, errorMessage: nil)
        } catch {
            return SourceCollection(checkpointKey: checkpointKey, sourceName: sourceName, items: [], errorMessage: "\(sourceName): \(error.localizedDescription)")
        }
    }

    /// `pendingItemCount` is reported once, when the set of items that will be sent
    /// to the model is known, so the UI never has to parse it back out of prose.
    ///
    /// `persists` is the only remaining dry-run switch. It used to be
    /// `writeToNotion`, which conflated three separate things — writing to
    /// Notion, saving local state, and reusing the day's earlier work — so a
    /// shadow run silently re-analysed everything. Notion is no longer part of
    /// a run at all; it is an export the reader asks for from the 보관함.
    func run(range: CollectionRange, persists: Bool = true, progress: @escaping @Sendable (RunPhase, String, Int?) async -> Void) async throws -> DailyBriefing {
        let state = store.load()
        let now = Date()
        // No checkpoint yet means the last run was a manual re-review, which still
        // read everything up to the moment it finished. Start from that instead of
        // a blind seven days, but never reach back further than thirty days: a
        // months-old success would otherwise pull an unbounded first window.
        let floor = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let initial = max(state.lastSuccessAt ?? Calendar.current.date(byAdding: .day, value: -7, to: now)!, floor)
        let manualSince = range.days.flatMap { Calendar.current.date(byAdding: .day, value: -$0, to: now) }
        let gmailSince = manualSince ?? state.checkpoints["gmail"] ?? initial
        let slackSince = manualSince ?? state.checkpoints["slack"] ?? initial
        do {
            await progress(.collecting, """
            1/4 · 새 항목 수집 중 (이 단계에서는 모델 RAM이 아직 증가하지 않습니다.)
            • Gmail: 두 계정의 새 메일/스레드 검색
            • Slack: 접근 가능한 채널·DM의 새 메시지 검색
            • 메시지: iMessage·SMS·RCS 수신 메시지 검색
            • 캘린더: 앞으로 14일 일정 읽기
            • eTL: 이번 학기 과목의 새 공지와 다가온 과제 마감 확인
            • 웹 공지: 등록한 학교 공지 게시판의 새 글 확인
            """, nil)
            let iMessageSince = manualSince ?? state.checkpoints["imessage"] ?? initial
            async let gmailResult = collectSafely(checkpointKey: "gmail", sourceName: "Gmail") { try await gmail.collect(since: gmailSince) }
            async let slackResult = collectSafely(checkpointKey: "slack", sourceName: "Slack") { try await slack.collect(since: slackSince) }
            async let iMessageResult = collectSafely(checkpointKey: "imessage", sourceName: "메시지") { SourceHarvest(items: try await iMessage.collect(since: iMessageSince)) }
            // Public pages only, so this one needs no checkpoint: a post is new when
            // its URL has not been seen before, which the source tracks itself.
            async let webResult = collectSafely(checkpointKey: "web", sourceName: "웹 공지") {
                await WebNoticeSource().collect(persists: persists)
            }
            // The token is the only credential here and the seen-set is the source's
            // own, so like the boards this one needs no checkpoint: an announcement is
            // new when its id has not been seen, and an assignment reappears on its
            // own schedule (처음 · D-3 · D-1).
            async let etlResult = collectSafely(checkpointKey: "etl", sourceName: SourceName.etl) {
                await ETLSource().collect(persists: persists)
            }
            let calendarEnd = Calendar.current.date(byAdding: .day, value: 14, to: now)!
            async let calendarResult = collectSafely(checkpointKey: "calendar", sourceName: "캘린더") {
                SourceHarvest(items: try calendar.collect(upcomingFrom: Calendar.current.startOfDay(for: now), through: calendarEnd))
            }
            let collections = await [gmailResult, slackResult, iMessageResult, calendarResult, etlResult, webResult]
            let collected = collections.flatMap(\.items)
            try Task.checkCancellation()
            let preferences = preferenceStore.load()
            let preferenceResult = BriefingPreferenceRules.partition(collected, preferences: preferences)
            let deduped = SourceDeduplicator.unique(preferenceResult.included)
            let grouped = IncidentGrouper.group(deduped)
            if deduped.isEmpty, collections.contains(where: { $0.errorMessage != nil }) {
                throw AgentError.processFailed("모든 수집 소스가 실패하거나 읽을 새 항목이 없습니다. 빈 브리핑을 저장하지 않았습니다.")
            }
            let collectionSummary = collections.map { collection in
                if let error = collection.errorMessage { return "• \(error)" }
                let warnings = collection.warnings.map { "\n  ⚠︎ \($0)" }.joined()
                return "• \(collection.sourceName): \(collection.items.count)개 수집\(warnings)"
            }.joined(separator: "\n")
            // Carry-forward runs before analysis, not after: an item that is still
            // open and unchanged keeps its earlier result instead of being sent to
            // the model again, which is what makes incremental collection cheap.
            let dateKey = Self.dateKey(now)
            // 표는 한 번만 읽는다. 이월 판단(끝냈는가·옮겼는가)과 분류 프롬프트에 실을
            // 교정 예시가 모두 같은 파일에서 나온다.
            let archived = archiveStore.load()
            // 사람이 같은 것을 반복해서 옮겼다면 그 사실을 분류에 함께 보낸다. 그러지
            // 않으면 모델은 매일 같은 자리에 같은 메일을 놓고, 사람은 매일 같은 것을
            // 다시 내린다.
            let correctionBlock = ClassificationLearning.promptBlock(
                from: ClassificationLearning.corrections(days: Array(state.dailyBriefings.values), marks: archived.marks)
            ) ?? ""
            var carried: [ClassifiedItem] = []
            var expiredCarryOverCount = 0
            var staleCarryOverCount = 0
            if let previous = state.dailyBriefings.values
                .filter({ $0.dateKey != dateKey && $0.updatedAt < now })
                .sorted(by: { $0.updatedAt > $1.updatedAt })
                .first {
                await progress(.collecting, "1/4 · 이전 브리핑에서 아직 끝나지 않은 항목을 확인하고 있습니다.", nil)
                // Read from disk, not over the network: what is finished is what
                // the reader ticked off in 브리핑 보관함.
                let outcome = CarryForwardPolicy.evaluate(
                    previousItems: previous.items,
                    completedIDs: archived.completedIDs,
                    overrides: archived.categoryOverrides,
                    now: now
                )
                carried = outcome.carried
                expiredCarryOverCount = outcome.expired.count
                staleCarryOverCount = outcome.stale.count
            }
            try Task.checkCancellation()
            // A second run on the same day must not re-analyse what the first run
            // already classified, only what is new or has changed since.
            let sameDayItems = state.dailyBriefings[dateKey]?.items ?? []
            let unchanged = CarryForwardPolicy.unchangedItems(in: grouped, alreadyCarried: carried + sameDayItems)
            let pending = grouped.filter { !unchanged.contains($0.id) }
            await progress(.collecting, """
            1/4 · 수집 완료
            \(collectionSummary)
            사용자 무시 규칙 \(preferenceResult.ignored.count)개 제외, 중복 제거 후 \(deduped.count)개, 반복 알림 묶음 후 \(grouped.count)개입니다.
            이전 브리핑에서 \(carried.count)개를 이월하고, 새롭거나 내용이 바뀐 \(pending.count)개만 분석합니다.
            """, pending.count)
            let sourceGroups = Dictionary(grouping: pending, by: \.source)
            // A source missing from the preferred order must still be classified.
            let orderedSources = SourceName.ordered.filter { sourceGroups[$0] != nil }
                + sourceGroups.keys.filter { !SourceName.ordered.contains($0) }.sorted()
            var classified: [ClassifiedItem] = []
            var analysisFailures: [String] = []
            for source in orderedSources where sourceGroups[source]?.isEmpty == false {
                try Task.checkCancellation()
                let items = sourceGroups[source] ?? []
                await progress(.classifying, "2/4 · \(source) \(items.count)개를 분류하고 한국어 브리핑 문장까지 한 번에 만들고 있습니다.", nil)
                do {
                    var sourceClassified = try await classifier.classify(items, userInstructions: preferences.userInstructions, corrections: correctionBlock)
                    sourceClassified = sourceClassified.map { item in
                        guard preferenceResult.importantIDs.contains(item.id) else { return item }
                        var important = item
                        important = ClassifiedItem(sourceItem: important.sourceItem, facts: important.facts, category: .action, summary: important.summary, reason: "사용자의 중요 규칙과 일치: \(important.reason)", importance: 5, nextAction: important.nextAction, deadline: important.deadline, displayTitle: important.displayTitle, displaySummary: important.displaySummary, displayNextAction: important.displayNextAction, confidence: 1, pinnedByUserRule: true, contentFingerprint: item.contentFingerprint, bodyExcerpt: item.bodyExcerpt)
                        return important
                    }
                    sourceClassified = sourceClassified.map { item in
                        var stamped = item
                        stamped.contentFingerprint = SourceFingerprint.of(item.sourceItem)
                        stamped.bodyExcerpt = ClassifiedItem.excerpt(of: item.sourceItem.body)
                        return stamped
                    }
                    classified += BriefingQualityGate.normalized(sourceClassified, preferences: preferences)
                } catch {
                    // One source must not erase useful results from the others.
                    analysisFailures.append("\(source) 분류: \(error.localizedDescription)")
                }
            }
            guard !classified.isEmpty || pending.isEmpty else {
                throw AgentError.processFailed("수집 항목의 로컬 분류에 모두 실패했습니다. 원본은 변경하지 않았습니다.")
            }
            classified = ClassifiedIncidentMerger.merge(classified)
            // A source that already knows the deadline overrules the model's reading
            // of it, so an eTL 과제 lands on the calendar at the hour Canvas gave.
            classified = ExactDeadlines.applied(to: classified)
            // A freshly analysed item wins over the carried copy of the same thing.
            classified = Array(Dictionary(grouping: classified + carried, by: { $0.trackingID }).compactMap { $0.value.first })
            try Task.checkCancellation()
            await progress(.writing, "3/4 · 정리한 결과를 브리핑 보관함에 저장하고 있습니다.", nil)
            var daily = state.dailyBriefings[dateKey] ?? DailyBriefing(dateKey: dateKey, items: [], sourceCounts: [:], failures: [], notionURL: nil, updatedAt: now)
            // A manual re-review must improve an earlier same-day draft rather
            // than preserve its old, lower-quality classification.
            daily.items = Array(Dictionary(grouping: classified + daily.items, by: \.trackingID).compactMap { $0.value.first })
            // Report collection status, including a genuine zero or a failed
            // source, rather than only the items that survived classification.
            daily.sourceCounts = Dictionary(uniqueKeysWithValues: collections.map { ($0.sourceName, $0.items.count) })
            daily.updatedAt = now
            // The report used to claim "마지막 성공 시점 이후" no matter what was selected.
            let effectiveSince = min(gmailSince, slackSince, iMessageSince)
            daily.collectionRange = "\(range.rawValue) · \(effectiveSince.formatted(date: .abbreviated, time: .shortened)) 이후"
            daily.expiredCarryOverCount = expiredCarryOverCount
            daily.staleCarryOverCount = staleCarryOverCount
            daily.failures = collections.compactMap(\.errorMessage) + collections.flatMap(\.warnings) + analysisFailures
            if !persists {
                await classifier.unload()
                return daily
            }
            var nextState = state
            nextState.dailyBriefings[dateKey] = daily
            // Recorded for every range, not only the incremental one. A manual
            // "최근 3일 재검토" also read that source cleanly up to now, so the next
            // incremental run should resume from here; skipping it was what left
            // the checkpoints permanently empty and every run re-reading the same
            // window. A source that only partly succeeded still does not advance.
            for collection in collections where collection.isComplete {
                nextState.checkpoints[collection.checkpointKey] = max(nextState.checkpoints[collection.checkpointKey] ?? now, now)
            }
            nextState.lastSuccessAt = now
            nextState.lastError = nil
            try store.save(nextState)
            await progress(.writing, "4/4 · 보관함에 저장했습니다. 로컬 모델 메모리를 해제하고 있습니다.", nil)
            await classifier.unload()
            return daily
        } catch is CancellationError {
            await classifier.unload()
            throw AgentError.cancelled
        } catch {
            await classifier.unload()
            var failed = state
            failed.lastError = error.localizedDescription
            try? store.save(failed)
            throw error
        }
    }

    static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yy/MM/dd"
        return formatter.string(from: date)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
