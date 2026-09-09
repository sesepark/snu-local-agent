import SwiftUI
import AppKit

/// 브리핑 보관함 — where the result of 자동 브리핑 now lives.
///
/// It used to live on a Notion page, which meant the app could produce a
/// briefing it could not itself show, and the reader had to leave for a browser
/// to find out what it said. The same three headings are here instead, with the
/// checkbox doing real work: ticking an item off is what tells tomorrow's run it
/// no longer needs carrying forward.
struct BriefingArchiveView: View {
    @ObservedObject var controller: AutomationController

    private var model: BriefingArchiveModel { controller.briefingArchive }

    var body: some View {
        WorkspaceScreen(title: AppSection.archive.title, subtitle: AppSection.archive.subtitle) {
            if model.days.isEmpty {
                empty
            } else {
                staleness
                ruleSuggestions
                dayBar
                filterBar
                ForEach(BriefingArchiveModel.Bucket.allCases) { bucket in
                    section(bucket)
                }
                collectionFootnote
            }
            if let error = model.error {
                DismissibleError(message: error) { model.error = nil }
            }
        }
        // Every piece of prose here is something the reader may want to paste
        // into a message or a form: a deadline, a room number, a sender. It is
        // applied to the screen rather than to single labels so that nothing is
        // arbitrarily unselectable — SwiftUI leaves control labels out on its
        // own, so buttons and menus keep behaving as buttons.
        .textSelection(.enabled)
        .animation(.appContent, value: model.selectedDateKey)
        .animation(.appContent, value: model.search)
        .onAppear { model.reconcilePlacements() }
        .sheet(item: Binding(get: { model.scheduling }, set: { model.scheduling = $0 })) { entry in
            ScheduleSheet(entry: entry, model: model)
        }
        .toolbar { toolbar }
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("이 날 브리핑 복사", systemImage: "doc.on.doc") {
                    ArchiveClipboard.put(model.plainText())
                    model.status = "브리핑을 클립보드에 복사했습니다."
                }
                .disabled(model.selectedDay == nil)
                .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("Notion으로 내보내기", systemImage: "arrow.up.forward.square") {
                    Task { await model.exportToNotion() }
                }
                .disabled(model.selectedDay == nil || model.isExporting)
                if let url = model.notionURL {
                    Button("내보낸 Notion 페이지 열기", systemImage: "safari") { NSWorkspace.shared.open(url) }
                }
                Divider()
                Button("Mac 캘린더 열기", systemImage: "calendar") {
                    NSWorkspace.shared.open(URL(string: "ical://")!)
                }
                Button("미리 알림 열기", systemImage: "checklist") {
                    NSWorkspace.shared.open(URL(string: "x-apple-reminderkit://")!)
                }
            } label: {
                Label("내보내기", systemImage: model.isExporting ? "arrow.up.circle" : "square.and.arrow.up")
            }
            .help("이 날의 브리핑을 복사하거나 Notion으로 보냅니다 (⇧⌘C)")
        }
        ToolbarItem {
            Button("새로고침", systemImage: "arrow.clockwise") {
                model.reload()
                model.reconcilePlacements()
            }
            .help("저장된 브리핑과 캘린더 상태를 다시 읽습니다")
        }
        ToolbarSpacer(.flexible)
        ToolbarItem {
            if controller.isRunning {
                Button("중지", systemImage: "stop.fill") { controller.stopBriefing() }
                    .tint(.red)
                    .toolbarKeepsTitle()
                    .help("모델을 안전하게 해제하고 멈춥니다 (⌘.)")
            } else {
                Button("인박스 정리 시작", systemImage: "tray.full.fill") { controller.startBriefing() }
                    .buttonStyle(.glassProminent)
                    .tint(.snuBlue)
                    .toolbarKeepsTitle()
                    .help("지금 수집하고 정리해 이 보관함에 저장합니다 (⌘R)")
            }
        }
    }

    // MARK: - 본문

    private var empty: some View {
        VStack(spacing: Spacing.m) {
            EmptyResults(
                symbol: "checklist",
                message: "아직 저장된 브리핑이 없습니다.\n인박스 정리를 한 번 돌리면 결과가 날짜별로 여기에 쌓입니다."
            )
            Button("인박스 정리 시작", systemImage: "tray.full.fill") { controller.startBriefing() }
                .buttonStyle(.glassProminent)
                .tint(.snuBlue)
                .disabled(controller.isRunning)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.l)
        .glassPanel()
    }

    private var dayBar: some View {
        HStack(spacing: Spacing.m) {
            Button("이전 날", systemImage: "chevron.left") { model.step(1) }
                .labelStyle(.iconOnly)
                .disabled(!model.canStepBack)
                .help("하루 전 브리핑")

            VStack(alignment: .leading, spacing: 1) {
                Text(BriefingArchiveModel.dayTitle(model.selectedDateKey))
                    .font(.headline)
                if let day = model.selectedDay {
                    Text("정리한 시각 \(day.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button("다음 날", systemImage: "chevron.right") { model.step(-1) }
                .labelStyle(.iconOnly)
                .disabled(!model.canStepForward)
                .help("하루 뒤 브리핑")

            Spacer()

            Label("남은 일 \(model.openActionCount)개", systemImage: "circle.badge.exclamationmark")
                .font(.callout.weight(.medium))
                .foregroundStyle(model.openActionCount == 0 ? Color.secondary : Color.snuBlueLabel)

            // Icon only: a picker showing the selected date would print the same
            // string twice in one bar, three inches from the heading.
            Menu {
                ForEach(model.days, id: \.dateKey) { day in
                    Button(BriefingArchiveModel.dayTitle(day.dateKey)) { model.selectedDateKey = day.dateKey }
                }
            } label: {
                Label("날짜 고르기", systemImage: "calendar")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("보관된 날짜 중에서 하나를 고릅니다")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .glassPanel(Radius.card)
    }

    private var filterBar: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("보관된 모든 날에서 검색", text: Binding(get: { model.search }, set: { model.search = $0 }))
                .textFieldStyle(.plain)
            if model.isSearching {
                Button("지우기", systemImage: "xmark.circle.fill") { model.search = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
            Divider().frame(height: 16)
            Toggle("끝낸 항목 숨기기", isOn: Binding(get: { model.hidesDone }, set: { model.hidesDone = $0 }))
                .toggleStyle(.checkbox)
                .font(.callout)
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.appBanner)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .glassPanel(Radius.card)
        .animation(.appControl, value: model.status)
    }

    @ViewBuilder
    private func section(_ bucket: BriefingArchiveModel.Bucket) -> some View {
        let all = model.entries(bucket)
        let visible = model.shown(bucket)
        // 기타 is the tray of things the pipeline set aside; showing an empty
        // heading for it every day would be three lines of nothing.
        if !all.isEmpty || bucket != .other {
            GroupBox {
                if all.isEmpty {
                    Text(model.isSearching ? "검색과 일치하는 항목이 없습니다." : bucket.emptyText)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Spacing.s)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visible.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            BriefingEntryRow(entry: entry, model: model, showsDate: model.isSearching)
                        }
                        // The cap is what makes this a briefing rather than a
                        // second inbox, so the rest stays one click away instead
                        // of being unreachable *or* always present.
                        if visible.hidden > 0 || model.expandedBuckets.contains(bucket) {
                            Divider()
                            Button(visible.hidden > 0 ? "\(visible.hidden)개 더 보기" : "덜 보기") {
                                model.toggleBucketExpansion(bucket)
                            }
                            .buttonStyle(.link)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Spacing.s)
                        }
                    }
                }
            } label: {
                HStack(spacing: Spacing.s) {
                    Label(bucket.rawValue, systemImage: bucket.symbol).font(.headline)
                    Text("\(all.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if visible.hidden > 0 {
                        Text("\(visible.entries.count)개 표시")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// The one thing the screen could not say before: that what it is showing is
    /// old. A seventeen-day-old briefing looked exactly like this morning's.
    @ViewBuilder
    private var staleness: some View {
        if let day = model.selectedDay, model.isStale(day) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.stalenessSummary(day))
                        .font(.callout.weight(.medium))
                    Text("지금 보고 있는 내용은 그때 수집한 것입니다. 새로 정리하면 그 이후의 메일과 공지가 들어옵니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("지금 정리", systemImage: "tray.full.fill") { controller.startBriefing() }
                    .buttonStyle(.borderedProminent)
                    .tint(.snuBlue)
                    .disabled(controller.isRunning)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .glassPanel(Radius.card)
        }
    }

    /// 같은 교정을 여러 번 한 것을 규칙으로 굳히자는 제안.
    ///
    /// **제안이지 자동 적용이 아니다.** `항상 무시`는 본문을 읽지 않고 수집 단계에서
    /// 빼는 규칙이라, 앱이 혼자 채워 넣기 시작하면 어느 날부터 안 오는 메일이 왜 안
    /// 오는지 알 수 없게 된다. 그래서 규칙은 언제나 사람이 눌러서 들어가고, 무엇이
    /// 근거인지(몇 번 옮겼는지)를 함께 적는다.
    ///
    /// 자리가 여기인 이유도 같다. 교정은 이 화면에서 일어나므로, 세 번째로 같은 것을
    /// 내린 바로 그 자리에서 "이제 규칙으로 만들까요"가 떠야 고리가 닫힌다.
    @ViewBuilder
    private var ruleSuggestions: some View {
        let suggestions = model.ruleSuggestions
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Label("반복해서 옮긴 것이 있습니다", systemImage: "wand.and.sparkles")
                    .font(.headline)
                    .foregroundStyle(Color.snuBlueLabel)
                ForEach(suggestions) { suggestion in
                    HStack(alignment: .top, spacing: Spacing.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title).font(.callout.weight(.medium))
                            Text(suggestion.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Spacing.s)
                        VStack(alignment: .trailing, spacing: Spacing.xs) {
                            Button("\(suggestion.destination.title)에 추가") {
                                model.applyRuleSuggestion(suggestion)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(.snuBlue)
                            Button("만들지 않기") { model.dismissRuleSuggestion(suggestion) }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                        }
                    }
                    if suggestion.id != suggestions.last?.id { Divider() }
                }
                Text("규칙은 본문을 읽지 않고 발신자·제목에 그 말이 있는지만 봅니다. 언제든 설정 › 분류 기준에서 지울 수 있고, 지우면 다시 모델이 판단합니다.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(Radius.card)
            .transition(.appCard)
        }
    }

    @ViewBuilder
    private var collectionFootnote: some View {
        if let day = model.selectedDay {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                if let range = day.collectionRange {
                    Text("수집 범위 · \(range)")
                }
                let counts = day.sourceCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)개" }
                if !counts.isEmpty { Text("소스별 · \(counts.joined(separator: ", "))") }
                if let expired = day.expiredCarryOverCount, expired > 0 {
                    Text("마감이 지나 이월하지 않은 항목 \(expired)개")
                }
                if let stale = day.staleCarryOverCount, stale > 0 {
                    Text("마감 없이 \(CarryForwardPolicy.staleAfterDays)일을 넘겨 이월하지 않은 항목 \(stale)개 · 그날을 펼치면 그대로 있습니다")
                }
                ForEach(day.failures, id: \.self) { failure in
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                // The archive is a window, not a vault. Saying how wide beats
                // letting the reader find out when a day they wanted is gone.
                Text("보관 중인 브리핑 \(model.days.count)일치 · 최근 \(PersistentState.retainedBriefingDays)일까지 보관하고 그보다 오래된 날은 지웁니다.")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 항목 한 줄

private struct BriefingEntryRow: View {
    let entry: BriefingArchiveModel.Entry
    @ObservedObject var model: BriefingArchiveModel
    let showsDate: Bool

    @State private var note = ""
    @State private var showsWholeBody = false
    @FocusState private var noteFocused: Bool

    private var isExpanded: Bool { model.isExpanded(entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            header
            if isExpanded { detail.transition(.appCard) }
        }
        .padding(.vertical, Spacing.s)
        .animation(.appControl, value: isExpanded)
        .animation(.appControl, value: entry.mark.isDone)
        .contextMenu {
            ForEach(entry.bucket.neighbours) { bucket in
                Button(bucket.moveVerb, systemImage: bucket == .action ? "arrow.up" : "arrow.down") {
                    model.move(entry, to: bucket)
                }
            }
            if entry.isReclassified {
                Button("모델 분류로 되돌리기", systemImage: "arrow.uturn.backward") { model.clearCategoryOverride(entry) }
            }
            Divider()
            Button("제목 복사", systemImage: "textformat") { ArchiveClipboard.put(entry.title) }
            Button("본문까지 복사", systemImage: "doc.on.doc") { ArchiveClipboard.put(entry.plainText) }
            Button("원문 링크 복사", systemImage: "link") { ArchiveClipboard.put(entry.link.absoluteString) }
            Divider()
            Button("원문 열기", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(entry.link) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Button {
                model.toggleDone(entry)
            } label: {
                Image(systemName: entry.mark.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(entry.mark.isDone ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(entry.mark.isDone ? "아직 안 끝났다고 표시합니다" : "끝냈다고 표시합니다. 내일 브리핑으로 이월되지 않습니다")

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.body.weight(.medium))
                    .strikethrough(entry.mark.isDone, color: .secondary)
                    .foregroundStyle(entry.mark.isDone ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                badges
            }

            Spacer(minLength: Spacing.s)

            Button {
                model.toggleExpanded(entry)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "접기" : "자세히 보기")
        }
        // Behind the text rather than over it. Selectable text takes the click
        // where there is text, so covering the row with a tap gesture would mean
        // a drag across the title expanded the row instead of selecting the
        // title; a click on the row's empty space still expands it, and the
        // chevron is always there for the rest.
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { model.toggleExpanded(entry) }
        }
    }

    private var badges: some View {
        HStack(spacing: Spacing.s) {
            Badge(text: entry.source, symbol: sourceSymbol)
            if showsDate {
                Badge(text: BriefingArchiveModel.dayTitle(entry.dateKey), symbol: "calendar.day.timeline.left")
            }
            if let deadline = entry.deadlineText {
                // 지난 마감은 다른 말로 적는다. 같은 `마감 9월 1일`이 오늘의 일과 3주 전에
                // 지나간 일에 똑같이 붙어 있으면, 그 배지는 아무것도 말하지 않는 것과 같다.
                if entry.isOverdue() && !entry.mark.isDone {
                    Badge(text: "마감 지남 · \(deadline)", symbol: "clock.badge.exclamationmark", tint: .red)
                } else {
                    Badge(text: "마감 \(deadline)", symbol: "clock", tint: .orange)
                }
            }
            if let placement = entry.placement {
                Badge(
                    text: placement.isReminder ? "미리 알림에 있음" : "캘린더에 있음",
                    symbol: placement.isReminder ? "checklist" : "calendar.badge.checkmark",
                    tint: .green
                )
            }
            if !model.note(for: entry).isEmpty {
                Badge(text: "메모", symbol: "text.bubble")
            }
            // Says out loud that the reader overruled the model here, so the
            // screen never quietly disagrees with the report it came from.
            if entry.isReclassified {
                Badge(text: "직접 옮김", symbol: "hand.point.up.left", tint: .snuBlueLabel)
            }
        }
    }

    private var sourceSymbol: String {
        switch entry.source {
        case SourceName.gmail: "envelope"
        case SourceName.slack: "number"
        case SourceName.messages: "message"
        case SourceName.calendar: "calendar"
        case SourceName.web: "globe"
        case SourceName.etl: "graduationcap"
        default: "tray"
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            field("맥락", entry.summary)
            if let action = entry.nextAction { field("요청", action) }
            field("발신", "\(entry.source) · \(entry.author.isEmpty ? "발신자 미상" : entry.author)")
            field("도착", entry.receivedText)
            if let deadline = entry.deadlineText { field("마감", deadline) }
            if let placement = entry.placement {
                field("캘린더", placement.date.formatted(date: .abbreviated, time: placement.isReminder ? .omitted : .shortened))
            }
            if !entry.bodyText.isEmpty { original }

            HStack(spacing: Spacing.s) {
                Text("메모").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                TextField("나중에 나에게 남길 한 줄", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .focused($noteFocused)
                    .onSubmit { model.setNote(note, for: entry) }
            }

            HStack(spacing: Spacing.s) {
                Button("원문 열기", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(entry.link) }
                    .buttonStyle(.bordered)
                    .help(entry.link.absoluteString)

                if entry.placement == nil {
                    Button("캘린더에 추가", systemImage: "calendar.badge.plus") {
                        Task { await model.schedule(entry) }
                    }
                    .buttonStyle(.bordered)
                    .help(scheduleHelp)

                    Menu {
                        Button("날짜 정해서 일정 추가…", systemImage: "calendar") { model.ask(entry, asReminder: false) }
                        Button("미리 알림으로 보내기…", systemImage: "checklist") { model.ask(entry, asReminder: true) }
                    } label: {
                        Label("다른 방식", systemImage: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                } else {
                    Button("캘린더에서 지우기", systemImage: "calendar.badge.minus") { model.unschedule(entry) }
                        .buttonStyle(.bordered)
                        .help("\(AgentCalendar.title) 캘린더에서 이 항목을 지웁니다")
                }

                Menu {
                    ForEach(entry.bucket.neighbours) { bucket in
                        Button(bucket.moveVerb, systemImage: bucket == .action ? "arrow.up" : "arrow.down") {
                            model.move(entry, to: bucket)
                        }
                    }
                    if entry.isReclassified {
                        Divider()
                        Button("모델 분류(\(BriefingArchiveModel.Bucket(entry.item.category).rawValue))로 되돌리기", systemImage: "arrow.uturn.backward") {
                            model.clearCategoryOverride(entry)
                        }
                    }
                    Divider()
                    Button("이 항목만 다시 분석", systemImage: "arrow.clockwise") {
                        Task { await model.reanalyze(entry) }
                    }
                    .disabled(model.isReanalyzing || entry.bodyText.isEmpty)
                } label: {
                    Label("분류 바꾸기", systemImage: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("이 항목을 다른 칸으로 옮기거나, 저장된 본문으로 다시 분석합니다")

                Spacer()
            }
        }
        .padding(.leading, 24)
        .onAppear { note = model.note(for: entry) }
        .onChange(of: noteFocused) { _, focused in
            if !focused { model.setNote(note, for: entry) }
        }
        // Collapsing the row tears the field down without ever moving focus, so
        // without this a note typed and then collapsed would be thrown away.
        // Safe here because these rows are in a plain `VStack`, not a lazy one:
        // scrolling past a row does not destroy it.
        .onDisappear { model.setNote(note, for: entry) }
    }

    /// The message as it arrived. Shown short by default: most of these are
    /// notices whose first two lines say everything, and a full mail body under
    /// every row would bury the next item.
    private var original: some View {
        VStack(alignment: .leading, spacing: 2) {
            field("원문", showsWholeBody ? entry.bodyText : entry.bodyPreview)
            if entry.hasLongBody {
                Button(showsWholeBody ? "접기" : "본문 더 보기") { showsWholeBody.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 48)
            }
        }
    }

    private var scheduleHelp: String {
        guard let parsed = entry.suggestedDate(), parsed.isConfident else {
            return "마감이 분명하지 않아 날짜를 확인하는 창이 열립니다"
        }
        let when = parsed.includesTime
            ? parsed.date.formatted(date: .abbreviated, time: .shortened)
            : parsed.date.formatted(date: .abbreviated, time: .omitted)
        return "\(when)로 \(AgentCalendar.title) 캘린더에 바로 넣습니다"
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String) -> some View {
        BriefingField(label: label, value: value)
    }
}

/// 항목을 펼쳤을 때 나오는 `맥락`·`요청`·`도착` 같은 한 줄.
///
/// 보관함과 일정 달력이 같은 항목을 서로 다른 축으로 보여 주지만, **펼쳤을 때 읽는
/// 것은 같아야 한다.** 라벨 너비 하나가 두 화면에서 다르면 같은 메일이 두 모양으로
/// 보이고, 그때부터 둘 중 어느 쪽이 맞는지 확인하게 된다.
struct BriefingField: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(value)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One place that writes to the pasteboard, so every copy in this screen
/// produces the same thing.
enum ArchiveClipboard {
    static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct Badge: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - 날짜 확인 창

/// Shown when the deadline was written in a way that could mean more than one
/// day — or was not written at all. Pre-filled with the best reading of it, so
/// confirming is one click and correcting is two.
struct ScheduleSheet: View {
    let entry: BriefingArchiveModel.Entry
    @ObservedObject var model: BriefingArchiveModel

    @State private var date = Date()
    @State private var includesTime = true
    @State private var asReminder = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("캘린더에 추가").font(.headline)
                Text(entry.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let raw = entry.deadlineText {
                Label("원문의 마감 표기: \(raw)", systemImage: "text.quote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("보낼 곳", selection: $asReminder) {
                Text("캘린더 일정").tag(false)
                Text("미리 알림").tag(true)
            }
            .pickerStyle(.segmented)

            DatePicker(
                "날짜",
                selection: $date,
                displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date]
            )
            .datePickerStyle(.compact)

            Toggle("시각도 정하기", isOn: $includesTime)
                .help("끄면 하루 종일 일정으로 들어갑니다")

            Label("\(AgentCalendar.title) 캘린더에만 씁니다. 원래 쓰던 캘린더는 건드리지 않습니다.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("취소") { model.scheduling = nil }
                Button("추가") {
                    Task { await model.place(entry, at: date, includesTime: includesTime, asReminder: asReminder) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.snuBlue)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420)
        .onAppear {
            asReminder = model.schedulingPrefersReminder
            guard let parsed = entry.suggestedDate() else {
                // Nothing readable in the deadline: tomorrow morning is a better
                // starting point than "now", which is already in the past by the
                // time anyone clicks.
                date = KoreanDeadline.calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date().addingTimeInterval(86_400)) ?? Date()
                return
            }
            date = parsed.date
            includesTime = parsed.includesTime
        }
    }
}
