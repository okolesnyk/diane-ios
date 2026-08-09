import DianeKit
import SwiftUI

/// Page 3 (M9e design): the Apple-familiar calendar — a collapsible
/// month↔week header, the member chip filter, full-width Agenda❘Day
/// segments, a rolling agenda, and a Day grid (calendar-color line +
/// member-tint fill, hairline now-line, drag-to-create). Swipe pages weeks
/// (collapsed) or months (expanded); the month title opens the month/year
/// long-jump picker; Today is the one return-home control.
struct CalendarPageView: View {
    let context: SignedInContext
    /// The caller's stack takes the detail pushes (nav rule 2). The page
    /// itself never owns a NavigationStack — nesting one silently killed
    /// the Home push — and always wears its own root bar: a module looks
    /// the same from the bottom menu and from Home (owner 2026-08-08).
    var open: (DetailRoute) -> Void = { _ in }
    @Environment(AppState.self) private var appState
    @Environment(SyncSignals.self) private var signals
    @Environment(HouseholdClock.self) private var clock

    /// nil = follow the household's today.
    @State private var selectedDay: String?
    /// Header + mode survive relaunch ("you reopen the calendar you left").
    @AppStorage("calExpanded") private var expanded = false
    @AppStorage("calDayMode") private var dayMode = false
    @State private var data: Loadable<PageData> = .loading
    @State private var activeSheet: Sheet?
    /// The drag-create draft: (startMinutes, endMinutes) while dragging.
    @State private var draft: (start: Int, end: Int)?
    /// Where the hold landed — the draft grows from here in both directions.
    @State private var draftAnchor: Int?
    /// Member chip filter — one app-wide store (owner 2026-08-06).
    @Environment(MemberFilterStore.self) private var filter
    /// Member tint — the device-local display pref.
    @AppStorage("memberTint") private var tintOn = true
    /// The month-title long-jump picker (mock: year ‹ › row + month grid).
    @State private var showJumpPicker = false
    @State private var pickerYear = 2026

    struct PageData: Equatable {
        var events: [Components.Schemas.EventOccurrence]
        /// TODAY's actionable chores — the chips' progress rings + late dots.
        var todayChores: [MyDayLogic.Chore]
        var members: [Components.Schemas.Member]
        var calendars: [Components.Schemas.Calendar]
        /// The [from,to) range the events cover — refetch when it moves.
        var range: (String, String)

        static func == (lhs: PageData, rhs: PageData) -> Bool {
            lhs.events == rhs.events && lhs.todayChores == rhs.todayChores
                && lhs.members == rhs.members && lhs.calendars == rhs.calendars
                && lhs.range == rhs.range
        }
    }

    enum Sheet: Identifiable {
        case newEvent(date: String, time: String?, end: String?)

        var id: String {
            switch self {
            case .newEvent(let date, let time, _): "new-\(date)-\(time ?? "")"
            }
        }
    }

    private var logic: CalendarPageLogic {
        // System week start out of the box (Settings override lands M9e-8).
        var calendar = Foundation.Calendar.current
        calendar.timeZone = clock.timeZone
        return CalendarPageLogic(calendar: calendar)
    }

    private var day: String { selectedDay ?? clock.today }

    private var anchorDate: Date {
        let parts = day.split(separator: "-").compactMap { Int(String($0)) }
        var components = DateComponents()
        guard parts.count == 3 else { return .now }
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        components.hour = 12
        return logic.calendar.date(from: components) ?? .now
    }

    var body: some View {
        VStack(spacing: 0) {
            DianeTopBar(
                context: context,
                title: logic.monthTitle(anchorDate),
                action: {
                    pickerYear = Int(day.prefix(4)) ?? 2026
                    showJumpPicker = true
                },
                chevron: true,
                showToday: day != clock.today,
                onToday: { selectedDay = nil },
                popover: $showJumpPicker,
                popoverContent: { AnyView(jumpPicker.presentationCompactAdaptation(.popover)) }
            )
            header
            chips
            Picker("View", selection: $dayMode) {
                Text("Agenda").tag(false)
                Text("Day").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            Divider()
            if dayMode { dayGrid } else { agendaList }
        }
        .dianeRootChrome()
        .task(id: "\(signals.version(of: [.events, .chores, .calendars, .members, .settings]))|\(fetchRange.from)|\(fetchRange.to)") {
            await load()
        }
        .dianeDetailDestinations(
            context: context,
            members: data.value?.members ?? [],
            onChanged: { Task { await load() } }
        )
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newEvent(let date, let time, let end):
                EventFormView(
                    context: context,
                    members: data.value?.members ?? [],
                    mode: .create(defaultDate: date, defaultTime: time, defaultEnd: end),
                    onSaved: { Task { await load() } }
                )
            }
        }
    }

    // MARK: - Month/year long-jump picker (quickly between months AND years)

    private var jumpPicker: some View {
        let months = DateFormatter().shortMonthSymbols ?? []
        let currentMonth = Int(day.dropFirst(5).prefix(2)) ?? 0
        let currentYear = Int(day.prefix(4)) ?? 0
        return VStack(spacing: 10) {
            HStack(spacing: 18) {
                Button { pickerYear -= 1 } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Previous year")
                Text(String(pickerYear))
                    .font(.headline)
                    .monospacedDigit()
                Button { pickerYear += 1 } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Next year")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 6) {
                ForEach(Array(months.enumerated()), id: \.offset) { index, name in
                    let isCurrent = pickerYear == currentYear && index + 1 == currentMonth
                    Button {
                        select(CalendarPageLogic.monthJumpTarget(
                            year: pickerYear, month: index + 1, today: clock.today
                        ))
                        showJumpPicker = false
                    } label: {
                        Text(name)
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(
                                isCurrent ? Color.accentColor : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(isCurrent ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 280)
    }

    // MARK: - Chips (Family Day's filter, approved harmonization)

    private var members: [Components.Schemas.Member] { data.value?.members ?? [] }
    private var allIDs: [String] { members.map(\.id) }
    private var effectiveSelected: Set<String> { filter.effective(all: allIDs) }
    private var isFiltered: Bool { filter.isFiltered && filter.selected.count < allIDs.count }

    private var chips: some View {
        HStack(spacing: 14) {
            ForEach(members, id: \.id) { member in
                let chip = FamilyDayLogic.chip(for: member.id, chores: data.value?.todayChores ?? [])
                let isOn = effectiveSelected.contains(member.id)
                VStack(spacing: 3) {
                    ZStack {
                        Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: chip.progress)
                            .stroke(
                                Color(hex: member.color) ?? .accentColor,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        MemberAvatarView(name: member.name, colorHex: member.color, avatar: member.avatar, size: 38)
                        if chip.hasLate {
                            Circle().fill(.red).frame(width: 8, height: 8).offset(x: 16, y: -16)
                        }
                    }
                    .frame(width: 46, height: 46)
                    Text(member.name).font(.caption2).lineLimit(1)
                }
                .opacity(isOn ? 1 : 0.35)
                // Double-tap OR long-press solos — both on trial (owner
                // 2026-08-08).
                .onTapGesture(count: 2) { filter.solo(member.id) }
                .onTapGesture { filter.toggle(member.id, all: allIDs) }
                .onLongPressGesture { filter.solo(member.id) }
                .accessibilityLabel("\(member.name)\(isOn ? "" : ", filtered out")")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    // MARK: - Header (collapsible month ↔ week; zero fixed controls)

    private var fetchRange: (from: String, to: String) {
        let base = expanded
            ? logic.monthQueryRange(containing: anchorDate)
            : logic.week.queryRange(anchor: anchorDate)
        // The rolling agenda shows selected+3 — extend past the header window.
        let agendaEnd = MyDayLogic.addDays(day, 4)
        return (base.from, max(base.to, agendaEnd))
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                ForEach(Array(logic.weekdayHeaders().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            if expanded {
                monthGrid
            } else {
                weekRow
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        // All gesture, no fixed controls: sideways pages, vertical collapses.
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                if abs(value.translation.width) > abs(value.translation.height) {
                    let direction = value.translation.width < 0 ? 1 : -1
                    withAnimation(.snappy) { page(by: direction) }
                } else {
                    withAnimation(.snappy) { expanded = value.translation.height > 0 }
                }
            }
        )
        .accessibilityAction(named: expanded ? "Collapse to week" : "Expand to month") {
            withAnimation(.snappy) { expanded.toggle() }
        }
    }

    private func page(by direction: Int) {
        if expanded {
            select(logic.week.dayString(logic.page(anchorDate, byMonths: direction)))
        } else {
            // Same landing rule as the day pages' strips (owner 2026-08-08):
            // forward = next week's first day, back = previous week's last.
            select(MyDayLogic.pagedStripTarget(
                from: day,
                forward: direction > 0,
                firstWeekday: logic.calendar.firstWeekday
            ))
        }
    }

    private func select(_ newDay: String) {
        selectedDay = newDay == clock.today ? nil : newDay
    }

    private var eventDays: Set<String> {
        guard let loaded = data.value else { return [] }
        let days = (expanded ? logic.monthCells(containing: anchorDate).map(\.day) : weekDayStrings)
        return logic.week.daysWithEvents(days: days, events: loaded.events)
    }

    private var weekDayStrings: [String] {
        logic.week.stripDays(anchor: anchorDate).map(logic.week.dayString)
    }

    private var monthGrid: some View {
        let cells = logic.monthCells(containing: anchorDate)
        let dots = eventDays
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
            ForEach(cells) { cell in
                dayCell(cell.day, number: cell.dayNumber, dim: !cell.inMonth, hasDot: dots.contains(cell.day))
            }
        }
    }

    private var weekRow: some View {
        let dots = eventDays
        return HStack(spacing: 0) {
            ForEach(weekDayStrings, id: \.self) { d in
                dayCell(d, number: Int(d.suffix(2)) ?? 0, dim: false, hasDot: dots.contains(d))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The SAME cell the day pages' strips use — one day grammar app-wide.
    private func dayCell(_ d: String, number: Int, dim: Bool, hasDot: Bool) -> some View {
        DayCell(
            date: d,
            weekday: nil, // the Sun–Sat header row above names the columns
            isSelected: d == day,
            isToday: d == clock.today,
            dim: dim,
            hasEvents: hasDot
        ) {
            select(d)
        }
    }

    // MARK: - Agenda (rolling: the selected day + the next three)

    @ViewBuilder
    private var agendaList: some View {
        switch data {
        case .loading:
            Spacer(); ProgressView(); Spacer()
        case .failed(let message):
            Spacer()
            ContentUnavailableView {
                Label("Couldn't load the calendar", systemImage: "wifi.slash")
            } description: { Text(message) } actions: {
                Button("Try again") { Task { await load() } }
            }
            Spacer()
        case .loaded(let loaded):
            ScrollViewReader { proxy in
                List {
                    ForEach(0..<4, id: \.self) { offset in
                        let d = MyDayLogic.addDays(day, offset)
                        let rows = logic.week.agenda(day: d, events: loaded.events)
                            .filter { FamilyDayLogic.visible($0, selected: effectiveSelected) }
                        Section {
                            if rows.isEmpty && offset != 0 {
                                Text("Nothing planned").font(.caption).foregroundStyle(.tertiary)
                                    .listRowSeparator(.hidden)
                            }
                            ForEach(rows, id: \.id) { event in
                                DetailRow(route: .event(event), open: open) {
                                    agendaRow(event, loaded: loaded)
                                }
                                .listRowBackground(tintWash(event))
                            }
                            if offset == 0 {
                                // ONE add affordance: the ghost row under the
                                // SELECTED day, moving with the selection.
                                Button {
                                    activeSheet = .newEvent(date: d, time: nil, end: nil)
                                } label: {
                                    GhostLabel(title: "New event")
                                }
                                .buttonStyle(.plain)
                                .listRowSeparator(.hidden)
                            }
                        } header: {
                            // One header anatomy: the date, always — today is
                            // marked by color, never by replacing the date.
                            Text(NavigationLogic.myDayTitle(for: d))
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .foregroundStyle(d == clock.today ? Color.accentColor : .secondary)
                                .contentShape(Rectangle())
                                .onTapGesture { select(d) }
                        }
                        .id(d)
                    }
                }
                .listStyle(.plain)
                .fontDesign(.rounded)
                .refreshable { await load() }
                .onChange(of: day) { _, newDay in
                    withAnimation { proxy.scrollTo(newDay, anchor: .top) }
                }
            }
        }
    }

    /// The 10% wash with hard band stops; neutral for whole-family rows.
    @ViewBuilder
    private func tintWash(_ event: Components.Schemas.EventOccurrence) -> some View {
        if tintOn, let ids = event.memberIds, !ids.isEmpty {
            let colors = ids.compactMap { id in members.first(where: { $0.id == id })?.color }
                .compactMap { Color(hex: $0) }
            if let style = bandedTint(colors) {
                Rectangle().fill(style)
            }
        }
    }

    private func agendaRow(_ event: Components.Schemas.EventOccurrence, loaded: PageData) -> some View {
        HStack(spacing: 10) {
            Text(logic.week.timeLabel(for: event))
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(railColor(event, loaded: loaded))
                .frame(width: 4)
                .frame(minHeight: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                if let location = event.location, !location.isEmpty {
                    Text(location).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            facepile(event.memberIds, loaded: loaded)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
    }

    private func railColor(_ event: Components.Schemas.EventOccurrence, loaded: PageData) -> Color {
        Color(hex: MyDayLogic.railColorHex(for: event, calendars: loaded.calendars) ?? "#34c759") ?? .green
    }

    @ViewBuilder
    private func facepile(_ memberIds: [String]?, loaded: PageData) -> some View {
        if let ids = memberIds, !ids.isEmpty {
            HStack(spacing: -7) {
                ForEach(ids.prefix(3), id: \.self) { id in
                    if let member = loaded.members.first(where: { $0.id == id }) {
                        MemberAvatarView(name: member.name, colorHex: member.color, avatar: nil, size: 22)
                    }
                }
            }
        } else {
            Text("🏠").font(.subheadline)
        }
    }

    // MARK: - Day grid

    private let hourHeight: CGFloat = 52
    private let gutter: CGFloat = 50

    @ViewBuilder
    private var dayGrid: some View {
        if let loaded = data.value {
            let blocks = logic.dayBlocks(
                day: day,
                events: loaded.events.filter { !$0.allDay && FamilyDayLogic.visible($0, selected: effectiveSelected) }
            )
            let allDay = loaded.events.filter {
                $0.allDay && logic.week.occursOn(day: day, occurrence: $0)
                    && FamilyDayLogic.visible($0, selected: effectiveSelected)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if !allDay.isEmpty {
                            ForEach(allDay, id: \.id) { event in
                                HStack(spacing: 8) {
                                    Text("all day").font(.caption2).foregroundStyle(.secondary)
                                        .frame(width: gutter, alignment: .trailing)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(railColor(event, loaded: loaded)).frame(width: 4, height: 20)
                                    DetailRow(route: .event(event), open: open) {
                                        Text(event.summary).font(.subheadline)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                            }
                            Divider()
                        }
                        gridBody(blocks: blocks, loaded: loaded)
                    }
                }
                // One finger scrolls; hold-then-drag draws. The pan is cut
                // only once a draft actually exists — a moving finger fails
                // the long press and scrolls normally (owner 2026-08-07:
                // "make scrolling work with 1 finger").
                .scrollDisabled(draft != nil)
                .refreshable { await load() }
                // Re-anchored per day AND per data arrival: an onAppear-only
                // scrollTo fires before the loaded grid has laid out and
                // lands on 00:00. The breath lets layout settle first.
                .task(id: "\(day)|\(data.value?.events.count ?? -1)") {
                    try? await Task.sleep(for: .milliseconds(120))
                    scrollToAnchor(proxy, blocks: blocks, animated: false)
                }
            }
        } else {
            Spacer(); ProgressView(); Spacer()
        }
    }

    /// Open the full-day grid at the useful part of the day: the now-line on
    /// today, the first event elsewhere, the waking morning on empty days.
    private func scrollToAnchor(_ proxy: ScrollViewProxy, blocks: [CalendarPageLogic.DayBlock], animated: Bool) {
        let hour = CalendarPageLogic.initialScrollHour(
            blocks: blocks,
            isToday: day == clock.today,
            nowMinutes: TodayLogic.minutes(clock.minute)
        )
        if animated {
            withAnimation { proxy.scrollTo("hour-\(hour)", anchor: .top) }
        } else {
            proxy.scrollTo("hour-\(hour)", anchor: .top)
        }
    }

    private func gridBody(blocks: [CalendarPageLogic.DayBlock], loaded: PageData) -> some View {
        // All 24 hours exist (owner 2026-08-07) — the grid scrolls, and
        // scrollToAnchor opens it at the useful part of the day.
        let hours = Array(0...23)
        let gridHeight = CGFloat(24) * hourHeight + 12
        let y = { (minutes: Int) in CGFloat(minutes) / 60 * hourHeight }
        return GeometryReader { proxy in
            let laneWidth = proxy.size.width - gutter - 12
            ZStack(alignment: .topLeading) {
                // The hour rows are REAL layout (a VStack of fixed-height
                // cells), not offsets: scrollTo needs true frames — offset
                // rows all "live" at y=0 and the reader lands on 00:00.
                VStack(spacing: 0) {
                    ForEach(hours, id: \.self) { hour in
                        HStack(spacing: 8) {
                            Text(String(format: "%02d:00", hour))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .frame(width: gutter, alignment: .trailing)
                            VStack { Divider() }
                        }
                        .offset(y: -6) // label rides ON its line, cosmetic only
                        .frame(height: hourHeight, alignment: .top)
                        .id("hour-\(hour)")
                    }
                }
                // UIKit long-press, not a SwiftUI gesture: even attached as
                // simultaneous, the sequenced LongPress+Drag starved the
                // ScrollView's pan and one-finger scrolling died (owner
                // 2026-08-07). The UIKit recognizer arbitrates natively:
                // movement pans, a stationary hold claims the touch and
                // cancels the scroll. Sits UNDER the blocks, so empty slots
                // draft and block taps still open details.
                HoldToDraftOverlay(
                    began: { point in
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        let start = (Int(point.y / hourHeight * 60) / 30) * 30
                        draftAnchor = start
                        draft = (start, start + 30)
                    },
                    moved: { point in
                        guard let anchor = draftAnchor else { return }
                        let at = (Int(point.y / hourHeight * 60) / 30) * 30
                        draft = (min(anchor, at), max(anchor, at) + 30)
                    },
                    ended: {
                        defer { draft = nil; draftAnchor = nil }
                        guard let d = draft else { return }
                        // The mock's contract: the form opens with THOSE times.
                        activeSheet = .newEvent(
                            date: day,
                            time: CalendarPageLogic.snappedSlot(minutes: d.start),
                            end: CalendarPageLogic.snappedSlot(minutes: d.end)
                        )
                    },
                    cancelled: {
                        draft = nil
                        draftAnchor = nil
                    }
                )
                .frame(width: proxy.size.width, height: gridHeight)
                // Event blocks: calendar-color line, member-tint fill.
                ForEach(blocks) { block in
                    let width = laneWidth / CGFloat(block.laneCount)
                    DetailRow(route: .event(block.event), open: open) {
                        HStack(alignment: .top, spacing: 6) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(railColor(block.event, loaded: loaded))
                                .frame(width: 3)
                                .frame(maxHeight: .infinity)
                            Text(block.event.summary)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .padding(4)
                        .frame(width: width - 2, height: max(CGFloat(block.durationMinutes) / 60 * hourHeight - 2, 24), alignment: .topLeading)
                        .background(blockFill(block.event, loaded: loaded), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .offset(
                        x: gutter + 8 + CGFloat(block.lane) * width,
                        y: y(block.startMinutes)
                    )
                }
                // Drag-create draft: a real block with a live time readout.
                if let draft {
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor)
                            .frame(width: 3)
                            .frame(maxHeight: .infinity)
                        Text("New event \(CalendarPageLogic.snappedSlot(minutes: draft.start))–\(CalendarPageLogic.snappedSlot(minutes: draft.end))")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(4)
                    .frame(
                        width: laneWidth,
                        height: max(CGFloat(draft.end - draft.start) / 60 * hourHeight, 24),
                        alignment: .topLeading
                    )
                    .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
                    .offset(x: gutter + 8, y: y(draft.start))
                    .allowsHitTesting(false)
                }
                // Hairline now-line, today only.
                if day == clock.today, let now = TodayLogic.minutes(clock.minute) {
                    HStack(spacing: 4) {
                        Text(clock.minute)
                            .font(.system(size: 9, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.red)
                            .frame(width: gutter, alignment: .trailing)
                        Circle().fill(.red).frame(width: 5, height: 5)
                        Rectangle().fill(.red).frame(height: 1)
                    }
                    .offset(y: y(now) - 5)
                    .allowsHitTesting(false)
                }
            }
            // The explicit full-size frame is what makes the grid WORK: the
            // ZStack's natural size ignores offset children, which left taps
            // and the create gesture a sliver at the top (owner bug report
            // 2026-08-07 — "day view doesn't open events").
            .frame(width: proxy.size.width, height: gridHeight, alignment: .topLeading)
        }
        .frame(height: gridHeight)
        .padding(.top, 8)
    }

    private func blockFill(_ event: Components.Schemas.EventOccurrence, loaded: PageData) -> AnyShapeStyle {
        let owners = event.memberIds ?? []
        let colors = owners.compactMap { id in
            loaded.members.first(where: { $0.id == id })?.color
        }.compactMap { Color(hex: $0) }
        if let style = bandedTint(colors) { return style }
        return AnyShapeStyle(Color.secondary.opacity(0.12))
    }

    // MARK: - Data

    private func load() async {
        if data.value == nil { data = .loading }
        let range = fetchRange
        do {
            async let eventsCall = context.client.api.listEvents(.init(query: .init(from: range.from, to: range.to)))
            async let choresCall = context.client.api.listChoreOccurrences(.init())
            async let membersCall = context.client.api.listMembers(.init())
            async let calendarsCall = context.client.api.listCalendars(.init())

            var loaded = PageData(events: [], todayChores: [], members: [], calendars: [], range: range)
            switch try await eventsCall {
            case .ok(let ok): loaded.events = try ok.body.json.events
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await choresCall {
            case .ok(let ok): loaded.todayChores = try ok.body.json.occurrences
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await membersCall {
            case .ok(let ok): loaded.members = try ok.body.json.members
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await calendarsCall {
            case .ok(let ok): loaded.calendars = try ok.body.json.calendars
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            data = .loaded(loaded)
        } catch {
            guard !isTaskCancellation(error) else { return }
            fail()
        }
    }

    private func fail() {
        if data.value == nil { data = .failed("Check the connection and try again.") }
    }
}

/// A UIKit long-press layer for the day grid. SwiftUI's sequenced
/// LongPress+Drag claimed every touch (even as a simultaneous gesture) and
/// killed one-finger scrolling; UIKit's recognizer is how Apple Calendar
/// does it — touches pass through to the scroll view until the hold fires,
/// then the recognizer owns the finger and streams the drag.
private struct HoldToDraftOverlay: UIViewRepresentable {
    var began: (CGPoint) -> Void
    var moved: (CGPoint) -> Void
    var ended: () -> Void
    var cancelled: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let recognizer = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        recognizer.minimumPressDuration = 0.3
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: HoldToDraftOverlay
        init(parent: HoldToDraftOverlay) { self.parent = parent }

        @objc func handle(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began: parent.began(point)
            case .changed: parent.moved(point)
            case .ended: parent.ended()
            default: parent.cancelled()
            }
        }
    }
}
