import DianeKit
import SwiftUI

// MARK: - Pure display logic (nonisolated, tested in DetailsLogicTests)

/// Schedule summary + stale-board rule for the routine detail sheet.
enum RoutineDetailLogic {
    /// "Every day" (nil/empty/all seven), else week-ordered "Mo, We, Fr".
    static func weekdaySummary(_ byWeekday: Components.Schemas.Routine.ByWeekdayPayload?) -> String {
        guard let byWeekday, !byWeekday.isEmpty, Set(byWeekday).count < 7 else { return "Every day" }
        let order: [Components.Schemas.Routine.ByWeekdayPayloadPayload] = [.mo, .tu, .we, .th, .fr, .sa, .su]
        return byWeekday
            .sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            .map { $0.rawValue.capitalized }
            .joined(separator: ", ")
    }

    /// D04: an action must never POST a board date that isn't household-today.
    static func isStale(boardDate: String, today: String) -> Bool {
        RoutinesBoardLogic.isStale(boardDate: boardDate, today: today)
    }

    static let staleMessage = "This board is from yesterday — reopen it"

    /// R12: per-task attribution the board payload already carries — "by Ada ·
    /// 07:12", "by you · 07:12", "Skipped by Ada · 07:12". Nil on open tasks
    /// and when the wire carries neither a completer nor an instant.
    static func taskAttribution(
        status: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload.StatusPayload,
        byName: String?,
        isMe: Bool,
        completedAt: String?,
        timeZone: TimeZone
    ) -> String? {
        guard status != .open else { return nil }
        let who = isMe ? "you" : byName
        let time = clockTime(completedAt, timeZone: timeZone)
        let credit: String? =
            switch (who, time) {
            case (let who?, let time?): "by \(who) · \(time)"
            case (let who?, nil): "by \(who)"
            case (nil, let time?): "at \(time)"
            case (nil, nil): nil
            }
        guard status == .skipped else { return credit }
        return credit.map { "Skipped \($0)" } ?? "Skipped"
    }

    /// "HH:mm" in the household zone; nil when absent or unparseable.
    private static func clockTime(_ instant: String?, timeZone: TimeZone) -> String? {
        guard let instant, let date = parseInstant(instant) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private static func parseInstant(_ instant: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: instant) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: instant)
    }
}

// MARK: - Sheet

/// Density contract: rows run edge-to-edge with a 16pt gutter.
private let routineDetailRowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

/// Tap-a-routine detail sheet. This sheet IS a task list, so its rows keep the
/// circle (complete / un-do) and take Skip / Un-do by swipe like every other
/// row in the app. The entry may belong to ANOTHER member (family Today view);
/// task actions then send that member's id — the server allows it by design
/// (shared-kiosk trust, web parity).
struct RoutineDetailView: View {
    let context: SignedInContext
    let boardDate: String
    let members: [Components.Schemas.Member]
    let onChanged: () -> Void

    @State private var entry: Components.Schemas.RoutineBoardEntry

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock

    @State private var routines: Loadable<[Components.Schemas.Routine]> = .loading
    @State private var busyTaskIds: Set<String> = []
    @State private var actionError: String?
    @State private var editing = false

    init(
        context: SignedInContext,
        entry: Components.Schemas.RoutineBoardEntry,
        boardDate: String,
        members: [Components.Schemas.Member],
        onChanged: @escaping () -> Void
    ) {
        self.context = context
        self.boardDate = boardDate
        self.members = members
        self.onChanged = onChanged
        _entry = State(initialValue: entry)
    }

    private var isStale: Bool {
        RoutineDetailLogic.isStale(boardDate: boardDate, today: clock.today)
    }

    private var routine: Components.Schemas.Routine? {
        routines.value?.first { $0.id == entry.routineId }
    }

    private var member: Components.Schemas.Member? {
        members.first { $0.id == entry.memberId }
    }

    private var membersByID: [String: Components.Schemas.Member] {
        Dictionary(members.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        NavigationStack {
            List {
                if isStale {
                    Section {
                        Label(RoutineDetailLogic.staleMessage, systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                            .listRowInsets(routineDetailRowInsets)
                    }
                }
                headerSection
                tasksSection
            }
            .listStyle(.plain)
            .navigationTitle("Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                if context.session.isAdmin, routine != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Edit") { editing = true }
                    }
                }
            }
            .task { await loadRoutines() }
            .alert(actionError ?? "Something went wrong.", isPresented: alertShown) {
                Button("OK", role: .cancel) {}
            }
            .sheet(isPresented: $editing) {
                RoutineFormView(context: context, members: members, mode: .edit(routineId: entry.routineId)) {
                    // The entry on screen is now stale — hand back to the list.
                    onChanged()
                    dismiss()
                }
            }
        }
    }

    // MARK: Sections

    /// Small uppercase header, flush with the same 16pt gutter as the rows.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    if let emoji = entry.emoji, !emoji.isEmpty {
                        Text(emoji).font(.system(size: 44))
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        windowLine
                    }
                    Spacer()
                    if RoutinesBoardLogic.showsStreakBadge(entry.streak) {
                        Text("🔥\(entry.streak)")
                            .font(.title3.weight(.semibold))
                    }
                }
                if let member {
                    HStack(spacing: 10) {
                        MemberAvatarView(name: member.name, colorHex: member.color, avatar: member.avatar, size: 32)
                        Text(member.name)
                            .font(.subheadline.weight(.medium))
                    }
                }
                if case .loaded = routines, let routine {
                    Label(RoutineDetailLogic.weekdaySummary(routine.byWeekday), systemImage: "repeat")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: RoutinesBoardLogic.progress(of: entry))
                    .tint(entry.complete ? .green : .cyan)
            }
            .padding(.vertical, 4)
            .listRowInsets(routineDetailRowInsets)
        }
    }

    /// "06:00–12:00 · Now" — phase against the household minute; the phase
    /// tag is meaningless on a stale board, so it drops there.
    private var windowLine: some View {
        var line = "\(entry.windowStart)–\(entry.windowEnd)"
        if !isStale {
            let phase = RoutinesBoardLogic.phase(
                windowStart: entry.windowStart,
                windowEnd: entry.windowEnd,
                now: clock.minute
            )
            line += " · \(phase.title)"
        }
        return Text(line)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }

    private var tasksSection: some View {
        Section {
            ForEach(entry.tasks, id: \.taskId) { task in
                taskRow(task)
            }
        } header: {
            sectionHeader("Tasks")
        }
    }

    private func taskRow(_ task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload) -> some View {
        let busy = busyTaskIds.contains(task.taskId)
        return HStack(spacing: 10) {
            if let emoji = task.emoji, !emoji.isEmpty {
                Text(emoji).font(.body)
            } else {
                Image(systemName: "sparkles")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(task.title)
                    .font(.subheadline)
                    .fontDesign(.rounded)
                    .strikethrough(task.status == .completed)
                    .foregroundStyle(task.status == .open ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                // R12: who resolved it and when — the payload carried it all along.
                if let attribution = RoutineDetailLogic.taskAttribution(
                    status: task.status,
                    byName: task.completedByMemberId.flatMap { membersByID[$0]?.name },
                    isMe: task.completedByMemberId == context.session.memberID,
                    completedAt: task.completedAt,
                    timeZone: clock.timeZone
                ) {
                    Text(attribution)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            Spacer()
            if task.starValue > 0 {
                Text("★ \(task.starValue)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            statusControl(task, busy: busy)
        }
        .listRowInsets(routineDetailRowInsets)
        // M9c: circle completes, swipe does the rest — same edges as the board.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isStale, RoutinesBoardLogic.recoveryEdge(for: task.status) == .trailing {
                // Skip is reversible, so no confirm dialog (board parity).
                Button {
                    Task { await perform(.skip, on: task) }
                } label: {
                    Label("Skip", systemImage: "arrow.uturn.forward")
                }
                .tint(.orange)
                .disabled(busy)
                .accessibilityLabel("Skip \(task.title)")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if !isStale, RoutinesBoardLogic.recoveryEdge(for: task.status) == .leading {
                Button {
                    Task { await perform(.undo, on: task) }
                } label: {
                    Label("Un-do", systemImage: "arrow.uturn.backward")
                }
                .tint(.blue)
                .disabled(busy)
                .accessibilityLabel(undoLabel(for: task))
            }
        }
    }

    /// Matches the circle's spoken label so both surfaces read the same.
    private func undoLabel(for task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload) -> String {
        task.status == .skipped ? "Un-do skip of \(task.title)" : "Un-do \(task.title)"
    }

    /// 44pt circle; tapping a checked one un-does (web parity).
    @ViewBuilder
    private func statusControl(
        _ task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload,
        busy: Bool
    ) -> some View {
        let (symbol, style, action, label): (String, AnyShapeStyle, TaskAction, String) =
            switch task.status {
            case .open:
                ("circle", AnyShapeStyle(.secondary), .complete, "Complete \(task.title)")
            case .completed:
                ("checkmark.circle.fill", AnyShapeStyle(.green), .undo, "Un-do \(task.title)")
            case .skipped:
                ("minus.circle", AnyShapeStyle(.secondary), .undo, "Un-do skip of \(task.title)")
            }
        Button {
            Task { await perform(action, on: task) }
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(style)
                .frame(width: RoutinesBoardLogic.tapTarget, height: RoutinesBoardLogic.tapTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(busy || isStale)
        .accessibilityLabel(label)
    }

    // MARK: Data + actions

    private var alertShown: Binding<Bool> {
        Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )
    }

    private func loadRoutines() async {
        do {
            switch try await context.client.api.listRoutines(.init()) {
            case .ok(let ok):
                routines = .loaded(try ok.body.json.routines)
            case .unauthorized:
                appState.handleUnauthorized()
            default:
                if routines.value == nil { routines = .failed("The schedule didn't load.") }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            if routines.value == nil { routines = .failed("Couldn't reach your home server.") }
        }
    }

    private enum TaskAction {
        case complete, skip, undo
    }

    /// Same semantics as the Routines board, but the body carries the ENTRY's
    /// member (this may not be the signed-in member — kiosk trust).
    private func perform(
        _ action: TaskAction,
        on task: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload
    ) async {
        // D04: never POST a stale board date (buttons are disabled too).
        guard !isStale, !busyTaskIds.contains(task.taskId) else { return }
        busyTaskIds.insert(task.taskId)
        defer { busyTaskIds.remove(task.taskId) }
        let body = Components.Schemas.RoutineTaskAction(date: boardDate, memberId: entry.memberId)
        do {
            switch action {
            case .complete:
                let output = try await context.client.api.completeRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                )
                switch output {
                case .ok(let ok): apply(try ok.body.json)
                case .unauthorized: appState.handleUnauthorized()
                case .notFound: fail("That task is gone — it may have been edited away.")
                case .unprocessableContent(let e): fail(copy(for: try? e.body.json))
                default: actionError = "That didn't go through. Try again in a moment."
                }
            case .skip:
                let output = try await context.client.api.skipRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                )
                switch output {
                case .ok(let ok): apply(try ok.body.json)
                case .unauthorized: appState.handleUnauthorized()
                case .conflict(let e): fail(copy(for: try? e.body.json))
                case .notFound: fail("That task is gone — it may have been edited away.")
                case .unprocessableContent(let e): fail(copy(for: try? e.body.json))
                default: actionError = "That didn't go through. Try again in a moment."
                }
            case .undo:
                let output = try await context.client.api.uncompleteRoutineTask(
                    .init(path: .init(id: task.taskId), body: .json(body))
                )
                switch output {
                case .ok(let ok): apply(try ok.body.json)
                case .unauthorized: appState.handleUnauthorized()
                case .conflict(let e): fail(copy(for: try? e.body.json))
                case .notFound: fail("That task is gone — it may have been edited away.")
                case .unprocessableContent(let e): fail(copy(for: try? e.body.json))
                default: actionError = "That didn't go through. Try again in a moment."
                }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            actionError = "Couldn't reach your home server."
        }
    }

    private func apply(_ result: Components.Schemas.RoutineTaskActionResult) {
        guard let payload = result.entry else {
            // Entry left the actionable view — nothing left to show here.
            onChanged()
            dismiss()
            return
        }
        entry = Components.Schemas.RoutineBoardEntry(payload)
        onChanged()
    }

    /// The screens behind us refetch; the alert explains what they'll show.
    private func fail(_ message: String) {
        actionError = message
        onChanged()
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
