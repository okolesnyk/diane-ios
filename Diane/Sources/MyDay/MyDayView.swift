import DianeKit
import SwiftUI

/// Page 1 scaffold — the real My Day (Catch up · Timeline · No set time ·
/// routine card, with the 7-day strip) lands in M9e-3. The scaffold already
/// speaks the top-bar rule: date on the left, avatar → Settings push right.
struct MyDayView: View {
    let context: SignedInContext
    @Environment(HouseholdClock.self) private var clock

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("My Day", systemImage: "sun.max")
            } description: {
                Text("Catch up, your timeline, and your routine arrive in the next slice.")
            }
            .navigationTitle(NavigationLogic.myDayTitle(for: clock.today))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SettingsAvatarButton(context: context) }
        }
    }

}
