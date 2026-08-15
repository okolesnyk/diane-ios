import DianeKit
import SwiftUI

// MARK: - Pure logic

/// Week/agenda math for the calendar screen, pure and calendar-injected.
/// Wire dates are strings: local days "YYYY-MM-DD", instants ISO-8601 UTC.
/// Day membership is decided in local-date-string space only; instants become
/// local days via the injected calendar's zone — the HOUSEHOLD zone in the
/// app (D02: the server frames [from,to) in household tz; a traveling phone
/// must still see the family's week).
struct CalendarWeekLogic {
    let calendar: Foundation.Calendar
    private let dayFormatter: DateFormatter
    private let timeFormatter: DateFormatter
    private let instantParser: ISO8601DateFormatter
    private let fractionalInstantParser: ISO8601DateFormatter

    init(calendar: Foundation.Calendar) {
        self.calendar = calendar
        dayFormatter = Self.makeFormatter("yyyy-MM-dd", calendar)
        timeFormatter = Self.makeFormatter("HH:mm", calendar)
        instantParser = ISO8601DateFormatter()
        fractionalInstantParser = ISO8601DateFormatter()
        fractionalInstantParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    private static func makeFormatter(_ format: String, _ calendar: Foundation.Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    // MARK: Week window

    /// First day of the week containing `date`, per the calendar's firstWeekday.
    func weekStart(containing date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// The 7 strip days of the week containing `anchor`.
    func stripDays(anchor: Date) -> [Date] {
        let start = weekStart(containing: anchor)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    func dayString(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    /// listEvents bounds covering the whole strip week: the server range is
    /// [from, to), so `to` is the day after the last strip day.
    func queryRange(anchor: Date) -> (from: String, to: String) {
        let start = weekStart(containing: anchor)
        let afterEnd = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return (dayString(start), dayString(afterEnd))
    }

    func parseInstant(_ instant: String) -> Date? {
        instantParser.date(from: instant) ?? fractionalInstantParser.date(from: instant)
    }

    /// Local day of an ISO-8601 UTC instant, in the calendar's zone.
    func localDay(ofInstant instant: String) -> String? {
        parseInstant(instant).map(dayFormatter.string(from:))
    }

    // MARK: Day membership

    /// Does the occurrence touch this local day? All-day ranges are
    /// [startDate, endDate) — endDate exclusive. Timed events cover every
    /// local day from start through end, except an end exactly at local
    /// midnight, which closes the previous day (matches the web grid).
    func occursOn(day: String, occurrence: Components.Schemas.EventOccurrence) -> Bool {
        if occurrence.allDay {
            guard let start = occurrence.startDate else { return false }
            guard let end = occurrence.endDate else { return start == day }
            return start <= day && day < end
        }
        guard let startsAt = occurrence.startsAt, let start = parseInstant(startsAt) else { return false }
        let startDay = dayFormatter.string(from: start)
        var endDay = startDay
        if let endsAt = occurrence.endsAt, let end = parseInstant(endsAt), end > start {
            if calendar.startOfDay(for: end) == end {
                endDay = dayString(calendar.date(byAdding: .day, value: -1, to: end) ?? end)
            } else {
                endDay = dayFormatter.string(from: end)
            }
        }
        return startDay <= day && day <= endDay
    }

    // MARK: Agenda shaping

    /// Agenda rows for one day: all-day first, then timed by local start.
    func agenda(day: String, events: [Components.Schemas.EventOccurrence]) -> [Components.Schemas.EventOccurrence] {
        let todays = events.filter { occursOn(day: day, occurrence: $0) }
        let allDay = todays.filter(\.allDay)
            .sorted { ($0.startDate ?? "", $0.summary) < ($1.startDate ?? "", $1.summary) }
        let timed = todays.filter { !$0.allDay }
            .sorted { ($0.startsAt ?? "", $0.summary) < ($1.startsAt ?? "", $1.summary) }
        return allDay + timed
    }

    /// Which of `days` have at least one event — the strip dots.
    func daysWithEvents(days: [String], events: [Components.Schemas.EventOccurrence]) -> Set<String> {
        Set(days.filter { day in events.contains { occursOn(day: day, occurrence: $0) } })
    }

    /// D14: commit gate for a finished load — only the week we fetched,
    /// and only while the task is still wanted.
    static func shouldCommit(fetched: String, current: String, cancelled: Bool) -> Bool {
        fetched == current && !cancelled
    }

    /// "17:00–18:00" / "5:00–6:00 PM" in the household zone, or "all day".
    func timeLabel(for occurrence: Components.Schemas.EventOccurrence, use24: Bool) -> String {
        guard !occurrence.allDay,
              let startsAt = occurrence.startsAt,
              let start = parseInstant(startsAt)
        else { return "all day" }
        let startText = timeFormatter.string(from: start)
        guard let endsAt = occurrence.endsAt, let end = parseInstant(endsAt) else {
            return ClockDisplay.label(startText, use24: use24)
        }
        return ClockDisplay.range(startText, timeFormatter.string(from: end), use24: use24)
    }
}

// MARK: - Screen

/// Week strip + day agenda, the web kiosk's phone-mode calendar.
/// Chores-on-calendar chips (web has them) are deferred past iOS v1.
struct CalendarWeekView: View {
    let context: SignedInContext
    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock
    @AppStorage("timeFormat") private var timeFormat = "system"

    private struct WeekData {
        var events: [Components.Schemas.EventOccurrence]
        var members: [Components.Schemas.Member]
    }

    /// One enum drives both sheets: tap-a-row detail and toolbar "+" create.
    private enum ActiveSheet: Identifiable {
        case detail(Components.Schemas.EventOccurrence)
        case create(defaultDate: String)

        var id: String {
            switch self {
            case .detail(let occurrence): "detail-\(occurrence.id)"
            case .create(let defaultDate): "create-\(defaultDate)"
            }
        }
    }

    // @State so the formatters are built once per zone, not per render;
    // D02: rebuilt in the HOUSEHOLD frame the moment the clock resolves it.
    @State private var logic = CalendarWeekLogic(calendar: .current)
    @State private var anchor = Date()
    @State private var selected = Date()
    @State private var data: Loadable<WeekData> = .loading
    @State private var loadedWeek = ""
    @State private var activeSheet: ActiveSheet?

    private var weekDays: [Date] { logic.stripDays(anchor: anchor) }
    private var weekKey: String { logic.dayString(weekDays.first ?? anchor) }

    /// M9c: agenda rows sit flush at 16pt — no card, no page inset.
    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    }

    var body: some View {
        Group { // M9e: the caller owns the NavigationStack (tab wrap or Apps push)
            VStack(spacing: 0) {
                weekStrip
                Divider()
                agenda
            }
            .navigationTitle(monthTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Today") { goToToday() }
                }
                // Events are ANY-member territory (kiosk trust) — no admin gate.
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .create(defaultDate: logic.dayString(selected))
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New event")
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .detail(let occurrence):
                    EventDetailView(
                        context: context,
                        occurrence: occurrence,
                        members: data.value?.members ?? [],
                        onChanged: { Task { await load() } }
                    )
                case .create(let defaultDate):
                    EventFormView(
                        context: context,
                        members: data.value?.members ?? [],
                        mode: .create(defaultDate: defaultDate),
                        onSaved: { Task { await load() } }
                    )
                }
            }
            // D02: strip days, ring, and query range live in household tz.
            .onChange(of: clock.timeZone, initial: true) { _, timeZone in
                var calendar = Foundation.Calendar.current
                calendar.timeZone = timeZone
                logic = CalendarWeekLogic(calendar: calendar)
            }
            // Refetch on SSE signals, week paging, or household day rollover.
            .task(id: "\(signals.version(of: [.events, .calendars, .members]))|\(weekKey)|\(clock.today)") {
                await load()
            }
        }
    }

    private var monthTitle: String {
        var style = Date.FormatStyle.dateTime.month(.wide).year()
        style.timeZone = clock.timeZone // D02
        return selected.formatted(style)
    }

    // MARK: Week strip

    private var weekStrip: some View {
        HStack(spacing: 2) {
            pageButton("chevron.left", weeks: -1)
            ForEach(weekDays, id: \.self) { day in
                dayCell(day)
            }
            pageButton("chevron.right", weeks: 1)
        }
        .padding(.vertical, 6)  // M9c: edge-to-edge — no horizontal inset
    }

    private func pageButton(_ symbol: String, weeks: Int) -> some View {
        Button {
            page(by: weeks)
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    private func dayCell(_ day: Date) -> some View {
        let dayKey = logic.dayString(day)
        let isSelected = dayKey == logic.dayString(selected)
        let isToday = dayKey == clock.today // D02: ring follows the household day
        let hasEvents = eventDays.contains(dayKey)
        return Button {
            selected = day
        } label: {
            VStack(spacing: 3) {
                Text(weekdayInitial(day))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : .primary)
                    .frame(width: 34, height: 34)
                    .background {
                        if isSelected {
                            Circle().fill(.tint)
                        } else if isToday {
                            Circle().strokeBorder(.tint, lineWidth: 2)
                        }
                    }
                Circle()
                    .fill(.secondary)
                    .frame(width: 4, height: 4)
                    .opacity(hasEvents ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var calendar: Foundation.Calendar { logic.calendar }

    private var eventDays: Set<String> {
        guard let events = data.value?.events else { return [] }
        return logic.daysWithEvents(days: weekDays.map(logic.dayString), events: events)
    }

    private func weekdayInitial(_ day: Date) -> String {
        let index = calendar.component(.weekday, from: day) - 1
        let symbols = calendar.veryShortWeekdaySymbols
        return symbols.indices.contains(index) ? symbols[index] : ""
    }

    private func page(by weeks: Int) {
        anchor = calendar.date(byAdding: .day, value: 7 * weeks, to: anchor) ?? anchor
        // Keep the same weekday selected in the new week.
        selected = calendar.date(byAdding: .day, value: 7 * weeks, to: selected) ?? anchor
    }

    private func goToToday() {
        anchor = Date()
        selected = Date()
    }

    // MARK: Agenda

    @ViewBuilder
    private var agenda: some View {
        switch data {
        case .loading:
            Spacer()
            ProgressView()
            Spacer()
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't reach home", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        case .loaded(let week):
            let rows = logic.agenda(day: logic.dayString(selected), events: week.events)
            List {
                if rows.isEmpty {
                    Text("Nothing planned.")
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                        .padding(.top, 48)
                        .listRowSeparator(.hidden)
                        .listRowInsets(rowInsets)
                } else {
                    ForEach(rows, id: \.id) { occurrence in
                        Button {
                            activeSheet = .detail(occurrence)
                        } label: {
                            EventRow(
                                occurrence: occurrence,
                                timeLabel: logic.timeLabel(
                                    for: occurrence,
                                    use24: DisplayPrefs.uses24Hour(timeFormat)
                                ),
                                members: week.members
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        // M9c: plain full-width rows, hairline separators.
                        .listRowInsets(rowInsets)
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await load() }
        }
    }

    // MARK: Loading

    private func load() async {
        let week = weekKey
        if loadedWeek != week { data = .loading }
        let range = logic.queryRange(anchor: anchor)
        do {
            async let eventsCall = context.client.api.listEvents(.init(query: .init(from: range.from, to: range.to)))
            async let membersCall = context.client.api.listMembers(.init())
            let (eventsOutput, membersOutput) = try await (eventsCall, membersCall)

            let events: [Components.Schemas.EventOccurrence]
            switch eventsOutput {
            case .ok(let ok):
                events = try ok.body.json.events
            case .unauthorized:
                appState.handleUnauthorized()
                return
            default:
                fail("The calendar didn't load. Try again in a moment.", week: week)
                return
            }

            let members: [Components.Schemas.Member]
            switch membersOutput {
            case .ok(let ok):
                members = try ok.body.json.members
            case .unauthorized:
                appState.handleUnauthorized()
                return
            default:
                fail("The calendar didn't load. Try again in a moment.", week: week)
                return
            }

            // D14: never commit a stale week's events under the new week key.
            guard CalendarWeekLogic.shouldCommit(fetched: week, current: weekKey, cancelled: Task.isCancelled) else { return }
            data = .loaded(WeekData(events: events, members: members))
            loadedWeek = week
        } catch {
            // D08: a cancelled task (week paging, tab switch) is not an outage.
            guard !isTaskCancellation(error) else { return }
            fail("Couldn't reach your home server.", week: week)
        }
    }

    /// D08: .failed only when there is nothing to show and the week still
    /// matches — a failed refresh keeps the stale agenda silently.
    private func fail(_ message: String, week: String) {
        guard weekKey == week, data.value == nil else { return }
        data = .failed(message)
    }
}

// MARK: - Row

private struct EventRow: View {
    let occurrence: Components.Schemas.EventOccurrence
    let timeLabel: String
    let members: [Components.Schemas.Member]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(barColor)
                .frame(width: 4)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(occurrence.summary)
                    .font(.system(.body, design: .rounded, weight: .medium))
                if let location = occurrence.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(timeLabel)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                memberDots
            }
        }
        .padding(.vertical, 2)
    }

    // Gray when the server merged no event/calendar color.
    private var barColor: Color {
        occurrence.color.map { Color(hex: $0) } ?? .gray
    }

    /// Small discs in each tagged member's color; none means the whole family.
    @ViewBuilder
    private var memberDots: some View {
        let colors = (occurrence.memberIds ?? []).compactMap { id in
            members.first { $0.id == id }?.color
        }
        if !colors.isEmpty {
            HStack(spacing: -3) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                }
            }
        }
    }
}
