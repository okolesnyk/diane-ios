import DianeKit
import SwiftUI

// MARK: - Pure logic (nonisolated, testable)

/// Data shaping for the Today screen. Callers inject dates/time zones.
enum TodayLogic {
    typealias Event = Components.Schemas.EventOccurrence
    typealias Chore = Components.Schemas.ChoreOccurrence
    typealias RoutineEntry = Components.Schemas.RoutineBoardEntry

    /// Local "YYYY-MM-DD" — the device's own calendar day, never via UTC.
    static func dateString(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The next local day — /events ranges are end-EXCLUSIVE [from, to), so
    /// "today only" must query [today, tomorrow).
    static func nextDayString(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let next = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return dateString(for: next, timeZone: timeZone)
    }

    /// All-day events first (server order), then timed by startsAt (ISO UTC
    /// strings compare lexicographically), summary as tiebreak.
    static func sortedEvents(_ events: [Event]) -> [Event] {
        let allDay = events.filter(\.allDay)
        let timed = events.filter { !$0.allDay }.sorted {
            ($0.startsAt ?? "", $0.summary) < ($1.startsAt ?? "", $1.summary)
        }
        return allDay + timed
    }

    /// ISO-8601 UTC instant → local "HH:mm". The api emits fractional
    /// seconds ("...T22:00:00.000Z") which the default parser REJECTS —
    /// try fractional first, then plain (caught live in M9).
    static func parseInstant(_ isoInstant: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: isoInstant) ?? ISO8601DateFormatter().date(from: isoInstant)
    }

    static func timeLabel(_ isoInstant: String?, timeZone: TimeZone) -> String? {
        guard let isoInstant, let date = parseInstant(isoInstant) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func owner(of chore: Chore) -> String? {
        chore.claimedByMemberId ?? chore.assigneeMemberId
    }

    struct ChoreSections: Equatable {
        var mine: [Chore] = []
        var pool: [Chore] = []
        var completed: [Chore] = []
        var isEmpty: Bool { mine.isEmpty && pool.isEmpty && completed.isEmpty }
    }

    /// Partition the actionable view: my open rows, the up-for-grabs pool,
    /// and my completed-today rows (input order preserved per bucket).
    /// D06: a completed row belongs to its OWNER; pool rows (no owner) belong
    /// to their COMPLETER — completing a sibling's chore stays on their board.
    static func choreSections(_ occurrences: [Chore], me: String) -> ChoreSections {
        var sections = ChoreSections()
        for occurrence in occurrences {
            let owner = owner(of: occurrence)
            if occurrence.status == .completed {
                if (owner ?? occurrence.completedByMemberId) == me {
                    sections.completed.append(occurrence)
                }
            } else if owner == me {
                sections.mine.append(occurrence)
            } else if owner == nil {
                sections.pool.append(occurrence)
            }
        }
        return sections
    }

    /// D06: "by <name>" when someone other than the owner checked it off.
    static func completedByNote(_ chore: Chore, names: [String: String]) -> String? {
        guard chore.status == .completed, let by = chore.completedByMemberId,
              let owner = owner(of: chore), by != owner else { return nil }
        return names[by].map { "by \($0)" }
    }

    /// D07: deadline chip for dueMode 'by' rows — "by Aug 15" — so a
    /// flexible-with-deadline chore never reads as due today. Pure string
    /// math on the wire date; no tz conversion.
    static func deadlineLabel(dueDate: String?, dueMode: Chore.DueModePayload?, locale: Locale = .current) -> String? {
        guard dueMode == .by, let dueDate else { return nil }
        let parts = dueDate.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        let symbols = formatter.shortMonthSymbols ?? []
        guard symbols.indices.contains(month - 1) else { return nil }
        return "by \(symbols[month - 1]) \(day)"
    }

    /// "HH:mm" → minutes since midnight.
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// [start, end] — END-INCLUSIVE like the web kiosk (D26): evening presets
    /// end 23:59 and the last minute must count. An end before start wraps
    /// past midnight.
    static func windowContains(clock: Int, start: String, end: String) -> Bool {
        guard let s = minutes(start), let e = minutes(end) else { return false }
        return s <= e ? (clock >= s && clock <= e) : (clock >= s || clock <= e)
    }

    static func clockMinutes(of date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// My board entries whose window contains the clock, board order kept.
    static func activeRoutines(_ entries: [RoutineEntry], me: String, clock: Int) -> [RoutineEntry] {
        entries.filter {
            $0.memberId == me && windowContains(clock: clock, start: $0.windowStart, end: $0.windowEnd)
        }
    }

    /// Resolved (completed or skipped) over total — matches the web kiosk.
    static func progress(of entry: RoutineEntry) -> (done: Int, total: Int) {
        (entry.tasks.filter { $0.status != .open }.count, entry.tasks.count)
    }

    static func balance(of memberID: String, in balances: [Components.Schemas.StarBalance]) -> Int {
        balances.first { $0.memberId == memberID }?.balance ?? 0
    }

    /// D21: the real emitted set (verified in diane-server apps/api/src);
    /// chore_archived was never a server code.
    static func conflictMessage(code: String?) -> String {
        switch code {
        case "already_claimed": "Someone already grabbed this one."
        case "not_claimable": "That one can't be claimed."
        case "not_actionable": "That chore can't be checked off right now."
        case "already_completed": "That one is already done."
        case "insufficient_stars": "Those stars are already spent."
        default: "Couldn't complete that chore."
        }
    }

    /// Action results carry the occurrence as an inline payload type.
    static func occurrence(from payload: Components.Schemas.ChoreActionResult.OccurrencePayload) -> Chore {
        .init(
            id: payload.id,
            choreId: payload.choreId,
            title: payload.title,
            emoji: payload.emoji,
            notes: payload.notes,
            starValue: payload.starValue,
            upForGrabs: payload.upForGrabs,
            dueDate: payload.dueDate,
            dueMode: payload.dueMode.flatMap { Chore.DueModePayload(rawValue: $0.rawValue) },
            dueTime: payload.dueTime,
            status: Chore.StatusPayload(rawValue: payload.status.rawValue) ?? .completed,
            late: payload.late,
            assigneeMemberId: payload.assigneeMemberId,
            claimedByMemberId: payload.claimedByMemberId,
            completedByMemberId: payload.completedByMemberId,
            completedAt: payload.completedAt
        )
    }
}

// MARK: - Screen

struct TodayView: View {
    struct TodayData {
        var events: [Components.Schemas.EventOccurrence]
        var occurrences: [Components.Schemas.ChoreOccurrence]
        var routines: [Components.Schemas.RoutineBoardEntry]
        var balance: Int
        var memberColors: [String: String]
        var memberNames: [String: String]
    }

    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @Environment(SyncSignals.self) private var signals
    @Environment(HouseholdClock.self) private var clock
    @State private var data: Loadable<TodayData> = .loading
    @State private var completingIDs: Set<String> = []
    @State private var actionError: String?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                switch data {
                case .loading:
                    ProgressView()
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Can't reach home", systemImage: "wifi.slash")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                case .loaded(let today):
                    content(today)
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(context: context)
            }
        }
        // D05: clock.today in the key refetches at household midnight.
        .task(id: "\(signals.version(of: [.events, .calendars, .chores, .routines, .stars, .members]))|\(clock.today)") {
            await load()
        }
        .alert("Chores", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    // MARK: Content

    private func content(_ today: TodayData) -> some View {
        let events = TodayLogic.sortedEvents(today.events)
        let chores = TodayLogic.choreSections(today.occurrences, me: context.session.memberID)
        // D03/D05: household wall clock; reading clock.minute re-renders each
        // tick, so a window opening appears within a minute on an idle screen.
        let routines = TodayLogic.activeRoutines(
            today.routines,
            me: context.session.memberID,
            clock: TodayLogic.minutes(clock.minute) ?? 0
        )
        return List {
            headerSection(balance: today.balance)
            if events.isEmpty && chores.isEmpty && routines.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing on your plate today 🎉",
                        systemImage: "sun.max",
                        description: Text("Enjoy your free time!")
                    )
                }
                .listRowBackground(Color.clear)
            }
            if !events.isEmpty {
                Section("Today") {
                    ForEach(events, id: \.id) { event in
                        eventRow(event, colors: today.memberColors)
                    }
                }
            }
            if !chores.isEmpty {
                Section("My chores") {
                    ForEach(chores.mine, id: \.id) { choreRow($0, pool: false, names: today.memberNames) }
                    ForEach(chores.pool, id: \.id) { choreRow($0, pool: true, names: today.memberNames) }
                    ForEach(chores.completed, id: \.id) { choreRow($0, pool: false, names: today.memberNames) }
                }
            }
            if !routines.isEmpty {
                Section("My routines") {
                    ForEach(routines, id: \.routineId) { routineRow($0) }
                }
            }
        }
        .fontDesign(.rounded)
        .refreshable { await load() }
    }

    private func headerSection(balance: Int) -> some View {
        Section {
            HStack(spacing: 14) {
                MemberAvatarView(
                    name: context.session.memberName,
                    colorHex: context.session.memberColor,
                    avatar: nil,
                    size: 52
                )
                Text("Hi, \(context.session.memberName)!")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("★ \(balance)")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.orange.opacity(0.15)))
                    .accessibilityLabel("\(balance) stars")
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
    }

    private func eventRow(_ event: Components.Schemas.EventOccurrence, colors: [String: String]) -> some View {
        HStack(spacing: 12) {
            // D02: event instants render in the household frame, like the kiosk.
            Text(event.allDay ? "All day" : (TodayLogic.timeLabel(event.startsAt, timeZone: clock.timeZone) ?? "—"))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(event.summary)
                .lineLimit(2)
            Spacer()
            if let memberIds = event.memberIds {
                HStack(spacing: -3) {
                    ForEach(memberIds, id: \.self) { id in
                        Circle()
                            .fill(Color(hex: colors[id] ?? "#8E8E93"))
                            .frame(width: 10, height: 10)
                    }
                }
            } else {
                // Whole-family event.
                Image(systemName: "house.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func choreRow(_ chore: Components.Schemas.ChoreOccurrence, pool: Bool, names: [String: String]) -> some View {
        let completed = chore.status == .completed
        return HStack(spacing: 12) {
            emojiBadge(chore.emoji)
            VStack(alignment: .leading, spacing: 3) {
                Text(chore.title)
                    .strikethrough(completed)
                    .foregroundStyle(completed ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text("★ \(chore.starValue)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    if pool {
                        tag("Up for grabs", color: .blue)
                    }
                    if chore.late && !completed {
                        tag("late", color: .red)
                    }
                    // D07: deadline chores must not read as due today.
                    if let deadline = TodayLogic.deadlineLabel(dueDate: chore.dueDate, dueMode: chore.dueMode),
                       !completed {
                        tag(deadline, color: .purple)
                    }
                    // D06: someone else checked off my chore.
                    if let note = TodayLogic.completedByNote(chore, names: names) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                Task { await complete(chore) }
            } label: {
                if completingIDs.contains(chore.id) {
                    ProgressView()
                } else {
                    Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(completed ? .green : .secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(completed || completingIDs.contains(chore.id))
            .accessibilityLabel(completed ? "Done" : "Complete \(chore.title)")
        }
    }

    private func routineRow(_ entry: Components.Schemas.RoutineBoardEntry) -> some View {
        let progress = TodayLogic.progress(of: entry)
        return HStack(spacing: 12) {
            emojiBadge(entry.emoji)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                Text("\(progress.done) of \(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if entry.streak >= 2 {
                Text("🔥 \(entry.streak)")
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func emojiBadge(_ emoji: String?) -> some View {
        Group {
            if let emoji, !emoji.isEmpty {
                Text(emoji).font(.title2)
            } else {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 34)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    // MARK: Data

    private func load() async {
        if data.value == nil { data = .loading }
        // D02: query the HOUSEHOLD's day — the server frames [from,to) in
        // household tz, and chores/routines always answer for household-today.
        let today = clock.today
        let tomorrow = clock.tomorrow
        let me = context.session.memberID
        do {
            async let eventsCall = context.client.api.listEvents(.init(query: .init(from: today, to: tomorrow)))
            async let membersCall = context.client.api.listMembers(.init())
            async let choresCall = context.client.api.listChoreOccurrences(.init())
            async let routinesCall = context.client.api.getRoutineBoard(.init())
            async let balancesCall = context.client.api.getStarBalances(.init())

            var events: [Components.Schemas.EventOccurrence] = []
            switch try await eventsCall {
            case .ok(let ok): events = try ok.body.json.events
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            var colors: [String: String] = [:]
            var names: [String: String] = [:]
            switch try await membersCall {
            case .ok(let ok):
                for member in try ok.body.json.members {
                    colors[member.id] = member.color
                    names[member.id] = member.name
                }
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            var occurrences: [Components.Schemas.ChoreOccurrence] = []
            switch try await choresCall {
            case .ok(let ok): occurrences = try ok.body.json.occurrences
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            var routines: [Components.Schemas.RoutineBoardEntry] = []
            switch try await routinesCall {
            case .ok(let ok): routines = try ok.body.json.entries
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            var balance = 0
            switch try await balancesCall {
            case .ok(let ok): balance = TodayLogic.balance(of: me, in: try ok.body.json.balances)
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            data = .loaded(TodayData(
                events: events,
                occurrences: occurrences,
                routines: routines,
                balance: balance,
                memberColors: colors,
                memberNames: names
            ))
        } catch {
            // D08: a cancelled task is lifecycle, not an outage.
            guard !isTaskCancellation(error) else { return }
            fail()
        }
    }

    /// D08: .failed may only replace a screen with NO data — a failed
    /// refresh keeps the stale board silently.
    private func fail() {
        if data.value == nil { data = .failed(failureCopy) }
    }

    private var failureCopy: String {
        "Your home server didn't answer. Pull down to try again."
    }

    /// Complete taps are optimistic: reflect the returned occurrence right
    /// away, the SSE bump refetches the rest (balance, other rows).
    private func complete(_ chore: Components.Schemas.ChoreOccurrence) async {
        completingIDs.insert(chore.id)
        defer { completingIDs.remove(chore.id) }
        do {
            let output = try await context.client.api.completeChoreOccurrence(.init(path: .init(id: chore.id)))
            switch output {
            case .ok(let ok):
                apply(try ok.body.json, tappedID: chore.id)
            case .unauthorized:
                appState.handleUnauthorized()
            case .conflict(let conflict):
                // D21: the semantic code is the Error body's `error` field.
                actionError = TodayLogic.conflictMessage(code: (try? conflict.body.json)?.error)
                await load()
            default:
                actionError = TodayLogic.conflictMessage(code: nil)
                await load()
            }
        } catch {
            guard !isTaskCancellation(error) else { return } // D08
            actionError = "Couldn't reach your home server. Try again."
        }
    }

    /// Swap (or drop) the tapped row. Occurrence ids are synthetic and may
    /// change — match on the id we tapped, take whatever comes back.
    private func apply(_ result: Components.Schemas.ChoreActionResult, tappedID: String) {
        guard var today = data.value else { return }
        if let index = today.occurrences.firstIndex(where: { $0.id == tappedID }) {
            if let payload = result.occurrence {
                today.occurrences[index] = TodayLogic.occurrence(from: payload)
            } else {
                today.occurrences.remove(at: index)
            }
        }
        data = .loaded(today)
    }
}
