import Foundation
import Testing
@testable import Diane

// The Today page (born Family Day): the river and chip math.
@Suite struct TodayLogicTests {
    typealias Chore = DayLogic.Chore

    private func chore(
        id: String = "c1",
        owner: String? = "a",
        claimed: String? = nil,
        dueDate: String? = "2026-08-06",
        dueTime: String? = nil,
        late: Bool = false,
        status: Chore.StatusPayload = .open,
        completedAt: String? = nil
    ) -> Chore {
        Chore(
            id: id, choreId: "def-\(id)", title: id, emoji: nil, notes: nil,
            starValue: 1, upForGrabs: owner == nil, dueDate: dueDate, dueMode: nil,
            dueTime: dueTime, status: status, late: late,
            assigneeMemberId: owner, claimedByMemberId: claimed,
            completedByMemberId: nil, completedAt: completedAt
        )
    }

    @Test func chipProgressAndLateDot() {
        let rows = [
            chore(id: "1", status: .completed),
            chore(id: "2"),
            chore(id: "3", late: true),
            chore(id: "sib", owner: "b", status: .completed),
        ]
        let chip = TodayLogic.chip(for: "a", chores: rows)
        #expect(abs(chip.progress - 1.0 / 3.0) < 0.001)
        #expect(chip.hasLate)
        // No chores → empty ring, no dot.
        let idle = TodayLogic.chip(for: "x", chores: rows)
        #expect(idle.progress == 0 && !idle.hasLate)
    }

    @Test func filterToggleCollapsesToEveryone() {
        let all = ["a", "b", "c"]
        var set = TodayLogic.toggledFilter(Set(all), all: all, tapping: "a")
        #expect(set == ["b", "c"])
        set = TodayLogic.toggledFilter(set, all: all, tapping: "b")
        #expect(set == ["c"])
        // Removing the last member means everyone again.
        set = TodayLogic.toggledFilter(["c"], all: all, tapping: "c")
        #expect(set == Set(all))
    }

    @Test func riverPartitionsCatchUp_Flow_AndDueToday() {
        let tz = TimeZone(identifier: "UTC")!
        let river = TodayLogic.river(
            events: [],
            chores: [
                chore(id: "pool", owner: nil),
                chore(id: "late", late: true),
                // Done chores stay IN PLACE, crossed and grey (owner
                // 2026-08-07) — a timed one in the flow, an untimed one on
                // the Due today shelf. Nothing folds away.
                chore(id: "done", dueTime: "09:00", status: .completed),
                chore(id: "doneLoose", status: .completed),
                chore(id: "timed", dueTime: "18:00"),
                chore(id: "loose"),
            ],
            selected: ["a"],
            phase: .today,
            minute: "12:00",
            timeZone: tz,
            today: "2026-08-06",
            day: "2026-08-06"
        )
        #expect(river.catchUp.map(\.id) == ["late"])
        #expect(river.flowing.map(\.id) == ["ch-done", "ch-timed"])
        // The dated pool row sits at the BOTTOM of Due today (owner
        // 2026-08-09 — the standalone Up for grabs shelf is gone).
        #expect(river.dueToday.map(\.id) == ["doneLoose", "loose", "pool"])
    }

    /// Owner 2026-08-09: the pool spreads by date and time — late is
    /// everyone's debt, timed joins the timeline, dated lands on Due today,
    /// undated at the bottom of Anytime — and stays filter-immune throughout.
    @Test func poolSpreadsByDateAndTime() {
        let tz = TimeZone(identifier: "UTC")!
        let chores = [
            chore(id: "own-late", late: true),
            chore(id: "pool-late", owner: nil, late: true),
            chore(id: "pool-timed", owner: nil, dueTime: "17:00"),
            chore(id: "own-dated"),
            chore(id: "pool-dated", owner: nil),
            chore(id: "own-any", dueDate: nil),
            chore(id: "pool-any", owner: nil, dueDate: nil),
        ]
        let river = TodayLogic.river(
            events: [], chores: chores,
            selected: ["a"],
            phase: .today, minute: "12:00", timeZone: tz,
            today: "2026-08-06", day: "2026-08-06"
        )
        #expect(river.catchUp.map(\.id) == ["own-late", "pool-late"])
        #expect(river.flowing.map(\.id) == ["ch-pool-timed"])
        #expect(river.dueToday.map(\.id) == ["own-dated", "pool-dated"])
        #expect(river.anytime.map(\.id) == ["own-any", "pool-any"])

        // Filter down to a member with nothing — the pool stays put.
        let filtered = TodayLogic.river(
            events: [], chores: chores,
            selected: ["nobody"],
            phase: .today, minute: "12:00", timeZone: tz,
            today: "2026-08-06", day: "2026-08-06"
        )
        #expect(filtered.catchUp.map(\.id) == ["pool-late"])
        #expect(filtered.flowing.map(\.id) == ["ch-pool-timed"])
        #expect(filtered.dueToday.map(\.id) == ["pool-dated"])
        #expect(filtered.anytime.map(\.id) == ["pool-any"])
    }

    /// Owner 2026-08-09: a checked late row STAYS in Catch Up as a late ✓ —
    /// via the server's flag or the completedAt display twin.
    @Test func lateDoneRowStaysInCatchUp() {
        let tz = TimeZone(identifier: "UTC")!
        let river = TodayLogic.river(
            events: [],
            chores: [
                chore(id: "flagged", late: true, status: .completed),
                chore(id: "twin", status: .completed, completedAt: "2026-08-07T10:00:00.000Z"),
                chore(id: "on-time", status: .completed, completedAt: "2026-08-06T10:00:00.000Z"),
            ],
            selected: ["a"],
            phase: .today,
            minute: "12:00",
            timeZone: tz,
            today: "2026-08-07",
            day: "2026-08-06"
        )
        #expect(river.catchUp.map(\.id) == ["flagged", "twin"])
        #expect(river.dueToday.map(\.id) == ["on-time"])
    }

    @Test func poolIsImmuneToTheFilterButClaimedRowsAreNot() {
        let tz = TimeZone(identifier: "UTC")!
        let river = TodayLogic.river(
            events: [],
            chores: [
                chore(id: "pool", owner: nil),
                chore(id: "claimed", owner: nil, claimed: "b"),
            ],
            selected: ["a"],
            phase: .today,
            minute: "12:00",
            timeZone: tz,
            today: "2026-08-06",
            day: "2026-08-06"
        )
        #expect(river.dueToday.map(\.id) == ["pool"])
        // b's claimed row is filtered out while only a is selected.
        #expect(river.flowing.isEmpty && river.anytime.isEmpty && river.catchUp.isEmpty)
    }

    @Test func everyEventFlowsAndEndedIsAPureGreyPredicate() {
        let tz = TimeZone(identifier: "UTC")!
        func ev(_ id: String, start: String, end: String) -> DayLogic.Event {
            DayLogic.Event(
                id: id, eventId: id, calendarId: "c", summary: id, location: nil,
                allDay: false, startsAt: start, endsAt: end,
                startDate: nil, endDate: nil, memberIds: nil
            )
        }
        // Nothing hides any more (owner 2026-08-07): ongoing, just-ended and
        // long-ended all stay in the flow, time-ordered.
        let ongoing = ev("ongoing", start: "2026-08-06T08:00:00.000Z", end: "2026-08-06T13:00:00.000Z")
        let old = ev("old", start: "2026-08-06T11:00:00.000Z", end: "2026-08-06T11:40:00.000Z")
        let river = TodayLogic.river(
            events: [ongoing, old], chores: [], selected: ["a"],
            phase: .today, minute: "12:00", timeZone: tz, today: "2026-08-06"
        )
        #expect(river.flowing.map(\.id) == ["ev-ongoing", "ev-old"])

        // hasEnded drives the grey: ended ⇢ true, ongoing/future ⇢ false.
        #expect(TodayLogic.hasEnded(old, minute: 12 * 60, day: "2026-08-06", timeZone: tz))
        #expect(!TodayLogic.hasEnded(ongoing, minute: 12 * 60, day: "2026-08-06", timeZone: tz))
        // Ends exactly now — that's ended.
        let onTheDot = ev("dot", start: "2026-08-06T11:00:00.000Z", end: "2026-08-06T12:00:00.000Z")
        #expect(TodayLogic.hasEnded(onTheDot, minute: 12 * 60, day: "2026-08-06", timeZone: tz))
        // Ended yesterday relative to the shown day.
        #expect(TodayLogic.hasEnded(old, minute: 0, day: "2026-08-07", timeZone: tz))
        // Runs into tomorrow — not ended today.
        let overnight = ev("late", start: "2026-08-06T22:00:00.000Z", end: "2026-08-07T01:00:00.000Z")
        #expect(!TodayLogic.hasEnded(overnight, minute: 23 * 60, day: "2026-08-06", timeZone: tz))
    }

    /// Owner 2026-08-08: a shared chore is ONE river row — the engine's
    /// per-assignee occurrences fold back together, like the Chores module.
    @Test func sharedChoresAggregateIntoOneRiverRow() {
        let tz = TimeZone(identifier: "UTC")!
        func occurrence(_ id: String, owner: String, status: Chore.StatusPayload = .open) -> Chore {
            Chore(
                id: id, choreId: "shared", title: "Test", emoji: nil, notes: nil,
                starValue: 1, upForGrabs: false, dueDate: "2026-08-08", dueMode: nil,
                dueTime: "22:00", status: status, late: false,
                assigneeMemberId: owner, claimedByMemberId: nil,
                completedByMemberId: status == .completed ? owner : nil, completedAt: nil
            )
        }
        let river = TodayLogic.river(
            events: [],
            chores: [occurrence("t|a", owner: "a"), occurrence("t|b", owner: "b"), occurrence("t|c", owner: "c")],
            selected: ["a", "b", "c"],
            phase: .today, minute: "12:00", timeZone: tz,
            today: "2026-08-08", day: "2026-08-08"
        )
        #expect(river.flowing.count == 1)
        guard case .chores(let row) = river.flowing[0] else {
            Issue.record("expected a chore row"); return
        }
        #expect(Set(row.owners) == ["a", "b", "c"])
        #expect(!row.completed)

        // Half-done stays ONE open row; it survives any owner's filter.
        let half = TodayLogic.river(
            events: [],
            chores: [occurrence("t|a", owner: "a", status: .completed), occurrence("t|b", owner: "b")],
            selected: ["b"],
            phase: .today, minute: "12:00", timeZone: tz,
            today: "2026-08-08", day: "2026-08-08"
        )
        #expect(half.flowing.count == 1)
        guard case .chores(let halfRow) = half.flowing[0] else {
            Issue.record("expected a chore row"); return
        }
        #expect(!halfRow.completed)
    }

    @Test func allDayEventsNeverReadAsEnded() {
        let tz = TimeZone(identifier: "UTC")!
        let allDay = DayLogic.Event(
            id: "allday", eventId: "e2", calendarId: "c", summary: "allday", location: nil,
            allDay: true, startsAt: nil, endsAt: nil,
            startDate: "2026-08-06", endDate: "2026-08-07", memberIds: nil
        )
        // A missing end reads as an instant event ending at its start.
        let instant = DayLogic.Event(
            id: "instant", eventId: "e1", calendarId: "c", summary: "instant", location: nil,
            allDay: false, startsAt: "2026-08-06T08:00:00.000Z", endsAt: nil,
            startDate: nil, endDate: nil, memberIds: nil
        )
        #expect(!TodayLogic.hasEnded(allDay, minute: 23 * 60, day: "2026-08-06", timeZone: tz))
        #expect(TodayLogic.hasEnded(instant, minute: 12 * 60, day: "2026-08-06", timeZone: tz))
    }

    @Test func tintOwnersAndColors() {
        #expect(TodayLogic.owners(of: chore(owner: "a")) == ["a"])
        #expect(TodayLogic.owners(of: chore(owner: nil, claimed: "b")) == ["b"])
        #expect(TodayLogic.owners(of: chore(owner: nil)).isEmpty)
    }
}
