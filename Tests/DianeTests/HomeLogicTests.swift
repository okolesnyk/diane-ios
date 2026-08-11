import DianeKit
import Foundation
import Testing
@testable import Diane

// The Home tiles' pulse: one count line per module, filter-aware, quiet
// doors when there is nothing to count (design doc rev 5, 2026-08-10).
@Suite struct HomeLogicTests {
    private let utc = TimeZone(identifier: "UTC")!

    private func event(
        id: String,
        start: String? = nil,
        allDay: Bool = false,
        startDate: String? = nil,
        endDate: String? = nil,
        memberIds: [String]? = nil
    ) -> DayLogic.Event {
        Components.Schemas.EventOccurrence(
            id: id, eventId: "e-\(id)", calendarId: "cal", summary: id, location: nil,
            allDay: allDay, startsAt: start.map { "\($0):00.000Z" }, endsAt: nil,
            startDate: startDate, endDate: endDate, memberIds: memberIds
        )
    }

    private func chore(
        id: String = "c1",
        choreId: String? = nil,
        owner: String? = "a",
        dueDate: String? = "2026-08-10",
        dueTime: String? = nil,
        late: Bool = false,
        status: DayLogic.Chore.StatusPayload = .open
    ) -> DayLogic.Chore {
        DayLogic.Chore(
            id: id, choreId: choreId ?? "def-\(id)", title: id, emoji: nil, notes: nil,
            starValue: 1, upForGrabs: owner == nil, dueDate: dueDate, dueMode: nil,
            dueTime: dueTime, status: status, late: late,
            assigneeMemberId: owner, claimedByMemberId: nil,
            completedByMemberId: nil, completedAt: nil
        )
    }

    private func entry(
        member: String,
        windowStart: String = "06:00",
        windowEnd: String = "12:00",
        open: Int,
        done: Int = 0
    ) -> Components.Schemas.RoutineBoardEntry {
        Components.Schemas.RoutineBoardEntry(
            routineId: "r-\(member)", title: "Routine", emoji: nil,
            windowStart: windowStart, windowEnd: windowEnd, memberId: member,
            complete: open == 0, streak: 0,
            tasks: (0..<open).map { .init(taskId: "o\($0)", title: "t", starValue: 0, status: .open) }
                + (0..<done).map { .init(taskId: "d\($0)", title: "t", starValue: 0, status: .completed) }
        )
    }

    // MARK: Calendar — "N today", filter-aware, family events always count

    @Test func calendarCountsOnlyTodayThroughTheFilter() {
        let events = [
            event(id: "family", start: "2026-08-10T09:00"),                 // no members = family
            event(id: "mine", start: "2026-08-10T14:00", memberIds: ["a"]),
            event(id: "hers", start: "2026-08-10T15:00", memberIds: ["b"]),
            event(id: "tomorrow", start: "2026-08-11T09:00"),
            event(id: "span", allDay: true, startDate: "2026-08-09", endDate: "2026-08-12"),
        ]
        let everyone = HomeLogic.calendarLine(
            events: events, today: "2026-08-10", timeZone: utc, selected: ["a", "b"]
        )
        #expect(everyone == HomeLogic.Line(count: "4 today"))
        // Filtered to a: b's event drops, family rows and the spanning
        // all-day stay.
        let justA = HomeLogic.calendarLine(
            events: events, today: "2026-08-10", timeZone: utc, selected: ["a"]
        )
        #expect(justA == HomeLogic.Line(count: "3 today"))
    }

    @Test func calendarWithNothingTodayIsAQuietDoor() {
        let line = HomeLogic.calendarLine(
            events: [event(id: "tomorrow", start: "2026-08-11T09:00")],
            today: "2026-08-10", timeZone: utc, selected: ["a"]
        )
        #expect(line == nil)
    }

    // MARK: Chores — rows fold like the Chores page; dot mirrors "late"

    @Test func choresCountRowsNotOccurrences() {
        // A shared chore (two occurrences, same chore + date) is ONE row.
        let line = HomeLogic.choresLine(
            chores: [
                chore(id: "s1", choreId: "shared", owner: "a"),
                chore(id: "s2", choreId: "shared", owner: "b"),
                chore(id: "solo", owner: "a"),
                chore(id: "done", owner: "a", status: .completed),
            ],
            today: "2026-08-10", minute: "09:00", selected: ["a", "b"]
        )
        #expect(line == HomeLogic.Line(count: "2 open"))
    }

    @Test func choresLatePartUsesTheDisplayTwin() {
        let line = HomeLogic.choresLine(
            chores: [
                chore(id: "flagged", late: true),
                // Timed today, past due + grace at 18:20 — late by the twin.
                chore(id: "timed", dueTime: "18:00"),
                chore(id: "fine"),
            ],
            today: "2026-08-10", minute: "18:20", selected: ["a"]
        )
        #expect(line == HomeLogic.Line(count: "3 open", late: "2 late"))
        var pulse = HomeLogic.Pulse()
        pulse.chores = line
        #expect(pulse.showsDot(for: .chores))
        #expect(!pulse.showsDot(for: .calendar))
    }

    @Test func choresPoolRowsCountForEveryoneAndFilteredOwnersDrop() {
        let line = HomeLogic.choresLine(
            chores: [chore(id: "pool", owner: nil), chore(id: "hers", owner: "b")],
            today: "2026-08-10", minute: "09:00", selected: ["a"]
        )
        #expect(line == HomeLogic.Line(count: "1 open"))
    }

    @Test func choresAllDoneIsAQuietDoor() {
        let line = HomeLogic.choresLine(
            chores: [chore(id: "done", status: .completed)],
            today: "2026-08-10", minute: "09:00", selected: ["a"]
        )
        #expect(line == nil)
    }

    // MARK: Routines — running windows only, summed across the family

    @Test func routinesSumOpenTasksAcrossRunningWindows() {
        let board = [
            entry(member: "a", open: 2, done: 1),
            entry(member: "b", open: 1),
            entry(member: "a", windowStart: "18:00", windowEnd: "21:00", open: 5),
        ]
        let line = HomeLogic.routinesLine(board: board, minute: "09:30", selected: ["a", "b"])
        #expect(line == HomeLogic.Line(count: "3 left"))
        // The evening window isn't running at 09:30; at 18:00 it is (start
        // inclusive) and the morning ones are over (end exclusive covers
        // 12:00 exactly).
        let evening = HomeLogic.routinesLine(board: board, minute: "18:00", selected: ["a", "b"])
        #expect(evening == HomeLogic.Line(count: "5 left"))
        let noon = HomeLogic.routinesLine(board: board, minute: "12:00", selected: ["a", "b"])
        #expect(noon == nil)
    }

    @Test func routinesFollowTheFilterAndGoQuietWhenDone() {
        let board = [entry(member: "a", open: 2), entry(member: "b", open: 1)]
        let justB = HomeLogic.routinesLine(board: board, minute: "09:30", selected: ["b"])
        #expect(justB == HomeLogic.Line(count: "1 left"))
        let done = HomeLogic.routinesLine(
            board: [entry(member: "a", open: 0, done: 3)], minute: "09:30", selected: ["a"]
        )
        #expect(done == nil)
    }

    // MARK: Rewards — a household count, quiet at zero

    @Test func rewardsCountWaitingOrStayQuiet() {
        #expect(HomeLogic.rewardsLine(waiting: 2) == HomeLogic.Line(count: "2 waiting"))
        #expect(HomeLogic.rewardsLine(waiting: 0) == nil)
    }

    // MARK: The assembled pulse

    @Test func pulseAssemblesAllFourLines() {
        var snapshot = HomeLogic.Snapshot()
        snapshot.events = [event(id: "one", start: "2026-08-10T09:00")]
        snapshot.chores = [chore(id: "open")]
        snapshot.board = [entry(member: "a", open: 1)]
        snapshot.waiting = 1
        snapshot.memberIds = ["a"]
        let pulse = HomeLogic.pulse(
            snapshot, today: "2026-08-10", minute: "09:00", timeZone: utc, selected: ["a"]
        )
        #expect(pulse.line(for: .calendar) == HomeLogic.Line(count: "1 today"))
        #expect(pulse.line(for: .chores) == HomeLogic.Line(count: "1 open"))
        #expect(pulse.line(for: .routines) == HomeLogic.Line(count: "1 left"))
        #expect(pulse.line(for: .rewards) == HomeLogic.Line(count: "1 waiting"))
    }
}
