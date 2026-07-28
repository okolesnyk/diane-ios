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

    /// D27: visible recovery label per task status (long-press was the only
    /// undo surface before).
    static func recoveryActionTitle(
        for status: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload.StatusPayload
    ) -> String {
        status == .open ? "Skip" : "Un-do"
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
    @State private var busyTaskIds: Set<String> = []
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Routines")
                // D04: clock.today in the key refetches at household midnight.
                .task(id: "\(signals.version(of: [.routines, .stars]))|\(clock.today)") { await load() }
                .refreshable { await load() }
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
                boardList(entries: mine, now: clock.minute)
            }
        }
    }

    private func boardList(entries: [Components.Schemas.RoutineBoardEntry], now: String) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(RoutinesBoardLogic.sections(for: entries, now: now), id: \.phase) { section in
                    Text(section.phase.title)
                        .font(.title3.weight(.semibold))
                        .fontDesign(.rounded)
                        .foregroundStyle(section.phase == .now ? Color.cyan : Color.secondary)
                        .padding(.top, 8)
                    ForEach(section.entries, id: \.routineId) { entry in
                        RoutineCardView(
                            entry: entry,
                            highlighted: section.phase == .now,
                            busyTaskIds: busyTaskIds
                        ) { action, task in
                            Task { await perform(action, on: task) }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
    }

    // MARK: Data

    private func load() async {
        do {
            let output = try await context.client.api.getRoutineBoard(.init())
            switch output {
            case .ok(let ok):
                board = .loaded(try ok.body.json)
            case .unauthorized:
                appState.handleUnauthorized()
            default:
                board = .failed("Something went wrong loading routines.")
            }
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            // Keep stale entries visible when the home server is unreachable.
            if board.value == nil { board = .failed("Couldn't reach your home server.") }
        }
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

// MARK: - Routine card

private struct RoutineCardView: View {
    let entry: Components.Schemas.RoutineBoardEntry
    let highlighted: Bool
    let busyTaskIds: Set<String>
    let onAction: (RoutinesView.TaskAction, Components.Schemas.RoutineBoardEntry.TasksPayloadPayload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ProgressView(value: RoutinesBoardLogic.progress(of: entry))
                .tint(entry.complete ? .green : .cyan)
            ForEach(entry.tasks, id: \.taskId) { task in
                RoutineTaskRow(
                    task: task,
                    busy: busyTaskIds.contains(task.taskId),
                    onAction: { onAction($0, task) }
                )
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderColor, lineWidth: 1.5)
        )
    }

    private var borderColor: Color {
        if entry.complete { return .green.opacity(0.4) }
        if highlighted { return .cyan.opacity(0.45) }
        return .clear
    }

    private var header: some View {
        HStack(spacing: 10) {
            EmojiView(emoji: entry.emoji, font: .title2)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.headline)
                    .fontDesign(.rounded)
                Text("\(entry.windowStart)–\(entry.windowEnd)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
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
        }
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
            recoveryButton
            statusControl
        }
        .contentShape(.rect)
        .contextMenu {
            if task.status == .open {
                // Skip preserves the streak, no stars.
                Button("Skip", systemImage: "arrow.uturn.forward") { onAction(.skip) }
            } else {
                Button("Un-do", systemImage: "arrow.uturn.backward") { onAction(.undo) }
            }
        }
    }

    /// D27: Skip / Un-do as a visible button, not a long-press secret.
    private var recoveryButton: some View {
        Button(RoutinesBoardLogic.recoveryActionTitle(for: task.status)) {
            onAction(task.status == .open ? .skip : .undo)
        }
        .font(.caption.weight(.semibold))
        .fontDesign(.rounded)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(.secondary)
        .disabled(busy)
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
