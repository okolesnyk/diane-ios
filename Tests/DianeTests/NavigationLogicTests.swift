import Foundation
import Testing
@testable import Diane

// M9e navigation skeleton: the module switchboard is server truth, the
// pinned tabs are device truth, and the fallback between them is pure
// client logic (owner rule 2026-08-05; up to three slots 2026-08-10).
@Suite struct NavigationLogicTests {
    @Test func calendarIsAlwaysOn() {
        let allOff = ModuleSwitchboard(chores: false, routines: false, rewards: false, lists: false)
        #expect(DianeModule.calendar.isOn(allOff))
        #expect(NavigationLogic.enabledModules(allOff) == [.calendar])
    }

    @Test func enabledModulesFollowTheSwitchboard() {
        let some = ModuleSwitchboard(chores: true, routines: false, rewards: true, lists: false)
        #expect(NavigationLogic.enabledModules(some) == [.calendar, .chores, .rewards])
        #expect(NavigationLogic.enabledModules(ModuleSwitchboard()) == DianeModule.allCases)
    }

    /// Owner 2026-08-10, "the Apple way": the bar is one ordered layout.
    /// Today and Home are always members (any position); an off module's
    /// slot sits out and revives where it was when the module returns.
    @Test func effectiveBarKeepsOrderAndSitsOutOffModules() {
        let rewardsOff = ModuleSwitchboard(chores: true, routines: true, rewards: false)
        let items: [TabItem] = [.module(.calendar), .today, .module(.rewards), .home, .module(.chores)]
        #expect(NavigationLogic.effectiveBar(items: items, modules: rewardsOff)
            == [.module(.calendar), .today, .home, .module(.chores)])
        // The slot is NOT forgotten — the module returning revives it.
        #expect(NavigationLogic.effectiveBar(items: items, modules: ModuleSwitchboard()) == items)
        // Today and Home cannot be lost, whatever is on disk.
        #expect(NavigationLogic.effectiveBar(items: [.module(.chores)], modules: ModuleSwitchboard())
            == [.today, .home, .module(.chores)])
        #expect(NavigationLogic.effectiveBar(items: [], modules: rewardsOff) == [.today, .home])
    }

    @Test @MainActor func tabLayoutStoreIsPerMemberAndPersists() {
        let defaults = UserDefaults(suiteName: "navlogic-tests-\(UUID().uuidString)")!
        let alex = TabLayoutStore(memberID: "m-alex", defaults: defaults)
        #expect(alex.barItems == [.today, .home, .module(.calendar)]) // default
        // ONE add path (owner 2026-08-10): modules append, capped at five.
        alex.addToBar(.chores)
        alex.addToBar(.rewards)
        alex.addToBar(.routines)
        #expect(alex.barItems == [.today, .home, .module(.calendar), .module(.chores), .module(.rewards)])
        #expect(alex.barIsFull)
        // Any module can leave — Calendar included.
        alex.removeFromBar(.calendar)
        alex.removeFromBar(.rewards)
        #expect(alex.barItems == [.today, .home, .module(.chores)])
        // Reorder moves anything, Today and Home included.
        alex.moveBarItem(.module(.chores), to: .today)
        #expect(alex.barItems == [.module(.chores), .today, .home])
        alex.moveBarItem(.today, to: .home)
        #expect(alex.barItems == [.module(.chores), .home, .today])
        // A different member on the same device keeps their own layout.
        #expect(TabLayoutStore(memberID: "m-bruno", defaults: defaults).barItems
            == [.today, .home, .module(.calendar)])
        // A fresh store for the same member reads the persisted layout.
        #expect(TabLayoutStore(memberID: "m-alex", defaults: defaults).barItems
            == [.module(.chores), .home, .today])
        // Older single-pin and pinned-list layouts read as bar slots 3+.
        let legacy = UserDefaults(suiteName: "navlogic-tests-\(UUID().uuidString)")!
        legacy.set("chores", forKey: "fourthTab.m-old")
        #expect(TabLayoutStore(memberID: "m-old", defaults: legacy).barItems
            == [.today, .home, .module(.chores)])
        legacy.set("calendar,rewards", forKey: "pinnedTabs.m-mid")
        #expect(TabLayoutStore(memberID: "m-mid", defaults: legacy).barItems
            == [.today, .home, .module(.calendar), .module(.rewards)])
        // Garbage on disk degrades to Today + Home, never crashes.
        defaults.set("meals,junk", forKey: "tabBar.m-alex")
        #expect(TabLayoutStore(memberID: "m-alex", defaults: defaults).barItems == [.today, .home])
    }

    @Test @MainActor func homeGridOrderPersistsAndAdoptsNewModules() {
        let defaults = UserDefaults(suiteName: "navlogic-tests-\(UUID().uuidString)")!
        let store = TabLayoutStore(memberID: "m-alex", defaults: defaults)
        let all = DianeModule.allCases
        #expect(store.orderedTiles(enabled: all) == all) // canonical default
        store.moveTile(.rewards, to: .calendar, enabled: all)
        #expect(store.orderedTiles(enabled: all) == [.rewards, .calendar, .chores, .routines, .lists])
        // A module the switchboard hides drops out without losing its seat.
        #expect(store.orderedTiles(enabled: [.calendar, .chores, .rewards]) == [.rewards, .calendar, .chores])
        // A fresh store reads the persisted order; unknown modules append.
        #expect(TabLayoutStore(memberID: "m-alex", defaults: defaults)
            .orderedTiles(enabled: all) == [.rewards, .calendar, .chores, .routines, .lists])
    }

    @Test func dayTitleFormatsTheHouseholdDay() {
        #expect(NavigationLogic.dayTitle(for: "2026-08-05").contains("5"))
        #expect(NavigationLogic.dayTitle(for: "not-a-date") == "Today")
    }
}
