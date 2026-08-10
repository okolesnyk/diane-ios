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

    /// What the pinned tabs render (owner 2026-08-10: the Calendar slot is
    /// changeable and up to two more can join). Each pin shows while its
    /// module is on; the MAIN slot falls back to Calendar when its module is
    /// off (owner rule 2026-08-05), optional slots simply sit out. The
    /// fallback is CLIENT logic by design: pins are device-local and the
    /// server never sweeps them — an off module's pin revives on return.
    static func effectivePinnedTabs(pinned: [DianeModule], modules: ModuleSwitchboard) -> [DianeModule] {
        let main = pinned.first ?? .calendar
        var out = [main.isOn(modules) ? main : .calendar]
        for module in pinned.dropFirst() where module.isOn(modules) && !out.contains(module) {
            out.append(module)
        }
        return Array(out.prefix(PinnedTabsStore.maxSlots))
    }
}

/// The device-local pinned module tabs, scoped per member so a shared phone
/// never leaks one member's layout onto another's sign-in. Slot 1 is the
/// always-present changeable tab (default Calendar); slots 2–3 are the
/// optional extras (owner 2026-08-10).
@MainActor
@Observable
final class PinnedTabsStore {
    nonisolated static let maxSlots = 3
    private let key: String
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var pinned: [DianeModule]

    init(memberID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "pinnedTabs.\(memberID)"
        // The pre-extras single pin reads as slot 1.
        let stored = defaults.string(forKey: key)
            ?? defaults.string(forKey: "fourthTab.\(memberID)")
            ?? ""
        var modules: [DianeModule] = []
        for raw in stored.split(separator: ",") {
            if let module = DianeModule(rawValue: String(raw)), !modules.contains(module) {
                modules.append(module)
            }
        }
        pinned = modules.isEmpty ? [.calendar] : Array(modules.prefix(Self.maxSlots))
        #if DEBUG
        // Screenshot hook, twin of RootTabView's -uiTab: pinning is a
        // long-press and simctl cannot tap. Never compiled into release.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiModule"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let module = DianeModule(rawValue: ProcessInfo.processInfo.arguments[index + 1]) {
            pinned = [module]
        }
        #endif
    }

    /// Replace the main slot; the module leaves any extra slot it held.
    func pin(_ module: DianeModule) {
        save([module] + pinned.dropFirst().filter { $0 != module })
    }

    /// Add an optional extra tab (the 4th/5th bottom item).
    func add(_ module: DianeModule) {
        guard !pinned.contains(module), pinned.count < Self.maxSlots else { return }
        save(pinned + [module])
    }

    /// Drop an extra slot — the main slot is replaced, never removed.
    func remove(_ module: DianeModule) {
        guard pinned.dropFirst().contains(module) else { return }
        save(pinned.filter { $0 != module })
    }

    private func save(_ modules: [DianeModule]) {
        pinned = modules
        defaults.set(modules.map(\.rawValue).joined(separator: ","), forKey: key)
    }
}
