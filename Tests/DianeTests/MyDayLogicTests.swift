import Foundation
import Testing
@testable import Diane
import DianeKit

// The day pages' shared math (My Day itself retired owner 2026-08-10).
@Suite struct MyDayLogicTests {
    typealias Chore = MyDayLogic.Chore
    typealias Event = MyDayLogic.Event

    private func chore(
        id: String = "c1",
        choreId: String? = nil,
        owner: String? = "me",
        claimed: String? = nil,
        dueDate: String? = "2026-08-05",
        dueMode: Chore.DueModePayload? = nil,
        dueTime: String? = nil,
        late: Bool = false,
        status: Chore.StatusPayload = .open,
        completedAt: String? = nil
    ) -> Chore {
        Chore(
            id: id, choreId: choreId ?? "def-\(id)", title: id, emoji: nil, notes: nil,
            starValue: 2, upForGrabs: owner == nil, dueDate: dueDate, dueMode: dueMode,
            dueTime: dueTime, status: status, late: late,
            assigneeMemberId: owner, claimedByMemberId: claimed,
            completedByMemberId: nil, completedAt: completedAt
        )
    }

    private func event(
        id: String = "e1",
        members: [String]? = nil,
        allDay: Bool = false,
        startsAt: String? = "2026-08-05T14:30:00.000Z",
        startDate: String? = nil,
        endDate: String? = nil,
        calendarId: String = "cal-home"
    ) -> Event {
        Event(
            id: id, eventId: "ev-\(id)", calendarId: calendarId, summary: id,
            location: nil, allDay: allDay, startsAt: startsAt,
            endsAt: startsAt, startDate: startDate, endDate: endDate, memberIds: members
        )
    }

    @Test func dateMathAndPhases() {
        #expect(MyDayLogic.addDays("2026-08-05", 1) == "2026-08-06")
        #expect(MyDayLogic.addDays("2026-08-31", 1) == "2026-09-01")
        #expect(MyDayLogic.addDays("2026-08-01", -1) == "2026-07-31")
        #expect(MyDayLogic.phase(of: "2026-08-04", today: "2026-08-05") == .past)
        #expect(MyDayLogic.phase(of: "2026-08-05", today: "2026-08-05") == .today)
        #expect(MyDayLogic.phase(of: "2026-08-06", today: "2026-08-05") == .future)
    }

    @Test func stripIsTheWeekContainingTheSelection() {
        // Sunday-start: the week of Wed Aug 5 2026 runs Aug 2…Aug 8.
        let sunday = MyDayLogic.weekDays(containing: "2026-08-05", firstWeekday: 1)
        #expect(sunday.map(\.date).first == "2026-08-02")
        #expect(sunday.map(\.date).last == "2026-08-08")
        // Monday-start shifts the same week to Aug 3…Aug 9.
        let monday = MyDayLogic.weekDays(containing: "2026-08-05", firstWeekday: 2)
        #expect(monday.map(\.date).first == "2026-08-03")
        #expect(monday.map(\.date).last == "2026-08-09")
        // Picking another day IN the week keeps the same seven days.
        #expect(MyDayLogic.weekDays(containing: "2026-08-08", firstWeekday: 1).map(\.date)
            == sunday.map(\.date))
    }

    @Test func fetchRangeCoversTheWeekPlusAPageEitherSide() {
        let range = MyDayLogic.fetchRange(centeredOn: "2026-08-05")
        #expect(range.from < "2026-08-02")
        #expect(range.to > "2026-08-08")
    }

    @Test func allDayEventsSpanEndExclusive() {
        let tz = TimeZone(identifier: "Europe/Warsaw")!
        let stay = event(allDay: true, startsAt: nil, startDate: "2026-08-05", endDate: "2026-08-07")
        #expect(MyDayLogic.onDay(stay, date: "2026-08-05", timeZone: tz))
        #expect(MyDayLogic.onDay(stay, date: "2026-08-06", timeZone: tz))
        #expect(!MyDayLogic.onDay(stay, date: "2026-08-07", timeZone: tz))
        // A timed event localizes: 23:30Z on Aug 5 is Aug 6 in Warsaw (+2).
        let lateNight = event(startsAt: "2026-08-05T23:30:00.000Z")
        #expect(!MyDayLogic.onDay(lateNight, date: "2026-08-05", timeZone: tz))
        #expect(MyDayLogic.onDay(lateNight, date: "2026-08-06", timeZone: tz))
    }

    /// Owner 2026-08-10: another year's due date carries its year — "Aug 11"
    /// alone could be next year's.
    @Test func dueOriginNamesTheYearWhenItDiffers() {
        let nextYear = chore(id: "ny", dueDate: "2027-08-11")
        #expect(MyDayLogic.dueOrigin(nextYear, today: "2026-08-10") == "due Wed, Aug 11, 2027")
        let sameYear = chore(id: "sy", dueDate: "2026-08-15")
        #expect(MyDayLogic.dueOrigin(sameYear, today: "2026-08-10") == "due Sat, Aug 15")
    }

    /// Owner 2026-08-09: a checked late chore reads as a truthful late-done
    /// — checked after its due day, or past its own-day time + grace.
    @Test func lateWhenDoneReadsTheCatchUpCheck() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(MyDayLogic.lateWhenDone(
            chore(id: "was-late", dueDate: "2026-08-04", status: .completed,
                  completedAt: "2026-08-05T10:00:00.000Z"), timeZone: utc))
        #expect(MyDayLogic.lateWhenDone(
            chore(id: "t-late", dueTime: "08:00", status: .completed,
                  completedAt: "2026-08-05T08:20:00.000Z"), timeZone: utc))
        #expect(!MyDayLogic.lateWhenDone(
            chore(id: "on-time", status: .completed,
                  completedAt: "2026-08-05T09:00:00.000Z"), timeZone: utc))
        #expect(!MyDayLogic.lateWhenDone(
            chore(id: "t-ok", dueTime: "08:00", status: .completed,
                  completedAt: "2026-08-05T08:10:00.000Z"), timeZone: utc))
        // The server's flag alone suffices once the api carries it.
        let flagged = chore(id: "flagged", dueDate: "2026-08-04", late: true, status: .completed)
        #expect(MyDayLogic.lateWhenDone(flagged, timeZone: utc))
    }

    @Test func railFollowsTheSourceCalendar() {
        let calendars = [
            Components.Schemas.Calendar(
                id: "cal-home", accountId: nil, ownerMemberId: nil, displayName: "Home",
                color: "#34c759", providerColor: nil, memberId: nil, enabled: true,
                writable: true, lastSyncAt: nil, lastSyncError: nil, eventCount: 0,
                createdAt: "2026-01-01T00:00:00.000Z"
            )
        ]
        #expect(MyDayLogic.railColorHex(for: event(calendarId: "cal-home"), calendars: calendars) == "#34c759")
        #expect(MyDayLogic.railColorHex(for: event(calendarId: "cal-x"), calendars: calendars) == nil)
    }

    /// Owner 2026-08-08: a strip swipe lands on the day NEAREST to where
    /// you came from — next week's first day, previous week's last.
    @Test func stripPagingLandsOnTheNearestEdgeDay() {
        // Monday-start week containing Thu Aug 6: Mon 3 … Sun 9.
        #expect(MyDayLogic.pagedStripTarget(from: "2026-08-06", forward: true, firstWeekday: 2) == "2026-08-10")
        #expect(MyDayLogic.pagedStripTarget(from: "2026-08-06", forward: false, firstWeekday: 2) == "2026-08-02")
        // Sunday-start week: Sun 2 … Sat 8.
        #expect(MyDayLogic.pagedStripTarget(from: "2026-08-06", forward: true, firstWeekday: 1) == "2026-08-09")
        #expect(MyDayLogic.pagedStripTarget(from: "2026-08-06", forward: false, firstWeekday: 1) == "2026-08-01")
    }

    /// Owner 2026-08-08: a timed chore reads LATE 15 min past its at/due
    /// time on its own day — the display twin of the server rule.
    @Test func gracedLatenessIsTheDisplayTwin() {
        let timed = chore(id: "t", dueDate: "2026-08-08", dueTime: "22:00")
        #expect(!MyDayLogic.effectivelyLate(timed, today: "2026-08-08", minute: "22:14"))
        #expect(MyDayLogic.effectivelyLate(timed, today: "2026-08-08", minute: "22:15"))
        // Another day's deadline never trips on today's clock.
        let later = chore(id: "l", dueDate: "2026-08-15", dueMode: .by, dueTime: "22:00")
        #expect(!MyDayLogic.effectivelyLate(later, today: "2026-08-08", minute: "23:00"))
        // Completed rows are never late; server-late passes straight through.
        let done = chore(id: "d", dueDate: "2026-08-08", dueTime: "22:00", status: .completed)
        #expect(!MyDayLogic.effectivelyLate(done, today: "2026-08-08", minute: "23:00"))
    }

    // MARK: - The future routine board (scheduled reality from definitions)

    private func routine(
        id: String = "r1",
        byWeekday: [String]? = nil,
        assignees: [String] = ["me"],
        tasks: [(String, Int)] = [("Brush teeth", 1)]
    ) -> Components.Schemas.Routine {
        .init(
            id: id,
            title: "Routine \(id)",
            emoji: nil,
            windowStart: "07:00",
            windowEnd: "09:00",
            byWeekday: byWeekday?.compactMap { .init(rawValue: $0) },
            assigneeIds: assignees,
            tasks: tasks.enumerated().map { index, task in
                .init(id: "t\(index)", title: task.0, emoji: nil, starValue: task.1, sortOrder: index)
            },
            sortOrder: 0,
            createdAt: "2026-01-01T00:00:00.000Z"
        )
    }

    @Test func weekdayCodesMatchTheServer() {
        #expect(MyDayLogic.weekdayCode(of: "2026-08-07") == "fr")
        #expect(MyDayLogic.weekdayCode(of: "2026-08-08") == "sa")
        #expect(MyDayLogic.weekdayCode(of: "2026-08-09") == "su")
        #expect(MyDayLogic.weekdayCode(of: "garbage") == nil)
    }

    @Test func futureBoardFollowsTheSchedule() {
        let routines = [
            routine(id: "daily", byWeekday: nil),
            routine(id: "weekend", byWeekday: ["sa", "su"]),
            routine(id: "weekday", byWeekday: ["mo", "tu", "we", "th", "fr"]),
        ]
        // Saturday: daily + weekend, never the weekday one.
        let saturday = MyDayLogic.futureBoard(routines: routines, day: "2026-08-08")
        #expect(saturday.map(\.routineId) == ["daily", "weekend"])
        // Friday: daily + weekday.
        let friday = MyDayLogic.futureBoard(routines: routines, day: "2026-08-07")
        #expect(friday.map(\.routineId) == ["daily", "weekday"])
    }

    @Test func futureBoardFansOutPerAssigneeAllOpen() {
        let entries = MyDayLogic.futureBoard(
            routines: [routine(assignees: ["kid", "me"], tasks: [("B", 2), ("A", 1)])],
            day: "2026-08-08"
        )
        #expect(entries.map(\.memberId) == ["kid", "me"])
        for entry in entries {
            #expect(!entry.complete)
            #expect(entry.streak == 0)
            // Task order is the definition's sortOrder.
            #expect(entry.tasks.map(\.title) == ["B", "A"])
            #expect(entry.tasks.allSatisfy { $0.status == .open })
        }
    }
}
