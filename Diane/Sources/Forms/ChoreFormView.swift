import DianeKit
import Foundation
import SwiftUI

// MARK: - Raw PATCH plumbing (shared by the chore + routine forms)

/// PATCH with EXPLICIT JSON nulls. The generated client omits nil optionals,
/// but the chores/routines PATCH routes read an absent key as "keep existing"
/// — clearing a field (or flipping a chore's schedule shape) needs a literal
/// null on the wire, so these two forms hand-encode their update bodies.
enum FormPatch {
    enum Outcome {
        case ok
        case unauthorized
        /// Any other 4xx/5xx, with the Error body's `error` code when present.
        case rejected(String?)
    }

    private struct ErrorBody: Decodable {
        let error: String?
    }

    static func send(
        _ body: some Encodable & Sendable,
        path: String,
        context: SignedInContext
    ) async throws -> Outcome {
        var request = URLRequest(url: context.client.origin.appending(path: path))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(context.session.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return .rejected(nil) }
        switch http.statusCode {
        case 200..<300: return .ok
        case 401: return .unauthorized
        default:
            return .rejected((try? JSONDecoder().decode(ErrorBody.self, from: data))?.error)
        }
    }
}

// MARK: - Chore form logic (nonisolated, tested in FormsLogicTests)

enum ChoreFormLogic {
    /// The four schedule shapes, mirroring the web segmented control and the
    /// server's one-shape rule (packages/chores shapeOf).
    enum Shape: String, CaseIterable, Identifiable {
        case anytime, onDay, byDate, repeats

        var id: String { rawValue }

        var label: String {
            switch self {
            case .anytime: "Anytime"
            case .onDay: "On a day"
            case .byDate: "By a date"
            case .repeats: "Repeats"
            }
        }
    }

    enum Freq: String, CaseIterable, Identifiable {
        case daily, weekly, monthly

        var id: String { rawValue }

        var label: String {
            switch self {
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            }
        }

        func unit(_ interval: Int) -> String {
            let units: (String, String) = switch self {
            case .daily: ("day", "days")
            case .weekly: ("week", "weeks")
            case .monthly: ("month", "months")
            }
            return interval == 1 ? units.0 : units.1
        }
    }

    /// Everything the form edits. Dates are household-local "YYYY-MM-DD" and
    /// times "HH:mm" strings, so every builder below is pure of time zones.
    /// There is NO upForGrabs field: zero selected members IS up for grabs
    /// (web parity — the builders derive the wire field).
    struct State: Equatable {
        var title = ""
        var emoji = ""
        var notes = ""
        var stars = 1
        var assigneeIds: Set<String> = []
        var shape: Shape = .anytime
        /// The date of the 'onDay' (fixed) and 'byDate' (deadline) shapes.
        var dueDate = ""
        /// Dated shapes only — the server 422s dueTime on anytime.
        var hasDueTime = false
        var dueTime = "12:00"
        // Repeats shape.
        var freq: Freq = .daily
        var interval = 1
        var byWeekday: Set<FormWeekday> = []
        /// Monthly only; nil = the start date's day (server rule).
        var byMonthDay: Int?
        var startDate = ""
        var hasEndDate = false
        var endDate = ""
    }

    /// Edit prefill — every server field round-trips untouched; upForGrabs
    /// prefills as an empty selection and derives right back on save.
    static func seed(from chore: Components.Schemas.Chore) -> State {
        var state = State()
        state.title = chore.title
        state.emoji = chore.emoji ?? ""
        state.notes = chore.notes ?? ""
        state.stars = chore.starValue
        state.assigneeIds = Set(chore.assigneeIds)
        if chore.recurrence != nil {
            state.shape = .repeats
        } else if chore.dueDate != nil {
            state.shape = chore.dueMode == .by ? .byDate : .onDay
        } else {
            state.shape = .anytime
        }
        state.dueDate = chore.dueDate ?? ""
        if let dueTime = chore.dueTime {
            state.hasDueTime = true
            state.dueTime = dueTime
        }
        if let recurrence = chore.recurrence {
            state.freq = Freq(rawValue: recurrence.freq.rawValue) ?? .daily
            state.interval = recurrence.interval ?? 1
            state.byWeekday = Set((recurrence.byWeekday ?? []).compactMap { FormWeekday(rawValue: $0.rawValue) })
            state.byMonthDay = recurrence.byMonthDay
            state.startDate = recurrence.startDate
            if let endDate = recurrence.endDate {
                state.hasEndDate = true
                state.endDate = endDate
            }
        }
        return state
    }

    /// R4 Anything typed since the form was seeded — the discard guard.
    static func isDirty(_ state: State, original: State) -> Bool {
        state != original
    }

    /// nil = submittable (client-side mirror of the server's 422 matrix).
    static func validate(_ state: State) -> String? {
        if state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the chore a title."
        }
        if !(0...100).contains(state.stars) { return "Stars must be between 0 and 100." }
        if state.shape == .onDay || state.shape == .byDate, state.dueDate.isEmpty {
            return "Pick a date."
        }
        if state.shape == .repeats {
            if state.startDate.isEmpty { return "Pick a start date." }
            if !(1...365).contains(state.interval) { return "Repeat every 1 to 365." }
            if let day = state.byMonthDay, !(1...31).contains(day) {
                return "Day of month must be between 1 and 31."
            }
            if state.hasEndDate, !state.endDate.isEmpty, state.endDate < state.startDate {
                return "The end date can't be before the start date."
            }
        }
        return nil
    }

    /// Empty selection IS up for grabs (the wire keeps the explicit field).
    static func upForGrabs(_ state: State) -> Bool {
        state.assigneeIds.isEmpty
    }

    /// Has a dueTime on the wire? Only dated shapes; leftovers from a shape
    /// switch are dropped.
    static func dueTimeWire(_ state: State) -> String? {
        state.shape != .anytime && state.hasDueTime ? state.dueTime : nil
    }

    /// Create body: only the selected shape's fields appear at all.
    static func createBody(_ state: State) -> Components.Schemas.ChoreCreate {
        var body = Components.Schemas.ChoreCreate(
            title: state.title.trimmingCharacters(in: .whitespacesAndNewlines),
            starValue: state.stars,
            upForGrabs: upForGrabs(state),
            assigneeIds: state.assigneeIds.sorted()
        )
        let notes = state.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { body.notes = notes }
        let emoji = state.emoji.trimmingCharacters(in: .whitespaces)
        if !emoji.isEmpty { body.emoji = emoji }
        switch state.shape {
        case .anytime:
            break
        case .onDay:
            body.dueDate = state.dueDate
            body.dueTime = dueTimeWire(state)
        case .byDate:
            body.dueDate = state.dueDate
            body.dueMode = .by
            body.dueTime = dueTimeWire(state)
        case .repeats:
            typealias Payload = Components.Schemas.ChoreCreate.RecurrencePayload
            let byWeekday: [Payload.ByWeekdayPayloadPayload]? =
                state.freq == .weekly && !state.byWeekday.isEmpty
                    ? FormWeekday.sorted(state.byWeekday).compactMap {
                        Payload.ByWeekdayPayloadPayload(rawValue: $0.rawValue)
                    }
                    : nil
            body.recurrence = Payload(
                freq: Payload.FreqPayload(rawValue: state.freq.rawValue) ?? .daily,
                interval: state.interval > 1 ? state.interval : nil,
                byWeekday: byWeekday,
                byMonthDay: state.freq == .monthly ? state.byMonthDay : nil,
                startDate: state.startDate,
                endDate: state.hasEndDate && !state.endDate.isEmpty ? state.endDate : nil
            )
            body.dueTime = dueTimeWire(state)
        }
        return body
    }

    /// PATCH body: a FULL schedule replacement — every schedule key present,
    /// null for the unselected shapes' fields — because the server validates
    /// the RESULTING chore of existing row + patch (web buildChoreUpdateBody).
    static func patchBody(_ state: State) -> ChorePatchBody {
        let dated = state.shape == .onDay || state.shape == .byDate
        let notes = state.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = state.emoji.trimmingCharacters(in: .whitespaces)
        return ChorePatchBody(
            title: state.title.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.isEmpty ? nil : notes,
            emoji: emoji.isEmpty ? nil : emoji,
            starValue: state.stars,
            upForGrabs: upForGrabs(state),
            assigneeIds: state.assigneeIds.sorted(),
            dueDate: dated ? state.dueDate : nil,
            dueMode: state.shape == .byDate ? "by" : nil,
            dueTime: dueTimeWire(state),
            recurrence: state.shape == .repeats
                ? ChorePatchBody.Recurrence(
                    freq: state.freq.rawValue,
                    interval: state.interval > 1 ? state.interval : nil,
                    byWeekday: state.freq == .weekly && !state.byWeekday.isEmpty
                        ? FormWeekday.sorted(state.byWeekday).map(\.rawValue)
                        : nil,
                    byMonthDay: state.freq == .monthly ? state.byMonthDay : nil,
                    startDate: state.startDate,
                    endDate: state.hasEndDate && !state.endDate.isEmpty ? state.endDate : nil
                )
                : nil
        )
    }

    /// Server error code -> honest copy for the form.
    static func friendlyError(_ code: String?) -> String {
        // R14 Raw zod paths ("validation_failed (emoji)") never reach the family.
        if let field = FormErrors.validationField(code) { return validationCopy(field) }
        switch code {
        case "invalid_schedule": return "That schedule isn't valid — check the date and repeat settings."
        case "invalid_assignees": return "Pick who does it, or leave it up for grabs."
        case "unknown_member": return "One of the selected members no longer exists."
        case "not_found": return "This chore no longer exists — it may have just been deleted."
        case "forbidden": return "Only a parent can manage chores."
        default: return "That didn't work. Check the connection and try again."
        }
    }

    /// R14 Per-field copy for a 422, generic when the field isn't one we show.
    static func validationCopy(_ field: String) -> String {
        switch field {
        case "title": "The title needs to be 1 to \(FormLimits.title) characters."
        case "notes": "The notes need to be under \(FormLimits.notes) characters."
        case "emoji": "That emoji isn't one the server accepts — pick another, or none."
        case "starValue": "Stars must be between 0 and 100."
        case "recurrence", "dueDate", "dueMode", "dueTime":
            "That schedule isn't valid — check the date and repeat settings."
        case "assigneeIds", "upForGrabs": "Pick who does it, or leave it up for grabs."
        default: "Something about the chore isn't valid. Check the fields and try again."
        }
    }
}

/// The hand-encoded PATCH /chores/:id body — every schedule key is ALWAYS
/// present so cleared fields go out as literal nulls (see FormPatch).
struct ChorePatchBody: Encodable, Equatable {
    var title: String
    var notes: String?
    var emoji: String?
    var starValue: Int
    var upForGrabs: Bool
    var assigneeIds: [String]
    var dueDate: String?
    var dueMode: String?
    var dueTime: String?
    var recurrence: Recurrence?

    /// Optional sub-fields use the synthesized encoder: inside a present
    /// recurrence, absent (not null) is the canonical wire shape.
    struct Recurrence: Encodable, Equatable {
        var freq: String
        var interval: Int?
        var byWeekday: [String]?
        var byMonthDay: Int?
        var startDate: String
        var endDate: String?
    }

    private enum CodingKeys: String, CodingKey {
        case title, notes, emoji, starValue, upForGrabs, assigneeIds
        case dueDate, dueMode, dueTime, recurrence
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        // `encode` (not encodeIfPresent) on optionals writes explicit nulls.
        try container.encode(notes, forKey: .notes)
        try container.encode(emoji, forKey: .emoji)
        try container.encode(starValue, forKey: .starValue)
        try container.encode(upForGrabs, forKey: .upForGrabs)
        try container.encode(assigneeIds, forKey: .assigneeIds)
        try container.encode(dueDate, forKey: .dueDate)
        try container.encode(dueMode, forKey: .dueMode)
        try container.encode(dueTime, forKey: .dueTime)
        try container.encode(recurrence, forKey: .recurrence)
    }
}

// MARK: - Screen

enum ChoreFormMode {
    case create
    case edit(choreId: String)
}

/// Create/edit sheet for a chore DEFINITION — the admin management surface.
/// The server enforces admin; callers gate the entry point on isAdmin.
struct ChoreFormView: View {
    let context: SignedInContext
    let members: [Components.Schemas.Member]
    let mode: ChoreFormMode
    let onSaved: () -> Void

    init(
        context: SignedInContext,
        members: [Components.Schemas.Member],
        mode: ChoreFormMode,
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

    @State private var state = ChoreFormLogic.State()
    /// R4 The seeded snapshot the dirty check compares against.
    @State private var original = ChoreFormLogic.State()
    @State private var seeded = false
    @State private var loadFailed: String?
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false

    private var editedChoreId: String? {
        if case .edit(let choreId) = mode { return choreId }
        return nil
    }

    /// R4 Typed edits would be lost by a swipe-down or a bare Cancel.
    private var isDirty: Bool {
        seeded && ChoreFormLogic.isDirty(state, original: original)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(editedChoreId == nil ? "New chore" : "Edit chore")
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
                                .disabled(!seeded || ChoreFormLogic.validate(state) != nil)
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
        // The chore delete is a HARD delete (chores-v2) — confirm strongly.
        .confirmationDialog(
            "Delete this chore?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete for good", role: .destructive) {
                Task { await deleteChore() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Removes the chore and its history for good. Earned stars are kept.")
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
                Label("Can't open this chore", systemImage: "wifi.exclamationmark")
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
                TextField("Notes", text: FormLimits.capping($state.notes, FormLimits.notes))
                Stepper(value: $state.stars, in: 0...100) {
                    HStack(spacing: 4) {
                        Text("Stars")
                        Text("★ \(state.stars)")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                FormMemberChips(members: members, selected: $state.assigneeIds)
                    .listRowInsets(FormDensity.rowInsets)
            } header: {
                Text("Who")
            } footer: {
                if state.assigneeIds.isEmpty {
                    Text("Nobody picked — it's up for grabs.")
                }
            }

            scheduleSection

            if editedChoreId != nil {
                Section {
                    Button("Delete chore", role: .destructive) {
                        confirmingDelete = true
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                } footer: {
                    // Shape flips / date moves reset resolution history by design.
                    Text("Changing when this chore happens resets its history.")
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

    private var scheduleSection: some View {
        Section {
            Picker("Schedule", selection: $state.shape) {
                ForEach(ChoreFormLogic.Shape.allCases) { shape in
                    Text(shape.label).tag(shape)
                }
            }
            .pickerStyle(.segmented)
            .listRowInsets(FormDensity.rowInsets)

            if state.shape == .onDay || state.shape == .byDate {
                DatePicker(
                    state.shape == .byDate ? "Due by" : "Date",
                    selection: FormDates.dayBinding($state.dueDate, timeZone: clock.timeZone),
                    displayedComponents: .date
                )
            }

            if state.shape == .repeats {
                repeatsFields
            }

            if state.shape != .anytime {
                Toggle("Due time", isOn: $state.hasDueTime)
                if state.hasDueTime {
                    DatePicker(
                        "At",
                        selection: FormDates.timeBinding($state.dueTime, timeZone: clock.timeZone),
                        displayedComponents: .hourAndMinute
                    )
                }
            }
        } header: {
            Text("Schedule")
        } footer: {
            switch state.shape {
            case .onDay: Text("Shows on that day; can't be checked off before then.")
            case .byDate: Text("Do it any time from now — it's late if not done by this day.")
            default: EmptyView()
            }
        }
    }

    @ViewBuilder
    private var repeatsFields: some View {
        Picker("Frequency", selection: $state.freq) {
            ForEach(ChoreFormLogic.Freq.allCases) { freq in
                Text(freq.label).tag(freq)
            }
        }
        Stepper(value: $state.interval, in: 1...365) {
            Text("Every \(state.interval) \(state.freq.unit(state.interval))")
        }
        if state.freq == .weekly {
            FormWeekdayChips(selected: $state.byWeekday)
                .listRowInsets(FormDensity.rowInsets)
        }
        if state.freq == .monthly {
            Picker("Day of month", selection: $state.byMonthDay) {
                Text("Start date's day").tag(Int?.none)
                ForEach(1...31, id: \.self) { day in
                    Text("\(day)").tag(Int?.some(day))
                }
            }
        }
        DatePicker(
            "Start date",
            selection: FormDates.dayBinding($state.startDate, timeZone: clock.timeZone),
            displayedComponents: .date
        )
        Toggle("End date", isOn: $state.hasEndDate)
        if state.hasEndDate {
            DatePicker(
                "Ends",
                selection: FormDates.dayBinding($state.endDate, timeZone: clock.timeZone),
                displayedComponents: .date
            )
        }
    }

    // MARK: Data

    private func prepare(retry: Bool = false) async {
        guard !seeded, retry || loadFailed == nil else { return }
        loadFailed = nil
        switch mode {
        case .create:
            state = ChoreFormLogic.State()
            fillEmptyDates()
            original = state  // R4
            seeded = true
        case .edit(let choreId):
            do {
                switch try await context.client.api.listChores(.init()) {
                case .ok(let ok):
                    guard let chore = try ok.body.json.chores.first(where: { $0.id == choreId }) else {
                        loadFailed = "This chore no longer exists — it may have just been deleted."
                        return
                    }
                    state = ChoreFormLogic.seed(from: chore)
                    fillEmptyDates()
                    original = state  // R4
                    seeded = true
                case .unauthorized:
                    appState.handleUnauthorized()
                default:
                    loadFailed = "The chore didn't load. Try again in a moment."
                }
            } catch {
                guard !isTaskCancellation(error) else { return }
                loadFailed = "Couldn't reach your home server."
            }
        }
    }

    /// Blank date fields start on the household's today, so a shape switch
    /// always shows a real date.
    private func fillEmptyDates() {
        if state.dueDate.isEmpty { state.dueDate = clock.today }
        if state.startDate.isEmpty { state.startDate = clock.today }
        if state.endDate.isEmpty { state.endDate = state.startDate }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        errorMessage = nil
        do {
            switch mode {
            case .create:
                let body = ChoreFormLogic.createBody(state)
                switch try await context.client.api.createChore(.init(body: .json(body))) {
                case .created:
                    onSaved()
                    dismiss()
                case .unauthorized:
                    appState.handleUnauthorized()
                case .forbidden:
                    errorMessage = ChoreFormLogic.friendlyError("forbidden")
                case .unprocessableContent(let response):
                    errorMessage = ChoreFormLogic.friendlyError((try? response.body.json)?.error)
                default:
                    errorMessage = "That didn't work. Check the connection and try again."
                }
            case .edit(let choreId):
                let body = ChoreFormLogic.patchBody(state)
                switch try await FormPatch.send(body, path: "api/v1/chores/\(choreId)", context: context) {
                case .ok:
                    onSaved()
                    dismiss()
                case .unauthorized:
                    appState.handleUnauthorized()
                case .rejected(let code):
                    errorMessage = ChoreFormLogic.friendlyError(code)
                }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }

    private func deleteChore() async {
        guard let choreId = editedChoreId, !saving else { return }
        saving = true
        defer { saving = false }
        errorMessage = nil
        do {
            switch try await context.client.api.deleteChore(.init(path: .init(id: choreId))) {
            case .noContent:
                onSaved()
                dismiss()
            case .unauthorized:
                appState.handleUnauthorized()
            case .forbidden:
                errorMessage = ChoreFormLogic.friendlyError("forbidden")
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
