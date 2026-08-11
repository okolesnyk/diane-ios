import DianeKit
import SwiftUI
import UniformTypeIdentifiers

/// The tile-grid launcher — renamed Home (owner 2026-08-08): every module
/// the household has ON, plus grayed tiles for what the future lands here.
/// Off modules disappear entirely — the switchboard is "what the family
/// sees, on every client".
///
/// Rearranging is "the Apple way" (owner 2026-08-10): long-press → ONE
/// menu item, "Edit position", entering a jiggle mode. DRAG only ever
/// reorders — tiles within the grid, items within the bottom bar (the
/// system bar hides and a jiggling twin stands exactly where it was; no
/// duplicate strip). Bar membership is the +/- badge on each tile (the
/// dock-style drag-in/out was tried and felt awkward — owner verdict).
/// Today and Home reorder but never leave. Done temporarily sits where
/// the member avatar was. All device-local, per member.
///
/// Opening a tile NEVER shows a back button (owner 2026-08-08): a module
/// page always wears the root chrome — title left, avatar right — exactly
/// as if it sat in the bottom menu. The tile of a module that IS in the
/// bottom menu selects that tab instead of pushing a twin; re-tapping Home
/// in the bottom menu returns pushed modules to this grid.
///
/// The pulse (owner 2026-08-10, rev 5): each live tile carries ONE count
/// line — just numbers — plus a red corner dot when Chores holds something
/// late. Counts are FAMILY-WIDE, untouched by the member filter (owner
/// verdict 2026-08-10); a tile with nothing to count is a quiet door, and
/// a failed fetch keeps the last pulse — a launcher never wears error
/// chrome.
struct HomeView: View {
    let context: SignedInContext
    /// Owned by RootTabView so re-tapping the Home tab can pop to the grid.
    @Binding var path: NavigationPath
    /// Modules currently in the bottom bar — their tiles switch tabs.
    let barModules: [DianeModule]
    let selectBarTab: (DianeModule) -> Void

    @Environment(HouseholdClock.self) private var clock
    @Environment(TabLayoutStore.self) private var layout
    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var editing = false
    @State private var snapshot = HomeLogic.Snapshot()
    /// The grid's system drag (hold-to-lift; it shares space with the
    /// scroll gesture). The bar uses its own INSTANT gesture below.
    @State private var dragging: TabItem?
    /// The bar's instant drag: grabbed item, finger travel, and how much
    /// of that travel is already banked as committed reorders.
    @State private var barDragItem: TabItem?
    @State private var barDragOffset: CGFloat = 0
    @State private var barDragShift: CGFloat = 0

    /// One column at accessibility type sizes (the review's Dynamic Type
    /// rule — tiles grow, the grid gives way, like Apple's Home app).
    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 150), spacing: 14)]
    }

    /// Refetch on any server change or day roll; minute changes only
    /// RECOMPUTE lines from the cached snapshot (no new timers).
    private var pulseKey: String {
        "\(signals.version(of: Set(DianeTopic.allCases)))|\(clock.today)"
    }

    var body: some View {
        let enabled = NavigationLogic.enabledModules(clock.modules)
        let tiles = layout.orderedTiles(enabled: enabled)
        let pulse = HomeLogic.pulse(
            snapshot,
            today: clock.today,
            minute: clock.minute,
            timeZone: clock.timeZone
        )
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                DianeTopBar(
                    context: context,
                    title: "Home",
                    avatarReplacement: editing ? AnyView(doneButton) : nil
                )
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(tiles) { module in
                            if editing {
                                editingTile(module, enabled: enabled, pulse: pulse)
                            } else {
                                launchTile(module, pulse: pulse)
                            }
                        }
                        ForEach(FutureModule.allCases) { future in
                            tile(title: future.title, systemImage: future.systemImage, comingLater: true)
                        }
                    }
                    .padding(16)
                }
                if editing { editableBar }
            }
            .dianeRootChrome()
            // The REAL bar steps aside while its jiggling twin stands in
            // its place (owner 2026-08-10 — no duplicate strip).
            .toolbar(editing ? .hidden : .visible, for: .tabBar)
            .navigationDestination(for: DianeModule.self) { module in
                ModuleScreen(module: module, context: context, open: { path.append($0) })
            }
            .task(id: pulseKey) { await loadPulse() }
        }
    }

    private var doneButton: some View {
        Button("Done") {
            withAnimation { editing = false }
            dragging = nil
            barDragItem = nil
            barDragOffset = 0
            barDragShift = 0
        }
        .font(.subheadline.weight(.semibold))
    }

    // MARK: - Tiles

    private func launchTile(_ module: DianeModule, pulse: HomeLogic.Pulse) -> some View {
        Button {
            if barModules.contains(module) {
                selectBarTab(module)
            } else {
                path.append(module)
            }
        } label: {
            tile(
                title: module.title,
                systemImage: module.systemImage,
                line: pulse.line(for: module),
                dot: pulse.showsDot(for: module)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            // ONE menu item (owner 2026-08-10) — everything else lives in
            // the jiggle mode itself.
            Button {
                withAnimation { editing = true }
            } label: {
                Label("Edit position", systemImage: "arrow.up.arrow.down")
            }
        }
    }

    /// Jiggling and draggable — the drag only ever REORDERS the grid; bar
    /// membership is the corner badge (owner 2026-08-10, the drag-in/out
    /// felt awkward).
    private func editingTile(_ module: DianeModule, enabled: [DianeModule], pulse: HomeLogic.Pulse) -> some View {
        let inBar = layout.barItems.contains(.module(module))
        // Edit mode: the badge owns the corner the icon sits in — content
        // steps down and the late dot hides (the design review's fix).
        return tile(title: module.title, systemImage: module.systemImage, line: pulse.line(for: module), editing: true)
            .overlay(alignment: .topLeading) {
                Button {
                    withAnimation {
                        if inBar { layout.removeFromBar(module) } else { layout.addToBar(module) }
                    }
                } label: {
                    Image(systemName: inBar ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 22))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, inBar ? Color.orange : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(!inBar && layout.barIsFull)
                .opacity(!inBar && layout.barIsFull ? 0.35 : 1)
                .offset(x: -6, y: -6)
                .accessibilityLabel(inBar ? "Remove \(module.title) from the tab bar" : "Add \(module.title) to the tab bar")
            }
            .jiggling()
            .onDrag {
                dragging = .module(module)
                return NSItemProvider(object: module.rawValue as NSString)
            }
            .onDrop(of: [.text], delegate: EditDropDelegate(dragging: $dragging) { dragged in
                guard let moved = dragged.module else { return }
                withAnimation { layout.moveTile(moved, to: module, enabled: enabled) }
            })
    }

    /// The decided tile (owner 2026-08-10, rev 5): small icon and name on a
    /// header row, one count line pinned at the bottom, red dot top-right
    /// when Chores holds something late. No hard height cap — Dynamic Type
    /// grows the tile (the review's rule).
    private func tile(
        title: String,
        systemImage: String,
        line: HomeLogic.Line? = nil,
        dot: Bool = false,
        comingLater: Bool = false,
        editing: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(comingLater ? Color.secondary : Color.accentColor)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if comingLater {
                Text("Coming later")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let line {
                lineText(line)
            }
        }
        .padding(12)
        // Edit mode: the +/− badge takes the icon's corner — content steps
        // down so they never collide.
        .padding(.top, editing ? 10 : 0)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            if dot && !editing {
                Circle().fill(.red).frame(width: 8, height: 8).padding(10)
            }
        }
        .opacity(comingLater ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(title: title, line: line, comingLater: comingLater))
    }

    /// "3 open · 1 late" — the count carries primary weight, the late part
    /// is red AND textual (never color alone), everything else recedes.
    private func lineText(_ line: HomeLogic.Line) -> some View {
        var text = Text(line.count).foregroundStyle(.primary).fontWeight(.semibold)
        if let late = line.late {
            text = text + Text(" · ").foregroundStyle(.secondary)
                + Text(late).foregroundStyle(.red).fontWeight(.semibold)
        }
        return text
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// One VoiceOver element per tile: "Chores, 3 open, 1 late." The dot
    /// announces nothing on its own.
    private func accessibilityText(title: String, line: HomeLogic.Line?, comingLater: Bool) -> String {
        if comingLater { return "\(title), coming later" }
        guard let line else { return title }
        return "\(title), \(([line.count] + (line.late.map { [$0] } ?? [])).joined(separator: ", "))"
    }

    // MARK: - The pulse data

    /// Every count comes from a fetch the app already performs elsewhere;
    /// failures keep the last snapshot — quiet doors beat error chrome.
    private func loadPulse() async {
        let today = clock.today
        do {
            async let eventsCall = context.client.api.listEvents(
                .init(query: .init(from: today, to: DayLogic.addDays(today, 1)))
            )
            async let choresCall = context.client.api.listChoreOccurrences(.init())
            async let boardCall = context.client.api.getRoutineBoard(.init(query: .init(date: today)))
            async let waitingCall = context.client.api.listRewardRedemptions(
                .init(query: .init(status: .redeemed, limit: RewardsLogic.waitingLimit))
            )

            var next = HomeLogic.Snapshot()
            switch try await eventsCall {
            case .ok(let ok): next.events = try ok.body.json.events
            case .unauthorized: appState.handleUnauthorized(); return
            default: break
            }
            if case .ok(let ok) = try await choresCall {
                next.chores = try ok.body.json.occurrences
            }
            if case .ok(let ok) = try await boardCall {
                next.board = try ok.body.json.entries
            }
            if case .ok(let ok) = try await waitingCall {
                next.waiting = try ok.body.json.redemptions.count
            }
            snapshot = next
        } catch {
            // Cancelled or offline: the last snapshot stands.
        }
    }

    // MARK: - The editable bar (the system bar's jiggling stand-in)

    /// The system tab bar can't jiggle or host drops, so edit mode hides it
    /// and this twin takes its exact place. Drag REORDERS only (owner
    /// 2026-08-10) — Today and Home move too, they just never leave; the
    /// tiles' badges handle membership. The grab is INSTANT (owner: "I
    /// don't expect anything else except moving it") — a plain gesture,
    /// not the system drag with its hold-to-lift.
    private var editableBar: some View {
        VStack(spacing: 0) {
            Divider()
            GeometryReader { geo in
                let cellWidth = geo.size.width / CGFloat(max(layout.barItems.count, 1))
                HStack(spacing: 0) {
                    ForEach(layout.barItems) { item in
                        VStack(spacing: 3) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 21))
                            Text(item.title)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: cellWidth)
                        .padding(.top, 8)
                        .contentShape(Rectangle())
                        .jiggling()
                        .offset(x: barDragItem == item ? barDragOffset - barDragShift : 0)
                        .zIndex(barDragItem == item ? 1 : 0)
                        .gesture(barDragGesture(for: item, cellWidth: cellWidth))
                    }
                }
            }
            .frame(height: 52)
            .padding(.bottom, 4)
        }
        .background(.bar)
        .transition(.opacity)
    }

    /// The dragged cell rides the finger; each time the travel clears 60%
    /// of a cell the reorder commits and that cell-width is banked, so the
    /// ride stays anchored while neighbours shuffle live.
    private func barDragGesture(for item: TabItem, cellWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if barDragItem != item {
                    barDragItem = item
                    barDragOffset = 0
                    barDragShift = 0
                }
                barDragOffset = value.translation.width
                let travel = barDragOffset - barDragShift
                guard abs(travel) > cellWidth * 0.6,
                      let index = layout.barItems.firstIndex(of: item) else { return }
                let target = travel > 0 ? index + 1 : index - 1
                guard layout.barItems.indices.contains(target) else { return }
                withAnimation(.snappy) {
                    layout.moveBarItem(item, to: layout.barItems[target])
                }
                barDragShift += CGFloat(target - index) * cellWidth
            }
            .onEnded { _ in
                withAnimation(.snappy) {
                    barDragItem = nil
                    barDragOffset = 0
                    barDragShift = 0
                }
            }
    }
}

/// One delegate for both zones: what a drag entering means is the caller's
/// closure — reorder here, stick or unstick across the seam. Live shuffle
/// (Apple's), not drop-at-the-end.
private struct EditDropDelegate: DropDelegate {
    @Binding var dragging: TabItem?
    let entered: (TabItem) -> Void

    init(dragging: Binding<TabItem?>, entered: @escaping (TabItem) -> Void) {
        _dragging = dragging
        self.entered = entered
    }

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        entered(dragging)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// The home-screen wobble. Phase-offset per view identity would be nicer;
/// one shared rhythm reads fine at this tile count.
private struct Jiggling: ViewModifier {
    @State private var wobble = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(wobble ? 1.6 : -1.6))
            .animation(.easeInOut(duration: 0.14).repeatForever(autoreverses: true), value: wobble)
            .onAppear { wobble = true }
    }
}

extension View {
    func jiggling() -> some View { modifier(Jiggling()) }
}
