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
        .onChange(of: draft) { _, value in scheduleSave(value) }
    }

    /// One row: my own default reminder time. No save button — picking IS the
    /// save.
    private var choresSection: some View {
        Section {
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
                    "Default reminder time",
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
        } header: {
            header("Chores")
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
