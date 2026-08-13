import DianeKit
import SwiftUI

// MARK: - Reminder-time logic (pure, tested in SupportTests)

/// A member's OWN default chore-reminder time: the wire's "HH:mm". Per member,
/// never per household — one shared chore rings each assignee at their own time.
///
/// The server validates `^([01]\d|2[0-3]):[0-5]\d$`, so mirror it here and let
/// nothing malformed leave the phone. Deliberately stricter than the ICU
/// reading of that pattern: only ASCII digits count, because zod's `\d` on the
/// server is ASCII-only.
enum ChoreReminderLogic {
    /// What a member who has never chosen one gets.
    static let fallback = "18:00"

    /// nil = not a valid wire time.
    static func parse(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2 else { return nil }
        guard parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        guard let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    /// Zero-padded 24h; nil for a time that isn't on the clock.
    static func format(hour: Int, minute: Int) -> String? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    static func isValid(_ text: String) -> Bool { parse(text) != nil }

    /// What the picker starts on: the stored time, else the fallback.
    static func draft(_ stored: String?) -> String {
        guard let stored, isValid(stored) else { return fallback }
        return stored
    }

    /// Server error code -> honest copy.
    static func friendlyError(_ code: String?) -> String {
        if FormErrors.validationField(code) != nil {
            return "That time isn't one the server accepts. Pick another."
        }
        switch code {
        case "forbidden": return "You can only change your own reminder time."
        case "not_found": return "That member no longer exists. Sign in again."
        default: return "That didn't work. Check the connection and try again."
        }
    }
}

/// PATCH /members/:id carrying only this one key. The field is nullable on the
/// wire; the app only ever sets a time, but the encoder stays explicit because
/// synthesized `Codable` omits nil and the route reads an absent key as "keep"
/// — a null would silently become a no-op (see FormPatch).
struct MemberReminderPatch: Encodable, Sendable {
    var choreReminderTime: String?

    private enum CodingKeys: String, CodingKey { case choreReminderTime }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // `encode`, not encodeIfPresent — nil must go out as an explicit null.
        try container.encode(choreReminderTime, forKey: .choreReminderTime)
    }
}

// MARK: - Screen

/// M9c density: the same 16pt gutter every list in the app uses.
private let settingsRowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
private let settingsHeaderInsets = EdgeInsets(top: 10, leading: 16, bottom: 4, trailing: 16)

struct SettingsView: View {
    let context: SignedInContext
    /// M9e top-bar rule: pushed as a PAGE from the avatar (no own stack, no
    /// Done button). The legacy sheet presentation keeps both.
    var asPage: Bool = false
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock
    @Environment(\.dismiss) private var dismiss

    @State private var reminder: Loadable<Void> = .loading
    /// What the picker shows and what gets saved.
    @State private var draft = ChoreReminderLogic.fallback
    /// The last value the server confirmed — the guard against re-saving it.
    @State private var saved: String?
    @State private var saveTask: Task<Void, Never>?
    @State private var reminderError: String?
    @State private var myBalance: Int?
    @State private var confirmingSignOut = false
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("memberTint") private var tintOn = true
    @AppStorage("weekStart") private var weekStart = "system"

    var body: some View {
        Group {
            if asPage {
                content
            } else {
                NavigationStack { content }
            }
        }
        .task { await loadReminder() }
        .onChange(of: draft) { _, value in scheduleSave(value) }
    }

    /// M9e-8 (mock page 7): hero + balance, My preferences, Household
    /// (parents only — ABSENT for kids, not grayed), Server, Sign out.
    private var content: some View {
            List {
                Section {
                    NavigationLink {
                        MyAccountView(context: context)
                    } label: {
                        HStack(spacing: 14) {
                            MemberAvatarView(
                                name: context.session.memberName,
                                colorHex: context.session.memberColor,
                                avatar: nil,
                                size: 52
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(context.session.memberName)
                                    .font(.headline)
                                Text("\(context.session.isAdmin ? "Parent" : "Member") · name, color")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let balance = myBalance {
                                // Balances live HERE and Rewards, nowhere
                                // else (standing rule).
                                Text("★ \(balance)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.orange)
                                    .monospacedDigit()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(settingsRowInsets)
                    .accessibilityLabel("\(context.session.memberName), \(context.session.isAdmin ? "parent" : "member")\(myBalance.map { ", \($0) stars" } ?? ""), opens account")
                }

                Section {
                    if clock.modules.chores { reminderRow }
                    Button {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        LabeledContent("Notifications", value: pushStatusLabel)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(settingsRowInsets)
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    .listRowInsets(settingsRowInsets)
                    Toggle(isOn: $tintOn) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Member tint")
                            Text("show everyone's rows in their own color")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowInsets(settingsRowInsets)
                    Picker("Week starts", selection: $weekStart) {
                        Text("System").tag("system")
                        Text("Sunday").tag("sunday")
                        Text("Monday").tag("monday")
                    }
                    .listRowInsets(settingsRowInsets)
                } header: {
                    header("My preferences")
                }

                if context.session.isAdmin {
                    Section {
                        NavigationLink("Members") { MembersAdminView(context: context) }
                            .listRowInsets(settingsRowInsets)
                        NavigationLink {
                            ModulesView(context: context)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Modules")
                                Text("what the family sees, on every client")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowInsets(settingsRowInsets)
                        NavigationLink {
                            ReminderLeadView(context: context)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Reminder lead")
                                Text("how early events and timed chores ring")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowInsets(settingsRowInsets)
                    } header: {
                        header("Household")
                    }
                }

                Section {
                    NavigationLink {
                        ServerView(context: context)
                    } label: {
                        LabeledContent("Home server", value: context.session.serverURL.host() ?? "")
                    }
                    .listRowInsets(settingsRowInsets)
                } header: {
                    header("Server")
                }

                Section {
                    Button(role: .destructive) {
                        confirmingSignOut = true
                    } label: {
                        Text("Sign out")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .listRowInsets(settingsRowInsets)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            // Centered alert, names the consequence (owner rules).
            .alert("Sign out?", isPresented: $confirmingSignOut) {
                Button("Sign out", role: .destructive) {
                    dismiss()
                    appState.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Signing back in needs the member password.")
            }
            .task { await loadBalance() }
            .toolbar {
                if !asPage {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
    }

    private func loadBalance() async {
        guard case .ok(let ok)? = try? await context.client.api.getStarBalances(.init()),
              let balances = try? ok.body.json.balances else { return }
        myBalance = balances.first(where: { $0.memberId == context.session.memberID })?.balance
    }

    /// One row: my own default reminder time. No save button — picking IS the
    /// save.
    @ViewBuilder private var reminderRow: some View {
            switch reminder {
            case .loading:
                LabeledContent("Chore default reminder time") { ProgressView() }
                    .listRowInsets(settingsRowInsets)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await loadReminder() } }
                        .frame(minHeight: 28)
                }
                .listRowInsets(settingsRowInsets)
            case .loaded:
                // The picker runs on the HOUSEHOLD clock — the server fires at
                // household-local time, so a travelling phone must not shift it.
                DatePicker(
                    "Chore reminder time",
                    selection: FormDates.timeBinding($draft, timeZone: clock.timeZone),
                    displayedComponents: .hourAndMinute
                )
                .environment(\.timeZone, clock.timeZone)
                .listRowInsets(settingsRowInsets)

                if let reminderError {
                    Text(reminderError)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .listRowInsets(settingsRowInsets)
                }
            }
    }

    /// One header look for the screen: small, uppercase, flush left.
    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .listRowInsets(settingsHeaderInsets)
    }

    private var pushStatusLabel: String {
        switch appState.pushRegistrar.status {
        case .idle: "Setting up…"
        case .waiting: "Setting up…"
        case .denied: "Off — allow notifications in iOS Settings"
        case .registered: "On"
        case .failed(let reason): reason
        }
    }

    // MARK: Data

    private func loadReminder() async {
        do {
            let id = context.session.memberID
            switch try await context.client.api.getMember(.init(path: .init(id: id))) {
            case .ok(let ok):
                let stored = try ok.body.json.choreReminderTime
                saved = ChoreReminderLogic.isValid(stored ?? "") ? stored : nil
                draft = ChoreReminderLogic.draft(stored)
                reminder = .loaded(())
                // Never chosen one: write the fallback now, so the row shows a
                // time the server will actually ring at. There is no "off"
                // switch any more — a default that does nothing isn't one.
                if saved == nil { await save(draft) }
            case .unauthorized:
                appState.handleUnauthorized()
            default:
                failReminder("Your reminder time didn't load. Try again in a moment.")
            }
        } catch {
            // A cancelled task is lifecycle, not an outage (review M9).
            guard !isTaskCancellation(error) else { return }
            failReminder("Couldn't reach your home server.")
        }
    }

    /// A failed refresh never replaces a value we already have (D08).
    private func failReminder(_ message: String) {
        if case .loaded = reminder { return }
        reminder = .failed(message)
    }

    /// The picker fires on every wheel tick, so let the choice settle before
    /// spending a request on it. A newer pick cancels the older save outright —
    /// including one already in flight, so the last pick is the one that lands.
    private func scheduleSave(_ value: String) {
        guard case .loaded = reminder, value != saved else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await save(value)
        }
    }

    private func save(_ value: String) async {
        guard ChoreReminderLogic.isValid(value) else { return }
        reminderError = nil
        do {
            let outcome = try await FormPatch.send(
                MemberReminderPatch(choreReminderTime: value),
                path: "api/v1/members/\(context.session.memberID)",
                context: context
            )
            switch outcome {
            case .ok:
                saved = value
            case .unauthorized:
                appState.handleUnauthorized()
            case .rejected(let code):
                reminderError = ChoreReminderLogic.friendlyError(code)
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            reminderError = "Couldn't reach your home server."
        }
    }
}

// MARK: - My account (mine to edit; parents edit kids from Members)

/// Name + color, PATCH self. Photo editing and calendar accounts land in a
/// later iteration (mock: the account screen is built with room for them).
@MainActor
struct MyAccountView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState

    @State private var name = ""
    @State private var color = Color.blue
    @State private var loadedHex = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                ColorPicker("Color", selection: $color, supportsOpacity: false)
            } footer: {
                Text("These are yours to edit — parents edit kids' accounts from Members.")
            }
        }
        .navigationTitle("My account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .task { await load() }
        .alert(errorMessage ?? "", isPresented: .init(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} }
    }

    private func load() async {
        guard case .ok(let ok)? = try? await context.client.api.getMember(
            .init(path: .init(id: context.session.memberID))
        ), let member = try? ok.body.json else { return }
        name = member.name
        loadedHex = member.color
        color = Color(hex: member.color)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let body = Components.Schemas.MemberUpdate(
                name: name.trimmingCharacters(in: .whitespaces),
                color: color.hexString ?? loadedHex
            )
            switch try await context.client.api.updateMember(
                .init(path: .init(id: context.session.memberID), body: .json(body))
            ) {
            case .ok: break
            case .unauthorized: appState.handleUnauthorized()
            default: errorMessage = "That didn't save. Try again?"
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }
}

// MARK: - Members (parents): list, edit, add, reset password

@MainActor
struct MembersAdminView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @State private var members: [Components.Schemas.Member] = []
    @State private var adding = false

    var body: some View {
        List {
            ForEach(members, id: \.id) { member in
                NavigationLink {
                    MemberEditView(context: context, member: member)
                } label: {
                    HStack(spacing: 10) {
                        MemberAvatarView(
                            name: member.name, colorHex: member.color,
                            avatar: member.avatar, size: 32
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.name)
                            Text(member.role == .kid ? "Kid" : "Parent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button { adding = true } label: { GhostLabel(title: "Add member") }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding) {
            NavigationStack { AddMemberView(context: context) { Task { await load() } } }
        }
    }

    private func load() async {
        guard case .ok(let ok)? = try? await context.client.api.listMembers(.init()),
              let list = try? ok.body.json.members else { return }
        members = list
    }
}

/// Edit a member (parents): name, color, role — and the red reset row that
/// arms the M5c claim flow.
@MainActor
struct MemberEditView: View {
    let context: SignedInContext
    let member: Components.Schemas.Member
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var color = Color.blue
    @State private var role: Components.Schemas.Role = .kid
    @State private var saving = false
    @State private var confirmingReset = false
    @State private var resetArmed = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                ColorPicker("Color", selection: $color, supportsOpacity: false)
                Picker("Role", selection: $role) {
                    Text("Mom").tag(Components.Schemas.Role.mom)
                    Text("Dad").tag(Components.Schemas.Role.dad)
                    Text("Kid").tag(Components.Schemas.Role.kid)
                }
            }
            Section {
                Button(role: .destructive) { confirmingReset = true } label: {
                    Text(resetArmed ? "Password reset armed" : "Reset password…")
                }
                .disabled(resetArmed)
            } footer: {
                Text("Reset arms the claim flow: the old password stops working now, and \(member.name) sets a new one at the next sign-in on the home network.")
            }
        }
        .navigationTitle(member.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .onAppear {
            name = member.name
            color = Color(hex: member.color)
            role = member.role
        }
        // Centered alert naming the consequence (owner rules).
        .alert("Reset \(member.name)'s password?", isPresented: $confirmingReset) {
            Button("Reset password", role: .destructive) { Task { await reset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The old password stops working now.")
        }
        .alert(errorMessage ?? "", isPresented: .init(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let body = Components.Schemas.MemberUpdate(
                name: name.trimmingCharacters(in: .whitespaces),
                color: color.hexString ?? member.color,
                role: role
            )
            switch try await context.client.api.updateMember(
                .init(path: .init(id: member.id), body: .json(body))
            ) {
            case .ok: dismiss()
            case .unauthorized: appState.handleUnauthorized()
            default: errorMessage = "That didn't save. Try again?"
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }

    private func reset() async {
        do {
            switch try await context.client.api.armMemberPasswordReset(
                .init(path: .init(id: member.id))
            ) {
            case .noContent: resetArmed = true
            case .unauthorized: appState.handleUnauthorized()
            default: errorMessage = "That didn't work. Try again?"
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }
}

@MainActor
struct AddMemberView: View {
    let context: SignedInContext
    let onAdded: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var color = Color.orange
    @State private var role: Components.Schemas.Role = .kid
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            TextField("Name", text: $name)
            ColorPicker("Color", selection: $color, supportsOpacity: false)
            Picker("Role", selection: $role) {
                Text("Mom").tag(Components.Schemas.Role.mom)
                Text("Dad").tag(Components.Schemas.Role.dad)
                Text("Kid").tag(Components.Schemas.Role.kid)
            }
        }
        .navigationTitle("Add member")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .alert(errorMessage ?? "", isPresented: .init(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let body = Components.Schemas.MemberCreate(
                name: name.trimmingCharacters(in: .whitespaces),
                color: color.hexString ?? "#0a84ff",
                role: role
            )
            switch try await context.client.api.createMember(.init(body: .json(body))) {
            case .created: onAdded(); dismiss()
            case .unauthorized: appState.handleUnauthorized()
            default: errorMessage = "That didn't save. Try again?"
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }
}

// MARK: - Modules (household-wide switchboard, parents only)

/// The Apps-page decision with its screen: off here = the tile and its
/// pages disappear on iOS, the kiosk, and the web at once. Calendar is the
/// spine — always on in v1. Future modules wait dashed and off.
@MainActor
struct ModulesView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock

    @State private var chores = true
    @State private var routines = true
    @State private var rewards = true
    @State private var loaded = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Calendar") {
                    Text("the spine — always on").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Chores", isOn: binding($chores, key: "chores"))
                Toggle("Routines", isOn: binding($routines, key: "routines"))
                Toggle("Rewards", isOn: binding($rewards, key: "rewards"))
            } header: {
                Text("On for this household").font(.caption.weight(.semibold))
            }
            Section {
                ForEach(FutureModule.allCases) { future in
                    LabeledContent(future.title) {
                        Text("future").font(.caption).foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Waiting for their day").font(.caption.weight(.semibold))
            } footer: {
                Text("Household-wide: off here means the tile and its pages disappear on iOS, the kiosk, and the web at once.")
            }
        }
        .navigationTitle("Modules")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            chores = clock.modules.chores
            routines = clock.modules.routines
            rewards = clock.modules.rewards
        }
        .alert(errorMessage ?? "", isPresented: .init(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} }
    }

    private func binding(_ source: Binding<Bool>, key: String) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue },
            set: { value in
                let previous = source.wrappedValue
                source.wrappedValue = value
                Task {
                    if await !patch() {
                        source.wrappedValue = previous
                    }
                }
            }
        )
    }

    /// Whole-object write of the switchboard; SSE settles every client.
    private func patch() async -> Bool {
        do {
            let body = Components.Schemas.HouseholdUpdate(
                modules: .init(chores: chores, routines: routines, rewards: rewards)
            )
            switch try await context.client.api.updateHousehold(.init(body: .json(body))) {
            case .ok: return true
            case .unauthorized: appState.handleUnauthorized(); return false
            default:
                errorMessage = "That didn't save. Try again?"
                return false
            }
        } catch {
            guard !isTaskCancellation(error) else { return false }
            errorMessage = "Couldn't reach your home server."
            return false
        }
    }
}

// MARK: - Server (the quiet row that makes it self-hosted)

@MainActor
struct ServerView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState

    @State private var reachable: Bool?
    @State private var confirmingSwitch = false

    var body: some View {
        List {
            Section {
                LabeledContent("Address", value: context.session.serverURL.absoluteString)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(reachable == true ? Color.green : reachable == false ? .red : .secondary)
                            .frame(width: 8, height: 8)
                        Text(reachable == true ? "connected" : reachable == false ? "unreachable" : "checking…")
                    }
                }
                Button(role: .destructive) { confirmingSwitch = true } label: {
                    Text("Switch server…")
                }
            } footer: {
                Text("Sessions belong to a server — switching starts a fresh sign-in against the new one.")
            }
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .task { await check() }
        .refreshable { await check() }
        .alert("Switch server?", isPresented: $confirmingSwitch) {
            Button("Switch — signs you out", role: .destructive) { appState.signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions belong to a server; you'll sign in against the new address.")
        }
    }

    private func check() async {
        var url = context.session.serverURL
        url.append(path: "healthz")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let ok = (try? await URLSession.shared.data(for: request))
            .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode } == 200
        reachable = ok
    }
}
