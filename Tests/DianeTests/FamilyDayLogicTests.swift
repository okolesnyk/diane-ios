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

    @Test func riverPartitionsThePool_CatchUp_AndFlow() {
        let tz = TimeZone(identifier: "UTC")!
        let river = FamilyDayLogic.river(
            events: [],
            chores: [
                chore(id: "pool", owner: nil),
                chore(id: "late", late: true),
                // Done chores stay IN PLACE, crossed and grey (owner
                // 2026-08-07) — a timed one in the flow, an untimed one on
                // the No set time shelf. Nothing folds away.
                chore(id: "done", dueTime: "09:00", status: .completed),
                chore(id: "doneLoose", status: .completed),
                chore(id: "timed", dueTime: "18:00"),
                chore(id: "loose"),
            ],
            selected: ["a"],
            phase: .today,
            minute: "12:00",
            timeZone: tz
        )
        #expect(river.pool.map(\Chore.id) == ["pool"])
        #expect(river.catchUp.map(\Chore.id) == ["late"])
        #expect(river.flowing.map(\.id) == ["ch-done", "ch-timed"])
        #expect(river.noSetTime.map(\Chore.id) == ["doneLoose", "loose"])
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

    @Test func everyEventFlowsAndEndedIsAPureGreyPredicate() {
        let tz = TimeZone(identifier: "UTC")!
        func ev(_ id: String, start: String, end: String) -> MyDayLogic.Event {
            MyDayLogic.Event(
                id: id, eventId: id, calendarId: "c", summary: id, location: nil,
                allDay: false, startsAt: start, endsAt: end,
                startDate: nil, endDate: nil, memberIds: nil
            )
        }
        // Nothing hides any more (owner 2026-08-07): ongoing, just-ended and
        // long-ended all stay in the flow, time-ordered.
        let ongoing = ev("ongoing", start: "2026-08-06T08:00:00.000Z", end: "2026-08-06T13:00:00.000Z")
        let old = ev("old", start: "2026-08-06T11:00:00.000Z", end: "2026-08-06T11:40:00.000Z")
        let river = FamilyDayLogic.river(
            events: [ongoing, old], chores: [], selected: ["a"],
            phase: .today, minute: "12:00", timeZone: tz, today: "2026-08-06"
        )
        #expect(river.flowing.map(\.id) == ["ev-ongoing", "ev-old"])

        // hasEnded drives the grey: ended ⇢ true, ongoing/future ⇢ false.
        #expect(FamilyDayLogic.hasEnded(old, minute: 12 * 60, day: "2026-08-06", timeZone: tz))
        #expect(!FamilyDayLogic.hasEnded(ongoing, minute: 12 * 60, day: "2026-08-06", timeZone: tz))
        // Ends exactly now — that's ended.
        let onTheDot = ev("dot", start: "2026-08-06T11:00:00.000Z", end: "2026-08-06T12:00:00.000Z")
        #expect(FamilyDayLogic.hasEnded(onTheDot, minute: 12 * 60, day: "2026-08-06", timeZone: tz))
        // Ended yesterday relative to the shown day.
        #expect(FamilyDayLogic.hasEnded(old, minute: 0, day: "2026-08-07", timeZone: tz))
        // Runs into tomorrow — not ended today.
        let overnight = ev("late", start: "2026-08-06T22:00:00.000Z", end: "2026-08-07T01:00:00.000Z")
        #expect(!FamilyDayLogic.hasEnded(overnight, minute: 23 * 60, day: "2026-08-06", timeZone: tz))
    }

    @Test func allDayEventsNeverReadAsEnded() {
        let tz = TimeZone(identifier: "UTC")!
        let allDay = MyDayLogic.Event(
            id: "allday", eventId: "e2", calendarId: "c", summary: "allday", location: nil,
            allDay: true, startsAt: nil, endsAt: nil,
            startDate: "2026-08-06", endDate: "2026-08-07", memberIds: nil
        )
        // A missing end reads as an instant event ending at its start.
        let instant = MyDayLogic.Event(
            id: "instant", eventId: "e1", calendarId: "c", summary: "instant", location: nil,
            allDay: false, startsAt: "2026-08-06T08:00:00.000Z", endsAt: nil,
            startDate: nil, endDate: nil, memberIds: nil
        )
        #expect(!FamilyDayLogic.hasEnded(allDay, minute: 23 * 60, day: "2026-08-06", timeZone: tz))
        #expect(FamilyDayLogic.hasEnded(instant, minute: 12 * 60, day: "2026-08-06", timeZone: tz))
    }

    @Test func tintOwnersAndColors() {
        #expect(FamilyDayLogic.owners(of: chore(owner: "a")) == ["a"])
        #expect(FamilyDayLogic.owners(of: chore(owner: nil, claimed: "b")) == ["b"])
        #expect(FamilyDayLogic.owners(of: chore(owner: nil)).isEmpty)
    }
}
