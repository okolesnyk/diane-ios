import Foundation
import Testing
@testable import Diane

// M9e navigation skeleton: the module switchboard is server truth, the
// fourth-tab pin is device truth, and the fallback between them is pure
// client logic (owner rule 2026-08-05).
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

    @Test func fourthTabFallsBackToCalendarWhileItsModuleIsOff() {
        let rewardsOff = ModuleSwitchboard(chores: true, routines: true, rewards: false)
        #expect(NavigationLogic.effectiveFourthTab(pinned: .rewards, modules: rewardsOff) == .calendar)
        // The pin is NOT forgotten — the module returning revives it.
        #expect(NavigationLogic.effectiveFourthTab(pinned: .rewards, modules: ModuleSwitchboard()) == .rewards)
        #expect(NavigationLogic.effectiveFourthTab(pinned: .chores, modules: rewardsOff) == .chores)
    }

    @Test @MainActor func fourthTabStoreIsPerMemberAndPersists() {
        let defaults = UserDefaults(suiteName: "navlogic-tests-\(UUID().uuidString)")!
        let alex = FourthTabStore(memberID: "m-alex", defaults: defaults)
        #expect(alex.pinned == .calendar) // default
        alex.pin(.chores)
        #expect(alex.pinned == .chores)
        // A different member on the same device keeps their own layout.
        let bruno = FourthTabStore(memberID: "m-bruno", defaults: defaults)
        #expect(bruno.pinned == .calendar)
        // A fresh store for the same member reads the persisted pin.
        #expect(FourthTabStore(memberID: "m-alex", defaults: defaults).pinned == .chores)
        // Garbage on disk degrades to the default, never crashes.
        defaults.set("meals", forKey: "fourthTab.m-alex")
        #expect(FourthTabStore(memberID: "m-alex", defaults: defaults).pinned == .calendar)
    }

    @Test func myDayTitleFormatsTheHouseholdDay() {
        #expect(NavigationLogic.myDayTitle(for: "2026-08-05").contains("5"))
        #expect(NavigationLogic.myDayTitle(for: "not-a-date") == "My Day")
    }
}
