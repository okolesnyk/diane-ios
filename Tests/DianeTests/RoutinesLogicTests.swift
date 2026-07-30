import DianeKit
import Foundation
import SwiftUI
import Testing

@testable import Diane

@Suite struct RoutinesLogicTests {
    private typealias Entry = Components.Schemas.RoutineBoardEntry
    private typealias TaskPayload = Entry.TasksPayloadPayload

    private func task(
        _ id: String = "t1",
        status: TaskPayload.StatusPayload = .open,
        stars: Int = 1
    ) -> TaskPayload {
        TaskPayload(taskId: id, title: "Task \(id)", starValue: stars, status: status)
    }

    private func entry(
        id: String = "r1",
        title: String = "Morning",
        start: String = "06:00",
        end: String = "12:00",
        member: String = "me",
        complete: Bool = false,
        streak: Int = 0,
        tasks: [TaskPayload] = []
    ) -> Entry {
        Entry(
            routineId: id,
            title: title,
            windowStart: start,
            windowEnd: end,
            memberId: member,
            complete: complete,
            streak: streak,
            tasks: tasks
        )
    }

    @Suite struct WindowPhase {
        private func phase(_ start: String, _ end: String, now: String) -> RoutinesBoardLogic.Phase {
            RoutinesBoardLogic.phase(windowStart: start, windowEnd: end, now: now)
        }

        @Test func insideWindowIsNow() {
            #expect(phase("06:00", "12:00", now: "08:30") == .now)
        }

        @Test func exactlyWindowStartIsNow() {
            #expect(phase("06:00", "12:00", now: "06:00") == .now)
        }

        // D26: end-INCLUSIVE, matching the web kiosk's windowBucket.
        @Test func exactlyWindowEndIsStillNow() {
            #expect(phase("06:00", "12:00", now: "12:00") == .now)
        }

        // D26: evening presets end 23:59 — the day's last minute must count.
        @Test func eveningPresetLastMinuteIsStillNow() {
            #expect(phase("18:00", "23:59", now: "23:59") == .now)
        }

        // D26: the minute AFTER the end is over.
        @Test func oneMinutePastEndIsEarlier() {
            #expect(phase("06:00", "12:00", now: "12:01") == .earlier)
        }

        @Test func beforeWindowIsLaterToday() {
            #expect(phase("18:00", "21:00", now: "09:15") == .laterToday)
        }

        @Test func afterWindowIsEarlier() {
            #expect(phase("06:00", "08:00", now: "22:45") == .earlier)
        }

        @Test func oneMinuteBeforeEndIsStillNow() {
            #expect(phase("06:00", "12:00", now: "11:59") == .now)
        }
    }

    @Suite struct StaleBoardDate {
        // D04: a tap after midnight must refetch, never POST yesterday.
        @Test func boardFromYesterdayIsStale() {
            #expect(RoutinesBoardLogic.isStale(boardDate: "2026-07-26", today: "2026-07-27"))
        }

        @Test func boardFromTodayIsFresh() {
            #expect(!RoutinesBoardLogic.isStale(boardDate: "2026-07-27", today: "2026-07-27"))
        }
    }

    @Suite struct RecoveryAffordance {
        // D27: visible Skip / Un-do labels replace the long-press-only menu.
        @Test func openTasksOfferSkip() {
            #expect(RoutinesBoardLogic.recoveryActionTitle(for: .open) == "Skip")
        }

        @Test func completedAndSkippedTasksOfferUndo() {
            #expect(RoutinesBoardLogic.recoveryActionTitle(for: .completed) == "Un-do")
            #expect(RoutinesBoardLogic.recoveryActionTitle(for: .skipped) == "Un-do")
        }

        // D27: circles are HIG-sized for kid fingers, like the web's 44px.
        @Test func tapTargetMeetsHIGMinimum() {
            #expect(RoutinesBoardLogic.tapTarget == 44)
        }

        // M9c: Skip swipes from the trailing edge while the task is open.
        @Test func openTasksSkipFromTheTrailingEdge() {
            #expect(RoutinesBoardLogic.recoveryEdge(for: .open) == .trailing)
        }

        // M9c: resolved tasks come back from the leading edge — one recovery
        // action per row, never both.
        @Test func resolvedTasksUndoFromTheLeadingEdge() {
            #expect(RoutinesBoardLogic.recoveryEdge(for: .completed) == .leading)
            #expect(RoutinesBoardLogic.recoveryEdge(for: .skipped) == .leading)
        }
    }

    @Suite struct Density {
        // M9c: rows run flush to the screen edge, 16pt gutter only.
        @Test func rowInsetsMatchTheSharedContract() {
            let insets = RoutinesBoardLogic.rowInsets
            #expect(insets.leading == 16)
            #expect(insets.trailing == 16)
            #expect(insets.top == 8)
            #expect(insets.bottom == 8)
        }
    }

    @Suite struct HeaderCaption {
        // The "Now" pill says the phase, so the caption doesn't repeat it.
        @Test func nowPhaseShowsWindowOnly() {
            #expect(
                RoutinesBoardLogic.headerCaption(windowStart: "06:00", windowEnd: "12:00", phase: .now)
                    == "06:00–12:00"
            )
        }

        // Off-phase routines keep the wording the old phase headings carried.
        @Test func otherPhasesAppendTheirTitle() {
            #expect(
                RoutinesBoardLogic.headerCaption(windowStart: "18:00", windowEnd: "23:59", phase: .laterToday)
                    == "18:00–23:59 · Later today"
            )
            #expect(
                RoutinesBoardLogic.headerCaption(windowStart: "06:00", windowEnd: "08:00", phase: .earlier)
                    == "06:00–08:00 · Earlier"
            )
        }
    }

    @Suite struct HouseholdClockFrame {
        // D03: phase input comes from the HOUSEHOLD wall clock, not the
        // device's — the same instant reads differently per household tz.
        @Test @MainActor func minuteAndTodayUseHouseholdTimeZone() {
            let instant = Date(timeIntervalSince1970: 1_785_121_200)  // 2026-07-27T03:00:00Z
            let chicago = HouseholdClock(timeZone: TimeZone(identifier: "America/Chicago")!, now: instant)
            #expect(chicago.minute == "22:00")
            #expect(chicago.today == "2026-07-26")

            let newYork = HouseholdClock(timeZone: TimeZone(identifier: "America/New_York")!, now: instant)
            #expect(newYork.minute == "23:00")
            #expect(newYork.today == "2026-07-26")
        }
    }

    @Suite struct CancellationGuard {
        // D08: SwiftUI task cancellation is lifecycle, not failure.
        @Test func cancellationErrorsAreRecognized() {
            #expect(isTaskCancellation(CancellationError()))
            #expect(isTaskCancellation(URLError(.cancelled)))
        }

        @Test func realFailuresAreNotSwallowed() {
            #expect(!isTaskCancellation(URLError(.timedOut)))
            #expect(!isTaskCancellation(URLError(.cannotConnectToHost)))
        }
    }

    @Suite struct Sections {
        private let tests = RoutinesLogicTests()

        @Test func ordersNowLaterEarlierAndSortsByWindowStart() {
            let entries = [
                tests.entry(id: "evening", title: "Evening", start: "18:00", end: "21:00"),
                tests.entry(id: "morning", title: "Morning", start: "06:00", end: "08:00"),
                tests.entry(id: "lunch", title: "Lunch", start: "11:00", end: "14:00"),
                tests.entry(id: "midday", title: "Midday", start: "10:00", end: "15:00"),
                tests.entry(id: "school", title: "School run", start: "07:30", end: "08:30"),
            ]

            let sections = RoutinesBoardLogic.sections(for: entries, now: "12:00")

            #expect(sections.map(\.phase) == [.now, .laterToday, .earlier])
            #expect(sections[0].entries.map(\.routineId) == ["midday", "lunch"])
            #expect(sections[1].entries.map(\.routineId) == ["evening"])
            #expect(sections[2].entries.map(\.routineId) == ["morning", "school"])
        }

        @Test func emptyPhasesAreOmitted() {
            let entries = [tests.entry(id: "r1", start: "06:00", end: "08:00")]

            let sections = RoutinesBoardLogic.sections(for: entries, now: "09:00")

            #expect(sections.count == 1)
            #expect(sections[0].phase == .earlier)
        }

        @Test func noEntriesMeansNoSections() {
            #expect(RoutinesBoardLogic.sections(for: [], now: "09:00").isEmpty)
        }

        @Test func equalWindowStartFallsBackToTitle() {
            let entries = [
                tests.entry(id: "b", title: "Zebra care", start: "06:00", end: "08:00"),
                tests.entry(id: "a", title: "Aardvark care", start: "06:00", end: "08:00"),
            ]

            let sections = RoutinesBoardLogic.sections(for: entries, now: "07:00")

            #expect(sections[0].entries.map(\.routineId) == ["a", "b"])
        }
    }

    @Suite struct MineFilter {
        private let tests = RoutinesLogicTests()

        @Test func keepsOnlyMyEntries() {
            let entries = [
                tests.entry(id: "r1", member: "me"),
                tests.entry(id: "r2", member: "sibling"),
                tests.entry(id: "r1", member: "sibling"),
                tests.entry(id: "r3", member: "me"),
            ]

            let mine = RoutinesBoardLogic.mine(entries, memberId: "me")

            #expect(mine.map(\.routineId) == ["r1", "r3"])
            #expect(mine.allSatisfy { $0.memberId == "me" })
        }
    }

    @Suite struct Progress {
        private let tests = RoutinesLogicTests()

        @Test func zeroTasksIsZeroNotNaN() {
            #expect(RoutinesBoardLogic.progress(of: tests.entry(tasks: [])) == 0)
        }

        @Test func countsCompletedAndSkippedOverTotal() {
            let entry = tests.entry(tasks: [
                tests.task("t1", status: .completed),
                tests.task("t2", status: .skipped),
                tests.task("t3", status: .open),
                tests.task("t4", status: .open),
            ])
            #expect(RoutinesBoardLogic.progress(of: entry) == 0.5)
        }

        @Test func allOpenIsZero() {
            let entry = tests.entry(tasks: [tests.task("t1"), tests.task("t2")])
            #expect(RoutinesBoardLogic.progress(of: entry) == 0)
        }

        @Test func allDoneIsOne() {
            let entry = tests.entry(tasks: [
                tests.task("t1", status: .completed),
                tests.task("t2", status: .skipped),
            ])
            #expect(RoutinesBoardLogic.progress(of: entry) == 1)
        }
    }

    @Suite struct StreakBadge {
        @Test func hiddenBelowTwo() {
            #expect(!RoutinesBoardLogic.showsStreakBadge(0))
            #expect(!RoutinesBoardLogic.showsStreakBadge(1))
        }

        @Test func shownFromTwoUp() {
            #expect(RoutinesBoardLogic.showsStreakBadge(2))
            #expect(RoutinesBoardLogic.showsStreakBadge(14))
        }
    }

    @Suite struct ManageList {
        private func routine(
            _ id: String,
            title: String = "Routine",
            start: String = "06:00",
            end: String = "12:00",
            sortOrder: Int = 0,
            assignees: [String] = ["m1"]
        ) -> Components.Schemas.Routine {
            Components.Schemas.Routine(
                id: id,
                title: title,
                windowStart: start,
                windowEnd: end,
                assigneeIds: assignees,
                tasks: [],
                sortOrder: sortOrder,
                createdAt: "2026-01-01T00:00:00Z"
            )
        }

        // Admin touch-reorder (sortOrder) is the canonical order (web parity).
        @Test func sortsBySortOrderFirst() {
            let sorted = RoutinesManageLogic.sorted([
                routine("b", start: "05:00", sortOrder: 2),
                routine("a", start: "18:00", sortOrder: 1),
            ])
            #expect(sorted.map(\.id) == ["a", "b"])
        }

        @Test func equalSortOrderFallsBackToWindowTitleId() {
            let sorted = RoutinesManageLogic.sorted([
                routine("late", start: "18:00", end: "21:00"),
                routine("z", title: "Zebra"),
                routine("a2", title: "Aardvark"),
                routine("a1", title: "Aardvark"),
            ])
            #expect(sorted.map(\.id) == ["a1", "a2", "z", "late"])
        }

        @Test func subtitleShowsWindowAndAssigneeCount() {
            #expect(
                RoutinesManageLogic.subtitle(windowStart: "06:00", windowEnd: "12:00", assigneeCount: 2)
                    == "06:00–12:00 · 2 members"
            )
        }

        @Test func singleAssigneeIsSingular() {
            #expect(
                RoutinesManageLogic.subtitle(windowStart: "18:00", windowEnd: "23:59", assigneeCount: 1)
                    == "18:00–23:59 · 1 member"
            )
        }
    }

    @Suite struct ActionResultBridge {
        @Test func entryPayloadMapsFieldAndTaskStatus() {
            let payload = Components.Schemas.RoutineTaskActionResult.EntryPayload(
                routineId: "r1",
                title: "Morning",
                emoji: "🌅",
                windowStart: "06:00",
                windowEnd: "12:00",
                memberId: "me",
                complete: true,
                streak: 3,
                tasks: [
                    .init(taskId: "t1", title: "Brush teeth", emoji: "🪥", starValue: 2, status: .completed),
                    .init(taskId: "t2", title: "Make bed", starValue: 0, status: .skipped),
                ]
            )

            let entry = Components.Schemas.RoutineBoardEntry(payload)

            #expect(entry.routineId == "r1")
            #expect(entry.memberId == "me")
            #expect(entry.complete)
            #expect(entry.streak == 3)
            #expect(entry.tasks.map(\.status) == [.completed, .skipped])
            #expect(entry.tasks.map(\.starValue) == [2, 0])
        }
    }
}
