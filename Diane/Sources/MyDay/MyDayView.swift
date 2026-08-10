import DianeKit
import SwiftUI

/// Page 1 (M9e design): Catch up → Today's Timeline (timed rows with the
/// hairline now-line, then dashed bands: due-today, anytime) → Tomorrow →
/// Later → the routine card pinned last, under a 7-day time-travel strip.
/// Past is the read-only record; future chores are completable ("a due day
/// is an estimate"); routines stay day-locked (streak math).
struct MyDayView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @Environment(SyncSignals.self) private var signals
    @Environment(HouseholdClock.self) private var clock

    /// nil = follow the household's today (so midnight moves the page).
    @State private var selectedDate: String?
    @State private var path = NavigationPath()
    @State private var data: Loadable<DayData> = .loading
    @State private var openRoutines: Set<String> = []
    @State private var activeSheet: ActiveSheet?
    @State private var confirmDismiss: MyDayLogic.Chore?
    @State private var actionError: String?
    @State private var inFlight: Set<String> = []

    /// Member tint — the same device-local switch Family Day reads.
    @AppStorage("memberTint") private var tintOn = true
    @Environment(\.colorScheme) private var colorScheme

    private let rowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

    struct DayData: Equatable {
        var events: [MyDayLogic.Event]
        var windowChores: [MyDayLogic.Chore]
        var actionableChores: [MyDayLogic.Chore]
        var board: [Components.Schemas.RoutineBoardEntry]
        var members: [Components.Schemas.Member]
        var calendars: [MyDayLogic.CalendarInfo]
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

    private func open(_ route: DetailRoute) { path.append(route) }

    /// Refetch when any relevant topic bumps or the shown day changes.
    private var reloadKey: String {
        let version = signals.version(of: [.chores, .events, .calendars, .routines, .members, .settings])
        return "\(version)|\(day)"
    }
    private var phase: MyDayLogic.DayPhase { MyDayLogic.phase(of: day, today: clock.today) }
    private var me: String { context.session.memberID }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                DianeTopBar(
                    context: context,
                    title: NavigationLogic.myDayTitle(for: day),
                    action: phase == .today ? nil : { selectedDate = nil },
                    showToday: phase != .today,
                    onToday: { selectedDate = nil }
                )
                strip
                content
            }
            .dianeRootChrome()
            .task(id: reloadKey) {
                await load()
            }
            .dianeDetailDestinations(
                context: context,
                members: data.value?.members ?? [],
                onChanged: { Task { await load() } }
            )
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .newEvent(let date):
                    EventFormView(
                        context: context,
                        members: data.value?.members ?? [],
                        mode: .create(defaultDate: date),
                        onSaved: { Task { await load() } }
                    )
                case .newChore:
                    ChoreFormView(
                        context: context,
                        members: data.value?.members ?? [],
                        mode: .create,
                        onSaved: { Task { await load() } }
                    )
                }
            }
            .alert(
                TodayLogic.dismissPrompt(confirmDismiss?.title ?? ""),
                isPresented: Binding(get: { confirmDismiss != nil }, set: { if !$0 { confirmDismiss = nil } })
            ) {
                Button("Dismiss", role: .destructive) {
                    if let chore = confirmDismiss { Task { await act("dismiss", on: chore) } }
                    confirmDismiss = nil
                }
            } message: {
                Text("No stars for it — and you can bring it back from History.")
            }
            .alert("That didn't work", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    // MARK: - Strip (the shared day cells — same grammar everywhere)

    private var strip: some View {
        DayStrip(day: day, today: clock.today) { date in
            MyDayLogic.dots(
                for: date,
                events: data.value?.events ?? [],
                chores: data.value?.windowChores ?? [],
                me: me,
                timeZone: clock.timeZone
            )
        } onSelect: { date in
            selectedDate = date == clock.today ? nil : date
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch data {
        case .loading:
            Spacer()
            ProgressView()
            Spacer()
        case .failed(let message):
            Spacer()
            ContentUnavailableView {
                Label("Couldn't load the day", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
            Spacer()
        case .loaded(let loaded):
            dayList(loaded)
        }
    }

    private func dayList(_ loaded: DayData) -> some View {
        let dayEvents = loaded.events
            .filter { MyDayLogic.isMyEvent($0, me: me) && MyDayLogic.onDay($0, date: day, timeZone: clock.timeZone) }
        let dayChores = phase == .today
            ? loaded.actionableChores
            : loaded.windowChores.filter { $0.dueDate == day }
        let sections = MyDayLogic.sections(
            dayChores, window: loaded.windowChores, actionable: loaded.actionableChores,
            me: me, phase: phase,
            today: clock.today, minute: clock.minute, timeZone: clock.timeZone,
            day: day
        )
        let timeline = MyDayLogic.timeline(
            events: TodayLogic.sortedEvents(dayEvents),
            timedChores: sections.timed,
            timeZone: clock.timeZone
        )
        let nowIndex = phase == .today
            ? MyDayLogic.nowLineIndex(items: timeline, minute: clock.minute, timeZone: clock.timeZone)
            : nil
        let myRoutines = loaded.board.filter { $0.memberId == me }

        let isEmpty = sections.catchUp.isEmpty && timeline.isEmpty
            && sections.dueToday.isEmpty && sections.anytime.isEmpty
            && sections.tomorrow.isEmpty && sections.later.isEmpty && myRoutines.isEmpty

        return List {
            DayModeNote(phase: phase)
            if isEmpty {
                // "An empty day isn't an error" — one calm line, then the ghost.
                VStack(spacing: 8) {
                    Image(systemName: "sun.max")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Nothing on your day.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .listRowSeparator(.hidden)
            }
            if !sections.catchUp.isEmpty {
                Section {
                    ForEach(sections.catchUp, id: \.id) { chore in choreRow(chore, late: true) }
                } header: {
                    sectionHeader("Catch up").foregroundStyle(.red)
                }
            }
            // ONE bold "Today's Timeline" section (owner 2026-08-10): the
            // timed day in order, then — each band behind a dashed hint —
            // the clockless dated rows and the anytimers.
            if !timeline.isEmpty || !sections.dueToday.isEmpty || !sections.anytime.isEmpty {
                Section {
                    ForEach(Array(timeline.enumerated()), id: \.element.id) { index, item in
                        if index == nowIndex { nowLine }
                        switch item {
                        case .event(let event): eventRow(event, calendars: loaded.calendars)
                        case .chore(let chore): choreRow(chore, late: chore.late)
                        }
                    }
                    if !timeline.isEmpty, nowIndex == timeline.count { nowLine }
                    if !timeline.isEmpty && !sections.dueToday.isEmpty { AnytimeHintRow() }
                    // The middle band wears the day's date (owner
                    // 2026-08-10) — a tiny extra cue against the anytimers.
                    ForEach(sections.dueToday, id: \.id) { chore in choreRow(chore, late: chore.late, dayCaption: true) }
                    if !sections.anytime.isEmpty && (!timeline.isEmpty || !sections.dueToday.isEmpty) { AnytimeHintRow() }
                    ForEach(sections.anytime, id: \.id) { chore in choreRow(chore, late: chore.late) }
                } header: {
                    // Other days keep the role template, date appended
                    // (owner 2026-08-10): "Today's Timeline - Wed, Aug 12".
                    sectionHeader(day == clock.today ? "Today's Timeline"
                        : "Today's Timeline - " + NavigationLogic.myDayTitle(for: day), bold: true)
                }
            }
            if !sections.tomorrow.isEmpty {
                Section {
                    ForEach(sections.tomorrow, id: \.id) { chore in
                        choreRow(chore, late: false, showDueCaption: false)
                    }
                } header: {
                    sectionHeader(day == clock.today ? "Tomorrow"
                        : "Tomorrow - " + NavigationLogic.myDayTitle(for: MyDayLogic.addDays(day, 1)))
                }
            }
            // Beyond tomorrow, a 30-day shelf — the Chores module is the
            // place for the full schedule (owner 2026-08-10).
            if !sections.later.isEmpty {
                Section {
                    ForEach(sections.later, id: \.id) { chore in choreRow(chore, late: false) }
                } header: {
                    sectionHeader("Next 30 days")
                }
            }
            if !myRoutines.isEmpty {
                Section {
                    ForEach(myRoutines, id: \.routineId) { entry in routineCard(entry) }
                } header: {
                    sectionHeader("Routine")
                }
            }
            // ONE ghost "+ New" for the whole page (owner-directed
            // 2026-08-06) — never on past days: the record takes no additions.
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
                        } label: {
                            ghostLabel("New")
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(rowInsets)
                        .listRowSeparator(.hidden)
                    } else {
                        ghostRow("New") { activeSheet = .newEvent(defaultDate: day) }
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
        // No page-level day swipe (owner 2026-08-06): it stole the rows'
        // swipe-to-dismiss. Day travel is the strip above and the Today pill.
    }

    /// Bold = the Today anchor (owner 2026-08-10) — heavier and primary so
    /// it reads apart from Tomorrow and the rest.
    private func sectionHeader(_ title: String, bold: Bool = false) -> some View {
        Text(title)
            .font(.caption.weight(bold ? .bold : .semibold))
            .textCase(.uppercase)
            .foregroundStyle(bold ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }

    /// The hairline now-line (owner-directed): 1pt red, edge to edge, no
    /// reserved band — a zero-height row the neighbours touch.
    private var nowLine: some View {
        HStack(spacing: 6) {
            Text(clock.minute)
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
        .accessibilityLabel("Now, \(clock.minute)")
    }

    private func eventRow(
        _ event: MyDayLogic.Event,
        calendars: [MyDayLogic.CalendarInfo]
    ) -> some View {
        // Fully-ended events grey in place — same approach as Family Day
        // (owner 2026-08-07); a past day has ended wholesale.
        let ended = phase == .past || (phase == .today && FamilyDayLogic.hasEnded(
            event,
            minute: TodayLogic.minutes(clock.minute) ?? 0,
            day: day,
            timeZone: clock.timeZone
        ))
        return HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                if event.allDay {
                    Text("all day").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(event.startsAt.flatMap { TodayLogic.timeLabel($0, timeZone: clock.timeZone) } ?? "")
                        .font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    if let end = event.endsAt.flatMap({ TodayLogic.timeLabel($0, timeZone: clock.timeZone) }) {
                        Text(end).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(width: 48, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(hex: MyDayLogic.railColorHex(for: event, calendars: calendars) ?? "#34c759"))
                .frame(width: 4)
                .frame(minHeight: 30)
            DetailRow(route: .event(event), open: open) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.summary)
                            .font(.body)
                            // The past is the record: finished things read struck.
                            .strikethrough(phase == .past, color: .secondary)
                        if let location = event.location, !location.isEmpty {
                            Text(location).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            whoBadge(owners: FamilyDayLogic.owners(of: event))
        }
        // Finished = the whole row drops its color (owner 2026-08-08).
        .grayscale(ended ? 1 : 0)
        .opacity(phase == .future ? 0.55 : ended ? (phase == .past ? 0.75 : 0.5) : 1)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .listRowInsets(rowInsets)
        .listRowBackground(tintWash(owners: FamilyDayLogic.owners(of: event)).grayscale(ended ? 1 : 0))
    }

    /// Family Day's exact row furniture: facepile for owned rows, the house
    /// glyph for whole-family ones, and the 10% member wash behind both.
    @ViewBuilder
    private func whoBadge(owners: [String]) -> some View {
        if owners.isEmpty {
            Text("🏠").font(.subheadline)
        } else {
            HStack(spacing: -7) {
                ForEach(owners.prefix(3), id: \.self) { id in
                    if let member = memberLookup[id] {
                        MemberAvatarView(
                            name: member.name,
                            colorHex: member.color,
                            avatar: nil,
                            size: 22
                        )
                    }
                }
            }
        }
    }

    /// A shared chore wears ALL its members, not just this occurrence's
    /// (owner 2026-08-08) — siblings come from the same fetched set.
    private func sharedOwners(_ chore: MyDayLogic.Chore) -> [String] {
        let all = phase == .today
            ? (data.value?.actionableChores ?? [])
            : (data.value?.windowChores ?? [])
        return MyDayLogic.sharedOwners(of: chore, in: all)
    }

    /// "⏱ 22:00" — a tiny glyph says whether the time is do-AT (clock) or
    /// due-BY (hourglass), owner 2026-08-08.
    private func choreTimeCol(_ chore: MyDayLogic.Chore) -> some View {
        // The glyph rides the column's left edge — widening the 48pt
        // column would break row alignment, squeezing it wrapped the time.
        Text(chore.dueTime ?? "")
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .frame(width: 48, alignment: .trailing)
            .overlay(alignment: .leading) {
                Image(systemName: chore.dueMode == .by ? "hourglass" : "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
    }

    private var memberLookup: [String: Components.Schemas.Member] {
        Dictionary(uniqueKeysWithValues: (data.value?.members ?? []).map { ($0.id, $0) })
    }

    @ViewBuilder
    private func tintWash(owners: [String]) -> some View {
        if tintOn, !owners.isEmpty {
            let colors = owners.compactMap { memberLookup[$0]?.color }.compactMap { Color(hex: $0) }
            if let style = bandedTint(colors, opacity: washOpacity(colorScheme)) {
                Rectangle().fill(style)
            }
        }
    }

    private func choreRow(
        _ chore: MyDayLogic.Chore,
        late: Bool,
        showDueCaption: Bool = true,
        dayCaption: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            if late {
                timeColumn(nil, allDay: false, lateBadge: true)
            } else if chore.dueTime != nil {
                choreTimeCol(chore)
            }
            CheckCircle(
                completed: chore.status == .completed,
                late: chore.late && chore.status == .open,
                locked: phase == .past,
                inFlight: inFlight.contains(chore.id)
            ) {
                Task { await act(chore.status == .completed ? "uncomplete" : "complete", on: chore) }
            }
            DetailRow(route: .chore(chore), open: open) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let emoji = chore.emoji { Text(emoji) }
                            // Done = crossed AND greyed (owner 2026-08-07).
                            Text(chore.title)
                                .strikethrough(chore.status == .completed, color: .secondary)
                                .foregroundStyle(chore.status == .completed ? Color.secondary : Color.primary)
                        }
                        if let note = TodayLogic.completedByNote(chore, names: memberNames) {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        } else if late, let origin = MyDayLogic.dueOrigin(chore, today: clock.today) {
                            // The debt's origin: "due yesterday 20:05".
                            Text(origin).font(.caption).foregroundStyle(.red)
                        } else if dayCaption {
                            Text(NavigationLogic.myDayTitle(for: day))
                                .font(.caption).foregroundStyle(.secondary)
                        } else if showDueCaption, let due = chore.dueDate, due != day,
                                  let origin = MyDayLogic.dueOrigin(chore, today: clock.today) {
                            // A Later row wears its date (owner 2026-08-10);
                            // the Tomorrow section's header already says it.
                            Text(origin).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            whoBadge(owners: sharedOwners(chore))
            if chore.starValue > 0 {
                Text("★ \(chore.starValue)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        // Done = the whole row goes gray — circle, avatar, star, wash
        // (owner 2026-08-08).
        .grayscale(chore.status == .completed ? 1 : 0)
        .opacity(chore.status == .completed ? 0.6 : 1)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .listRowInsets(rowInsets)
        .listRowBackground(
            tintWash(owners: sharedOwners(chore))
                .grayscale(chore.status == .completed ? 1 : 0)
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if chore.status == .open && phase != .past {
                Button("Dismiss") { confirmDismiss = chore }
                    .tint(.orange)
            }
        }
    }

    private func timeColumn(_ label: String?, allDay: Bool, lateBadge: Bool = false) -> some View {
        Group {
            if lateBadge {
                Text("late")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
            } else if allDay {
                Text("all day")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(label ?? "")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, alignment: .trailing)
    }

    private func ghostLabel(_ title: String) -> some View {
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

    private func ghostRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { ghostLabel(title) }
            .buttonStyle(.plain)
            .listRowInsets(rowInsets)
            .listRowSeparator(.hidden)
    }

    // MARK: - Routine card (the module's card, foldable, day-locked)

    private func routineCard(_ entry: Components.Schemas.RoutineBoardEntry) -> some View {
        let done = entry.tasks.count(where: { $0.status != .open })
        let total = entry.tasks.count
        let complete = total > 0 && done == total
        let streak = entry.streak + (complete ? 1 : 0)
        let open = openRoutines.contains("\(day)|\(entry.routineId)")
        let locked = phase != .today

        return VStack(spacing: 0) {
            Button {
                let key = "\(day)|\(entry.routineId)"
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.title), \(done) of \(total) done, \(open ? "expanded" : "collapsed")")
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
                }
            }
        }
        .padding(.vertical, 4)
        .listRowInsets(rowInsets)
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

    // MARK: - Data + actions

    private var memberNames: [String: String] {
        Dictionary(uniqueKeysWithValues: (data.value?.members ?? []).map { ($0.id, $0.name) })
    }

    private func load() async {
        if data.value == nil { data = .loading }
        let range = MyDayLogic.fetchRange(centeredOn: day)
        let selected = day
        do {
            async let eventsCall = context.client.api.listEvents(.init(query: .init(from: range.from, to: range.to)))
            async let windowCall = context.client.api.listChoreOccurrences(
                .init(query: .init(from: range.from, to: MyDayLogic.addDays(range.to, -1)))
            )
            async let actionableCall = context.client.api.listChoreOccurrences(.init())
            async let boardCall = fetchBoard(day: selected)
            async let membersCall = context.client.api.listMembers(.init())
            async let calendarsCall = context.client.api.listCalendars(.init())

            var loaded = DayData(
                events: [], windowChores: [], actionableChores: [],
                board: [], members: [], calendars: []
            )
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

    /// A failed refresh keeps stale data silently; only a dataless screen
    /// shows the failure state (M9 rule).
    private func fail() {
        if data.value == nil { data = .failed("Check the connection and try again.") }
    }

    /// Today and the recent past come from the real board. FUTURE days come
    /// from the definitions — "future days show scheduled reality" (mock) —
    /// because the board endpoint refuses dates actions can't land on; its
    /// 422 used to sink the whole load and discard every fetched payload.
    private func fetchBoard(day: String) async -> [Components.Schemas.RoutineBoardEntry] {
        if day > clock.today {
            guard case .ok(let ok)? = try? await context.client.api.listRoutines(.init()),
                  let routines = try? ok.body.json.routines
            else { return [] }
            return MyDayLogic.futureBoard(routines: routines, day: day)
        }
        guard case .ok(let ok)? = try? await context.client.api.getRoutineBoard(
            .init(query: .init(date: day))
        ) else { return [] }
        return (try? ok.body.json.entries) ?? []
    }

    private func act(_ name: String, on chore: MyDayLogic.Chore) async {
        inFlight.insert(chore.id)
        defer { inFlight.remove(chore.id) }
        do {
            switch name {
            case "complete":
                let output = try await context.client.api.completeChoreOccurrence(.init(path: .init(id: chore.id)))
                if case .conflict(let conflict) = output {
                    actionError = TodayLogic.conflictMessage(code: try? conflict.body.json.error)
                }
            case "uncomplete":
                let output = try await context.client.api.uncompleteChoreOccurrence(.init(path: .init(id: chore.id)))
                if case .conflict(let conflict) = output {
                    actionError = TodayLogic.conflictMessage(code: try? conflict.body.json.error)
                }
            case "dismiss":
                let output = try await context.client.api.dismissChoreOccurrence(.init(path: .init(id: chore.id)))
                if case .conflict(let conflict) = output {
                    actionError = TodayLogic.conflictMessage(code: try? conflict.body.json.error)
                }
            default:
                break
            }
            await load()
        } catch {
            guard !isTaskCancellation(error) else { return }
            actionError = "Check the connection and try again."
        }
    }

    private func routineAct(
        _ task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload,
        entry: Components.Schemas.RoutineBoardEntry
    ) async {
        do {
            let body = Components.Schemas.RoutineTaskAction(date: day)
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
}
