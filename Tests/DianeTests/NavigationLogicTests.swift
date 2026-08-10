import Foundation
import Testing
@testable import Diane

// M9e navigation skeleton: the module switchboard is server truth, the
// pinned tabs are device truth, and the fallback between them is pure
// client logic (owner rule 2026-08-05; up to three slots 2026-08-10).
@Suite struct NavigationLogicTests {
    @Test func calendarIsAlwaysOn() {
        let allOff = ModuleSwitchboard(chores: false, routines: false, rewards: false)
        #expect(DianeModule.calendar.isOn(allOff))
        #expect(NavigationLogic.enabledModules(allOff) == [.calendar])
    }

    @Test func enabledModulesFollowTheSwitchboard() {
        let some = ModuleSwitchboard(chores: true, routines: false, rewards: true)
        #expect(NavigationLogic.enabledModules(some) == [.calendar, .chores, .rewards])
        #expect(NavigationLogic.enabledModules(ModuleSwitchboard()) == DianeModule.allCases)
    }

    @Test func mainSlotFallsBackToCalendarWhileItsModuleIsOff() {
        let rewardsOff = ModuleSwitchboard(chores: true, routines: true, rewards: false)
        #expect(NavigationLogic.effectivePinnedTabs(pinned: [.rewards], modules: rewardsOff) == [.calendar])
        // The pin is NOT forgotten — the module returning revives it.
        #expect(NavigationLogic.effectivePinnedTabs(pinned: [.rewards], modules: ModuleSwitchboard()) == [.rewards])
        #expect(NavigationLogic.effectivePinnedTabs(pinned: [.chores], modules: rewardsOff) == [.chores])
    }

    /// Owner 2026-08-10: up to two extra slots. An off extra sits out (no
    /// Calendar fallback — only the main slot has one), and the main slot's
    /// fallback never doubles an extra Calendar pin.
    @Test func extraSlotsSitOutWhenOffAndNeverDouble() {
        let rewardsOff = ModuleSwitchboard(chores: true, routines: true, rewards: false)
        #expect(NavigationLogic.effectivePinnedTabs(
            pinned: [.calendar, .chores, .rewards], modules: rewardsOff) == [.calendar, .chores])
        #expect(NavigationLogic.effectivePinnedTabs(
            pinned: [.calendar, .chores, .rewards], modules: ModuleSwitchboard()) == [.calendar, .chores, .rewards])
        // Main pinned rewards while off → Calendar; a Calendar extra must
        // not appear twice.
        #expect(NavigationLogic.effectivePinnedTabs(
            pinned: [.rewards, .calendar], modules: rewardsOff) == [.calendar])
        #expect(NavigationLogic.effectivePinnedTabs(pinned: [], modules: rewardsOff) == [.calendar])
    }

    @Test @MainActor func pinnedTabsStoreIsPerMemberAndPersists() {
        let defaults = UserDefaults(suiteName: "navlogic-tests-\(UUID().uuidString)")!
        let alex = PinnedTabsStore(memberID: "m-alex", defaults: defaults)
        #expect(alex.pinned == [.calendar]) // default
        alex.pin(.chores)
        #expect(alex.pinned == [.chores])
        // Extras append after the main slot, capped at three total.
        alex.add(.rewards)
        alex.add(.routines)
        alex.add(.calendar)
        #expect(alex.pinned == [.chores, .rewards, .routines])
        // Removing frees a slot; the main slot is never removable.
        alex.remove(.rewards)
        alex.remove(.chores)
        #expect(alex.pinned == [.chores, .routines])
        // Re-pinning a module that held an extra slot moves it, not doubles.
        alex.pin(.routines)
        #expect(alex.pinned == [.routines])
        // A different member on the same device keeps their own layout.
        #expect(PinnedTabsStore(memberID: "m-bruno", defaults: defaults).pinned == [.calendar])
        // A fresh store for the same member reads the persisted pins.
        #expect(PinnedTabsStore(memberID: "m-alex", defaults: defaults).pinned == [.routines])
        // The pre-extras single pin reads as slot 1.
        let legacy = UserDefaults(suiteName: "navlogic-tests-\(UUID().uuidString)")!
        legacy.set("chores", forKey: "fourthTab.m-old")
        #expect(PinnedTabsStore(memberID: "m-old", defaults: legacy).pinned == [.chores])
        // Garbage on disk degrades to the default, never crashes.
        defaults.set("meals,junk", forKey: "pinnedTabs.m-alex")
        #expect(PinnedTabsStore(memberID: "m-alex", defaults: defaults).pinned == [.calendar])
    }

    @Test func myDayTitleFormatsTheHouseholdDay() {
        #expect(NavigationLogic.myDayTitle(for: "2026-08-05").contains("5"))
        #expect(NavigationLogic.myDayTitle(for: "not-a-date") == "My Day")
    }
}
