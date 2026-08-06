import DianeKit
import SwiftUI

/// Page 2 scaffold — the real Family Day (member chips with rings, the
/// river, the pool) lands in M9e-4. Top-bar rule already in force.
struct FamilyDayView: View {
    let context: SignedInContext

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Family Day", systemImage: "person.3")
            } description: {
                Text("The family river, chips, and the pool arrive in a coming slice.")
            }
            .navigationTitle("Family Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SettingsAvatarButton(context: context) }
        }
    }
}
