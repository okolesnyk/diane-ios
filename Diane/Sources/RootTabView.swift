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
    /// One member filter for the whole app (owner 2026-08-06).
    @State private var filter = MemberFilterStore()
    /// Which tab is showing. DEBUG builds accept `-uiTab <0…3>` at launch so
    /// screenshots can reach any page without a human tapping (simctl can
    /// capture the screen but cannot tap).
    @State private var tab = RootTabView.launchTab
    /// The fourth tab's own stack — module pages push chore/event details
    /// onto it (nav rule 2: details open from anywhere).
    @State private var modulePath = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    /// DEBUG screenshot hook; always 0 in release.
    static var launchTab: Int {
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiTab"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let value = Int(ProcessInfo.processInfo.arguments[index + 1]),
           (0...3).contains(value) {
            return value
        }
        #endif
        return 0
    }

    init(context: SignedInContext) {
        self.context = context
        _fourthTab = State(initialValue: FourthTabStore(memberID: context.session.memberID))
    }

    var body: some View {
        let effective = NavigationLogic.effectiveFourthTab(
            pinned: fourthTab.pinned,
            modules: clock.modules
        )
        TabView(selection: $tab) {
            MyDayView(context: context)
                .tabItem { Label("My Day", systemImage: "sun.max") }
                .tag(0)
            FamilyDayView(context: context)
                .tabItem { Label("Family Day", systemImage: "person.3") }
                .tag(1)
            AppsView(context: context)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
                .tag(2)
            NavigationStack(path: $modulePath) {
                ModuleScreen(
                    module: effective,
                    context: context,
                    isRoot: true,
                    open: { modulePath.append($0) }
                )
            }
                .tabItem { Label(effective.title, systemImage: effective.systemImage) }
                // A different module is a different tab identity — rebuild,
                // don't morph, so per-screen state never leaks across.
                .id(effective)
                .tag(3)
        }
        .environment(signals)
        .environment(clock)
        .environment(fourthTab)
        .environment(filter)
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
    /// Root = a tab's own screen (title left, avatar right); pushed from
    /// Apps it wears ‹ Back and a centered title instead (nav rule 1).
    var isRoot = false
    /// Push a chore/event detail onto whichever stack owns this screen.
    var open: (DetailRoute) -> Void = { _ in }

    @ViewBuilder
    var body: some View {
        if isRoot && module != .calendar {
            // Calendar carries its own bar; the others get the root chrome.
            VStack(spacing: 0) {
                DianeTopBar(
                    context: context,
                    title: module.title,
                    trailing: barAccessory.map { AnyView($0) }
                )
                content
            }
            .dianeRootChrome()
        } else {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let barAccessory {
                        ToolbarItem(placement: .topBarTrailing) { barAccessory }
                    }
                }
        }
    }

    /// The one module with a destination of its own in the bar (owner
    /// 2026-08-06: History goes up top, as the mock drew it).
    private var barAccessory: AnyView? {
        guard module == .chores else { return nil }
        return AnyView(
            NavigationLink {
                ChoreHistoryView(context: context)
            } label: {
                Image(systemName: "clock").font(.title3)
            }
            .accessibilityLabel("History")
        )
    }

    @ViewBuilder
    private var content: some View {
        switch module {
        case .calendar: CalendarPageView(context: context)
        case .chores: ChoresPageView(context: context, open: open)
        case .routines: RoutinesView(context: context)
        case .rewards: RewardsView(context: context)
        }
    }
}
