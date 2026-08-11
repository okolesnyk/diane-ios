import DianeKit
import SwiftUI

// MARK: - Pure board logic (nonisolated, tested in RoutinesLogicTests)

/// Section math for the routine board. Times are zero-padded "HH:mm" strings,
/// so lexicographic comparison is chronological; "now" is always injected.
enum RoutinesBoardLogic {
    enum Phase: CaseIterable {
        case now
        case laterToday
        case earlier

        var title: String {
            switch self {
            case .now: "Now"
            case .laterToday: "Later today"
            case .earlier: "Earlier"
            }
        }
    }

    struct Section {
        let phase: Phase
        let entries: [Components.Schemas.RoutineBoardEntry]
    }

    /// windowStart <= now <= windowEnd → now. End-INCLUSIVE (web parity):
    /// evening presets end 23:59, and the last minute must still count. // D26
    static func phase(windowStart: String, windowEnd: String, now: String) -> Phase {
        if now > windowEnd { return .earlier }
        if now < windowStart { return .laterToday }
        return .now
    }

    /// D04: an action must never POST a board date that isn't household-today.
    static func isStale(boardDate: String, today: String) -> Bool {
        boardDate != today
    }

    /// D27: kid-facing controls match the web's 44px circles (HIG minimum).
    static let tapTarget: CGFloat = 44

    /// M9c density contract: rows sit flush to the screen edge.
    static var rowInsets: EdgeInsets { EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16) }

    /// D27: visible recovery label per task status (long-press was the only
    /// undo surface before).
    static func recoveryActionTitle(
        for status: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload.StatusPayload
    ) -> String {
        status == .open ? "Skip" : "Un-do"
    }

    /// Which swipe edge carries a task's recovery action.
    enum RecoveryEdge {
        case leading
        case trailing
    }

    /// M9c: Skip swipes in from the trailing edge while a task is open; Un-do
    /// comes back from the leading edge once it's resolved. One per row.
    static func recoveryEdge(
        for status: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload.StatusPayload
    ) -> RecoveryEdge {
        status == .open ? .trailing : .leading
    }

    /// Routine section caption: the window, plus the phase when no "Now" pill
    /// is there to say it.
    static func headerCaption(windowStart: String, windowEnd: String, phase: Phase) -> String {
        let window = "\(windowStart)–\(windowEnd)"
        return phase == .now ? window : "\(window) · \(phase.title)"
    }

    static func mine(
        _ entries: [Components.Schemas.RoutineBoardEntry],
        memberId: String
    ) -> [Components.Schemas.RoutineBoardEntry] {
        entries.filter { $0.memberId == memberId }
    }

    /// Non-empty sections in Now / Later today / Earlier order, each sorted
    /// by windowStart (title, then routineId break ties deterministically).
    static func sections(
        for entries: [Components.Schemas.RoutineBoardEntry],
        now: String
    ) -> [Section] {
        var buckets: [Phase: [Components.Schemas.RoutineBoardEntry]] = [:]
        for entry in entries {
            let phase = phase(windowStart: entry.windowStart, windowEnd: entry.windowEnd, now: now)
            buckets[phase, default: []].append(entry)
        }
        return Phase.allCases.compactMap { phase in
            guard var list = buckets[phase], !list.isEmpty else { return nil }
            list.sort {
                ($0.windowStart, $0.title, $0.routineId) < ($1.windowStart, $1.title, $1.routineId)
            }
            return Section(phase: phase, entries: list)
        }
    }

    /// (completed + skipped) / total; 0 for a task-less routine.
    static func progress(of entry: Components.Schemas.RoutineBoardEntry) -> Double {
        guard !entry.tasks.isEmpty else { return 0 }
        let counted = entry.tasks.count(where: { $0.status != .open })
        return Double(counted) / Double(entry.tasks.count)
    }

    static func showsStreakBadge(_ streak: Int) -> Bool {
        streak >= 2
    }
}

/// Admin "All routines" list math (web's All-routines parity).
enum RoutinesManageLogic {
    /// Admin touch-reorder (sortOrder) is canonical; deterministic tie-breaks.
    static func sorted(_ routines: [Components.Schemas.Routine]) -> [Components.Schemas.Routine] {
        routines.sorted {
            ($0.sortOrder, $0.windowStart, $0.title, $0.id)
                < ($1.sortOrder, $1.windowStart, $1.title, $1.id)
        }
    }

    /// "06:00–12:00 · 2 members" row subtitle.
    static func subtitle(windowStart: String, windowEnd: String, assigneeCount: Int) -> String {
        let who = assigneeCount == 1 ? "1 member" : "\(assigneeCount) members"
        return "\(windowStart)–\(windowEnd) · \(who)"
    }
}

// The action result's entry is a structurally identical but distinct
// generated type — bridge it back onto the board.
extension Components.Schemas.RoutineBoardEntry {
    init(_ payload: Components.Schemas.RoutineTaskActionResult.EntryPayload) {
        self.init(
            routineId: payload.routineId,
            title: payload.title,
            emoji: payload.emoji,
            windowStart: payload.windowStart,
            windowEnd: payload.windowEnd,
            memberId: payload.memberId,
            complete: payload.complete,
            streak: payload.streak,
            tasks: payload.tasks.map {
                .init(
                    taskId: $0.taskId,
                    title: $0.title,
                    emoji: $0.emoji,
                    starValue: $0.starValue,
                    status: .init(rawValue: $0.status.rawValue) ?? .open,
                    completedByMemberId: $0.completedByMemberId,
                    completedAt: $0.completedAt
                )
            }
        )
    }
}

// MARK: - Screen (M9e-7, mock page 6 rev 3: the FAMILY board)

/// Family cards — one routine x one member — bucketed Now / Later today /
/// Earlier today. Live-window cards come expanded, everything else folds;
/// windows are display, not locks. Stars credit the CARD's member (owner-
/// not-tapper, the Chores verdict); cross-member reverts confirm. The chip
/// row is the day pages' filter (rings = today's routine progress; the red
/// dot = a closed window still holding open tasks). Yesterday lives behind
/// the clock in the bar (RoutinesPastView).
@MainActor
struct RoutinesView: View {
    let context: SignedInContext
    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock  // D03
    @Environment(MemberFilterStore.self) private var filter

    /// Member tint — the device-local display pref (owner rule 2026-08-05).
    @AppStorage("memberTint") private var tintOn = true

    @State private var board: Loadable<Components.Schemas.RoutineBoard> = .loading
    @State private var members: [Components.Schemas.Member] = []
    @State private var busyTaskIds: Set<String> = []
    @State private var actionError: String?
    @State private var activeSheet: ActiveSheet?
    /// Fold state by card key; nil until the first load seeds the default
    /// (live-window cards open) — after that the user owns it.
    @State private var expandedCards: Set<String>?
    @State private var pendingRevert: PendingRevert?

    struct PendingRevert: Identifiable {
        let entry: Components.Schemas.RoutineBoardEntry
        let task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload
        let reopensSkip: Bool
        var id: String { task.taskId }
    }

    /// One sheet driver: detail and create (All routines is a pushed view).
    enum ActiveSheet: Identifiable {
        case detail(entry: Components.Schemas.RoutineBoardEntry, boardDate: String)
        case create

        var id: String {
            switch self {
            case .detail(let entry, _): "detail-\(entry.routineId)-\(entry.memberId)"
            case .create: "create"
            }
        }
    }

    private var allIDs: [String] { members.map(\.id) }
    private var effective: Set<String> { filter.effective(all: allIDs) }

    var body: some View {
        Group { // M9e: the caller owns the NavigationStack (tab wrap or Home push)
            content
                // D04: clock.today in the key refetches at household midnight.
                .task(id: "\(signals.version(of: [.routines, .stars, .members]))|\(clock.today)") { await load() }
                .refreshable { await load() }
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .detail(let entry, let boardDate):
                        RoutineDetailView(
                            context: context,
                            entry: entry,
                            boardDate: boardDate,
                            members: members,
                            onChanged: { Task { await load() } }
                        )
                    case .create:
                        RoutineFormView(context: context, members: members, mode: .create) {
                            Task { await load() }
                        }
                    }
                }
                // .alert, not confirmationDialog: iOS 26 anchors dialogs to their
        // source with a pointer bubble — the owner wants a plain centered
        // modal (2026-08-09, re-affirmed 2026-08-10).
        .alert(
                    pendingRevert.map { revertTitle($0) } ?? "",
                    isPresented: Binding(
                        get: { pendingRevert != nil },
                        set: { if !$0 { pendingRevert = nil } }
                    ),
                ) {
                    if let pending = pendingRevert {
                        Button(pending.reopensSkip ? "Reopen task" : "Undo check", role: .destructive) {
                            let target = pending
                            pendingRevert = nil
                            Task { await perform(.undo, on: target.task, entry: target.entry) }
                        }
                        Button("Cancel", role: .cancel) { pendingRevert = nil }
                    }
                } message: {
                    if let pending = pendingRevert { Text(revertMessage(pending)) }
                }
                .alert(
                    "Routines",
                    isPresented: Binding(
                        get: { actionError != nil },
                        set: { if !$0 { actionError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(actionError ?? "")
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch board {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load routines", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        case .loaded(let loadedBoard):
            VStack(spacing: 0) {
                chips(entries: loadedBoard.entries)
                // D03: phase math on the household wall clock, not the
                // device's; reading clock.minute re-renders every tick.
                boardList(entries: loadedBoard.entries, now: clock.minute, date: loadedBoard.date)
            }
        }
    }

    // MARK: - Chips (the day pages' row; rings = today's routine progress)

    private func chips(entries: [Components.Schemas.RoutineBoardEntry]) -> some View {
        HStack(spacing: 14) {
            ForEach(members, id: \.id) { member in
                memberChip(member, entries: entries)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func memberChip(
        _ member: Components.Schemas.Member,
        entries: [Components.Schemas.RoutineBoardEntry]
    ) -> some View {
        let isOn = effective.contains(member.id)
        let progress = RoutinesPageLogic.progress(for: member.id, entries: entries)
        let late = RoutinesPageLogic.hasLate(memberID: member.id, entries: entries, now: clock.minute)
        return VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
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
                if late {
                    Circle().fill(.red).frame(width: 8, height: 8).offset(x: 16, y: -16)
                }
            }
            .frame(width: 46, height: 46)
            Text(member.name).font(.caption2).lineLimit(1)
        }
        .opacity(isOn ? 1 : 0.35)
        .contentShape(Rectangle())
        // Double-tap OR long-press solos — both on trial (owner 2026-08-08).
        // No Anyone chip: routines always belong to somebody.
        .onTapGesture(count: 2) { filter.solo(member.id) }
        .onTapGesture { filter.toggle(member.id, all: allIDs) }
        .onLongPressGesture { filter.solo(member.id) }
        .accessibilityLabel(
            "\(member.name), \(Int(progress * 100)) percent of today's routines done\(late ? ", has an open window that closed" : "")"
        )
    }

    // MARK: - The bucketed board

    private func boardList(
        entries: [Components.Schemas.RoutineBoardEntry],
        now: String,
        date: String
    ) -> some View {
        let buckets = RoutinesPageLogic.buckets(entries: entries, now: now, selected: effective)
        let expanded = expandedCards ?? RoutinesPageLogic.defaultExpanded(entries: entries, now: now)
        return List {
            ForEach(buckets, id: \.phase) { bucket in
                Section {
                    // Keyed by the whole entry: a shared routine is one card
                    // PER member, and routineId alone collides.
                    ForEach(bucket.entries, id: \.self) { entry in
                        card(entry, phase: bucket.phase, date: date, expanded: expanded)
                    }
                } header: {
                    Text(bucket.label)
                        .font(.caption.weight(.semibold))
                }
            }
            if buckets.isEmpty {
                Text("No routines for this filter — the dotted row makes one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowInsets(RoutinesBoardLogic.rowInsets)
            }
            if context.session.isAdmin {
                Button {
                    activeSheet = .create
                } label: {
                    GhostLabel(title: "New routine")
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(RoutinesBoardLogic.rowInsets)
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
    }

    /// One card: the fold header, then the task rows while expanded. The
    /// header row wears the member wash (main row only, the Today rule).
    @ViewBuilder
    private func card(
        _ entry: Components.Schemas.RoutineBoardEntry,
        phase: RoutinesBoardLogic.Phase,
        date: String,
        expanded: Set<String>
    ) -> some View {
        let key = RoutinesPageLogic.cardKey(entry)
        let open = expanded.contains(key)
        let sub = RoutinesPageLogic.sub(entry, phase: phase)
        let streak = RoutinesPageLogic.displayedStreak(entry)

        HStack(spacing: 8) {
            Button {
                var next = expanded
                if open { next.remove(key) } else { next.insert(key) }
                withAnimation(.snappy) { expandedCards = next }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title).font(.body.weight(.semibold))
                        subText(sub)
                    }
                    Spacer(minLength: 6)
                    if RoutinesBoardLogic.showsStreakBadge(streak) {
                        Text("🔥 \(streak)").font(.subheadline)
                    }
                    avatar(for: entry.memberId)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(cardLabel(entry, sub: sub, open: open))
            Button {
                activeSheet = .detail(entry: entry, boardDate: date)
            } label: {
                Image(systemName: "info.circle")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entry.title) routine details")
        }
        .listRowInsets(RoutinesBoardLogic.rowInsets)
        .listRowBackground(cardWash(for: entry.memberId))

        if open {
            if entry.tasks.isEmpty {
                Text("No tasks yet — a routine needs at least one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(RoutinesBoardLogic.rowInsets)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(entry.tasks, id: \.taskId) { task in
                    RoutineTaskRow(
                        task: task,
                        busy: busyTaskIds.contains(task.taskId),
                        onAction: { action in requestAction(action, on: task, entry: entry) }
                    )
                    .listRowInsets(RoutinesBoardLogic.rowInsets)
                    .listRowSeparator(.hidden)
                }
            }
        }
    }

    private func subText(_ sub: RoutinesPageLogic.Sub) -> some View {
        var text = Text(sub.text)
        if sub.done { text = text.foregroundStyle(.green) }
        if sub.stillOpen > 0 {
            text = text + Text(" · ")
                + Text("\(sub.stillOpen) still open").foregroundStyle(.red).fontWeight(.semibold)
        }
        return text.font(.caption).foregroundStyle(sub.done ? .green : .secondary).monospacedDigit()
    }

    private func cardLabel(
        _ entry: Components.Schemas.RoutineBoardEntry,
        sub: RoutinesPageLogic.Sub,
        open: Bool
    ) -> String {
        let who = members.first(where: { $0.id == entry.memberId })?.name ?? ""
        let still = sub.stillOpen > 0 ? ", \(sub.stillOpen) still open" : ""
        return "\(entry.title) — \(who), \(sub.text)\(still), \(open ? "expanded" : "collapsed")"
    }

    private func avatar(for memberID: String) -> some View {
        Group {
            if let member = members.first(where: { $0.id == memberID }) {
                MemberAvatarView(
                    name: member.name, colorHex: member.color, avatar: member.avatar, size: 24
                )
            }
        }
    }

    /// Solid wash — a routine card has exactly one member (mock rule).
    @ViewBuilder
    private func cardWash(for memberID: String) -> some View {
        if tintOn, let member = members.first(where: { $0.id == memberID }) {
            Color(hex: member.color).opacity(0.1)
        }
    }

    // MARK: Data

    private func load() async {
        do {
            async let boardCall = context.client.api.getRoutineBoard(.init())
            async let membersCall = context.client.api.listMembers(.init())
            let (boardOut, membersOut) = try await (boardCall, membersCall)

            if case .unauthorized = boardOut { appState.handleUnauthorized(); return }
            if case .unauthorized = membersOut { appState.handleUnauthorized(); return }
            guard case .ok(let boardOK) = boardOut, case .ok(let membersOK) = membersOut else {
                fail("Something went wrong loading routines.")
                return
            }
            let loaded = try boardOK.body.json
            if expandedCards == nil {
                expandedCards = RoutinesPageLogic.defaultExpanded(
                    entries: loaded.entries, now: clock.minute
                )
            }
            board = .loaded(loaded)
            members = try membersOK.body.json.members
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            fail("Couldn't reach your home server.")
        }
    }

    /// Keep stale entries visible; only an empty screen fails hard.
    private func fail(_ message: String) {
        if board.value == nil { board = .failed(message) }
    }

    enum TaskAction {
        case complete
        case skip
        case undo
    }

    /// The confirm gate: completing and skipping are always instant; a
    /// revert of someone ELSE's check or skip asks first (a skip guards
    /// their completed day). Your own reverts are instant.
    private func requestAction(
        _ action: TaskAction,
        on task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload,
        entry: Components.Schemas.RoutineBoardEntry
    ) {
        if action == .undo,
           RoutinesPageLogic.revertNeedsConfirm(
               cardMemberID: entry.memberId, sessionMemberID: context.session.memberID
           ) {
            pendingRevert = PendingRevert(
                entry: entry, task: task, reopensSkip: task.status == .skipped
            )
            return
        }
        Task { await perform(action, on: task, entry: entry) }
    }

    private func revertTitle(_ pending: PendingRevert) -> String {
        let who = members.first(where: { $0.id == pending.entry.memberId })?.name ?? "their"
        return pending.reopensSkip
            ? "Reopen \(who)'s skipped task?"
            : "Undo \(who)'s check?"
    }

    private func revertMessage(_ pending: PendingRevert) -> String {
        let who = members.first(where: { $0.id == pending.entry.memberId })?.name ?? "They"
        if pending.reopensSkip {
            return "\"\(pending.task.title)\" won't count as done until it's finished or re-skipped today. No stars move."
        }
        let stars = pending.task.starValue
        return stars > 0 ? "\(who) loses ★ \(stars)." : "No stars move."
    }

    /// Acts AS the card's member (owner-not-tapper — the Chores verdict):
    /// stars land with whoever the routine belongs to.
    private func perform(
        _ action: TaskAction,
        on task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload,
        entry: Components.Schemas.RoutineBoardEntry
    ) async {
        guard let date = board.value?.date, !busyTaskIds.contains(task.taskId) else { return }
        // D04: never POST a stale board date — a 12:02 AM tap must not
        // record (and double-award) yesterday. Refetch instead.
        if RoutinesBoardLogic.isStale(boardDate: date, today: clock.today) {
            await load()
            return
        }
        busyTaskIds.insert(task.taskId)
        defer { busyTaskIds.remove(task.taskId) }
        let body = Components.Schemas.RoutineTaskAction(date: date, memberId: entry.memberId)
        do {
            switch action {
            case .complete:
                let output = try await context.client.api.completeRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                )
                switch output {
                case .ok(let ok): apply(try ok.body.json)
                case .unauthorized: appState.handleUnauthorized()
                case .notFound: await failAndRefetch("That task is gone — refreshing.")
                case .unprocessableContent(let e): await failAndRefetch(copy(for: try? e.body.json))
                default: actionError = "That didn't go through. Try again in a moment."
                }
            case .skip:
                let output = try await context.client.api.skipRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                )
                switch output {
                case .ok(let ok): apply(try ok.body.json)
                case .unauthorized: appState.handleUnauthorized()
                case .conflict(let e): await failAndRefetch(copy(for: try? e.body.json))
                case .notFound: await failAndRefetch("That task is gone — refreshing.")
                case .unprocessableContent(let e): await failAndRefetch(copy(for: try? e.body.json))
                default: actionError = "That didn't go through. Try again in a moment."
                }
            case .undo:
                let output = try await context.client.api.uncompleteRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                )
                switch output {
                case .ok(let ok): apply(try ok.body.json)
                case .unauthorized: appState.handleUnauthorized()
                case .conflict(let e): await failAndRefetch(copy(for: try? e.body.json))
                case .notFound: await failAndRefetch("That task is gone — refreshing.")
                case .unprocessableContent(let e): await failAndRefetch(copy(for: try? e.body.json))
                default: actionError = "That didn't go through. Try again in a moment."
                }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            actionError = "Couldn't reach your home server."
        }
    }

    /// Apply the returned entry in place; the SSE bump refetches anyway.
    private func apply(_ result: Components.Schemas.RoutineTaskActionResult) {
        guard case .loaded(var current) = board else { return }
        guard let payload = result.entry else {
            // Entry left the actionable view — reconcile with the server.
            Task { await load() }
            return
        }
        let updated = Components.Schemas.RoutineBoardEntry(payload)
        if let index = current.entries.firstIndex(where: {
            $0.routineId == updated.routineId && $0.memberId == updated.memberId
        }) {
            current.entries[index] = updated
            board = .loaded(current)
        }
    }

    private func failAndRefetch(_ message: String) async {
        actionError = message
        await load()
    }

    private func copy(for error: Components.Schemas._Error?) -> String {
        switch error?.error {
        case "already_completed": "Already done — use Un-do instead."
        case "insufficient_stars": "Can't un-do that — those stars are already spent."
        case "not_assignee": "That task belongs to someone else."
        default: "That task can't be changed right now."
        }
    }
}

// MARK: - The past 7 days ("yesterday got away from us" — the heal screen)

/// Chores' History idiom, but CHECKABLE: the engine takes backfill up to 7
/// days and recomputes the streak, so every circle here is live. Actions
/// post their day's date and act as the card's member.
@MainActor
struct RoutinesPastView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock

    @State private var days: Loadable<[(date: String, entries: [Components.Schemas.RoutineBoardEntry])]> = .loading
    @State private var members: [Components.Schemas.Member] = []
    @State private var busyKeys: Set<String> = []
    @State private var actionError: String?
    @State private var expanded: Set<String> = []
    @State private var pendingRevert: RoutinesView.PendingRevert?
    @State private var pendingRevertDate = ""

    var body: some View {
        content
            .navigationTitle("Past 7 days")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .refreshable { await load() }
        // .alert, not confirmationDialog: iOS 26 anchors dialogs to their
        // source with a pointer bubble — the owner wants a plain centered
        // modal (2026-08-09, re-affirmed 2026-08-10).
        .alert(
            pendingRevert.map { revertTitle($0) } ?? "",
            isPresented: Binding(
                get: { pendingRevert != nil },
                set: { if !$0 { pendingRevert = nil } }
            ),
        ) {
            if let pending = pendingRevert {
                Button(pending.reopensSkip ? "Reopen task" : "Undo check", role: .destructive) {
                    let target = pending
                    let date = pendingRevertDate
                    pendingRevert = nil
                    Task { await act(.undo, task: target.task, entry: target.entry, date: date) }
                }
                Button("Cancel", role: .cancel) { pendingRevert = nil }
            }
        } message: {
            if let pending = pendingRevert {
                Text(pending.reopensSkip
                    ? "\"\(pending.task.title)\" won't count as done for that day until it's finished again."
                    : "The stars from that day come back off.")
            }
        }
        .alert(
            "Past 7 days",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        switch days {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load the past days", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        case .loaded(let loaded):
            if loaded.allSatisfy(\.entries.isEmpty) {
                ContentUnavailableView(
                    "Nothing scheduled in the past week.",
                    systemImage: "clock",
                    description: Text("Routines land here once their day has passed.")
                )
            } else {
                List {
                    ForEach(loaded.filter { !$0.entries.isEmpty }, id: \.date) { day in
                        Section {
                            ForEach(day.entries, id: \.self) { entry in
                                pastCard(entry, date: day.date)
                            }
                        } header: {
                            Text(dayLabel(day.date)).font(.caption.weight(.semibold))
                        }
                    }
                }
                .listStyle(.plain)
                .contentMargins(.top, 0, for: .scrollContent)
            }
        }
    }

    private func dayLabel(_ date: String) -> String {
        let title = NavigationLogic.dayTitle(for: date)
        return date == DayLogic.addDays(clock.today, -1) ? "Yesterday — \(title)" : title
    }

    @ViewBuilder
    private func pastCard(
        _ entry: Components.Schemas.RoutineBoardEntry,
        date: String
    ) -> some View {
        let key = "\(date)|\(RoutinesPageLogic.cardKey(entry))"
        let counted = entry.tasks.count(where: { $0.status != .open })
        let total = entry.tasks.count
        let complete = total > 0 && counted == total
        let open = expanded.contains(key) || (!complete && !expanded.contains("closed|\(key)"))

        Button {
            withAnimation(.snappy) {
                if open {
                    expanded.remove(key)
                    if !complete { expanded.insert("closed|\(key)") }
                } else {
                    expanded.insert(key)
                    expanded.remove("closed|\(key)")
                }
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.body.weight(.semibold))
                    pastSub(counted: counted, total: total, complete: complete)
                }
                Spacer(minLength: 6)
                avatar(for: entry.memberId)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(entry.title), \(counted) of \(total) done, \(open ? "expanded" : "collapsed")")
        .listRowInsets(RoutinesBoardLogic.rowInsets)

        if open {
            ForEach(entry.tasks, id: \.taskId) { task in
                RoutineTaskRow(
                    task: task,
                    busy: busyKeys.contains("\(date)|\(task.taskId)"),
                    onAction: { action in request(action, task: task, entry: entry, date: date) }
                )
                .listRowInsets(RoutinesBoardLogic.rowInsets)
                .listRowSeparator(.hidden)
            }
        }
    }

    private func pastSub(counted: Int, total: Int, complete: Bool) -> some View {
        Group {
            if complete {
                Text("All \(total) done ✓").foregroundStyle(.green)
            } else {
                Text("\(counted) of \(total) · ")
                    + Text("\(total - counted) still open").foregroundStyle(.red).fontWeight(.semibold)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }

    private func avatar(for memberID: String) -> some View {
        Group {
            if let member = members.first(where: { $0.id == memberID }) {
                MemberAvatarView(
                    name: member.name, colorHex: member.color, avatar: member.avatar, size: 24
                )
            }
        }
    }

    private func revertTitle(_ pending: RoutinesView.PendingRevert) -> String {
        let who = members.first(where: { $0.id == pending.entry.memberId })?.name ?? "their"
        return pending.reopensSkip ? "Reopen \(who)'s skipped task?" : "Undo \(who)'s check?"
    }

    private func request(
        _ action: RoutinesView.TaskAction,
        task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload,
        entry: Components.Schemas.RoutineBoardEntry,
        date: String
    ) {
        if action == .undo,
           RoutinesPageLogic.revertNeedsConfirm(
               cardMemberID: entry.memberId, sessionMemberID: context.session.memberID
           ) {
            pendingRevert = RoutinesView.PendingRevert(
                entry: entry, task: task, reopensSkip: task.status == .skipped
            )
            pendingRevertDate = date
            return
        }
        Task { await act(action, task: task, entry: entry, date: date) }
    }

    private func act(
        _ action: RoutinesView.TaskAction,
        task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload,
        entry: Components.Schemas.RoutineBoardEntry,
        date: String
    ) async {
        let busyKey = "\(date)|\(task.taskId)"
        guard !busyKeys.contains(busyKey) else { return }
        busyKeys.insert(busyKey)
        defer { busyKeys.remove(busyKey) }
        let body = Components.Schemas.RoutineTaskAction(date: date, memberId: entry.memberId)
        do {
            let outcome: Bool
            switch action {
            case .complete:
                outcome = if case .ok = try await context.client.api.completeRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                ) { true } else { false }
            case .skip:
                outcome = if case .ok = try await context.client.api.skipRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                ) { true } else { false }
            case .undo:
                outcome = if case .ok = try await context.client.api.uncompleteRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                ) { true } else { false }
            }
            if outcome {
                await load()
            } else {
                actionError = "That check didn't land — the day may be out of the 7-day window."
                await load()
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            actionError = "Couldn't reach your home server."
        }
    }

    private func load() async {
        do {
            async let membersCall = context.client.api.listMembers(.init())
            var loaded: [(date: String, entries: [Components.Schemas.RoutineBoardEntry])] = []
            for date in RoutinesPageLogic.pastDays(today: clock.today) {
                guard case .ok(let ok) = try await context.client.api.getRoutineBoard(
                    .init(query: .init(date: date))
                ) else { continue }
                loaded.append((date: date, entries: try ok.body.json.entries))
            }
            if case .ok(let membersOK) = try await membersCall {
                members = try membersOK.body.json.members
            }
            days = .loaded(loaded)
        } catch {
            guard !isTaskCancellation(error) else { return }
            if days.value == nil { days = .failed("Couldn't reach your home server.") }
        }
    }
}

// MARK: - Task row (the family row DNA: circle leading, star trailing)

private struct RoutineTaskRow: View {
    let task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload
    let busy: Bool
    let onAction: (RoutinesView.TaskAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusControl
            EmojiView(emoji: task.emoji, font: .body)
            VStack(alignment: .leading, spacing: 0) {
                Text(task.title)
                    .font(.subheadline)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(task.status == .open ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if task.status == .skipped {
                    Text("Skipped — streak safe")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if task.starValue > 0 {
                Text("★ \(task.starValue)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(.rect)
        // M9c: circle completes, swipe does the rest — no inline Skip/Un-do.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if RoutinesBoardLogic.recoveryEdge(for: task.status) == .trailing {
                // Skip preserves the streak, no stars; reversible, so no dialog.
                Button {
                    onAction(.skip)
                } label: {
                    Label("Skip", systemImage: "arrow.uturn.forward")
                }
                .tint(.orange)
                .disabled(busy)
                .accessibilityLabel("Skip \(task.title)")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if RoutinesBoardLogic.recoveryEdge(for: task.status) == .leading {
                Button {
                    onAction(.undo)
                } label: {
                    Label("Un-do", systemImage: "arrow.uturn.backward")
                }
                .tint(.blue)
                .disabled(busy)
                .accessibilityLabel(undoLabel)
            }
        }
    }

    private var undoLabel: String {
        task.status == .skipped ? "Un-do skip of \(task.title)" : "Un-do \(task.title)"
    }

    /// D27: every circle is a 44pt button; tapping a checked one un-does
    /// (web parity — the checkmark is the undo surface, not decoration).
    @ViewBuilder private var statusControl: some View {
        switch task.status {
        case .open:
            circleButton("circle", style: busy ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary), action: .complete, label: "Complete \(task.title)")
        case .completed:
            circleButton("checkmark.circle.fill", style: AnyShapeStyle(.green), action: .undo, label: "Un-do \(task.title)")
        case .skipped:
            circleButton("minus.circle", style: AnyShapeStyle(.orange), action: .undo, label: "Un-do skip of \(task.title)")
        }
    }

    private func circleButton(
        _ systemImage: String,
        style: AnyShapeStyle,
        action: RoutinesView.TaskAction,
        label: String
    ) -> some View {
        Button {
            onAction(action)
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(style)
                .frame(width: RoutinesBoardLogic.tapTarget, height: RoutinesBoardLogic.tapTarget)  // D27
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(label)
    }
}

/// Emoji-first with the estate-wide sparkles fallback.
private struct EmojiView: View {
    let emoji: String?
    let font: Font

    var body: some View {
        if let emoji, !emoji.isEmpty {
            Text(emoji).font(font)
        } else {
            Image(systemName: "sparkles")
                .font(font)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Admin manage list

/// Every routine definition (web's All-routines parity) — the only route to
/// edit a routine with no card on today's board, or another member's.
/// A PUSHED dedicated view beside the History clock (owner 2026-08-10).
@MainActor
struct ManageRoutinesView: View {
    let context: SignedInContext

    @Environment(AppState.self) private var appState

    @State private var routines: Loadable<[Components.Schemas.Routine]> = .loading
    @State private var members: [Components.Schemas.Member] = []
    @State private var editing: EditTarget?

    private struct EditTarget: Identifiable {
        let routineId: String
        var id: String { routineId }
    }

    var body: some View {
        content
            .navigationTitle("All routines")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .refreshable { await load() }
            .sheet(item: $editing) { target in
                RoutineFormView(
                    context: context,
                    members: members,
                    mode: .edit(routineId: target.routineId)
                ) {
                    Task { await load() }
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch routines {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load routines", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        case .loaded(let list):
            if list.isEmpty {
                ContentUnavailableView(
                    "No routines yet.",
                    systemImage: "sparkles",
                    description: Text("The dotted row on the Routines page creates one.")
                )
            } else {
                List(list, id: \.id) { routine in
                    row(routine)
                        .listRowInsets(RoutinesBoardLogic.rowInsets)
                }
                .listStyle(.plain)
                .contentMargins(.top, 0, for: .scrollContent)
            }
        }
    }

    private func row(_ routine: Components.Schemas.Routine) -> some View {
        Button {
            editing = EditTarget(routineId: routine.id)
        } label: {
            HStack(spacing: 10) {
                EmojiView(emoji: routine.emoji, font: .title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(routine.title)
                        .font(.headline)
                    Text(RoutinesManageLogic.subtitle(
                        windowStart: routine.windowStart,
                        windowEnd: routine.windowEnd,
                        assigneeCount: routine.assigneeIds.count
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: RoutinesBoardLogic.tapTarget)  // D27
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit \(routine.title)")
    }

    private func load() async {
        do {
            async let membersCall = context.client.api.listMembers(.init())
            switch try await context.client.api.listRoutines(.init()) {
            case .ok(let ok):
                routines = .loaded(RoutinesManageLogic.sorted(try ok.body.json.routines))
            case .unauthorized:
                appState.handleUnauthorized()
            default:
                if routines.value == nil { routines = .failed("The routines didn't load.") }
            }
            if case .ok(let ok) = try await membersCall {
                members = try ok.body.json.members
            }
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            if routines.value == nil { routines = .failed("Couldn't reach your home server.") }
        }
    }
}
