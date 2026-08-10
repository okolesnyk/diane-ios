import DianeKit
import SwiftUI

/// The M9e shell: Today · Home · one customizable slot. My Day is gone
/// (owner 2026-08-10 — "almost everything is on Family Day"), and Family
/// Day wears the Today name. The third tab is a device-local per-member pin
/// (owner rule 2026-08-05); when its module is switched off household-wide
/// it falls back to Calendar at render time — no server sweep, the pin
/// survives for the module's return.
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
    /// Which tab is showing. DEBUG builds accept `-uiTab <0…2>` at launch so
    /// screenshots can reach any page without a human tapping (simctl can
    /// capture the screen but cannot tap).
    @State private var tab = RootTabView.launchTab
    /// The fourth tab's own stack — module pages push chore/event details
    /// onto it (nav rule 2: details open from anywhere).
    @State private var modulePath = NavigationPath()
    /// Home's stack, held here so re-tapping the Home tab pops to the grid.
    @State private var homePath = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    /// DEBUG screenshot hook; always 0 in release.
    static var launchTab: Int {
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiTab"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let value = Int(ProcessInfo.processInfo.arguments[index + 1]),
           (0...2).contains(value) {
            return value
        }
        #endif
        return 0
    }

    init(context: SignedInContext) {
        self.context = context
        _fourthTab = State(initialValue: FourthTabStore(memberID: context.session.memberID))
    }

    /// Re-tapping the active tab pops its stack — that's how you leave a
    /// module opened from Home, since module pages never wear a back button
    /// (owner 2026-08-08).
    private var tabSelection: Binding<Int> {
        Binding(
            get: { tab },
            set: { newValue in
                if newValue == tab {
                    if newValue == 1 { homePath = NavigationPath() }
                    if newValue == 2 { modulePath = NavigationPath() }
                }
                tab = newValue
            }
        )
    }

    var body: some View {
        let effective = NavigationLogic.effectiveFourthTab(
            pinned: fourthTab.pinned,
            modules: clock.modules
        )
        TabView(selection: tabSelection) {
            FamilyDayView(context: context)
                .tabItem { Label("Today", systemImage: "sun.max") }
                .tag(0)
            HomeView(
                context: context,
                path: $homePath,
                pinnedTab: effective,
                // The bottom menu never gets a twin: the pinned module's
                // tile selects its tab (owner 2026-08-08).
                selectPinnedTab: { tab = 2 }
            )
            .tabItem { Label("Home", systemImage: "house") }
            .tag(1)
            NavigationStack(path: $modulePath) {
                ModuleScreen(
                    module: effective,
                    context: context,
                    open: { modulePath.append($0) }
                )
            }
                .tabItem { Label(effective.title, systemImage: effective.systemImage) }
                // A different module is a different tab identity — rebuild,
                // don't morph, so per-screen state never leaks across.
                .id(effective)
                .tag(2)
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
        #if DEBUG
        // Diagnostic dump for screenshot sessions (simctl cannot tap).
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-dumpBoard") else { return }
            print("DUMP-ME \(context.session.memberID)")
            if case .ok(let ok)? = try? await context.client.api.getRoutineBoard(.init()),
               let body = try? ok.body.json {
                print("DUMP-BOARD date=\(body.date) entries=\(body.entries.map { "\($0.title)|member=\($0.memberId)" })")
            }
            if case .ok(let ok)? = try? await context.client.api.listRoutines(.init()),
               let body = try? ok.body.json {
                print("DUMP-ROUTINES \(body.routines.map { "\($0.title)|byWeekday=\($0.byWeekday?.map(\.rawValue) ?? [])|assignees=\($0.assigneeIds)|tasks=\($0.tasks.count)" })")
            }
        }
        #endif
        // A tz or module flip on any client reframes every screen.
        .task(id: signals.version(of: [.settings])) {
            await clock.refreshTimeZone(client: context.client)
        }
    }

}

/// One module screen for BOTH doors: a module always wears the root chrome
/// — title left, avatar right, never a back button — whether it sits in the
/// bottom menu or was opened from Home (owner 2026-08-08: "all Apps I open
/// should behave like they are opened from the bottom menu"). Callers
/// provide the NavigationStack; leaving a Home-opened module is the bottom
/// menu itself.
struct ModuleScreen: View {
    let module: DianeModule
    let context: SignedInContext
    /// Push a chore/event detail onto whichever stack owns this screen.
    var open: (DetailRoute) -> Void = { _ in }

    @ViewBuilder
    var body: some View {
        if module == .calendar {
            // Calendar carries its own bar (the month title IS a control).
            content
        } else {
            VStack(spacing: 0) {
                DianeTopBar(
                    context: context,
                    title: module.title,
                    trailing: barAccessory.map { AnyView($0) }
                )
                content
            }
            .dianeRootChrome()
        }
    }

    /// The one module with a destination of its own in the bar (owner
    /// 2026-08-06: History goes up top; 2026-08-08: circled, so it reads
    /// as a button beside the avatar).
    private var barAccessory: AnyView? {
        guard module == .chores else { return nil }
        return AnyView(
            NavigationLink {
                ChoreHistoryView(context: context)
            } label: {
                Image(systemName: "clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("History")
        )
    }

    @ViewBuilder
    private var content: some View {
        switch module {
        case .calendar: CalendarPageView(context: context, open: open)
        case .chores: ChoresPageView(context: context, open: open)
        case .routines: RoutinesView(context: context)
        case .rewards: RewardsView(context: context)
        }
    }
}
