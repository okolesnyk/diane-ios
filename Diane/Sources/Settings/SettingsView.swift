import DianeKit
import SwiftUI

struct SettingsView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

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
                }

                Section("Server") {
                    LabeledContent("Home server", value: context.session.serverURL.absoluteString)
                }

                Section("Notifications") {
                    LabeledContent("Chore reminders", value: pushStatusLabel)
                }

                Section {
                    // Instant: local teardown is synchronous, the network
                    // goodbyes run in the background (review M9).
                    Button(role: .destructive) {
                        dismiss()
                        appState.signOut()
                    } label: {
                        Text("Sign out").frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
}
