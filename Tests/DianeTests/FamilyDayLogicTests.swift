import Foundation
import Testing
@testable import Diane

// Page 2 (M9e): the pure math behind Family Day.
@Suite struct FamilyDayLogicTests {
    typealias Chore = MyDayLogic.Chore

    private func chore(
        id: String = "c1",
        owner: String? = "a",
        claimed: String? = nil,
        dueTime: String? = nil,
        late: Bool = false,
        status: Chore.StatusPayload = .open
    ) -> Chore {
        Chore(
            id: id, choreId: "def-\(id)", title: id, emoji: nil, notes: nil,
            starValue: 1, upForGrabs: owner == nil, dueDate: "2026-08-06", dueMode: nil,
            dueTime: dueTime, status: status, late: late,
            assigneeMemberId: owner, claimedByMemberId: claimed,
            completedByMemberId: nil, completedAt: nil
        )
    }

    @Test func chipProgressAndLateDot() {
        let rows = [
            chore(id: "1", status: .completed),
            chore(id: "2"),
            chore(id: "3", late: true),
            chore(id: "sib", owner: "b", status: .completed),
        ]
        let chip = FamilyDayLogic.chip(for: "a", chores: rows)
        #expect(abs(chip.progress - 1.0 / 3.0) < 0.001)
        #expect(chip.hasLate)
        // No chores → empty ring, no dot.
        let idle = FamilyDayLogic.chip(for: "x", chores: rows)
        #expect(idle.progress == 0 && !idle.hasLate)
    }

    @Test func filterToggleCollapsesToEveryone() {
        let all = ["a", "b", "c"]
        var set = FamilyDayLogic.toggledFilter(Set(all), all: all, tapping: "a")
        #expect(set == ["b", "c"])
        set = FamilyDayLogic.toggledFilter(set, all: all, tapping: "b")
        #expect(set == ["c"])
        // Removing the last member means everyone again.
        set = FamilyDayLogic.toggledFilter(["c"], all: all, tapping: "c")
        #expect(set == Set(all))
    }

    @Test func riverPartitionsThePool_CatchUp_Fold_AndFlow() {
        let tz = TimeZone(identifier: "UTC")!
        let river = FamilyDayLogic.river(
            events: [],
            chores: [
                chore(id: "pool", owner: nil),
                chore(id: "late", late: true),
                chore(id: "done", status: .completed),
                chore(id: "timed", dueTime: "18:00"),
                chore(id: "loose"),
            ],
            selected: ["a"],
            phase: .today,
            minute: "12:00",
            timeZone: tz
        )
        #expect(river.pool.map(\.id) == ["pool"])
        #expect(river.catchUp.map(\.id) == ["late"])
        #expect(river.folded.map(\.id) == ["ch-done"])
        #expect(river.flowing.map(\.id) == ["ch-timed"])
        #expect(river.noSetTime.map(\.id) == ["loose"])
    }

    @Test func poolIsImmuneToTheFilterButClaimedRowsAreNot() {
        let tz = TimeZone(identifier: "UTC")!
        let river = FamilyDayLogic.river(
            events: [],
            chores: [
                chore(id: "pool", owner: nil),
                chore(id: "claimed", owner: nil, claimed: "b"),
            ],
            selected: ["a"],
            phase: .today,
            minute: "12:00",
            timeZone: tz
        )
        #expect(river.pool.map(\.id) == ["pool"])
        // b's claimed row is filtered out while only a is selected.
        #expect(river.flowing.isEmpty && river.noSetTime.isEmpty)
    }

    @Test func ongoingEventsNeverFoldAndGraceIs15Minutes() {
        let tz = TimeZone(identifier: "UTC")!
        func ev(_ id: String, start: String, end: String) -> MyDayLogic.Event {
            MyDayLogic.Event(
                id: id, eventId: id, calendarId: "c", summary: id, location: nil,
                allDay: false, startsAt: start, endsAt: end,
                startDate: nil, endDate: nil, memberIds: nil
            )
        }
        // Started 08:00, ends 13:00 — at 12:00 it is ONGOING: stays flowing.
        let ongoing = ev("ongoing", start: "2026-08-06T08:00:00.000Z", end: "2026-08-06T13:00:00.000Z")
        // Ended 11:50 — at 12:00 it is inside the 15-min grace: stays.
        let justEnded = ev("justEnded", start: "2026-08-06T11:00:00.000Z", end: "2026-08-06T11:50:00.000Z")
        // Ended 11:40 — 15+ min ago: folds.
        let old = ev("old", start: "2026-08-06T11:00:00.000Z", end: "2026-08-06T11:40:00.000Z")
        let river = FamilyDayLogic.river(
            events: [ongoing, justEnded, old], chores: [], selected: ["a"],
            phase: .today, minute: "12:00", timeZone: tz, today: "2026-08-06"
        )
        #expect(river.flowing.map(\.id).sorted() == ["ev-justEnded", "ev-ongoing"])
        #expect(river.folded.map(\.id) == ["ev-old"])
    }

    @Test func todayFoldsPastTimedEventsButNeverAllDay() {
        let tz = TimeZone(identifier: "UTC")!
        let past = MyDayLogic.Event(
            id: "past", eventId: "e1", calendarId: "c", summary: "past", location: nil,
            allDay: false, startsAt: "2026-08-06T08:00:00.000Z", endsAt: nil,
            startDate: nil, endDate: nil, memberIds: nil
        )
        let allDay = MyDayLogic.Event(
            id: "allday", eventId: "e2", calendarId: "c", summary: "allday", location: nil,
            allDay: true, startsAt: nil, endsAt: nil,
            startDate: "2026-08-06", endDate: "2026-08-07", memberIds: nil
        )
        let river = FamilyDayLogic.river(
            events: [past, allDay], chores: [], selected: ["a"],
            phase: .today, minute: "12:00", timeZone: tz, today: "2026-08-06"
        )
        #expect(river.folded.map(\.id) == ["ev-past"])
        #expect(river.flowing.map(\.id) == ["ev-allday"])
    }

    @Test func tintOwnersAndColors() {
        #expect(FamilyDayLogic.owners(of: chore(owner: "a")) == ["a"])
        #expect(FamilyDayLogic.owners(of: chore(owner: nil, claimed: "b")) == ["b"])
        #expect(FamilyDayLogic.owners(of: chore(owner: nil)).isEmpty)
    }
}
