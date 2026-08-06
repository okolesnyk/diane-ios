import DianeKit
import SwiftUI

/// The M9e shell: My Day · Family Day · Apps · one customizable slot.
/// The fourth tab is a device-local per-member pin (owner rule 2026-08-05);
/// when its module is switched off household-wide it falls back to Calendar
/// at render time — no server sweep, the pin survives for the module's return.
struct RootTabView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @State private var signals = SyncSignals()
    @State private var clock = HouseholdClock()
    /// ONE client for the view's life — each SSEClient owns a URLSession,
    /// and sessions are never fully released (review M9).
    @State private var sse = SSEClient()
    @State private var fourthTab: FourthTabStore
    @Environment(\.scenePhase) private var scenePhase

    init(context: SignedInContext) {
        self.context = context
        _fourthTab = State(initialValue: FourthTabStore(memberID: context.session.memberID))
    }

    var body: some View {
        let effective = NavigationLogic.effectiveFourthTab(
            pinned: fourthTab.pinned,
            modules: clock.modules
        )
        TabView {
            MyDayView(context: context)
                .tabItem { Label("My Day", systemImage: "sun.max") }
            FamilyDayView(context: context)
                .tabItem { Label("Family Day", systemImage: "person.3") }
            AppsView(context: context)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
            NavigationStack { ModuleScreen(module: effective, context: context) }
                .tabItem { Label(effective.title, systemImage: effective.systemImage) }
                // A different module is a different tab identity — rebuild,
                // don't morph, so per-screen state never leaks across.
                .id(effective)
        }
        .environment(signals)
        .environment(clock)
        .environment(fourthTab)
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
        // A tz or module flip on any client reframes every screen.
        .task(id: signals.version(of: [.settings])) {
            await clock.refreshTimeZone(client: context.client)
        }
    }

}

/// The interim module screens — each is rebuilt to its design page in
/// M9e-5..7; until then the M9c screens serve. Callers provide the
/// NavigationStack (the fourth tab wraps one; Apps pushes inside its own).
struct ModuleScreen: View {
    let module: DianeModule
    let context: SignedInContext

    var body: some View {
        switch module {
        case .calendar: CalendarWeekView(context: context)
        case .chores: ChoresView(context: context)
        case .routines: RoutinesView(context: context)
        case .rewards: RewardsView(context: context)
        }
    }
}
