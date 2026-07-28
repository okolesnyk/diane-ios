import DianeKit
import SwiftUI

struct RootTabView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @State private var signals = SyncSignals()
    @State private var clock = HouseholdClock()
    /// ONE client for the view's life — each SSEClient owns a URLSession,
    /// and sessions are never fully released (review M9).
    @State private var sse = SSEClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            TodayView(context: context)
                .tabItem { Label("Today", systemImage: "sun.max") }
            CalendarWeekView(context: context)
                .tabItem { Label("Calendar", systemImage: "calendar") }
            ChoresView(context: context)
                .tabItem { Label("Chores", systemImage: "checkmark.circle") }
            RoutinesView(context: context)
                .tabItem { Label("Routines", systemImage: "repeat") }
            RewardsView(context: context)
                .tabItem { Label("Rewards", systemImage: "star") }
        }
        .environment(signals)
        .environment(clock)
        // The stream tears down only on real backgrounding — transient
        // .inactive (control center, permission alerts, app switcher peek)
        // must not flap the connection and force full refetches (review M9).
        .task(id: scenePhase == .background) {
            guard scenePhase != .background else { return }
            appState.pushRegistrar.retryIfNeeded()
            let token = context.session.token
            for await signal in sse.signals(
                url: context.client.streamURL,
                token: { token }
            ) {
                if case .unauthorized = signal {
                    // Revoked session: surface the sign-out instead of
                    // retrying a dead token forever (review M9).
                    appState.handleUnauthorized()
                    return
                }
                signals.apply(signal)
            }
        }
        // The household's wall clock drives every "today"/window decision.
        .task { await clock.run(client: context.client) }
        // A tz edit on the kiosk reframes every screen.
        .task(id: signals.version(of: [.settings])) {
            await clock.refreshTimeZone(client: context.client)
        }
    }
}
