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

// MARK: - Screen

@MainActor
struct RoutinesView: View {
    let context: SignedInContext
    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock  // D03

    @State private var board: Loadable<Components.Schemas.RoutineBoard> = .loading
    @State private var members: [Components.Schemas.Member] = []
    @State private var busyTaskIds: Set<String> = []
    @State private var actionError: String?
    @State private var activeSheet: ActiveSheet?

    /// One sheet driver: detail, create, and the admin Manage list.
    enum ActiveSheet: Identifiable {
        case detail(entry: Components.Schemas.RoutineBoardEntry, boardDate: String)
        case create
        case manage

        var id: String {
            switch self {
            case .detail(let entry, _): "detail-\(entry.routineId)-\(entry.memberId)"
            case .create: "create"
            case .manage: "manage"
            }
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Routines")
                // D04: clock.today in the key refetches at household midnight.
                .task(id: "\(signals.version(of: [.routines, .stars]))|\(clock.today)") { await load() }
                .refreshable { await load() }
                .toolbar {
                    // Server enforces admin on routines CRUD; gate the UI too.
                    if context.session.isAdmin {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Manage") { activeSheet = .manage }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("New routine", systemImage: "plus") { activeSheet = .create }
                        }
                    }
                }
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
                    case .manage:
                        ManageRoutinesView(context: context, members: members) {
                            Task { await load() }
                        }
                    }
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
            let mine = RoutinesBoardLogic.mine(
                loadedBoard.entries, memberId: context.session.memberID
            )
            if mine.isEmpty {
                ContentUnavailableView(
                    "No routines scheduled today.",
                    systemImage: "sparkles",
                    description: Text("Enjoy!")
                )
            } else {
                // D03: phase math on the household wall clock, not the
                // device's; reading clock.minute re-renders every tick.
                boardList(entries: mine, now: clock.minute, date: loadedBoard.date)
            }
        }
    }

    /// M9c: one plain, edge-to-edge List — each routine is a Section whose
    /// header carries the identity, phase ordering (Now → Later → Earlier)
    /// still drives the order.
    private func boardList(
        entries: [Components.Schemas.RoutineBoardEntry],
        now: String,
        date: String
    ) -> some View {
        List {
            ForEach(RoutinesBoardLogic.sections(for: entries, now: now), id: \.phase) { section in
                ForEach(section.entries, id: \.routineId) { entry in
                    Section {
                        if entry.tasks.isEmpty {
                            Text("No tasks in this routine yet.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .listRowInsets(RoutinesBoardLogic.rowInsets)
                        } else {
                            ForEach(entry.tasks, id: \.taskId) { task in
                                RoutineTaskRow(
                                    task: task,
                                    busy: busyTaskIds.contains(task.taskId),
                                    onAction: { action in Task { await perform(action, on: task) } }
                                )
                                .listRowInsets(RoutinesBoardLogic.rowInsets)
                            }
                        }
                    } header: {
                        RoutineSectionHeader(
                            entry: entry,
                            phase: section.phase,
                            onTap: { activeSheet = .detail(entry: entry, boardDate: date) }
                        )
                        .listRowInsets(RoutinesBoardLogic.rowInsets)
                        .textCase(nil)  // The routine title is not a shouty label.
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: Data

    private func load() async {
        do {
            // Members ride along for the detail sheet's avatar/name lookups.
            async let boardCall = context.client.api.getRoutineBoard(.init())
            async let membersCall = context.client.api.listMembers(.init())
            let (boardOut, membersOut) = try await (boardCall, membersCall)

            if case .unauthorized = boardOut { appState.handleUnauthorized(); return }
            if case .unauthorized = membersOut { appState.handleUnauthorized(); return }
            guard case .ok(let boardOK) = boardOut, case .ok(let membersOK) = membersOut else {
                fail("Something went wrong loading routines.")
                return
            }
            board = .loaded(try boardOK.body.json)
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

    private func perform(
        _ action: TaskAction,
        on task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload
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
        let body = Components.Schemas.RoutineTaskAction(date: date, memberId: context.session.memberID)
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

// MARK: - Routine section header

/// The routine's identity row — replaces the old card chrome. Tapping it (not
/// the task rows) still opens the detail sheet.
private struct RoutineSectionHeader: View {
    let entry: Components.Schemas.RoutineBoardEntry
    let phase: RoutinesBoardLogic.Phase
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    EmojiView(emoji: entry.emoji, font: .title2)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title)
                            .font(.headline)
                            .fontDesign(.rounded)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(RoutinesBoardLogic.headerCaption(
                            windowStart: entry.windowStart,
                            windowEnd: entry.windowEnd,
                            phase: phase
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                    Spacer(minLength: 6)
                    if phase == .now { nowPill }
                    if RoutinesBoardLogic.showsStreakBadge(entry.streak) {
                        Text("🔥\(entry.streak)")
                            .font(.subheadline.weight(.semibold))
                    }
                    if entry.complete {
                        Text("All done ✓")
                            .font(.caption.weight(.semibold))
                            .fontDesign(.rounded)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green.opacity(0.12), in: .capsule)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                ProgressView(value: RoutinesBoardLogic.progress(of: entry))
                    .tint(entry.complete ? .green : .cyan)
            }
            .frame(minHeight: RoutinesBoardLogic.tapTarget)  // D27
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(entry.title) details")
    }

    /// The one badge the phase headings used to carry.
    private var nowPill: some View {
        Text("Now")
            .font(.caption2.weight(.bold))
            .fontDesign(.rounded)
            .foregroundStyle(.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.cyan.opacity(0.15), in: .capsule)
    }
}

private struct RoutineTaskRow: View {
    let task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload
    let busy: Bool
    let onAction: (RoutinesView.TaskAction) -> Void

    var body: some View {
        HStack(spacing: 10) {
            EmojiView(emoji: task.emoji, font: .body)
            VStack(alignment: .leading, spacing: 0) {
                Text(task.title)
                    .font(.subheadline)
                    .fontDesign(.rounded)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(task.status == .open ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if task.status == .skipped {
                    Text("skipped")
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
            statusControl
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
            circleButton("minus.circle", style: AnyShapeStyle(.secondary), action: .undo, label: "Un-do skip of \(task.title)")
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
@MainActor
private struct ManageRoutinesView: View {
    let context: SignedInContext
    let members: [Components.Schemas.Member]
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var routines: Loadable<[Components.Schemas.Routine]> = .loading
    @State private var editing: EditTarget?

    private struct EditTarget: Identifiable {
        let routineId: String
        var id: String { routineId }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("All routines")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .task { await load() }
                .refreshable { await load() }
                .sheet(item: $editing) { target in
                    RoutineFormView(
                        context: context,
                        members: members,
                        mode: .edit(routineId: target.routineId)
                    ) {
                        onChanged()
                        Task { await load() }
                    }
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
                    description: Text("Tap + on the Routines screen to create one.")
                )
            } else {
                List(list, id: \.id) { routine in
                    row(routine)
                        .listRowInsets(RoutinesBoardLogic.rowInsets)
                }
                .listStyle(.plain)
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
                        .fontDesign(.rounded)
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
            switch try await context.client.api.listRoutines(.init()) {
            case .ok(let ok):
                routines = .loaded(RoutinesManageLogic.sorted(try ok.body.json.routines))
            case .unauthorized:
                appState.handleUnauthorized()
            default:
                if routines.value == nil { routines = .failed("The routines didn't load.") }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            if routines.value == nil { routines = .failed("Couldn't reach your home server.") }
        }
    }
}
