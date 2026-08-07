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
    @Environment(AppState.self) private var appState
    @Environment(SyncSignals.self) private var signals
    @Environment(HouseholdClock.self) private var clock

    /// nil = follow the household's today.
    @State private var selectedDay: String?
    @State private var path = NavigationPath()
    /// Header + mode survive relaunch ("you reopen the calendar you left").
    @AppStorage("calExpanded") private var expanded = false
    @AppStorage("calDayMode") private var dayMode = false
    @State private var data: Loadable<PageData> = .loading
    @State private var activeSheet: Sheet?
    /// The drag-create draft: (startMinutes, endMinutes) while dragging.
    @State private var draft: (start: Int, end: Int)?
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
        case newEvent(date: String, time: String?)

        var id: String {
            switch self {
            case .newEvent(let date, let time): "new-\(date)-\(time ?? "")"
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

    private func open(_ route: DetailRoute) { path.append(route) }

    private var anchorDate: Date {
        let parts = day.split(separator: "-").compactMap { Int(String($0)) }
        var components = DateComponents()
        guard parts.count == 3 else { return .now }
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        components.hour = 12
        return logic.calendar.date(from: components) ?? .now
    }

    var body: some View {
        NavigationStack(path: $path) {
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
                case .newEvent(let date, _):
                    EventFormView(
                        context: context,
                        members: data.value?.members ?? [],
                        mode: .create(defaultDate: date),
                        onSaved: { Task { await load() } }
                    )
                }
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
        let next = expanded
            ? logic.page(anchorDate, byMonths: direction)
            : logic.page(anchorDate, byWeeks: direction)
        select(logic.week.dayString(next))
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
                                    activeSheet = .newEvent(date: d, time: nil)
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
            ScrollView {
                VStack(spacing: 0) {
                    if !allDay.isEmpty {
                        ForEach(allDay, id: \.id) { event in
                            HStack(spacing: 8) {
                                Text("all day").font(.caption2).foregroundStyle(.secondary)
                                    .frame(width: gutter, alignment: .trailing)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(railColor(event, loaded: loaded)).frame(width: 4, height: 20)
                                Text(event.summary).font(.subheadline)
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
        } else {
            Spacer(); ProgressView(); Spacer()
        }
    }

    private func gridBody(blocks: [CalendarPageLogic.DayBlock], loaded: PageData) -> some View {
        let window = CalendarPageLogic.gridWindow(blocks: blocks)
        let hours = Array(window.start...window.end)
        // Everything positions against the window's first hour.
        let y = { (minutes: Int) in CGFloat(minutes - window.start * 60) / 60 * hourHeight }
        return GeometryReader { proxy in
            let laneWidth = proxy.size.width - gutter - 12
            ZStack(alignment: .topLeading) {
                ForEach(hours, id: \.self) { hour in
                    HStack(spacing: 8) {
                        Text(String(format: "%02d:00", hour))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(width: gutter, alignment: .trailing)
                        VStack { Divider() }
                    }
                    .offset(y: y(hour * 60) - 6)
                }
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
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.25)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        guard case .second(true, let drag?) = value else { return }
                        let base = window.start * 60
                        let start = base + Int(min(drag.startLocation.y, drag.location.y) / hourHeight * 60)
                        let end = base + Int(max(drag.startLocation.y, drag.location.y) / hourHeight * 60)
                        draft = ((start / 30) * 30, max((end / 30) * 30 + 30, (start / 30) * 30 + 30))
                    }
                    .onEnded { value in
                        guard case .second(true, _) = value, let d = draft else { draft = nil; return }
                        draft = nil
                        activeSheet = .newEvent(date: day, time: CalendarPageLogic.snappedSlot(minutes: d.start))
                    }
            )
        }
        .frame(height: CGFloat(hours.count) * hourHeight + 12)
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
