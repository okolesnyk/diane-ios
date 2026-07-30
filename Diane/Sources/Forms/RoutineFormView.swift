import DianeKit
import Foundation
import SwiftUI

// MARK: - Routine form logic (nonisolated, tested in FormsLogicTests)

enum RoutineFormLogic {
    /// One-tap window fills (web WINDOW_PRESETS) + an explicit Custom that
    /// shows the two time wheels.
    enum Preset: String, CaseIterable, Identifiable {
        case morning, afternoon, evening, custom

        var id: String { rawValue }

        var label: String {
            switch self {
            case .morning: "Morning"
            case .afternoon: "Afternoon"
            case .evening: "Evening"
            case .custom: "Custom"
            }
        }

        /// nil for .custom.
        var window: (start: String, end: String)? {
            switch self {
            case .morning: ("06:00", "12:00")
            case .afternoon: ("12:00", "18:00")
            case .evening: ("18:00", "23:59")
            case .custom: nil
            }
        }

        static func matching(start: String, end: String) -> Preset {
            allCases.first { $0.window.map { $0 == (start, end) } ?? false } ?? .custom
        }
    }

    /// One editable task row. `serverId` = an existing task, kept through the
    /// edit so completions and streak history survive a rename or reorder;
    /// nil = new. `id` is client-only identity for ForEach.
    struct TaskRow: Equatable, Identifiable {
        var id = UUID()
        var serverId: String?
        var title = ""
        var emoji = ""
        var stars = 1
    }

    /// Everything the form edits; times are "HH:mm" strings comparable to the
    /// server's window bounds.
    struct State: Equatable {
        var title = ""
        var emoji = ""
        var windowStart = "06:00"
        var windowEnd = "12:00"
        /// All seven selected = daily = byWeekday null on the wire.
        var byWeekday: Set<FormWeekday> = Set(FormWeekday.allCases)
        var assigneeIds: Set<String> = []
        /// Visual order IS the wire order (array order = sortOrder).
        var tasks: [TaskRow] = []
    }

    /// Edit prefill; byWeekday null (daily) prefills as all seven chips.
    static func seed(from routine: Components.Schemas.Routine) -> State {
        var state = State()
        state.title = routine.title
        state.emoji = routine.emoji ?? ""
        state.windowStart = routine.windowStart
        state.windowEnd = routine.windowEnd
        state.byWeekday = routine.byWeekday.map {
            Set($0.compactMap { FormWeekday(rawValue: $0.rawValue) })
        } ?? Set(FormWeekday.allCases)
        state.assigneeIds = Set(routine.assigneeIds)
        state.tasks = routine.tasks
            .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
            .map { TaskRow(serverId: $0.id, title: $0.title, emoji: $0.emoji ?? "", stars: $0.starValue) }
        return state
    }

    /// R4 Anything typed since the form was seeded — the discard guard.
    static func isDirty(_ state: State, original: State) -> Bool {
        state != original
    }

    /// nil = submittable. The server requires at least one assignee
    /// (invalid_assignees) and a non-empty weekday set — mirror it here.
    static func validate(_ state: State) -> String? {
        if state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the routine a title."
        }
        if state.windowStart >= state.windowEnd { return "The window must end after it starts." }
        if state.byWeekday.isEmpty { return "Pick at least one day." }
        if state.assigneeIds.isEmpty { return "Pick at least one member." }
        for task in state.tasks {
            if task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Every task needs a title."
            }
            if !(0...100).contains(task.stars) { return "Task stars must be between 0 and 100." }
        }
        return nil
    }

    /// ALL SEVEN selected = daily = nil on the wire; otherwise the exact set
    /// in canonical order.
    static func byWeekdayWire(_ selected: Set<FormWeekday>) -> [String]? {
        selected.count == FormWeekday.allCases.count
            ? nil
            : FormWeekday.sorted(selected).map(\.rawValue)
    }

    static func createBody(_ state: State) -> Components.Schemas.RoutineCreate {
        let byWeekday: [Components.Schemas.RoutineCreate.ByWeekdayPayloadPayload]? =
            byWeekdayWire(state.byWeekday).map { days in
                days.compactMap { Components.Schemas.RoutineCreate.ByWeekdayPayloadPayload(rawValue: $0) }
            }
        let tasks: [Components.Schemas.RoutineTaskCreate] = state.tasks.map { task in
            let taskEmoji = task.emoji.trimmingCharacters(in: .whitespaces)
            return Components.Schemas.RoutineTaskCreate(
                title: task.title.trimmingCharacters(in: .whitespacesAndNewlines),
                emoji: taskEmoji.isEmpty ? nil : taskEmoji,
                starValue: task.stars
            )
        }
        var body = Components.Schemas.RoutineCreate(
            title: state.title.trimmingCharacters(in: .whitespacesAndNewlines),
            windowStart: state.windowStart,
            windowEnd: state.windowEnd,
            byWeekday: byWeekday,
            assigneeIds: state.assigneeIds.sorted(),
            tasks: tasks
        )
        let emoji = state.emoji.trimmingCharacters(in: .whitespaces)
        if !emoji.isEmpty { body.emoji = emoji }
        return body
    }

    /// PATCH body: a full replacement with explicit nulls (see FormPatch).
    /// Kept rows carry their server task id — dropping ids wipes task history.
    static func patchBody(_ state: State) -> RoutinePatchBody {
        let emoji = state.emoji.trimmingCharacters(in: .whitespaces)
        return RoutinePatchBody(
            title: state.title.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: emoji.isEmpty ? nil : emoji,
            windowStart: state.windowStart,
            windowEnd: state.windowEnd,
            byWeekday: byWeekdayWire(state.byWeekday),
            assigneeIds: state.assigneeIds.sorted(),
            tasks: state.tasks.map { task in
                let taskEmoji = task.emoji.trimmingCharacters(in: .whitespaces)
                return RoutinePatchBody.Task(
                    id: task.serverId,
                    title: task.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    emoji: taskEmoji.isEmpty ? nil : taskEmoji,
                    starValue: task.stars
                )
            }
        )
    }

    /// Server error code -> honest copy for the form.
    static func friendlyError(_ code: String?) -> String {
        // R14 Raw zod paths ("validation_failed (tasks.0.title)") stay internal.
        if let field = FormErrors.validationField(code) { return validationCopy(field) }
        switch code {
        case "invalid_window": return "The window must end after it starts."
        case "invalid_schedule": return "Pick at least one day."
        case "invalid_assignees": return "Pick at least one member."
        case "unknown_member": return "One of the selected members no longer exists."
        case "unknown_task": return "A task didn't match this routine — close the form and retry."
        case "not_found": return "This routine no longer exists — it may have just been deleted."
        case "forbidden": return "Only a parent can manage routines."
        default: return "That didn't work. Check the connection and try again."
        }
    }

    /// R14 Per-field copy for a 422, generic when the field isn't one we show.
    static func validationCopy(_ field: String) -> String {
        switch field {
        case "title": "The title needs to be 1 to \(FormLimits.title) characters."
        case "emoji": "That emoji isn't one the server accepts — pick another, or none."
        case "windowStart", "windowEnd": "The window must end after it starts."
        case "byWeekday": "Pick at least one day."
        case "assigneeIds": "Pick at least one member."
        case "tasks": "One of the tasks isn't valid — check its title, emoji and stars."
        default: "Something about the routine isn't valid. Check the fields and try again."
        }
    }
}

/// The hand-encoded PATCH /routines/:id body — byWeekday and the emoji go out
/// as literal nulls when cleared (the generated client would omit them, which
/// the server reads as "keep existing").
struct RoutinePatchBody: Encodable, Equatable {
    var title: String
    var emoji: String?
    var windowStart: String
    var windowEnd: String
    var byWeekday: [String]?
    var assigneeIds: [String]
    var tasks: [Task]

    struct Task: Encodable, Equatable {
        /// Present = keep this server task (history survives); ABSENT for new
        /// rows — the schema rejects a null id.
        var id: String?
        var title: String
        var emoji: String?
        var starValue: Int

        private enum CodingKeys: String, CodingKey {
            case id, title, emoji, starValue
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(title, forKey: .title)
            // Explicit null clears a kept task's emoji.
            try container.encode(emoji, forKey: .emoji)
            try container.encode(starValue, forKey: .starValue)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case title, emoji, windowStart, windowEnd, byWeekday, assigneeIds, tasks
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(emoji, forKey: .emoji)
        try container.encode(windowStart, forKey: .windowStart)
        try container.encode(windowEnd, forKey: .windowEnd)
        // null = every day.
        try container.encode(byWeekday, forKey: .byWeekday)
        try container.encode(assigneeIds, forKey: .assigneeIds)
        try container.encode(tasks, forKey: .tasks)
    }
}

// MARK: - Screen

enum RoutineFormMode {
    case create
    case edit(routineId: String)
}

/// Create/edit sheet for a routine DEFINITION — the admin management surface.
/// The server enforces admin; callers gate the entry point on isAdmin.
struct RoutineFormView: View {
    let context: SignedInContext
    let members: [Components.Schemas.Member]
    let mode: RoutineFormMode
    let onSaved: () -> Void

    init(
        context: SignedInContext,
        members: [Components.Schemas.Member],
        mode: RoutineFormMode,
        onSaved: @escaping () -> Void
    ) {
        self.context = context
        self.members = members
        self.mode = mode
        self.onSaved = onSaved
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock

    @State private var state = RoutineFormLogic.State()
    /// R4 The seeded snapshot the dirty check compares against.
    @State private var original = RoutineFormLogic.State()
    @State private var preset: RoutineFormLogic.Preset = .morning
    @State private var seeded = false
    @State private var loadFailed: String?
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false
    /// Which task row owns the emoji keyboard / the open grid — one at a time.
    @State private var focusedTask: UUID?
    @State private var gridTask: UUID?

    private var editedRoutineId: String? {
        if case .edit(let routineId) = mode { return routineId }
        return nil
    }

    /// R4 Typed edits would be lost by a swipe-down or a bare Cancel.
    private var isDirty: Bool {
        seeded && RoutineFormLogic.isDirty(state, original: original)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(editedRoutineId == nil ? "New routine" : "Edit routine")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { cancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving {
                            ProgressView()
                        } else {
                            Button("Save") { Task { await save() } }
                                .disabled(!seeded || RoutineFormLogic.validate(state) != nil)
                        }
                    }
                }
                // R4 Confirm before throwing away what's been typed.
                .confirmationDialog(
                    "Discard changes?",
                    isPresented: $confirmingDiscard,
                    titleVisibility: .visible
                ) {
                    Button("Discard changes", role: .destructive) { dismiss() }
                    Button("Keep editing", role: .cancel) {}
                }
        }
        .interactiveDismissDisabled(saving || isDirty)  // R4
        .task { await prepare() }
        .confirmationDialog(
            "Delete this routine?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete for good", role: .destructive) {
                Task { await deleteRoutine() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Removes the routine and its history for good. Earned stars are kept.")
        }
    }

    /// R4 A dirty form asks first; a pristine one just closes.
    private func cancel() {
        if isDirty { confirmingDiscard = true } else { dismiss() }
    }

    @ViewBuilder
    private var content: some View {
        if let loadFailed {
            ContentUnavailableView {
                Label("Can't open this routine", systemImage: "wifi.exclamationmark")
            } description: {
                Text(loadFailed)
            } actions: {
                Button("Try again") { Task { await prepare(retry: true) } }
                    .buttonStyle(.borderedProminent)
            }
        } else if !seeded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                // R14 Capped as you type — the spec's maxLength, never a 422.
                EmojiPickerRow(emoji: FormLimits.capping($state.emoji, FormLimits.emoji))
                TextField("Title", text: FormLimits.capping($state.title, FormLimits.title))
            }

            windowSection

            Section {
                FormWeekdayChips(selected: $state.byWeekday)
                    .listRowInsets(FormDensity.rowInsets)
            } header: {
                Text("Days")
            } footer: {
                if state.byWeekday.count == FormWeekday.allCases.count {
                    Text("Every day.")
                }
            }

            Section {
                FormMemberChips(members: members, selected: $state.assigneeIds)
                    .listRowInsets(FormDensity.rowInsets)
            } header: {
                Text("Who")
            } footer: {
                if state.assigneeIds.isEmpty {
                    Text("Pick at least one member — the routine shows on their board.")
                }
            }

            tasksSection

            if editedRoutineId != nil {
                Section {
                    Button("Delete routine", role: .destructive) {
                        confirmingDelete = true
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .disabled(saving)
        .environment(\.timeZone, clock.timeZone)
    }

    private var windowSection: some View {
        Section("Window") {
            Picker("Window", selection: $preset) {
                ForEach(RoutineFormLogic.Preset.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(FormDensity.rowInsets)
            .onChange(of: preset) { _, newValue in
                if let window = newValue.window {
                    state.windowStart = window.start
                    state.windowEnd = window.end
                }
            }
            if preset == .custom {
                DatePicker(
                    "Starts",
                    selection: FormDates.timeBinding($state.windowStart, timeZone: clock.timeZone),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "Ends",
                    selection: FormDates.timeBinding($state.windowEnd, timeZone: clock.timeZone),
                    displayedComponents: .hourAndMinute
                )
            } else {
                Text("\(state.windowStart)–\(state.windowEnd)")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tasksSection: some View {
        Section {
            ForEach($state.tasks) { $task in
                taskRow($task)
            }
            .onDelete { state.tasks.remove(atOffsets: $0) }
            // Array order = sortOrder on the wire.
            .onMove { state.tasks.move(fromOffsets: $0, toOffset: $1) }

            Button {
                state.tasks.append(RoutineFormLogic.TaskRow())
            } label: {
                Label("Add task", systemImage: "plus")
            }
        } header: {
            HStack {
                Text("Tasks")
                Spacer()
                if state.tasks.count > 1 {
                    EditButton()
                        .font(.caption)
                        .textCase(nil)
                }
            }
        } footer: {
            if state.tasks.isEmpty {
                Text("Add the steps to check off, in order.")
            }
        }
    }

    private func taskRow(_ task: Binding<RoutineFormLogic.TaskRow>) -> some View {
        let id = task.wrappedValue.id
        // R14 Capped as you type, same as the routine's own fields.
        let emoji = FormLimits.capping(task.emoji, FormLimits.emoji)
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Tapping the well raises the emoji keyboard; the chevron opens
                // the curated grid, which is the way in without that keyboard.
                EmojiWell(
                    emoji: emoji,
                    focused: Binding(
                        get: { focusedTask == id },
                        set: { focusedTask = $0 ? id : nil }
                    )
                )
                TextField("Task title", text: FormLimits.capping(task.title, FormLimits.title))
                EmojiGridToggle(expanded: Binding(
                    get: { gridTask == id },
                    set: { gridTask = $0 ? id : nil }
                ))
            }
            if gridTask == id {
                EmojiGridPicker { picked in
                    emoji.wrappedValue = picked
                    focusedTask = nil
                    withAnimation { gridTask = nil }
                }
            }
            Stepper(value: task.stars, in: 0...100) {
                Text("★ \(task.stars.wrappedValue)")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Data

    private func prepare(retry: Bool = false) async {
        guard !seeded, retry || loadFailed == nil else { return }
        loadFailed = nil
        switch mode {
        case .create:
            state = RoutineFormLogic.State()
            preset = .morning
            original = state  // R4
            seeded = true
        case .edit(let routineId):
            do {
                switch try await context.client.api.listRoutines(.init()) {
                case .ok(let ok):
                    guard let routine = try ok.body.json.routines.first(where: { $0.id == routineId }) else {
                        loadFailed = "This routine no longer exists — it may have just been deleted."
                        return
                    }
                    state = RoutineFormLogic.seed(from: routine)
                    preset = .matching(start: state.windowStart, end: state.windowEnd)
                    original = state  // R4
                    seeded = true
                case .unauthorized:
                    appState.handleUnauthorized()
                default:
                    loadFailed = "The routine didn't load. Try again in a moment."
                }
            } catch {
                guard !isTaskCancellation(error) else { return }
                loadFailed = "Couldn't reach your home server."
            }
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        errorMessage = nil
        do {
            switch mode {
            case .create:
                let body = RoutineFormLogic.createBody(state)
                switch try await context.client.api.createRoutine(.init(body: .json(body))) {
                case .created:
                    onSaved()
                    dismiss()
                case .unauthorized:
                    appState.handleUnauthorized()
                case .forbidden:
                    errorMessage = RoutineFormLogic.friendlyError("forbidden")
                case .unprocessableContent(let response):
                    errorMessage = RoutineFormLogic.friendlyError((try? response.body.json)?.error)
                default:
                    errorMessage = "That didn't work. Check the connection and try again."
                }
            case .edit(let routineId):
                let body = RoutineFormLogic.patchBody(state)
                switch try await FormPatch.send(body, path: "api/v1/routines/\(routineId)", context: context) {
                case .ok:
                    onSaved()
                    dismiss()
                case .unauthorized:
                    appState.handleUnauthorized()
                case .rejected(let code):
                    errorMessage = RoutineFormLogic.friendlyError(code)
                }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }

    private func deleteRoutine() async {
        guard let routineId = editedRoutineId, !saving else { return }
        saving = true
        defer { saving = false }
        errorMessage = nil
        do {
            switch try await context.client.api.deleteRoutine(.init(path: .init(id: routineId))) {
            case .noContent:
                onSaved()
                dismiss()
            case .unauthorized:
                appState.handleUnauthorized()
            case .forbidden:
                errorMessage = RoutineFormLogic.friendlyError("forbidden")
            case .notFound:
                // Already gone — the goal state; refresh and close.
                onSaved()
                dismiss()
            default:
                errorMessage = "That didn't work. Check the connection and try again."
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }
}
