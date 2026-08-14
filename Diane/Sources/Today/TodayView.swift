import DianeKit
import SwiftUI

/// The Today tab (owner 2026-08-10 — My Day is gone, this IS the day page):
/// the family river under the member chips, everyone's routine cards pinned
/// last. Chips tap to filter and double-tap to solo (owner 2026-08-07 — the
/// mock's chip grammar); whole-family rows render once and ignore every
/// filter; finished business greys out in place (owner 2026-08-07 — nothing
/// folds away).
struct TodayView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @Environment(SyncSignals.self) private var signals
    @Environment(HouseholdClock.self) private var clock

    @State private var selectedDate: String?
    @State private var path = NavigationPath()
    @State private var data: Loadable<DayData> = .loading
    @Environment(MemberFilterStore.self) private var filter
    @State private var activeSheet: ActiveSheet?
    @State private var openRoutines: Set<String> = []
    @State private var confirmDismiss: DayLogic.Chore?
    @State private var confirmUncheck: ChoresPageLogic.Row?
    @State private var actionError: String?
    @State private var inFlight: Set<String> = []
    /// Member tint — the device-local display pref (owner rule 2026-08-05).
    @AppStorage("memberTint") private var tintOn = true
    @Environment(\.colorScheme) private var colorScheme

    private let rowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

    struct DayData: Equatable {
        var events: [DayLogic.Event]
        var windowChores: [DayLogic.Chore]
        var actionableChores: [DayLogic.Chore]
        var board: [Components.Schemas.RoutineBoardEntry]
        var members: [Components.Schemas.Member]
        var calendars: [DayLogic.CalendarInfo]
    }

    enum ActiveSheet: Identifiable {
        case newEvent(defaultDate: String)
        case newChore

        var id: String {
            switch self {
            case .newEvent(let date): "ev-\(date)"
            case .newChore: "ch"
            }
        }
    }

    private var day: String { selectedDate ?? clock.today }
    private var phase: DayLogic.DayPhase { DayLogic.phase(of: day, today: clock.today) }
    private var members: [Components.Schemas.Member] { data.value?.members ?? [] }
    private var allIDs: [String] { members.map(\.id) }
    private var effectiveSelected: Set<String> { filter.effective(all: allIDs) }
    private var isFiltered: Bool { filter.isFiltered && filter.selected.count < allIDs.count }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // Mock order (owner-confirmed): top bar → week strip →
                // member chips → the river.
                DianeTopBar(
                    context: context,
                    title: NavigationLogic.dayTitle(for: day),
                    action: phase == .today ? nil : { selectedDate = nil },
                    showToday: phase != .today,
                    onToday: { selectedDate = nil }
                )
                strip
                chips
                OfflinePill(center: context.offline)
                content
            }
            .dianeRootChrome()
            .task(id: "\(signals.version(of: [.chores, .events, .calendars, .members, .settings]))|\(day)") {
                await load()
            }
            .dianeDetailDestinations(
                context: context,
                members: members,
                onChanged: { Task { await load() } }
            )
            // The filter is app-wide now (owner 2026-08-06) — it follows
            // you to Calendar instead of resetting when you leave the tab.
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .newEvent(let date):
                    EventFormView(
                        context: context,
                        members: members,
                        mode: .create(defaultDate: date),
                        onSaved: { Task { await load() } }
                    )
                case .newChore:
                    // A future day's new chore is due THAT day (owner
                    // 2026-08-10); today keeps the anytime default.
                    ChoreFormView(
                        context: context,
                        members: members,
                        mode: .create,
                        defaultDate: day == clock.today ? nil : day,
                        onSaved: { Task { await load() } }
                    )
                }
            }
            .alert(
                TimeLogic.dismissPrompt(confirmDismiss?.title ?? ""),
                isPresented: Binding(get: { confirmDismiss != nil }, set: { if !$0 { confirmDismiss = nil } })
            ) {
                Button("Dismiss", role: .destructive) {
                    if let chore = confirmDismiss { Task { await act("dismiss", on: chore) } }
                    confirmDismiss = nil
                }
            } message: {
                Text("No stars for it — and you can bring it back from History.")
            }
            .alert(
                uncheckPrompt,
                isPresented: Binding(get: { confirmUncheck != nil }, set: { if !$0 { confirmUncheck = nil } })
            ) {
                Button("Undo the check", role: .destructive) {
                    if let row = confirmUncheck { Task { await act("uncomplete", on: row.lead) } }
                    confirmUncheck = nil
                }
            }
            .alert("That didn't work", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    private func open(_ route: DetailRoute) { path.append(route) }

    /// Cross-member un-checks confirm and name the cost (owner-approved) —
    /// the Chores module's copy, so a shared row names everyone credited.
    private var uncheckPrompt: String {
        guard let row = confirmUncheck else { return "" }
        return ChoresPageLogic.undoPrompt(row, names: memberNames)
            + " " + ChoresPageLogic.undoDetail(row, names: memberNames)
    }

    // MARK: - Chips

    private var chips: some View {
        HStack(spacing: 14) {
            ForEach(members, id: \.id) { member in
                let chip = TodayLogic.chip(for: member.id, chores: dayChores, board: data.value?.board ?? [])
                let isOn = effectiveSelected.contains(member.id)
                VStack(spacing: 3) {
                    ZStack {
                        Circle()
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: chip.progress)
                            .stroke(
                                Color(hex: member.color),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        MemberAvatarView(
                            name: member.name,
                            colorHex: member.color,
                            avatar: member.avatar,
                            size: 38
                        )
                        if chip.hasLate {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 16, y: -16)
                        }
                    }
                    .frame(width: 46, height: 46)
                    Text(member.name)
                        .font(.caption2)
                        .lineLimit(1)
                }
                .opacity(isOn ? 1 : 0.35)
                .onTapGesture(count: 2) {
                    // Double-tap OR long-press solos — both on trial (owner
                    // 2026-08-08, "so I can check what I use more"); a
                    // second solo restores everyone.
                    filter.solo(member.id)
                }
                .onTapGesture { filter.toggle(member.id, all: allIDs) }
                .onLongPressGesture { filter.solo(member.id) }
                .accessibilityLabel("\(member.name), \(Int(chip.progress * 100)) percent done\(chip.hasLate ? ", has late chores" : "")")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Strip (the shared day cells, family-wide dots)

    private var strip: some View {
        DayStrip(day: day, today: clock.today) { date in
            TodayLogic.familyDots(
                for: date,
                events: data.value?.events ?? [],
                chores: data.value?.windowChores ?? [],
                timeZone: clock.timeZone
            )
        } onSelect: { date in
            selectedDate = date == clock.today ? nil : date
        }
    }

    // MARK: - Content

    private var dayChores: [DayLogic.Chore] {
        guard let loaded = data.value else { return [] }
        return phase == .today
            ? loaded.actionableChores
            : loaded.windowChores.filter { $0.dueDate == day }
    }

    @ViewBuilder
    private var content: some View {
        switch data {
        case .loading:
            Spacer(); ProgressView(); Spacer()
        case .failed(let message):
            Spacer()
            ContentUnavailableView {
                Label("Couldn't load the family", systemImage: "wifi.slash")
            } description: { Text(message) } actions: {
                Button("Try again") { Task { await load() } }
            }
            Spacer()
        case .loaded(let loaded):
            riverList(loaded)
        }
    }

    private func riverList(_ loaded: DayData) -> some View {
        let dayEvents = loaded.events.filter { DayLogic.onDay($0, date: day, timeZone: clock.timeZone) }
        let river = TodayLogic.river(
            events: dayEvents,
            chores: dayChores,
            selected: effectiveSelected,
            phase: phase,
            minute: clock.minute,
            timeZone: clock.timeZone,
            today: clock.today,
            day: day
        )
        let nowIndex = phase == .today
            ? TodayLogic.nowIndex(items: river.flowing, minute: clock.minute, timeZone: clock.timeZone)
            : nil
        // Everyone's routine cards, member-filtered like every owned row.
        let routines = loaded.board.filter { effectiveSelected.contains($0.memberId) }

        let isEmpty = river.catchUp.isEmpty && river.flowing.isEmpty
            && river.dueToday.isEmpty && river.anytime.isEmpty && routines.isEmpty

        return List {
            DayModeNote(phase: phase)
            if isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sun.max").font(.title2).foregroundStyle(.secondary)
                    Text("Nothing planned for anyone.").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .listRowSeparator(.hidden)
            }
            if !river.catchUp.isEmpty {
                Section {
                    // Washed like every owned row (owner 2026-08-08 — the
                    // "Catch up stays neutral" rule made the pages disagree).
                    ForEach(river.catchUp, id: \.id) { row in choreRow(row, loaded: loaded, late: true) }
                } header: { header("Catch up").foregroundStyle(.red) }
            }
            // ONE bold "Today's Timeline" section (owner 2026-08-10): the
            // timed day in order — nothing folds away (owner 2026-08-07),
            // finished things grey in place — then, each band behind a
            // dashed hint, the clockless dated rows and the anytimers. Pool
            // rows sit at the bottom of whichever band their date and time
            // chose; the standalone Up for grabs shelf is gone.
            if !river.flowing.isEmpty || !river.dueToday.isEmpty || !river.anytime.isEmpty {
                Section {
                    ForEach(Array(river.flowing.enumerated()), id: \.element.id) { index, item in
                        if index == nowIndex { NowLineRow(minute: clock.minute) }
                        riverRow(item, loaded: loaded)
                    }
                    if !river.flowing.isEmpty, nowIndex == river.flowing.count { NowLineRow(minute: clock.minute) }
                    if !river.flowing.isEmpty && !river.dueToday.isEmpty { AnytimeHintRow() }
                    // The middle band wears the day's date (owner
                    // 2026-08-10) — a tiny extra cue against the anytimers.
                    ForEach(river.dueToday, id: \.id) { row in choreRow(row, loaded: loaded, late: row.late && !row.completed, dayCaption: true) }
                    if !river.anytime.isEmpty && (!river.flowing.isEmpty || !river.dueToday.isEmpty) { AnytimeHintRow() }
                    ForEach(river.anytime, id: \.id) { row in choreRow(row, loaded: loaded, late: false) }
                } header: {
                    // Other days keep the role template, date appended
                    // (owner 2026-08-10): "Today's Timeline - Wed, Aug 12".
                    header(day == clock.today ? "Today's Timeline"
                        : "Today's Timeline - " + NavigationLogic.dayTitle(for: day), bold: true)
                }
            }
            // Routines ride where Tomorrow and the 30-day shelf were (owner
            // 2026-08-10) — My Day's cards, washed in each member's color.
            if !routines.isEmpty {
                Section {
                    ForEach(routines, id: \.self) { entry in routineRows(entry) }
                } header: { header("Routines") }
            }
            if phase != .past {
                Section {
                    if context.session.isAdmin {
                        Menu {
                            Button { activeSheet = .newEvent(defaultDate: day) } label: {
                                Label("New event", systemImage: "calendar")
                            }
                            Button { activeSheet = .newChore } label: {
                                Label("New chore", systemImage: "checkmark.circle")
                            }
                        } label: { GhostLabel(title: "New") }
                            .buttonStyle(.plain)
                            .listRowInsets(rowInsets)
                            .listRowSeparator(.hidden)
                    } else {
                        Button { activeSheet = .newEvent(defaultDate: day) } label: { GhostLabel(title: "New") }
                            .buttonStyle(.plain)
                            .listRowInsets(rowInsets)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .fontDesign(.rounded)
        .refreshable { await load() }
        // The hairline row must hug the seam: List reserves ~44pt per row
        // and pads between sections, which left "now" floating in a band.
        .environment(\.defaultMinListRowHeight, 1)
        .listSectionSpacing(10)
        // No page-level day swipe (owner 2026-08-06): rows own the
        // horizontal gesture. The strip above travels days.
    }

    /// Bold = the Today anchor (owner 2026-08-10) — heavier and primary so
    /// it reads apart from Tomorrow and the rest.
    private func header(_ title: String, bold: Bool = false) -> some View {
        Text(title)
            .font(.caption.weight(bold ? .bold : .semibold))
            .textCase(.uppercase)
            .foregroundStyle(bold ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }

    @ViewBuilder
    private func riverRow(_ item: TodayLogic.RiverItem, loaded: DayData) -> some View {
        switch item {
        case .event(let event): eventRow(event, loaded: loaded)
        case .chores(let row): choreRow(row, loaded: loaded, late: false)
        }
    }

    private func eventRow(_ event: DayLogic.Event, loaded: DayData) -> some View {
        let owners = TodayLogic.owners(of: event)
        // Fully-ended events grey in place, they never hide (owner
        // 2026-08-07). A past day has ended wholesale.
        let ended = phase == .past || (phase == .today && TodayLogic.hasEnded(
            event,
            minute: TimeLogic.minutes(clock.minute) ?? 0,
            day: day,
            timeZone: clock.timeZone
        ))
        return HStack(spacing: 10) {
            timeCol(event.allDay ? "all day" : event.startsAt.flatMap { TimeLogic.timeLabel($0, timeZone: clock.timeZone) } ?? "")
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: DayLogic.railColorHex(for: event, calendars: loaded.calendars) ?? "#34c759"))
                .frame(width: 4)
                .frame(minHeight: 30)
            DetailRow(route: .event(event), open: open) {
                HStack {
                    Text(event.summary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            whoBadge(owners: owners)
        }
        // Finished = the WHOLE row drops its color — rail, facepile, wash,
        // everything (owner 2026-08-08: "remove color from those elements
        // completely"). Grayscale, not just dimming.
        .grayscale(ended ? 1 : 0)
        .opacity(phase == .future ? 0.55 : ended ? 0.5 : 1)
        // One separator line for every row, late or not (owner 2026-08-08)
        // — the varying leading columns were sliding it around.
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .listRowInsets(rowInsets)
        .listRowBackground(tintBackground(owners: owners).grayscale(ended ? 1 : 0))
    }

    private func choreRow(
        _ row: ChoresPageLogic.Row,
        loaded: DayData,
        late: Bool,
        dayCaption: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            if late {
                timeCol("late", red: true)
            } else if let time = row.dueTime {
                Text(time)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
                    .overlay(alignment: .leading) {
                        Image(systemName: row.dueMode == .by ? "hourglass" : "clock")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
            }
            circleButton(row, late: late)
            DetailRow(route: .chore(row.lead), open: open) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let emoji = row.emoji { Text(emoji) }
                            // Done = crossed AND greyed (owner 2026-08-07),
                            // so finished work stops shouting.
                            Text(row.title)
                                .strikethrough(row.completed, color: .secondary)
                                .foregroundStyle(row.completed ? Color.secondary : Color.primary)
                        }
                        // No pool caption any more (owner 2026-08-10:
                        // "Anyone can take it" was noise) — the dashed
                        // circle says it; pool rows caption like the rest.
                        if let note = ChoresPageLogic.subtitle(row, today: clock.today, names: memberNames),
                           row.completed {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        } else if dayCaption {
                            Text(NavigationLogic.dayTitle(for: day))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if let due = row.dueDate, due != day,
                                  let origin = DayLogic.dueOrigin(row.lead, today: clock.today) {
                            // An off-day row wears its origin ("due
                            // yesterday" in Catch Up), owner 2026-08-10.
                            Text(origin).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            whoBadge(owners: row.owners)
            // No star values on this page (owner 2026-08-09) — the cost
            // lives in the chore detail and the Chores module.
        }
        // Done = the whole row goes gray — circle, avatar, star, wash
        // (owner 2026-08-08).
        .grayscale(row.completed ? 1 : 0)
        .opacity(row.completed ? 0.6 : 1)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .listRowInsets(rowInsets)
        .listRowBackground(
            tintBackground(owners: row.owners)
                .grayscale(row.completed ? 1 : 0)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Pool rows dismiss too (owner 2026-08-10): "I don't want this
            // done any more" needs no owner. Claim is gone — checking a pool
            // row takes it, and edit assigns it deliberately.
            if !row.completed && phase != .past {
                Button("Dismiss") { confirmDismiss = row.lead }.tint(.orange)
            }
        }
    }

    private func circleButton(_ row: ChoresPageLogic.Row, late: Bool) -> some View {
        Button {
            if row.completed {
                // Your own check reverts instantly; someone else's confirms
                // (a shared row counts as someone else's if ANY of them is).
                if ChoresPageLogic.needsUndoConfirm(row, me: context.session.memberID) {
                    confirmUncheck = row
                } else {
                    Task { await act("uncomplete", on: row.lead) }
                }
            } else {
                Task { await act("complete", on: row.lead) }
            }
        } label: {
            if inFlight.contains(row.lead.id) {
                ProgressView().frame(width: 44, height: 44)
            } else {
                // The doc's pool language: an unowned chore's check circle
                // is ITSELF dashed — dashed but live, tap to do it.
                Image(systemName: row.completed ? "checkmark.circle.fill"
                    : row.isPool ? "circle.dashed" : "circle")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(row.completed ? .green : late ? .red : .secondary)
                    .frame(width: 44, height: 44)
            }
        }
        .buttonStyle(.plain)
        .disabled(phase == .past)
        .accessibilityLabel(row.completed ? "Completed" : "Not completed")
    }

    private func timeCol(_ text: String, red: Bool = false) -> some View {
        Text(text)
            .font(.caption.weight(red ? .bold : .medium))
            .monospacedDigit()
            .foregroundStyle(red ? .red : .secondary)
            .frame(width: 48, alignment: .trailing)
    }

    /// Facepile for owned rows; whole-family rows carry no badge — the
    /// house glyph was noise (owner 2026-08-10).
    @ViewBuilder
    private func whoBadge(owners: [String]) -> some View {
        if !owners.isEmpty {
            HStack(spacing: -7) {
                ForEach(owners.prefix(3), id: \.self) { id in
                    if let member = members.first(where: { $0.id == id }) {
                        MemberAvatarView(name: member.name, colorHex: member.color, avatar: nil, size: 22)
                    }
                }
            }
        }
    }

    /// The 10% wash: solid for one owner, diagonal bands for shared; neutral
    /// (nil) for family and pool rows. Device-local setting.
    @ViewBuilder
    private func tintBackground(owners: [String]) -> some View {
        if tintOn, !owners.isEmpty {
            let colors = TodayLogic.tintColors(forOwners: owners, members: members)
                .compactMap { Color(hex: $0) }
            if let style = bandedTint(colors, opacity: washOpacity(colorScheme)) {
                Rectangle().fill(style)
            }
        }
    }

    private var memberNames: [String: String] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.name) })
    }

    // MARK: - Data + actions

    private func load() async {
        if data.value == nil { data = .loading }
        let range = DayLogic.fetchRange(centeredOn: day)
        do {
            async let eventsCall = context.client.api.listEvents(.init(query: .init(from: range.from, to: range.to)))
            async let windowCall = context.client.api.listChoreOccurrences(
                .init(query: .init(from: range.from, to: DayLogic.addDays(range.to, -1)))
            )
            async let actionableCall = context.client.api.listChoreOccurrences(.init())
            async let boardCall = fetchBoard(day: day)
            async let membersCall = context.client.api.listMembers(.init())
            async let calendarsCall = context.client.api.listCalendars(.init())

            var loaded = DayData(events: [], windowChores: [], actionableChores: [], board: [], members: [], calendars: [])
            switch try await eventsCall {
            case .ok(let ok): loaded.events = try ok.body.json.events
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await windowCall {
            case .ok(let ok): loaded.windowChores = try ok.body.json.occurrences
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await actionableCall {
            case .ok(let ok): loaded.actionableChores = try ok.body.json.occurrences
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            loaded.board = await boardCall
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

    /// Today and the recent past come from the real board. FUTURE days come
    /// from the definitions — "future days show scheduled reality" (mock) —
    /// because the board endpoint refuses dates actions can't land on; its
    /// 422 must never sink the whole load.
    private func fetchBoard(day: String) async -> [Components.Schemas.RoutineBoardEntry] {
        if day > clock.today {
            guard case .ok(let ok)? = try? await context.client.api.listRoutines(.init()),
                  let routines = try? ok.body.json.routines
            else { return [] }
            return DayLogic.futureBoard(routines: routines, day: day)
        }
        guard case .ok(let ok)? = try? await context.client.api.getRoutineBoard(
            .init(query: .init(date: day))
        ) else { return [] }
        return (try? ok.body.json.entries) ?? []
    }

    // MARK: - Routine cards (My Day's exact card — owner 2026-08-10 — plus
    // the member wash on the MAIN row only; foldable, day-locked)

    /// The header row wears the member wash; expanded task rows go bare
    /// (owner 2026-08-10 — "just the routine main row, tasks without").
    @ViewBuilder
    private func routineRows(_ entry: Components.Schemas.RoutineBoardEntry) -> some View {
        let done = entry.tasks.count(where: { $0.status != .open })
        let total = entry.tasks.count
        let complete = total > 0 && done == total
        let streak = entry.streak + (complete ? 1 : 0)
        let key = "\(day)|\(entry.routineId)|\(entry.memberId)"
        let open = openRoutines.contains(key)
        let locked = phase != .today

        Button {
            if open { openRoutines.remove(key) } else { openRoutines.insert(key) }
        } label: {
            HStack(spacing: 8) {
                if let emoji = entry.emoji { Text(emoji) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.body.weight(.semibold))
                    Text(routineSub(entry, done: done, total: total, complete: complete))
                        .font(.caption)
                        .foregroundStyle(complete ? .green : .secondary)
                }
                Spacer()
                if streak >= 2 {
                    Text("🔥 \(streak)").font(.subheadline)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.title), \(done) of \(total) done, \(open ? "expanded" : "collapsed")")
        .listRowInsets(rowInsets)
        .listRowBackground(tintBackground(owners: [entry.memberId]))

        if open {
            ForEach(entry.tasks, id: \.taskId) { task in
                HStack(spacing: 10) {
                    Button {
                        guard !locked else { return }
                        Task { await routineAct(task, entry: entry) }
                    } label: {
                        Image(systemName: task.status == .open
                            ? (locked ? "circle.dashed" : "circle")
                            : task.status == .skipped ? "arrow.uturn.right.circle" : "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(task.status == .completed ? .green : task.status == .skipped ? .orange : .secondary)
                            .opacity(locked ? 0.55 : 1)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .disabled(locked)
                    if let emoji = task.emoji { Text(emoji).font(.subheadline) }
                    Text(task.title)
                        .font(.subheadline)
                        .strikethrough(task.status == .completed, color: .secondary)
                    Spacer()
                    if task.starValue > 0 {
                        Text("★ \(task.starValue)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.leading, 6)
                .listRowInsets(rowInsets)
                .listRowSeparator(.hidden)
            }
        }
    }

    private func routineSub(
        _ entry: Components.Schemas.RoutineBoardEntry,
        done: Int,
        total: Int,
        complete: Bool
    ) -> String {
        let window = "\(entry.windowStart)–\(entry.windowEnd)"
        return complete ? "\(window) · Done for today ✓" : "\(window) · \(done) of \(total)"
    }

    private func routineAct(
        _ task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload,
        entry: Components.Schemas.RoutineBoardEntry
    ) async {
        do {
            // Acts AS the card's member — the family page's kiosk grammar.
            let body = Components.Schemas.RoutineTaskAction(date: day, memberId: entry.memberId)
            switch task.status {
            case .open:
                _ = try await context.client.api.completeRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                )
            default:
                _ = try await context.client.api.uncompleteRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                )
            }
            await load()
        } catch {
            guard !isTaskCancellation(error) else { return }
            actionError = "Check the connection and try again."
        }
    }

    private func act(_ name: String, on chore: DayLogic.Chore) async {
        inFlight.insert(chore.id)
        defer { inFlight.remove(chore.id) }
        do {
            switch name {
            case "complete":
                let output = try await context.client.api.completeChoreOccurrence(.init(path: .init(id: chore.id)))
                if case .conflict(let c) = output { actionError = TimeLogic.conflictMessage(code: try? c.body.json.error) }
            case "uncomplete":
                let output = try await context.client.api.uncompleteChoreOccurrence(.init(path: .init(id: chore.id)))
                if case .conflict(let c) = output { actionError = TimeLogic.conflictMessage(code: try? c.body.json.error) }
            case "dismiss":
                let output = try await context.client.api.dismissChoreOccurrence(.init(path: .init(id: chore.id)))
                if case .conflict(let c) = output { actionError = TimeLogic.conflictMessage(code: try? c.body.json.error) }
            case "claim":
                let output = try await context.client.api.claimChoreOccurrence(.init(path: .init(id: chore.id)))
                if case .conflict(let c) = output { actionError = TimeLogic.conflictMessage(code: try? c.body.json.error) }
            default: break
            }
            await load()
        } catch {
            guard !isTaskCancellation(error) else { return }
            actionError = "Check the connection and try again."
        }
    }
}

/// The dashed ghost-row look, shared by the day pages' "+ New" menus.
struct GhostLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
            Text(title)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, minHeight: 40)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(.tertiary)
        )
        .contentShape(Rectangle())
    }
}

/// The hairline now-line as a zero-height list row (shared by the day pages).
struct NowLineRow: View {
    let minute: String

    var body: some View {
        HStack(spacing: 6) {
            Text(minute)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.red)
                .monospacedDigit()
            Circle().fill(.red).frame(width: 5, height: 5)
            Rectangle().fill(.red).frame(height: 1)
        }
        .frame(height: 1)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        // List reserves ~44pt per row; the hairline must hug the seam.
        .environment(\.defaultMinListRowHeight, 1)
        .accessibilityLabel("Now, \(minute)")
    }
}
