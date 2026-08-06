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

    /// What the fourth tab renders: the pinned module while its switch is on,
    /// else Calendar. The fallback is CLIENT logic by design (owner rule
    /// 2026-08-05): the pin itself is device-local and the server never
    /// sweeps it, so a client whose pin points at an off module steps back
    /// to the spine on its own — without forgetting the pin, which revives
    /// when the module returns.
    static func effectiveFourthTab(pinned: DianeModule, modules: ModuleSwitchboard) -> DianeModule {
        pinned.isOn(modules) ? pinned : .calendar
    }
}

/// The device-local fourth-tab pin, scoped per member so a shared phone
/// never leaks one member's layout onto another's sign-in.
@MainActor
@Observable
final class FourthTabStore {
    private let key: String
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var pinned: DianeModule

    init(memberID: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "fourthTab.\(memberID)"
        pinned = DianeModule(rawValue: defaults.string(forKey: key) ?? "") ?? .calendar
    }

    func pin(_ module: DianeModule) {
        pinned = module
        defaults.set(module.rawValue, forKey: key)
    }
}
