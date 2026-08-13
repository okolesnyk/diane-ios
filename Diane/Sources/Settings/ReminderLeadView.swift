import DianeKit
import SwiftUI

/// The household default reminder lead (notifications v1): how many minutes
/// before a timed event or timed chore the first ping rings. Household-wide
/// — one family rhythm — with per-event overrides on the event itself.
/// Picking IS the save.
@MainActor
struct ReminderLeadView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState

    @State private var minutes = 15
    @State private var loaded = false
    @State private var errorMessage: String?

    private let choices = [0, 5, 10, 15, 30, 60]

    var body: some View {
        List {
            Section {
                Picker("Lead", selection: $minutes) {
                    ForEach(choices, id: \.self) { value in
                        Text(value == 0 ? "At the start" : "\(value) min before").tag(value)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .onChange(of: minutes) { previous, next in
                    guard loaded, previous != next else { return }
                    Task { await save(next) }
                }
            } footer: {
                Text("Timed events and timed chores ring this early, then again at their moment. An event can override this for itself.")
            }
        }
        .navigationTitle("Reminder lead")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(errorMessage ?? "", isPresented: .init(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) {} }
    }

    private func load() async {
        guard case .ok(let ok)? = try? await context.client.api.getHousehold(.init()),
              let household = try? ok.body.json else { return }
        minutes = household.reminderLeadMinutes
        loaded = true
    }

    private func save(_ value: Int) async {
        do {
            let body = Components.Schemas.HouseholdUpdate(reminderLeadMinutes: value)
            switch try await context.client.api.updateHousehold(.init(body: .json(body))) {
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
