import DianeKit
import SwiftUI

/// The pushed member drill-down (M9e mock: "survives for now; chip-solo may
/// retire it after real use") — one member's day on one page: their events,
/// their chores, their routines, for the day Family Day was showing.
/// Self-contained: fetches its own slice, follows the day it was pushed with.
struct FamilyMemberDayView: View {
    let context: SignedInContext
    let member: Components.Schemas.Member
    let day: String
    /// Pushes onto Family Day's stack — this page is already inside it.
    let open: (DetailRoute) -> Void

    @Environment(AppState.self) private var appState
    @Environment(SyncSignals.self) private var signals
    @Environment(HouseholdClock.self) private var clock

    @State private var data: Loadable<DayData> = .loading

    struct DayData: Equatable {
        var events: [MyDayLogic.Event]
        var chores: [MyDayLogic.Chore]
        var board: [Components.Schemas.RoutineBoardEntry]
        var calendars: [MyDayLogic.CalendarInfo]
    }

    private var phase: MyDayLogic.DayPhase { MyDayLogic.phase(of: day, today: clock.today) }

    var body: some View {
        Group {
            switch data {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't load \(member.name)'s day", systemImage: "wifi.slash")
                } description: { Text(message) } actions: {
                    Button("Try again") { Task { await load() } }
                }
            case .loaded(let loaded):
                dayList(loaded)
            }
        }
        .navigationTitle("\(member.name) · \(NavigationLogic.myDayTitle(for: day))")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: signals.version(of: [.chores, .events, .routines])) {
            await load()
        }
    }

    private func dayList(_ loaded: DayData) -> some View {
        let events = loaded.events.filter {
            MyDayLogic.isMyEvent($0, me: member.id) && MyDayLogic.onDay($0, date: day, timeZone: clock.timeZone)
        }
        let sections = MyDayLogic.sections(loaded.chores, me: member.id, phase: phase)
        let timeline = MyDayLogic.timeline(
            events: TodayLogic.sortedEvents(events),
            timedChores: sections.timed,
            timeZone: clock.timeZone
        )
        let routines = loaded.board.filter { $0.memberId == member.id }

        return List {
            if !sections.catchUp.isEmpty {
                Section {
                    ForEach(sections.catchUp, id: \.id) { chore in row(chore, late: true) }
                } header: { header("Catch up").foregroundStyle(.red) }
            }
            if !timeline.isEmpty {
                Section {
                    ForEach(timeline, id: \.id) { item in
                        switch item {
                        case .event(let event): eventRow(event, calendars: loaded.calendars)
                        case .chore(let chore): row(chore, late: false)
                        }
                    }
                } header: { header("Timeline") }
            }
            if !sections.noSetTime.isEmpty {
                Section {
                    ForEach(sections.noSetTime, id: \.id) { chore in row(chore, late: false) }
                } header: { header("No set time") }
            }
            if !routines.isEmpty {
                Section {
                    ForEach(routines, id: \.routineId) { entry in
                        HStack(spacing: 8) {
                            if let emoji = entry.emoji { Text(emoji) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.body.weight(.semibold))
                                Text("\(entry.windowStart)–\(entry.windowEnd) · \(entry.tasks.count(where: { $0.status != .open })) of \(entry.tasks.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if entry.streak >= 2 { Text("🔥 \(entry.streak)").font(.subheadline) }
                        }
                    }
                } header: { header("Routines") }
            }
            if sections.catchUp.isEmpty && timeline.isEmpty && sections.noSetTime.isEmpty && routines.isEmpty {
                Text("Free day ✨")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .fontDesign(.rounded)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }

    private func eventRow(_ event: MyDayLogic.Event, calendars: [MyDayLogic.CalendarInfo]) -> some View {
        HStack(spacing: 10) {
            Text(event.allDay ? "all day" : event.startsAt.flatMap { TodayLogic.timeLabel($0, timeZone: clock.timeZone) } ?? "")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: MyDayLogic.railColorHex(for: event, calendars: calendars) ?? "#34c759") ?? .green)
                .frame(width: 4)
                .frame(minHeight: 30)
            DetailRow(route: .event(event), open: open) {
                HStack {
                    Text(event.summary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
        }
    }

    /// Read-only rows: the drill-down is a glance, actions live on Family Day.
    private func row(_ chore: MyDayLogic.Chore, late: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: chore.status == .completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(chore.status == .completed ? .green : late ? .red : .secondary)
            DetailRow(route: .chore(chore), open: open) {
                HStack(spacing: 6) {
                    if let emoji = chore.emoji { Text(emoji) }
                    Text(chore.title).strikethrough(chore.status == .completed, color: .secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            if chore.starValue > 0 {
                Text("★ \(chore.starValue)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
    }

    private func load() async {
        if data.value == nil { data = .loading }
        let next = MyDayLogic.addDays(day, 1)
        do {
            async let eventsCall = context.client.api.listEvents(.init(query: .init(from: day, to: next)))
            async let choresCall = phase == .today
                ? context.client.api.listChoreOccurrences(.init())
                : context.client.api.listChoreOccurrences(.init(query: .init(from: day, to: day)))
            async let boardCall = context.client.api.getRoutineBoard(.init(query: .init(date: day)))
            async let calendarsCall = context.client.api.listCalendars(.init())

            var loaded = DayData(events: [], chores: [], board: [], calendars: [])
            switch try await eventsCall {
            case .ok(let ok): loaded.events = try ok.body.json.events
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await choresCall {
            case .ok(let ok):
                let rows = try ok.body.json.occurrences
                loaded.chores = phase == .today ? rows : rows.filter { $0.dueDate == day }
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await boardCall {
            case .ok(let ok): loaded.board = try ok.body.json.entries
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
