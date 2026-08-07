import Foundation
import Observation

/// The member chip filter, shared by every page that shows one (owner
/// 2026-08-06: "if on Family Day I picked myself and my wife and then I move
/// to Calendar it stays me and my wife"). This supersedes the mock's
/// "filter resets when you leave the tab" rule — one filter, app-wide, for
/// the session.
///
/// Empty = everyone. Kept in memory only: a fresh launch looks at the whole
/// family again.
@MainActor
@Observable
final class MemberFilterStore {
    private(set) var selected: Set<String> = []

    func isOn(_ id: String, all: [String]) -> Bool {
        selected.isEmpty || selected.contains(id)
    }

    var isFiltered: Bool { !selected.isEmpty }

    func effective(all: [String]) -> Set<String> {
        selected.isEmpty ? Set(all) : selected
    }

    /// Tap: add/remove; emptying it — or selecting everyone — means everyone.
    func toggle(_ id: String, all: [String]) {
        var next = FamilyDayLogic.toggledFilter(effective(all: all), all: all, tapping: id)
        if next.count == all.count { next = [] }
        selected = next
    }

    /// Long-press: solo this member, or return to everyone if already solo.
    func solo(_ id: String) {
        selected = selected == [id] ? [] : [id]
    }

    func clear() {
        selected = []
    }
}
