import DianeKit
import Foundation
import Testing
@testable import Diane

// The M9e Routines page: family cards bucketed Now / Later / Earlier,
// chip rings + late dots, fold defaults, and the confirm gate.
@Suite struct RoutinesPageLogicTests {
    private func entry(
        routine: String = "r1",
        member: String = "a",
        windowStart: String = "07:00",
        windowEnd: String = "09:00",
        streak: Int = 0,
        open: Int = 0,
        done: Int = 0,
        skipped: Int = 0
    ) -> Components.Schemas.RoutineBoardEntry {
        Components.Schemas.RoutineBoardEntry(
            routineId: routine, title: routine, emoji: nil,
            windowStart: windowStart, windowEnd: windowEnd, memberId: member,
            complete: open == 0 && done + skipped > 0, streak: streak,
            tasks: (0..<open).map { .init(taskId: "o\($0)", title: "t", starValue: 1, status: .open) }
                + (0..<done).map { .init(taskId: "d\($0)", title: "t", starValue: 1, status: .completed) }
                + (0..<skipped).map { .init(taskId: "s\($0)", title: "t", starValue: 1, status: .skipped) }
        )
    }

    @Test func bucketsSplitOnTheClockAndHonorTheFilter() {
        let entries = [
            entry(routine: "morning", member: "a", windowStart: "07:00", windowEnd: "09:00", open: 1),
            entry(routine: "after", member: "a", windowStart: "15:30", windowEnd: "17:30", open: 2),
            entry(routine: "after", member: "b", windowStart: "15:30", windowEnd: "17:30", open: 2),
            entry(routine: "evening", member: "a", windowStart: "19:00", windowEnd: "20:30", open: 3),
        ]
        let buckets = RoutinesPageLogic.buckets(entries: entries, now: "16:10", selected: ["a", "b"])
        #expect(buckets.map(\.label) == ["Now", "Later today", "Earlier today"])
        #expect(buckets[0].entries.count == 2)
        // Filtering to b leaves only the shared after-school card.
        let justB = RoutinesPageLogic.buckets(entries: entries, now: "16:10", selected: ["b"])
        #expect(justB.map(\.label) == ["Now"])
        #expect(justB[0].entries.map(\.memberId) == ["b"])
    }

    @Test func subLinesFollowTheMockGrammar() {
        let live = entry(windowStart: "15:30", windowEnd: "17:30", open: 2, done: 1)
        #expect(RoutinesPageLogic.sub(live, phase: .now, use24: true).text == "Until 17:30 · 1 of 3")
        let liveDone = entry(windowStart: "15:30", windowEnd: "17:30", done: 2, skipped: 1)
        let doneSub = RoutinesPageLogic.sub(liveDone, phase: .now, use24: true)
        #expect(doneSub.text == "Done for today ✓" && doneSub.done)
        let later = entry(windowStart: "19:00", windowEnd: "20:30", open: 3)
        #expect(RoutinesPageLogic.sub(later, phase: .laterToday, use24: true).text == "19:00–20:30")
        let earlier = entry(open: 1, done: 3)
        let earlierSub = RoutinesPageLogic.sub(earlier, phase: .earlier, use24: true)
        #expect(earlierSub.text == "3 of 4" && earlierSub.stillOpen == 1)
        let empty = entry()
        #expect(RoutinesPageLogic.sub(empty, phase: .now, use24: true).text.contains("No tasks yet"))
    }

    @Test func displayedStreakAddsTodayOnlyWhenTrulyComplete() {
        #expect(RoutinesPageLogic.displayedStreak(entry(streak: 4, done: 2, skipped: 1)) == 5)
        #expect(RoutinesPageLogic.displayedStreak(entry(streak: 4, open: 1, done: 2)) == 4)
        // A zero-task card banks nothing, whatever the server flag says.
        #expect(RoutinesPageLogic.displayedStreak(entry(streak: 4)) == 4)
    }

    @Test func chipRingCountsSkipsAndLateDotNeedsAClosedWindow() {
        let entries = [
            entry(routine: "m", member: "a", windowStart: "07:00", windowEnd: "09:00", open: 1, done: 2, skipped: 1),
            entry(routine: "e", member: "a", windowStart: "19:00", windowEnd: "20:30", open: 2),
        ]
        #expect(abs(RoutinesPageLogic.progress(for: "a", entries: entries) - 0.5) < 0.001)
        #expect(RoutinesPageLogic.progress(for: "nobody", entries: entries) == 0)
        // The morning window closed with a task open → dot at 16:00.
        #expect(RoutinesPageLogic.hasLate(memberID: "a", entries: entries, now: "16:00"))
        // At 08:00 the window is still live — pressure, not a dot.
        #expect(!RoutinesPageLogic.hasLate(memberID: "a", entries: entries, now: "08:00"))
    }

    @Test func liveWindowCardsStartExpanded() {
        let entries = [
            entry(routine: "after", member: "a", windowStart: "15:30", windowEnd: "17:30", open: 1),
            entry(routine: "evening", member: "a", windowStart: "19:00", windowEnd: "20:30", open: 1),
        ]
        let expanded = RoutinesPageLogic.defaultExpanded(entries: entries, now: "16:10")
        #expect(expanded == ["after|a"])
    }

    @Test func crossMemberRevertsConfirmFamilySessionsAlways() {
        #expect(!RoutinesPageLogic.revertNeedsConfirm(cardMemberID: "a", sessionMemberID: "a"))
        #expect(RoutinesPageLogic.revertNeedsConfirm(cardMemberID: "a", sessionMemberID: "b"))
        #expect(RoutinesPageLogic.revertNeedsConfirm(cardMemberID: "a", sessionMemberID: ""))
    }

    @Test func pastDaysWalkBackSevenNewestFirst() {
        let days = RoutinesPageLogic.pastDays(today: "2026-08-10")
        #expect(days.first == "2026-08-09")
        #expect(days.last == "2026-08-03")
        #expect(days.count == 7)
    }
}
