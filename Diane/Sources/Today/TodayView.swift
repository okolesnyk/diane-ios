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

    /// Kiosk trust: the circle completes an open row and un-checks a done
    /// one — no matter who owns it or checked it.
    enum CircleAction: Equatable {
        case complete, uncomplete
    }

    static func circleAction(for chore: Chore) -> CircleAction {
        chore.status == .completed ? .uncomplete : .complete
    }

    /// M9c: beyond the circle a row has exactly one other surface — swipe.
    /// Mirrors the Chores board rules so both screens behave identically.
    struct SwipeActions: Equatable {
        var canClaim = false
        var canPutBack = false
        var canDismiss = false
    }

    /// Claim an unowned open row, put back any claimed one (D27), dismiss any
    /// open one (D23). A completed row offers nothing — the circle un-checks it.
    static func swipeActions(for chore: Chore) -> SwipeActions {
        guard chore.status != .completed else { return SwipeActions() }
        return SwipeActions(
            canClaim: chore.assigneeMemberId == nil && chore.claimedByMemberId == nil,
            canPutBack: chore.claimedByMemberId != nil,
            canDismiss: true
        )
    }

    /// D24: dismiss is permanent, so it names the chore and confirms first.
    static func dismissPrompt(_ title: String) -> String {
        "Dismiss \u{201C}\(title)\u{201D}?"
    }

    /// One family-hub block: another member's whole day.
    struct MemberDay: Equatable {
        var member: Components.Schemas.Member
        var events: [Event] = []  // R6
        var openChores: [Chore] = []
        var doneCount: Int = 0
        var routines: [RoutineEntry] = []
        /// R6: events are plans too — a day with an appointment isn't free.
        var isFree: Bool { events.isEmpty && openChores.isEmpty && doneCount == 0 && routines.isEmpty }
    }

    /// R6: a member's events are the ones whose memberIds CONTAINS their id.
    /// Whole-family events (memberIds nil) belong to the shared Today section
    /// only — never duplicated onto every member's block. Sorted like the
    /// shared list: all-day first, then by start.
    static func memberEvents(_ events: [Event], member: String) -> [Event] {
        sortedEvents(events.filter { $0.memberIds?.contains(member) ?? false })
    }

    /// Hub blocks for every OTHER member, by sortOrder (name tiebreak).
    /// Open rows go to their OWNER; done rows count per D06 (owner, else
    /// completer); unowned pool rows stay off the blocks — they live in
    /// "My day" as up-for-grabs. Routines are the member's WHOLE day in
    /// board order — the window cut is only for MY actionable list.
    static func familyDays(
        members: [Components.Schemas.Member],
        me: String,
        occurrences: [Chore],
        routines: [RoutineEntry],
        events: [Event]
    ) -> [MemberDay] {
        members
            .filter { $0.id != me }
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .map { member in
                var day = MemberDay(member: member)
                for occurrence in occurrences {
                    let owner = owner(of: occurrence)
                    if occurrence.status == .completed {
                        if (owner ?? occurrence.completedByMemberId) == member.id {
                            day.doneCount += 1
                        }
                    } else if owner == member.id {
                        day.openChores.append(occurrence)
                    }
                }
                day.routines = routines.filter { $0.memberId == member.id }
                day.events = memberEvents(events, member: member.id)  // R6
                return day
            }
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

    /// R8: one of MY routines, flagged when the clock is inside its window.
    struct DayRoutine: Equatable {
        var entry: RoutineEntry
        var isNow: Bool
    }

    /// R8: my WHOLE day — same as every other member's block, no window cut.
    /// In-window entries come first and carry the "Now" pill; board order is
    /// kept inside each group.
    static func myRoutines(_ entries: [RoutineEntry], me: String, clock: Int) -> [DayRoutine] {
        let mine = entries.filter { $0.memberId == me }.map {
            DayRoutine(
                entry: $0,
                isNow: windowContains(clock: clock, start: $0.windowStart, end: $0.windowEnd)
            )
        }
        return mine.filter(\.isNow) + mine.filter { !$0.isNow }
    }

    /// Resolved (completed or skipped) over total — matches the web kiosk.
    static func progress(of entry: RoutineEntry) -> (done: Int, total: Int) {
        (entry.tasks.filter { $0.status != .open }.count, entry.tasks.count)
    }

    /// "2 of 3" progress line; every task resolved reads "All done ✓".
    static func routineProgressLabel(of entry: RoutineEntry) -> String {
        let progress = progress(of: entry)
        return progress.done == progress.total ? "All done ✓" : "\(progress.done) of \(progress.total)"
    }

    // R13: rows are real Buttons — one curated VoiceOver label each, so the
    // trait and the announcement arrive together.
    static func eventRowLabel(_ event: Event, timeZone: TimeZone) -> String {
        let when = event.allDay ? "all day" : timeLabel(event.startsAt, timeZone: timeZone).map { "at \($0)" }
        return when.map { "\(event.summary), \($0)" } ?? event.summary
    }

    static func choreRowLabel(_ chore: Chore, names: [String: String] = [:]) -> String {
        var parts = [chore.title, "\(chore.starValue) stars"]
        if chore.status == .completed {
            parts.append("done")
        } else if chore.late {
            parts.append("late")
        }
        if let note = completedByNote(chore, names: names) { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    static func routineRowLabel(_ entry: RoutineEntry, isNow: Bool) -> String {
        let progress = progress(of: entry)
        var parts = [entry.title]
        if isNow { parts.append("now") }
        parts.append("\(progress.done) of \(progress.total) done")
        return parts.joined(separator: ", ")
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
        var boardDate: String
        var members: [Components.Schemas.Member]
        var balances: [Components.Schemas.StarBalance]
    }

    /// One state drives every sheet: detail taps and settings.
    /// R3: the routine payload FREEZES the board date it was opened with —
    /// a live `boardDate` would go un-stale at household midnight and re-arm
    /// actions against yesterday's snapshot (RoutinesView freezes it too).
    enum ActiveSheet: Identifiable {
        case event(Components.Schemas.EventOccurrence)
        case chore(Components.Schemas.ChoreOccurrence)
        case routine(entry: Components.Schemas.RoutineBoardEntry, boardDate: String)
        case settings

        /// Stable per row so a data refresh never re-presents the sheet.
        var id: String {
            switch self {
            case .event(let occurrence): "event-\(occurrence.id)"
            case .chore(let occurrence): "chore-\(occurrence.id)"
            case .routine(let entry, _): "routine-\(entry.routineId)-\(entry.memberId)"
            case .settings: "settings"
            }
        }
    }

    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @Environment(SyncSignals.self) private var signals
    @Environment(HouseholdClock.self) private var clock
    @State private var data: Loadable<TodayData> = .loading
    @State private var completingIDs: Set<String> = []
    @State private var actionError: String?
    @State private var activeSheet: ActiveSheet?
    @State private var pendingDismiss: Components.Schemas.ChoreOccurrence?  // D24

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
                        activeSheet = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(item: $activeSheet) { sheet in
                sheetContent(sheet)
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
        // D24: dismiss never resurfaces, so it always confirms first.
        .confirmationDialog(
            TodayLogic.dismissPrompt(pendingDismiss?.title ?? ""),
            isPresented: Binding(
                get: { pendingDismiss != nil },
                set: { if !$0 { pendingDismiss = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDismiss
        ) { chore in
            Button("Dismiss", role: .destructive) {
                Task { await perform(.dismiss, on: chore) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It goes away for good — no stars, and it won't come back.")
        }
    }

    /// Detail sheets refetch on any mutation (SSE bumps too).
    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .event(let occurrence):
            EventDetailView(
                context: context,
                occurrence: occurrence,
                members: data.value?.members ?? []
            ) {
                Task { await load() }
            }
        case .chore(let occurrence):
            ChoreDetailView(
                context: context,
                occurrence: occurrence,
                members: data.value?.members ?? []
            ) {
                Task { await load() }
            }
        case .routine(let entry, let boardDate):  // R3: frozen at tap time
            RoutineDetailView(
                context: context,
                entry: entry,
                boardDate: boardDate,
                members: data.value?.members ?? []
            ) {
                Task { await load() }
            }
        case .settings:
            SettingsView(context: context)
        }
    }

    // MARK: Content

    private func content(_ today: TodayData) -> some View {
        let me = context.session.memberID
        let names = Dictionary(uniqueKeysWithValues: today.members.map { ($0.id, $0.name) })
        let colors = Dictionary(uniqueKeysWithValues: today.members.map { ($0.id, $0.color) })
        let events = TodayLogic.sortedEvents(today.events)
        let chores = TodayLogic.choreSections(today.occurrences, me: me)
        // D03/D05: household wall clock; reading clock.minute re-renders each
        // tick, so a window opening appears within a minute on an idle screen.
        // R8: my whole day, in-window entries first with a "Now" pill.
        let routines = TodayLogic.myRoutines(
            today.routines,
            me: me,
            clock: TodayLogic.minutes(clock.minute) ?? 0
        )
        let family = TodayLogic.familyDays(
            members: today.members,
            me: me,
            occurrences: today.occurrences,
            routines: today.routines,
            events: today.events  // R6
        )
        return List {
            headerSection(balance: TodayLogic.balance(of: me, in: today.balances))
            if events.isEmpty && chores.isEmpty && routines.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing on your plate today 🎉",
                        systemImage: "sun.max",
                        description: Text("Enjoy your free time!")
                    )
                    .listRowInsets(rowInsets)
                    .listRowSeparator(.hidden)
                }
            }
            if !events.isEmpty {
                Section {
                    ForEach(events, id: \.id) { event in
                        eventRow(event, colors: colors)
                    }
                } header: {
                    sectionHeader("Today")
                }
            }
            if !chores.isEmpty || !routines.isEmpty {
                Section {
                    ForEach(chores.mine, id: \.id) { choreRow($0, pool: false, names: names) }
                    ForEach(chores.pool, id: \.id) { choreRow($0, pool: true, names: names) }
                    ForEach(chores.completed, id: \.id) { choreRow($0, pool: false, names: names) }
                    ForEach(routines, id: \.entry.routineId) { routineRow($0, boardDate: today.boardDate) }
                } header: {
                    sectionHeader("My day")
                }
            }
            // The family hub: everyone else's whole day, at a glance.
            ForEach(Array(family.enumerated()), id: \.element.member.id) { index, day in
                familySection(day, first: index == 0, balances: today.balances, boardDate: today.boardDate)
            }
        }
        .listStyle(.plain)  // M9c: edge-to-edge, square, hairline-grouped
        .fontDesign(.rounded)
        .refreshable { await load() }
    }

    /// M9c: every row sits flush at 16pt, no card, no page inset.
    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    }

    /// M9c: small uppercase secondary label, flush with the rows.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 6, trailing: 16))
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
                starChip(balance, font: .headline)
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)
        }
    }

    private func starChip(_ balance: Int, font: Font) -> some View {
        Text("★ \(balance)")
            .font(font.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.orange.opacity(0.15)))
            .accessibilityLabel("\(balance) stars")
    }

    // R13: a real Button, so VoiceOver announces the row as actionable.
    private func eventRow(_ event: Components.Schemas.EventOccurrence, colors: [String: String]) -> some View {
        Button {
            activeSheet = .event(event)
        } label: {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TodayLogic.eventRowLabel(event, timeZone: clock.timeZone))
        .listRowInsets(rowInsets)
    }

    /// M9c: the two action surfaces, identical to the Chores tab — the circle
    /// on the row, and swipe. Trailing dismisses (orange, never full-swipe,
    /// always confirmed); leading claims or puts back.
    private func choreSwipes<Content: View>(
        _ chore: Components.Schemas.ChoreOccurrence,
        @ViewBuilder row: () -> Content
    ) -> some View {
        let actions = TodayLogic.swipeActions(for: chore)
        return row()
            .listRowInsets(rowInsets)
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                if actions.canClaim {
                    Button { Task { await perform(.claim, on: chore) } } label: {
                        Label("Claim", systemImage: "hand.raised")
                    }
                    .tint(.blue)
                    .accessibilityLabel("Claim \(chore.title)")
                }
                if actions.canPutBack {
                    // D27: the visible undo of Claim.
                    Button { Task { await perform(.unclaim, on: chore) } } label: {
                        Label("Put back", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                    .accessibilityLabel("Put back \(chore.title)")
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if actions.canDismiss {
                    Button { pendingDismiss = chore } label: {  // D24: confirms first
                        Label("Dismiss", systemImage: "xmark.circle")
                    }
                    .tint(.orange)
                    .accessibilityLabel("Dismiss \(chore.title)")
                }
            }
    }

    // R13: the detail tap is a Button beside the circle — never wrapping it,
    // so the circle keeps its own tap.
    private func choreRow(_ chore: Components.Schemas.ChoreOccurrence, pool: Bool, names: [String: String]) -> some View {
        let completed = chore.status == .completed
        return choreSwipes(chore) {
            HStack(spacing: 12) {
                Button {
                    activeSheet = .chore(chore)
                } label: {
                    HStack(spacing: 12) {
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
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TodayLogic.choreRowLabel(chore, names: names))
                completeCircle(chore)
            }
        }
    }

    /// R8: my own routine row — the "Now" pill marks an open window; the rest
    /// of my day stays visible instead of being filtered out.
    private func routineRow(_ day: TodayLogic.DayRoutine, boardDate: String) -> some View {
        let entry = day.entry
        return Button {
            activeSheet = .routine(entry: entry, boardDate: boardDate)  // R3
        } label: {
            HStack(spacing: 12) {
                emojiBadge(entry.emoji)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                        if day.isNow {
                            tag("Now", color: .green)
                        }
                    }
                    Text(TodayLogic.routineProgressLabel(of: entry))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(day.isNow ? .primary : .secondary)
                Spacer()
                if entry.streak >= 2 {
                    Text("🔥 \(entry.streak)")
                        .font(.subheadline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TodayLogic.routineRowLabel(entry, isNow: day.isNow))
        // M9c: display-only here — the tap opens the detail sheet, where the
        // task circles and their swipes live.
        .listRowInsets(rowInsets)
    }

    // MARK: Family hub

    private func familySection(
        _ day: TodayLogic.MemberDay,
        first: Bool,
        balances: [Components.Schemas.StarBalance],
        boardDate: String
    ) -> some View {
        Section {
            // R6: their appointments — the owner's "what are my wife's plans".
            ForEach(day.events, id: \.id) { familyEventRow($0) }
            ForEach(day.openChores, id: \.id) { familyChoreRow($0) }
            if day.doneCount > 0 {
                Text("\(day.doneCount) done ✓")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowInsets(rowInsets)
            }
            ForEach(day.routines, id: \.routineId) { familyRoutineRow($0, boardDate: boardDate) }
            if day.isFree {
                Text("Free day ✨")
                    .foregroundStyle(.secondary)
                    .listRowInsets(rowInsets)
            }
        } header: {
            // M9c: no card — the header IS the member's identity, rows sit flush.
            VStack(alignment: .leading, spacing: 8) {
                if first {
                    Text("The family")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                HStack(spacing: 10) {
                    MemberAvatarView(
                        name: day.member.name,
                        colorHex: day.member.color,
                        avatar: day.member.avatar,
                        size: 30
                    )
                    Text(day.member.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    starChip(TodayLogic.balance(of: day.member.id, in: balances), font: .caption)
                }
                .textCase(nil)
            }
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 6, trailing: 16))
        }
    }

    /// R6: one of their events. Whole-family events aren't here — they stay in
    /// the shared "Today" section, unduplicated.
    private func familyEventRow(_ event: Components.Schemas.EventOccurrence) -> some View {
        Button {
            activeSheet = .event(event)
        } label: {
            HStack(spacing: 12) {
                // D02: household frame, like the shared list.
                Text(event.allDay ? "All day" : (TodayLogic.timeLabel(event.startsAt, timeZone: clock.timeZone) ?? "—"))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Text(event.summary)
                    .lineLimit(2)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TodayLogic.eventRowLabel(event, timeZone: clock.timeZone))  // R13
        .listRowInsets(rowInsets)
    }

    /// Compact open row on another member's block; the circle still checks
    /// it off (kiosk trust — helping is the point) and swipe still acts.
    private func familyChoreRow(_ chore: Components.Schemas.ChoreOccurrence) -> some View {
        choreSwipes(chore) {
            HStack(spacing: 12) {
                // R13: Button beside the circle, so both stay tappable.
                Button {
                    activeSheet = .chore(chore)
                } label: {
                    HStack(spacing: 12) {
                        emojiBadge(chore.emoji)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chore.title)
                            HStack(spacing: 6) {
                                if let time = chore.dueTime {
                                    tag(time, color: .secondary)
                                }
                                if chore.late {
                                    tag("late", color: .red)
                                }
                                // D07: deadline chores must not read as due today.
                                if let deadline = TodayLogic.deadlineLabel(dueDate: chore.dueDate, dueMode: chore.dueMode) {
                                    tag(deadline, color: .purple)
                                }
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TodayLogic.choreRowLabel(chore))
                completeCircle(chore)
            }
        }
    }

    /// "🌅 Morning · 2 of 3" — the whole day's routines, not just open windows.
    private func familyRoutineRow(_ entry: Components.Schemas.RoutineBoardEntry, boardDate: String) -> some View {
        Button {
            activeSheet = .routine(entry: entry, boardDate: boardDate)  // R3
        } label: {
            HStack(spacing: 12) {
                emojiBadge(entry.emoji)
                Text(entry.title)
                Text("· \(TodayLogic.routineProgressLabel(of: entry))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if entry.streak >= 2 {
                    Text("🔥 \(entry.streak)")
                        .font(.subheadline)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TodayLogic.routineRowLabel(entry, isNow: false))  // R13
        .listRowInsets(rowInsets)
    }

    /// The 44pt circle: completes an open row, un-checks a done one.
    private func completeCircle(_ chore: Components.Schemas.ChoreOccurrence) -> some View {
        let completed = chore.status == .completed
        return Button {
            Task { await toggle(chore) }
        } label: {
            Group {
                if completingIDs.contains(chore.id) {
                    ProgressView()
                } else {
                    Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(completed ? Color.green : Color.secondary)
                }
            }
            .frame(width: 44, height: 44)  // HIG minimum tap target
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(completingIDs.contains(chore.id))
        .accessibilityLabel(completed ? "Uncomplete \(chore.title)" : "Complete \(chore.title)")
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
            var members: [Components.Schemas.Member] = []
            switch try await membersCall {
            case .ok(let ok): members = try ok.body.json.members
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
            var boardDate = today
            switch try await routinesCall {
            case .ok(let ok):
                let board = try ok.body.json
                routines = board.entries
                boardDate = board.date
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            // The whole family's balances — the hub shows everyone's chip.
            var balances: [Components.Schemas.StarBalance] = []
            switch try await balancesCall {
            case .ok(let ok): balances = try ok.body.json.balances
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            data = .loaded(TodayData(
                events: events,
                occurrences: occurrences,
                routines: routines,
                boardDate: boardDate,
                members: members,
                balances: balances
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

    /// The circle is a toggle (kiosk trust); both sides share the swipe
    /// actions' optimistic apply + 409 plumbing.
    private func toggle(_ chore: Components.Schemas.ChoreOccurrence) async {
        switch TodayLogic.circleAction(for: chore) {
        case .complete: await perform(.complete, on: chore)
        case .uncomplete: await perform(.uncomplete, on: chore)
        }
    }

    private enum RowCall {
        case complete, uncomplete, claim, unclaim, dismiss
    }

    private enum CallOutcome {
        case ok(Components.Schemas.ChoreActionResult)
        case unauthorized
        case conflict(String?)
        case failed
    }

    /// Every row action is optimistic: reflect the returned occurrence right
    /// away, the SSE bump refetches the rest (balance, other rows).
    private func perform(_ call: RowCall, on chore: Components.Schemas.ChoreOccurrence) async {
        guard completingIDs.insert(chore.id).inserted else { return }
        defer { completingIDs.remove(chore.id) }
        do {
            switch try await send(call, id: chore.id) {
            case .ok(let result):
                apply(result, tappedID: chore.id)
            case .unauthorized:
                appState.handleUnauthorized()
            case .conflict(let code):
                actionError = TodayLogic.conflictMessage(code: code)
                await load()
            case .failed:
                actionError = TodayLogic.conflictMessage(code: nil)
                await load()
            }
        } catch {
            guard !isTaskCancellation(error) else { return } // D08
            actionError = "Couldn't reach your home server. Try again."
        }
    }

    /// One outcome from five per-operation Output enums. D21: the semantic
    /// code is the Error body's `error` field; unclaim declares no 409.
    private func send(_ call: RowCall, id: String) async throws -> CallOutcome {
        let api = context.client.api
        switch call {
        case .complete:
            switch try await api.completeChoreOccurrence(.init(path: .init(id: id))) {
            case .ok(let ok): return .ok(try ok.body.json)
            case .unauthorized: return .unauthorized
            case .conflict(let conflict): return .conflict((try? conflict.body.json)?.error)
            default: return .failed
            }
        case .uncomplete:
            // The server revokes the award (409 insufficient_stars when spent).
            switch try await api.uncompleteChoreOccurrence(.init(path: .init(id: id))) {
            case .ok(let ok): return .ok(try ok.body.json)
            case .unauthorized: return .unauthorized
            case .conflict(let conflict): return .conflict((try? conflict.body.json)?.error)
            default: return .failed
            }
        case .claim:
            switch try await api.claimChoreOccurrence(.init(path: .init(id: id))) {
            case .ok(let ok): return .ok(try ok.body.json)
            case .unauthorized: return .unauthorized
            case .conflict(let conflict): return .conflict((try? conflict.body.json)?.error)
            default: return .failed
            }
        case .unclaim:
            switch try await api.unclaimChoreOccurrence(.init(path: .init(id: id))) {
            case .ok(let ok): return .ok(try ok.body.json)
            case .unauthorized: return .unauthorized
            default: return .failed
            }
        case .dismiss:
            switch try await api.dismissChoreOccurrence(.init(path: .init(id: id))) {
            case .ok(let ok): return .ok(try ok.body.json)
            case .unauthorized: return .unauthorized
            case .conflict(let conflict): return .conflict((try? conflict.body.json)?.error)
            default: return .failed
            }
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
