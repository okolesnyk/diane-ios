import Foundation
import Testing
@testable import Diane
import DianeKit

// Page 1 (M9e): the pure math behind My Day.
@Suite struct MyDayLogicTests {
    typealias Chore = MyDayLogic.Chore
    typealias Event = MyDayLogic.Event

    private func chore(
        id: String = "c1",
        owner: String? = "me",
        claimed: String? = nil,
        dueDate: String? = "2026-08-05",
        dueTime: String? = nil,
        late: Bool = false,
        status: Chore.StatusPayload = .open
    ) -> Chore {
        Chore(
            id: id, choreId: "def-\(id)", title: id, emoji: nil, notes: nil,
            starValue: 2, upForGrabs: owner == nil, dueDate: dueDate, dueMode: nil,
            dueTime: dueTime, status: status, late: late,
            assigneeMemberId: owner, claimedByMemberId: claimed,
            completedByMemberId: nil, completedAt: nil
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

    @Test func minenessKeepsMineAndClaimedButDropsTheUnclaimedPool() {
        #expect(MyDayLogic.isMine(chore(owner: "me"), me: "me"))
        #expect(MyDayLogic.isMine(chore(owner: nil, claimed: "me"), me: "me"))
        #expect(!MyDayLogic.isMine(chore(owner: nil), me: "me"))
        #expect(!MyDayLogic.isMine(chore(owner: "sib"), me: "me"))
        // A pool chore someone ELSE claimed is theirs, not mine.
        #expect(!MyDayLogic.isMine(chore(owner: nil, claimed: "sib"), me: "me"))
    }

    @Test func familyEventsAreMine() {
        #expect(MyDayLogic.isMyEvent(event(members: nil), me: "me"))
        #expect(MyDayLogic.isMyEvent(event(members: []), me: "me"))
        #expect(MyDayLogic.isMyEvent(event(members: ["me", "sib"]), me: "me"))
        #expect(!MyDayLogic.isMyEvent(event(members: ["sib"]), me: "me"))
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

    @Test func sectionsPartitionLateTimedAndUntimed() {
        let rows = [
            chore(id: "late", late: true),
            chore(id: "timed", dueTime: "18:00"),
            chore(id: "untimed"),
            chore(id: "anytime", dueDate: nil),
            chore(id: "sibling", owner: "sib", dueTime: "09:00"),
        ]
        let sections = MyDayLogic.sections(rows, me: "me", phase: .today)
        #expect(sections.catchUp.map(\.id) == ["late"])
        #expect(sections.timed.map(\.id) == ["timed"])
        #expect(sections.noSetTime.map(\.id) == ["untimed", "anytime"])
        // Off-today a late row is just the day's record, not a Catch up debt.
        let past = MyDayLogic.sections([chore(id: "late", late: true)], me: "me", phase: .past)
        #expect(past.catchUp.isEmpty)
        #expect(past.noSetTime.map(\.id) == ["late"])
    }

    @Test func timelineMergesAndOrdersEventsWithTimedChores() {
        let tz = TimeZone(identifier: "UTC")!
        let items = MyDayLogic.timeline(
            events: [
                event(id: "lunch", startsAt: "2026-08-05T12:00:00.000Z"),
                event(id: "allday", allDay: true, startsAt: nil, startDate: "2026-08-05", endDate: "2026-08-06"),
            ],
            timedChores: [chore(id: "recycle", dueTime: "09:30")],
            timeZone: tz
        )
        #expect(items.map(\.id) == ["ev-allday", "ch-recycle", "ev-lunch"])
        // The hairline sits after everything ≤ now.
        #expect(MyDayLogic.nowLineIndex(items: items, minute: "10:00", timeZone: tz) == 2)
        #expect(MyDayLogic.nowLineIndex(items: items, minute: "23:59", timeZone: tz) == 3)
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

    @Test func dotsPreviewMyLoad() {
        let tz = TimeZone(identifier: "UTC")!
        let dots = MyDayLogic.dots(
            for: "2026-08-05",
            events: [event()],
            chores: [chore(dueDate: "2026-08-05")],
            me: "me",
            timeZone: tz
        )
        #expect(dots.hasEvents && dots.hasChores)
        let empty = MyDayLogic.dots(for: "2026-08-09", events: [event()], chores: [chore()], me: "me", timeZone: tz)
        #expect(!empty.hasEvents && !empty.hasChores)
    }
}
