import Foundation
import Observation

/// The household module switchboard as the app consumes it (M9e). Server
/// truth on every client; absent/unknown reads as everything on.
struct ModuleSwitchboard: Equatable {
    var chores = true
    var routines = true
    var rewards = true
}

/// The launchable modules. Calendar is the spine and always on; the rest
/// follow the household switchboard.
enum DianeModule: String, CaseIterable, Identifiable, Codable {
    case calendar, chores, routines, rewards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .chores: "Chores"
        case .routines: "Routines"
        case .rewards: "Rewards"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .chores: "checkmark.circle"
        case .routines: "repeat"
        case .rewards: "star"
        }
    }

    func isOn(_ modules: ModuleSwitchboard) -> Bool {
        switch self {
        case .calendar: true
        case .chores: modules.chores
        case .routines: modules.routines
        case .rewards: modules.rewards
        }
    }
}

/// Tiles for modules that exist in the design but not yet in the product —
/// shown grayed in Apps so the family knows where the future lands.
enum FutureModule: String, CaseIterable, Identifiable {
    case lists, meals, photos, assistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lists: "Lists"
        case .meals: "Meals"
        case .photos: "Photos"
        case .assistant: "Assistant"
        }
    }

    var systemImage: String {
        switch self {
        case .lists: "checklist"
        case .meals: "fork.knife"
        case .photos: "photo.on.rectangle"
        case .assistant: "sparkles"
        }
    }
}

enum NavigationLogic {
    /// Modules the household has ON, in launcher order.
    static func enabledModules(_ modules: ModuleSwitchboard) -> [DianeModule] {
        DianeModule.allCases.filter { $0.isOn(modules) }
    }

    /// "Tue, Aug 5" from a household-local YYYY-MM-DD (My Day's nav title).
    /// Lives here, not on the View — View members inherit @MainActor and a
    /// pure formatter must stay callable from anywhere (isolation trap).
    static func myDayTitle(for today: String) -> String {
        let parts = today.split(separator: "-").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return "My Day" }
        var components = DateComponents()
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let date = calendar.date(from: components) else { return "My Day" }
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter.string(from: date)
    }

    /// What the bottom bar renders (owner 2026-08-10, "the Apple way"): the
    /// member's ordered layout with off modules sitting out. Today and Home
    /// are always members — reorderable, never removable. CLIENT logic by
    /// design: the layout is device-local and the server never sweeps it —
    /// an off module's slot revives where it was when the module returns.
    static func effectiveBar(items: [TabItem], modules: ModuleSwitchboard) -> [TabItem] {
        var out = items.filter { item in
            switch item {
            case .today, .home: true
            case .module(let module): module.isOn(modules)
            }
        }
        if !out.contains(.today) { out.insert(.today, at: 0) }
        if !out.contains(.home) { out.insert(.home, at: min(1, out.count)) }
        return Array(out.prefix(TabLayoutStore.maxBarItems))
    }
}

/// One bottom-bar slot: the two fixed pages, or a module.
enum TabItem: Hashable, Identifiable {
    case today
    case home
    case module(DianeModule)

    var id: String { raw }

    var raw: String {
        switch self {
        case .today: "today"
        case .home: "home"
        case .module(let module): module.rawValue
        }
    }

    init?(raw: String) {
        switch raw {
        case "today": self = .today
        case "home": self = .home
        default:
            guard let module = DianeModule(rawValue: raw) else { return nil }
            self = .module(module)
        }
    }

    var module: DianeModule? {
        if case .module(let module) = self { module } else { nil }
    }

    var title: String {
        switch self {
        case .today: "Today"
        case .home: "Home"
        case .module(let module): module.title
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .home: "house"
        case .module(let module): module.systemImage
        }
    }
}

/// The device-local layout — bottom-bar order AND Home-grid tile order —
/// scoped per member so a shared phone never leaks one member's layout onto
/// another's sign-in. The bar always holds Today and Home (reorderable,
/// never removable) plus up to three module tabs (owner 2026-08-10).
@MainActor
@Observable
final class TabLayoutStore {
    nonisolated static let maxBarItems = 5
    private let barKey: String
    private let gridKey: String
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var barItems: [TabItem]
    /// Home-grid tile order; enabled modules missing here append in
    /// canonical order (a fresh module lands at the end, not nowhere).
    private(set) var gridOrder: [DianeModule]

    init(memberID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        barKey = "tabBar.\(memberID)"
        gridKey = "homeGrid.\(memberID)"
        // Older single-pin / pinned-list layouts read as bar slots 3+.
        let storedBar = defaults.string(forKey: barKey)
            ?? defaults.string(forKey: "pinnedTabs.\(memberID)").map { "today,home,\($0)" }
            ?? defaults.string(forKey: "fourthTab.\(memberID)").map { "today,home,\($0)" }
            ?? "today,home,calendar"
        barItems = Self.normalizedBar(storedBar.split(separator: ",").compactMap { TabItem(raw: String($0)) })
        gridOrder = (defaults.string(forKey: gridKey) ?? "")
            .split(separator: ",").compactMap { DianeModule(rawValue: String($0)) }
        #if DEBUG
        // Screenshot hook, twin of RootTabView's -uiTab: rearranging is a
        // long-press and simctl cannot tap. Never compiled into release.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiModule"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let module = DianeModule(rawValue: ProcessInfo.processInfo.arguments[index + 1]) {
            barItems = [.today, .home, .module(module)]
        }
        #endif
    }

    /// Today first, Home present, no doubles, five at most.
    private nonisolated static func normalizedBar(_ items: [TabItem]) -> [TabItem] {
        var out: [TabItem] = []
        for item in items where !out.contains(item) { out.append(item) }
        if !out.contains(.today) { out.insert(.today, at: 0) }
        if !out.contains(.home) { out.insert(.home, at: min(1, out.count)) }
        return Array(out.prefix(maxBarItems))
    }

    var barIsFull: Bool { barItems.count >= Self.maxBarItems }

    func addToBar(_ module: DianeModule) {
        guard !barItems.contains(.module(module)), !barIsFull else { return }
        saveBar(barItems + [.module(module)])
    }

    func removeFromBar(_ module: DianeModule) {
        saveBar(barItems.filter { $0 != .module(module) })
    }

    /// Drag reorder within the bar tray — any item, Today and Home included.
    func moveBarItem(_ item: TabItem, to target: TabItem) {
        guard item != target,
              let from = barItems.firstIndex(of: item),
              let to = barItems.firstIndex(of: target) else { return }
        var next = barItems
        next.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        saveBar(next)
    }

    /// The Home grid in the member's order, holding every enabled module.
    func orderedTiles(enabled: [DianeModule]) -> [DianeModule] {
        gridOrder.filter { enabled.contains($0) } + enabled.filter { !gridOrder.contains($0) }
    }

    /// Drag reorder on the Home grid.
    func moveTile(_ module: DianeModule, to target: DianeModule, enabled: [DianeModule]) {
        var order = orderedTiles(enabled: enabled)
        guard module != target,
              let from = order.firstIndex(of: module),
              let to = order.firstIndex(of: target) else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        gridOrder = order
        defaults.set(order.map(\.rawValue).joined(separator: ","), forKey: gridKey)
    }

    private func saveBar(_ items: [TabItem]) {
        barItems = Self.normalizedBar(items)
        defaults.set(barItems.map(\.raw).joined(separator: ","), forKey: barKey)
    }
}
