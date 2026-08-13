import DianeKit
import SwiftUI

/// The M9e shell, fully rearrangeable (owner 2026-08-10, "the Apple way"):
/// the bottom bar renders the member's ordered layout — Today and Home
/// always present but movable, plus up to three module tabs (default just
/// Calendar). My Day is gone ("almost everything is on Family Day"); Family
/// Day wears the Today name. The layout is device-local per member (owner
/// rule 2026-08-05); a module switched off household-wide sits out at
/// render time — no server sweep, its slot revives on return.
struct RootTabView: View {
    let context: SignedInContext
    @Environment(AppState.self) private var appState
    @State private var signals = SyncSignals()
    @State private var clock = HouseholdClock()
    /// ONE client for the view's life — each SSEClient owns a URLSession,
    /// and sessions are never fully released (review M9).
    @State private var sse = SSEClient()
    @State private var layout: TabLayoutStore
    /// One member filter for the whole app (owner 2026-08-06), persisted
    /// on-device per member (owner 2026-08-10).
    @State private var filter: MemberFilterStore
    /// Which tab is showing — the ITEM, not its index: reordering the bar
    /// must never teleport the selection. DEBUG builds accept `-uiTab
    /// <0…4>` at launch so screenshots can reach any page without a human
    /// tapping (simctl can capture the screen but cannot tap).
    @State private var tab: TabItem = .today
    @State private var appliedLaunchTab = false
    /// One stack per module — module pages push chore/event details onto
    /// theirs (nav rule 2: details open from anywhere). Keyed by module so
    /// reordering the bar never mixes stacks up.
    @State private var modulePaths: [DianeModule: NavigationPath] = [:]
    /// Home's stack, held here so re-tapping the Home tab pops to the grid.
    @State private var homePath = NavigationPath()
    @Environment(\.scenePhase) private var scenePhase

    /// DEBUG screenshot hook; always 0 in release.
    static var launchTab: Int {
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiTab"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let value = Int(ProcessInfo.processInfo.arguments[index + 1]),
           (0...4).contains(value) {
            return value
        }
        #endif
        return 0
    }

    init(context: SignedInContext) {
        self.context = context
        _layout = State(initialValue: TabLayoutStore(memberID: context.session.memberID))
        _filter = State(initialValue: MemberFilterStore(memberID: context.session.memberID))
    }

    /// Re-tapping the active tab pops its stack — that's how you leave a
    /// module opened from Home, since module pages never wear a back button
    /// (owner 2026-08-08).
    private var tabSelection: Binding<TabItem> {
        Binding(
            get: { tab },
            set: { newValue in
                if newValue == tab {
                    switch newValue {
                    case .today: break
                    case .home: homePath = NavigationPath()
                    case .module(let module): modulePaths[module] = NavigationPath()
                    }
                }
                tab = newValue
            }
        )
    }

    private func modulePath(_ module: DianeModule) -> Binding<NavigationPath> {
        Binding(
            get: { modulePaths[module] ?? NavigationPath() },
            set: { modulePaths[module] = $0 }
        )
    }

    var body: some View {
        let bar = NavigationLogic.effectiveBar(items: layout.barItems, modules: clock.modules)
        TabView(selection: tabSelection) {
            ForEach(bar) { item in
                tabContent(item, bar: bar)
                    .tabItem { Label(item.title, systemImage: item.systemImage) }
                    // A different occupant is a different tab identity —
                    // rebuild, don't morph, so per-screen state never
                    // leaks across.
                    .id(item)
                    .tag(item)
            }
        }
        // A slot vanishing (module switched off or removed) must not
        // strand the selection on a tag that no longer exists.
        .onChange(of: bar) { _, next in
            if !next.contains(tab) { tab = .today }
        }
        .onAppear {
            guard !appliedLaunchTab else { return }
            appliedLaunchTab = true
            let index = Self.launchTab
            if bar.indices.contains(index) { tab = bar[index] }
        }
        .environment(signals)
        .environment(clock)
        .environment(layout)
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

    @ViewBuilder
    private func tabContent(_ item: TabItem, bar: [TabItem]) -> some View {
        switch item {
        case .today:
            TodayView(context: context)
        case .home:
            HomeView(
                context: context,
                path: $homePath,
                barModules: bar.compactMap(\.module),
                // The bottom menu never gets a twin: a bar module's tile
                // selects its tab (owner 2026-08-08).
                selectBarTab: { module in tab = .module(module) }
            )
        case .module(let module):
            NavigationStack(path: modulePath(module)) {
                ModuleScreen(
                    module: module,
                    context: context,
                    open: { modulePaths[module, default: NavigationPath()].append($0) }
                )
            }
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

    /// Modules with a destination of their own in the bar (owner 2026-08-06:
    /// History goes up top; 2026-08-08: circled, so it reads as a button
    /// beside the avatar). Routines' clock opens the past 7 days — the same
    /// idiom, but checkable, because there the past can still be fixed
    /// (mock page 6).
    private var barAccessory: AnyView? {
        switch module {
        case .chores:
            AnyView(barLink("History", systemImage: "clock") { ChoreHistoryView(context: context) })
        case .routines:
            AnyView(HStack(spacing: 8) {
                if context.session.isAdmin {
                    barLink("All routines", systemImage: "list.bullet") {
                        ManageRoutinesView(context: context)
                    }
                }
                barLink("Past 7 days", systemImage: "clock") {
                    RoutinesPastView(context: context)
                }
            })
        default:
            nil
        }
    }

    private func barLink(
        _ label: String,
        systemImage: String,
        @ViewBuilder destination: @escaping () -> some View
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var content: some View {
        switch module {
        case .calendar: CalendarPageView(context: context, open: open)
        case .chores: ChoresPageView(context: context, open: open)
        case .routines: RoutinesView(context: context)
        case .rewards: RewardsView(context: context)
        case .lists: ListsView(context: context)
        }
    }
}
