import Foundation
import Observation

/// The member chip filter, shared by every page that shows one (owner
/// 2026-08-06: "if on Family Day I picked myself and my wife and then I move
/// to Calendar it stays me and my wife"). This supersedes the mock's
/// "filter resets when you leave the tab" rule — one filter, app-wide.
///
/// It survives relaunch too (owner 2026-08-10): stored on the DEVICE in
/// UserDefaults, per signed-in member, so a shared phone never leaks one
/// member's filter onto another's sign-in. Empty = everyone; a stored
/// selection whose members all left the household degrades to everyone.
@MainActor
@Observable
final class MemberFilterStore {
    private let key: String
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var selected: Set<String>

    init(memberID: String = "", defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "memberFilter.\(memberID)"
        selected = Set(
            (defaults.string(forKey: key) ?? "").split(separator: ",").map(String.init)
        )
    }

    func isOn(_ id: String, all: [String]) -> Bool {
        let live = selected.intersection(all)
        return live.isEmpty || live.contains(id)
    }

    var isFiltered: Bool { !selected.isEmpty }

    func effective(all: [String]) -> Set<String> {
        let live = selected.intersection(all)
        return live.isEmpty ? Set(all) : live
    }

    /// Tap: add/remove; emptying it — or selecting everyone — means everyone.
    func toggle(_ id: String, all: [String]) {
        var next = TodayLogic.toggledFilter(effective(all: all), all: all, tapping: id)
        if next.count == all.count { next = [] }
        save(next)
    }

    /// Long-press: solo this member, or return to everyone if already solo.
    func solo(_ id: String) {
        solo([id])
    }

    /// Solo a set — Chores solos a member together with the "Anyone" pool
    /// chip, since unowned chores stay everyone's business.
    func solo(_ ids: Set<String>) {
        save(selected == ids ? [] : ids)
    }

    func clear() {
        save([])
    }

    private func save(_ next: Set<String>) {
        selected = next
        defaults.set(next.sorted().joined(separator: ","), forKey: key)
    }
}
