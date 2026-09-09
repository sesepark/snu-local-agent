import SwiftUI
import AppKit

/// 일정 달력 — 브리핑에서 나온 마감과, 사람이 캘린더·미리 알림으로 넘긴 일정을 한 달치로
/// 모아 놓은 화면.
///
/// 보관함이 이미 같은 항목들을 보여 주는데 화면을 하나 더 두는 이유가 있다. **보관함의
/// 축은 "언제 온 메일인가"이고, 마감의 축은 "언제까지인가"다.** 그 둘은 다른 날짜다.
/// 화요일에 온 메일의 마감이 다다음 주 금요일이면, 보관함에서 그것을 보려면 화요일을
/// 펼쳐야 하는데 그때 사람이 알고 싶은 것은 "이번 주에 뭐가 있지"다. 날짜를 축으로 놓으면
/// 그 질문에 한눈에 답할 수 있고, 같은 자료가 두 번 저장되지도 않는다 — 이 화면은
/// 보관함이 들고 있는 것을 다른 축으로 다시 그릴 뿐이다.
struct BriefingCalendarView: View {
    @ObservedObject var controller: AutomationController

    /// 보고 있는 달의 아무 날. 달을 옮길 때만 바뀐다.
    @State private var month = Date()
    /// 고른 날. 처음에는 오늘이다.
    @State private var selectedDay = KoreanDeadline.calendar.startOfDay(for: Date())
    @State private var showsUndated = false
    /// 펼쳐 놓은 줄. 달력의 한 칸에는 여러 건이 놓이므로 **여러 줄을 동시에** 펼칠 수
    /// 있어야 한다 — 같은 날의 두 마감을 견주어 보는 것이 이 화면에서 가장 자주 하는 일이다.
    @State private var expanded: Set<String> = []
    /// 본문을 끝까지 펼친 줄. 대부분의 공지는 첫 두 줄이 전부라 기본은 발췌다.
    @State private var wholeBody: Set<String> = []

    private var model: BriefingArchiveModel { controller.briefingArchive }

    /// 화면을 눌러 보지 않고도 펼친 모양을 확인할 수 있게 하는 점검용 인자.
    /// `--music-query`와 같은 자리의 것이다 — 눌러야만 볼 수 있는
    /// 상태는 그 길이 없으면 화면 캡처로 확인할 수가 없다.
    private static let expandsOnLaunch = CommandLine.arguments.contains("--calendar-expand")
    private static var calendar: Calendar { KoreanDeadline.calendar }

    var body: some View {
        WorkspaceScreen(title: AppSection.briefingCalendar.title, subtitle: AppSection.briefingCalendar.subtitle) {
            if model.days.isEmpty {
                EmptyResults(
                    symbol: "calendar",
                    message: "아직 브리핑이 없습니다.\n`자동 브리핑`에서 인박스 정리를 한 번 돌리면 여기에 마감이 놓입니다."
                )
            } else {
                grid
                dayList
                undated
            }
        }
        .textSelection(.enabled)
        .animation(.appContent, value: selectedDay)
        .animation(.appContent, value: month)
        .animation(.appContent, value: showsUndated)
        .animation(.appContent, value: expanded)
        .animation(.appContent, value: wholeBody)
        // 다른 날을 고르면 펼쳐 둔 것은 닫는다. 열어 둔 채로 두면 돌아왔을 때 화면이
        // 왜 그렇게 길어져 있는지 알 수 없다.
        .onChange(of: selectedDay) { _, _ in expanded.removeAll(); wholeBody.removeAll() }
        .onAppear {
            model.reload()
            // 오늘로 돌아온다. 며칠 만에 다시 열었을 때 지난달을 펼쳐 두는 것은
            // 이 화면이 답해야 하는 질문("이번 주에 뭐가 있지")과 정반대다.
            let today = Self.calendar.startOfDay(for: Date())
            selectedDay = today
            month = today
            if Self.expandsOnLaunch {
                expanded = Set((byDay[today] ?? []).map(\.id))
            }
        }
        .toolbar { toolbar }
        // 보관함과 같은 시트다. 이 화면에서 `캘린더에 추가`를 눌렀을 때 날짜를 확인하는
        // 창이 뜨지 않으면, 마감이 애매한 항목은 아무 일도 일어나지 않은 것처럼 보인다.
        .sheet(item: Binding(get: { model.scheduling }, set: { model.scheduling = $0 })) { entry in
            ScheduleSheet(entry: entry, model: model)
        }
    }

    // MARK: - 툴바

    /// **달을 옮기는 자리는 툴바다.** 처음에는 본문 맨 위에 두었는데, `WorkspaceScreen`의
    /// 스크롤이 툴바 아래로 흐르는 구조라 그 줄이 통째로 툴바에 가려 흐릿해졌다 —
    /// `‹`는 창 제목에 덮여 아예 보이지 않았고 달 이름은 읽을 수 없었다. 스크롤과 함께
    /// 움직이는 자리에 **꼭 필요한 조작**을 두면 언젠가 가려진다. 캘린더 앱이 같은 것을
    /// 툴바에 두는 이유도 이것이다.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button("이전 달", systemImage: "chevron.left") { step(-1) }
                .help("이전 달")
        }
        ToolbarItem {
            Text(Self.monthTitle(month))
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        ToolbarItem {
            Button("다음 달", systemImage: "chevron.right") { step(1) }
                .help("다음 달")
        }
        // 달을 옮기는 셋과 `오늘`은 하는 일이 다르므로 유리 덩이도 나눈다. 한 덩이에
        // 넣으면 `›`와 `오늘`이 붙어 서서 잘못 누르기 쉽다.
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button("오늘", systemImage: "calendar.badge.clock") { goToToday() }
                .toolbarKeepsTitle()
                .disabled(isShowingToday)
                .help("오늘이 있는 달로 돌아갑니다")
        }
        ToolbarSpacer(.flexible)
        ToolbarItem {
            Label(summary.text, systemImage: "flag.checkered")
                .font(.caption)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(summary.isAlarming ? Color.orange : .secondary)
                .help("이 달에 아직 남은 마감·일정의 수입니다")
        }
        ToolbarItem {
            Button("보관함 열기", systemImage: "checklist") { controller.section = .archive }
                .toolbarKeepsTitle()
                .help("같은 항목을 브리핑이 만들어진 날짜별로 봅니다")
        }
    }

    /// 오늘이 있는 달을 보고 있고 오늘을 고른 상태인가. `오늘` 버튼이 아무 일도 하지 않을
    /// 때 눌리지 않게 한다.
    private var isShowingToday: Bool {
        let today = Self.calendar.startOfDay(for: Date())
        return selectedDay == today && Self.calendar.isDate(month, equalTo: today, toGranularity: .month)
    }

    // MARK: - 범례

    /// 무엇이 무슨 색인지. 색만 두고 설명을 두지 않으면 주황이 "늦음"인지 "중요"인지
    /// 화면이 말해 주지 않는다. 격자 **아래**에 두는 이유는, 범례는 한 번 읽고 마는
    /// 것이라 매번 격자를 밀어 내릴 값어치가 없기 때문이다.
    private var legendRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.l) {
                Text("색").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                legend(color: .orange, text: "지난 마감")
                legend(color: .snuBlue, text: "마감")
                legend(color: .secondary, text: "넘긴 일정 · 끝낸 것 · 기타")
                Spacer(minLength: 0)
                Text("칸의 숫자는 아직 남은 건수입니다")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: Spacing.l) {
                Text("모양").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                ForEach(BriefingArchiveModel.Bucket.allCases) { bucket in
                    Label(bucket.rawValue, systemImage: bucket.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - 달력

    private var grid: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                ForEach(Array(Self.weekdayNames.enumerated()), id: \.offset) { index, name in
                    Text(name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Self.weekdayColor(index))
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: Spacing.xs) {
                    ForEach(week, id: \.timeIntervalSince1970) { day in
                        dayCell(day)
                    }
                }
            }
            legendRow.padding(.top, Spacing.xs)
        }
        .padding(Spacing.l)
        .glassPanel()
    }

    private func dayCell(_ day: Date) -> some View {
        let items = byDay[day] ?? []
        let remaining = items.filter { !$0.isDone }.count
        let isThisMonth = Self.calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = Self.calendar.isDateInToday(day)
        let isSelected = day == selectedDay
        // `isLate`가 이미 끝낸 것을 걸러 내므로, 다 끝낸 날의 칸은 붉게 서지 않는다.
        let late = items.contains(where: nags)
        return Button {
            selectedDay = day
            // 다른 달의 날을 누르면 그 달로 넘어간다. 누른 날이 화면에서 흐릿한 채로
            // 남아 있으면, 아래 목록이 무엇을 보여 주는지가 어긋나 보인다.
            if !isThisMonth { month = day }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text("\(Self.calendar.component(.day, from: day))")
                        .font(.caption.weight(isToday ? .bold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isThisMonth
                                         ? (isToday ? AnyShapeStyle(Color.snuBlueLabel) : AnyShapeStyle(.primary))
                                         : AnyShapeStyle(.quaternary))
                    Spacer(minLength: 0)
                    // **남은 건수**를 적는다. 총계를 적으면 이미 다 끝낸 날에도 `6`이
                    // 서 있어서, 달력을 훑는 사람이 할 일이 여섯 개 남은 날로 읽는다.
                    if remaining > 0 {
                        Text("\(remaining)")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if !items.isEmpty {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("이 날 것은 모두 끝냈습니다")
                    }
                }
                ForEach(items.prefix(2)) { item in
                    HStack(spacing: 3) {
                        // 분류는 **모양**으로, 마감 상태는 **색**으로 나눈다. 둘 다 색을
                        // 쓰면 주황이 "지났다"인지 "중요하다"인지 화면이 말해 주지 못한다.
                        Image(systemName: item.entry.bucket.symbol)
                            .font(.system(size: 8))
                            .imageScale(.small)
                        Text(item.entry.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .strikethrough(item.isDone, color: .secondary)
                    }
                    .font(.caption2)
                    .foregroundStyle(color(for: item))
                }
                if items.count > 2 {
                    Text("+\(items.count - 2)").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.xs)
            // 칸 높이는 못 박는다. 안에 든 것에 맡기면 항목이 있는 주와 없는 주의 높이가
            // 달라져서, 달을 넘길 때마다 격자가 출렁인다.
            .frame(maxWidth: .infinity, minHeight: 62, maxHeight: 62, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .fill(isSelected ? Color.snuBlue.opacity(0.16) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                    .strokeBorder(late ? Color.orange.opacity(0.55)
                                  : (isToday ? Color.snuBlue.opacity(0.55) : Color.primary.opacity(0.06)),
                                  lineWidth: (late || isToday) ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(items.isEmpty
              ? Self.dayTitle(day)
              : "\(Self.dayTitle(day)) · 남은 \(remaining)건 / 모두 \(items.count)건")
    }

    /// 규칙은 모델이 들고 있다. 화면은 부르기만 한다.
    private func nags(_ item: BriefingArchiveModel.DatedEntry) -> Bool { item.nags() }

    /// 줄의 색. **사람이 내린 분류가 모델의 급함보다 앞선다.**
    ///
    /// `기타`로 내린 항목은 마감이 지났더라도 붉게 서지 않는다. 그것은 "이 일은 나와
    /// 상관없다"고 사람이 이미 말한 것이고, 그 위에 앱이 다시 재촉하는 것은 옮기기를
    /// 무시하는 일이다. 이 순서는 이월과 보관함이 이미 따르고 있는 규칙과 같다.
    private func color(for item: BriefingArchiveModel.DatedEntry) -> Color {
        if item.isDone { return .secondary }
        if item.entry.bucket == .other { return Color.secondary.opacity(0.6) }
        if item.isLate() { return .orange }
        return item.kind == .scheduled ? .secondary : .snuBlueLabel
    }

    // MARK: - 고른 날

    private var dayList: some View {
        GroupBox(dayListTitle) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                let items = byDay[selectedDay] ?? []
                if items.isEmpty {
                    Text("이 날에 놓인 마감이나 일정이 없습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(items) { item in
                        row(item)
                        if expanded.contains(item.id) {
                            detail(item).transition(.appCard)
                        }
                        if item.id != items.last?.id { Divider() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ item: BriefingArchiveModel.DatedEntry) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            // 체크는 보관함의 것과 같은 값을 만진다. 달력에서 끝냈다고 체크한 일이
            // 보관함에서 아직 남아 있으면 두 화면이 같은 일에 대해 다른 말을 한다.
            Toggle(isOn: Binding(
                get: { item.isDone },
                set: { _ in model.toggleDone(item.entry) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(item.isDone ? "끝낸 것으로 표시되어 있습니다" : "끝낸 것으로 표시합니다")

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.s) {
                    // 어느 칸의 항목인지. 보관함이 이미 정해 둔 값이라 여기서 다시
                    // 판단하지 않고 그대로 옮겨 적는다 — 두 화면이 같은 메일을 두고
                    // 다른 말을 하면 어느 쪽이 맞는지 확인하러 가야 한다.
                    Badge(
                        text: item.entry.bucket.rawValue,
                        symbol: item.entry.bucket.symbol,
                        tint: item.entry.bucket == .action ? Color.snuBlueLabel : .secondary
                    )
                    Label(item.kind.title, systemImage: item.kind.symbol)
                        .font(.caption2.weight(.medium))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(nags(item) ? Color.orange : Color.snuBlueLabel)
                    if let time = item.timeText {
                        Text(time).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text("시간 미정").font(.caption).foregroundStyle(.tertiary)
                    }
                    if nags(item) {
                        Text("지났습니다").font(.caption.weight(.medium)).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                }
                Text(item.entry.title)
                    .font(.callout.weight(.medium))
                    .strikethrough(item.isDone, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(item.entry.source) · \(item.entry.author.isEmpty ? "발신자 미상" : item.entry.author) · \(item.entry.receivedText) 도착")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // 원문에 적힌 마감은 **위 줄과 다를 때만** 보여 준다. 같은 값을 두 번
                // 적으면 한 줄이 늘어나는 만큼 읽을 것이 줄어든다 — `마감 11:00` 아래에
                // `적힌 마감: 9월 3일 11시 00분`은 새로 말해 주는 것이 없다.
                if item.kind == .deadline, let deadline = item.entry.deadlineText, deadline != Self.sameDayText(item) {
                    Text("적힌 마감: \(deadline)").font(.caption).foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: expanded.contains(item.id) ? "chevron.down" : "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.vertical, Spacing.xs)
        // 글자 위에서 끄는 것은 선택이고, 빈 자리를 누르는 것은 펼치기다. 보관함의
        // 줄과 같은 규칙이라 두 화면에서 손이 다르게 움직이지 않는다.
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { toggle(item) }
        }
    }

    private func toggle(_ item: BriefingArchiveModel.DatedEntry) {
        if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
    }

    /// 펼쳤을 때. **보관함으로 건너가지 않고 여기서 읽을 수 있어야 한다** — 달력에서
    /// 마감을 보다가 "이게 무슨 메일이었지"를 확인하려고 화면을 옮기면, 돌아왔을 때
    /// 보던 날짜를 다시 찾아야 한다.
    ///
    /// 보관함의 펼친 줄과 같은 것을 보여 주되 조작은 이 화면의 것만 둔다. 분류를 옮기고
    /// 다시 분석하는 일은 날짜가 아니라 분류의 문제라 보관함에 남는다.
    @ViewBuilder
    private func detail(_ item: BriefingArchiveModel.DatedEntry) -> some View {
        let entry = item.entry
        VStack(alignment: .leading, spacing: Spacing.s) {
            BriefingField(label: "맥락", value: entry.summary)
            if let action = entry.nextAction { BriefingField(label: "요청", value: action) }
            // 발신과 도착은 **접힌 줄이 이미 적고 있다.** 보관함에서는 그 줄이 배지만
            // 달고 있어서 펼쳤을 때 처음 나오지만, 여기서는 같은 말을 두 번 하는 것이
            // 된다. 펼쳐서 새로 얻는 것만 남긴다.
            // 마감은 **이 줄이 이미 말하고 있지 않을 때만** 적는다. 9월 3일 칸에서
            // `마감 11:00`이라고 적어 놓고 아래에 다시 `9월 3일 11시 00분`을 적으면
            // 한 줄이 늘어나는 만큼 읽을 것이 줄어든다. 사람이 넘긴 일정(`일정`) 줄에서는
            // 마감이 다른 날일 수 있으므로 그때는 새로운 정보다.
            if let deadline = entry.deadlineText,
               item.kind == .scheduled || deadline != Self.sameDayText(item) {
                BriefingField(label: "마감", value: deadline)
            }
            if let placement = entry.placement {
                BriefingField(
                    label: "캘린더",
                    value: placement.date.formatted(date: .abbreviated, time: placement.isReminder ? .omitted : .shortened)
                        + (placement.isReminder ? " · 미리 알림" : "")
                )
            }
            if !entry.mark.note.isEmpty { BriefingField(label: "메모", value: entry.mark.note) }
            if !entry.bodyText.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    BriefingField(label: "원문", value: wholeBody.contains(item.id) ? entry.bodyText : entry.bodyPreview)
                    if entry.hasLongBody {
                        Button(wholeBody.contains(item.id) ? "접기" : "본문 더 보기") {
                            if wholeBody.contains(item.id) { wholeBody.remove(item.id) } else { wholeBody.insert(item.id) }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .padding(.leading, 48)
                    }
                }
            }

            HStack(spacing: Spacing.s) {
                Button("원문 열기", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(entry.link) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(entry.link.absoluteString)

                Button("복사", systemImage: "doc.on.doc") { ArchiveClipboard.put(entry.plainText) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("제목·발신·마감·본문을 글로 복사합니다")

                // 날짜를 다루는 화면이므로 일정으로 넘기는 것은 여기 있는 것이 맞다.
                if entry.placement == nil {
                    Button("캘린더에 추가", systemImage: "calendar.badge.plus") {
                        Task { await model.schedule(entry) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Menu {
                        Button("날짜 정해서 일정 추가…", systemImage: "calendar") { model.ask(entry, asReminder: false) }
                        Button("미리 알림으로 보내기…", systemImage: "checklist") { model.ask(entry, asReminder: true) }
                    } label: {
                        Label("다른 방식", systemImage: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                } else {
                    Button("캘린더에서 지우기", systemImage: "calendar.badge.minus") { model.unschedule(entry) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Button("보관함에서 보기", systemImage: "checklist") {
                    model.revealInArchive(item)
                    controller.section = .archive
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("분류를 옮기거나 메모를 남기려면 보관함에서 엽니다")

                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 24)
        .padding(.bottom, Spacing.xs)
    }

    // MARK: - 날짜를 읽지 못한 것

    @ViewBuilder
    private var undated: some View {
        let entries = model.undatedDeadlineEntries()
        if !entries.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Button {
                        showsUndated.toggle()
                    } label: {
                        HStack(spacing: Spacing.s) {
                            Label("달력에 놓지 못한 항목 \(entries.count)개", systemImage: "questionmark.circle")
                                .font(.headline)
                            Spacer()
                            Image(systemName: showsUndated ? "chevron.up" : "chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)

                    Text("마감이 적혀 있지만 날짜로 읽히지 않는 것들입니다 — `가급적 빠른 시일 내`처럼 날짜가 아닌 말이 대부분입니다. 달력이 조용히 빠뜨리면 없는 일처럼 보이므로 여기에 세어 둡니다. 보관함에서 날짜를 직접 골라 캘린더로 넘기면 이 달력에 놓입니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if showsUndated {
                        ForEach(entries.prefix(20)) { entry in
                            HStack(alignment: .top, spacing: Spacing.s) {
                                Text(entry.title)
                                    .font(.callout)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                Text(entry.item.deadline)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                                Button("보관함에서 보기") {
                                    model.selectedDateKey = entry.dateKey
                                    model.search = ""
                                    model.expanded.insert(entry.id)
                                    controller.section = .archive
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                        if entries.count > 20 {
                            Text("그 밖에 \(entries.count - 20)개가 더 있습니다.")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var dayListTitle: String {
        let items = byDay[selectedDay] ?? []
        let remaining = items.filter { !$0.isDone }.count
        guard !items.isEmpty else { return Self.dayTitle(selectedDay) }
        return remaining == items.count
            ? "\(Self.dayTitle(selectedDay)) · \(remaining)건"
            : "\(Self.dayTitle(selectedDay)) · 남은 \(remaining)건 · 끝낸 \(items.count - remaining)건"
    }

    // MARK: - 계산

    private var byDay: [Date: [BriefingArchiveModel.DatedEntry]] {
        model.datedEntriesByDay()
    }

    /// 이 달에 놓인 것들. 툴바 배지가 읽는 값이다.
    private var summary: (text: String, isAlarming: Bool) {
        let items = byDay.filter { Self.calendar.isDate($0.key, equalTo: month, toGranularity: .month) }
            .flatMap(\.value)
        guard !items.isEmpty else { return ("이 달에 놓인 것 없음", false) }
        // 끝낸 것은 세지 않는다. 배지가 답하는 질문은 "이 달에 얼마나 남았나"이고,
        // 다 끝낸 뒤에도 같은 숫자가 서 있으면 그 질문에 답하지 못한다.
        let remaining = items.filter { !$0.isDone }
        guard !remaining.isEmpty else { return ("이 달 것은 모두 끝냈습니다", false) }
        // `오늘 꼭 할 일`의 수를 먼저 적는다. 남은 28건 가운데 실제로 해야 하는 것이
        // 12건인지 28건인지는 전혀 다른 이야기이고, 배지 한 줄이 답할 수 있는 질문 중
        // 가장 값진 것이다.
        let actions = remaining.filter { $0.entry.bucket == .action }.count
        let late = remaining.filter(nags).count
        var text = "할 일 \(actions) / 남은 \(remaining.count)건"
        if late > 0 { text += " · 지난 마감 \(late)" }
        return (text, late > 0)
    }

    /// 달력에 그릴 주들. 그 달의 1일이 든 주의 일요일부터, 마지막 날이 든 주의 토요일까지.
    ///
    /// 주 수를 6으로 고정하지 않는다. 대부분의 달은 5주이고, 여섯 번째 줄을 늘 비워 두면
    /// 화면 아래가 그만큼 잘린다.
    private var weeks: [[Date]] {
        let calendar = Self.calendar
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: interval.start),
              // `end`는 다음 달 1일 0시라 그대로 쓰면 한 주가 더 붙는다.
              let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end),
              let lastWeek = calendar.dateInterval(of: .weekOfMonth, for: lastDay)
        else { return [] }
        var result: [[Date]] = []
        var cursor = calendar.startOfDay(for: firstWeek.start)
        let end = calendar.startOfDay(for: lastWeek.end)
        while cursor < end {
            var week: [Date] = []
            for offset in 0 ..< 7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: cursor) else { break }
                week.append(calendar.startOfDay(for: day))
            }
            result.append(week)
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private func step(_ months: Int) {
        guard let next = Self.calendar.date(byAdding: .month, value: months, to: month) else { return }
        month = next
    }

    private func goToToday() {
        let today = Self.calendar.startOfDay(for: Date())
        month = today
        selectedDay = today
    }

    /// 이 항목의 마감을 위 줄이 이미 말하고 있는 모양으로 적은 것. 같으면 아래 줄을
    /// 그리지 않는다.
    private static func sameDayText(_ item: BriefingArchiveModel.DatedEntry) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = KoreanDeadline.timeZone
        formatter.dateFormat = item.includesTime ? "M월 d일 HH시 mm분" : "M월 d일"
        return formatter.string(from: item.date)
    }

    private static let weekdayNames = ["일", "월", "화", "수", "목", "금", "토"]

    private static func weekdayColor(_ index: Int) -> Color {
        switch index {
        case 0: .red.opacity(0.8)
        case 6: .blue.opacity(0.8)
        default: .secondary
        }
    }

    private static func monthTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = KoreanDeadline.timeZone
        formatter.dateFormat = "yyyy년 M월"
        return formatter.string(from: date)
    }

    private static func dayTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = KoreanDeadline.timeZone
        formatter.dateFormat = "M월 d일 (E)"
        return formatter.string(from: date)
    }
}
