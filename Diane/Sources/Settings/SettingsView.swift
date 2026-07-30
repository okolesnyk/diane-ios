import DianeKit
import SwiftUI

// MARK: - Reminder-time logic (pure, tested in SupportTests)

/// A member's OWN default chore-reminder time: the wire's "HH:mm", or nil for
/// off. Per member, never per household — one shared chore rings each assignee
/// at their own time.
///
/// The server validates `^([01]\d|2[0-3]):[0-5]\d$`, so mirror it here and let
/// nothing malformed leave the phone. Deliberately stricter than the ICU
/// reading of that pattern: only ASCII digits count, because zod's `\d` on the
/// server is ASCII-only.
enum ChoreReminderLogic {
    /// What the picker offers first when the reminder is off.
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

    /// The row's value — the app shows raw "HH:mm" everywhere else.
    static func label(_ stored: String?) -> String {
        guard let stored, isValid(stored) else { return "Off" }
        return stored
    }

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

/// PATCH /members/:id carrying only this one key. The generated client omits
/// nil optionals and the route reads an absent key as "keep", so turning the
/// reminder OFF needs a literal null on the wire — the same reason the forms
/// hand-encode their bodies (see FormPatch).
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
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock
    @Environment(\.dismiss) private var dismiss

    /// The stored value; `.loaded(nil)` is a real answer — off.
    @State private var reminder: Loadable<String?> = .loading
    @State private var draft = ChoreReminderLogic.fallback
    @State private var saving = false
    @State private var reminderError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
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
                            Text(context.session.isAdmin ? "Parent" : "Member")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(settingsRowInsets)
                }

                choresSection

                Section {
                    LabeledContent("Home server", value: context.session.serverURL.absoluteString)
                        .listRowInsets(settingsRowInsets)
                } header: {
                    header("Server")
                }

                Section {
                    LabeledContent("Chore reminders", value: pushStatusLabel)
                        .listRowInsets(settingsRowInsets)
                } header: {
                    header("Notifications")
                }

                Section {
                    // Instant: local teardown is synchronous, the network
                    // goodbyes run in the background (review M9).
                    Button(role: .destructive) {
                        dismiss()
                        appState.signOut()
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadReminder() }
    }

    /// My own default reminder time — the only preference this screen edits.
    private var choresSection: some View {
        Section {
            switch reminder {
            case .loading:
                LabeledContent("My reminder time") { ProgressView() }
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
            case .loaded(let stored):
                reminderRows(stored)
            }
        } header: {
            header("Chores")
        } footer: {
            Text(
                """
                This is yours alone — everyone in the family sets their own. \
                Chores that have a date but no time of their own remind you at \
                this time, in your household's time zone. Off means they don't \
                remind you at all.
                """
            )
            .listRowInsets(settingsHeaderInsets)
        }
    }

    @ViewBuilder
    private func reminderRows(_ stored: String?) -> some View {
        LabeledContent("My reminder time", value: ChoreReminderLogic.label(stored))
            .listRowInsets(settingsRowInsets)

        // The picker runs on the HOUSEHOLD clock — the time the server fires at
        // is household-local, so a travelling phone must not shift it.
        DatePicker(
            "Remind me at",
            selection: FormDates.timeBinding($draft, timeZone: clock.timeZone),
            displayedComponents: .hourAndMinute
        )
        .environment(\.timeZone, clock.timeZone)
        .disabled(saving)
        .listRowInsets(settingsRowInsets)

        Button {
            Task { await save(draft) }
        } label: {
            HStack {
                Text(stored == nil ? "Turn reminders on" : "Save reminder time")
                Spacer()
                if saving { ProgressView() }
            }
            .frame(minHeight: 28)
        }
        .disabled(saving || draft == stored)
        .listRowInsets(settingsRowInsets)

        if stored != nil {
            Button("Turn reminders off") { Task { await save(nil) } }
                .disabled(saving)
                .frame(minHeight: 28)
                .listRowInsets(settingsRowInsets)
        }

        if let reminderError {
            Text(reminderError)
                .font(.subheadline)
                .foregroundStyle(.red)
                .listRowInsets(settingsRowInsets)
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
                reminder = .loaded(stored)
                draft = ChoreReminderLogic.draft(stored)
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

    private func save(_ value: String?) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        reminderError = nil
        do {
            let outcome = try await FormPatch.send(
                MemberReminderPatch(choreReminderTime: value),
                path: "api/v1/members/\(context.session.memberID)",
                context: context
            )
            switch outcome {
            case .ok:
                // The server accepted it; refetch so the row shows what it
                // actually stored, not what we hoped.
                reminder = .loaded(value)
                await loadReminder()
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
