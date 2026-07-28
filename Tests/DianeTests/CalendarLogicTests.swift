import DianeKit
import Foundation
import Testing

@testable import Diane

@Suite struct CalendarLogicTests {
    // Berlin is UTC+2 in July — offsets make zone bugs visible.
    private func makeLogic(firstWeekday: Int = 2, zone: String = "Europe/Berlin") -> CalendarWeekLogic {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.firstWeekday = firstWeekday
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return CalendarWeekLogic(calendar: calendar)
    }

    private func date(_ logic: CalendarWeekLogic, _ y: Int, _ m: Int, _ d: Int) -> Date {
        logic.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func timed(_ startsAt: String, _ endsAt: String?, summary: String = "Event") -> Components.Schemas.EventOccurrence {
        .init(id: startsAt + summary, eventId: "e", calendarId: "c", summary: summary, allDay: false, startsAt: startsAt, endsAt: endsAt)
    }

    private func allDay(_ startDate: String, _ endDate: String?, summary: String = "Event") -> Components.Schemas.EventOccurrence {
        .init(id: startDate + summary, eventId: "e", calendarId: "c", summary: summary, allDay: true, startDate: startDate, endDate: endDate)
    }

    // MARK: Week window

    @Test func stripDaysMondayFirst() {
        let logic = makeLogic(firstWeekday: 2)
        // Wednesday 2026-07-29 → Mon 27 … Sun Aug 2 (crosses the month edge).
        let days = logic.stripDays(anchor: date(logic, 2026, 7, 29)).map(logic.dayString)
        #expect(days == ["2026-07-27", "2026-07-28", "2026-07-29", "2026-07-30", "2026-07-31", "2026-08-01", "2026-08-02"])
    }

    @Test func stripDaysRespectFirstWeekday() {
        let logic = makeLogic(firstWeekday: 1)
        // Sunday-first device: the same Wednesday's week starts Sun 26.
        let days = logic.stripDays(anchor: date(logic, 2026, 7, 29)).map(logic.dayString)
        #expect(days.first == "2026-07-26")
        #expect(days.last == "2026-08-01")
        #expect(days.count == 7)
    }

    @Test func queryRangeCoversWholeWeekEndExclusive() {
        let logic = makeLogic(firstWeekday: 2)
        let range = logic.queryRange(anchor: date(logic, 2026, 7, 29))
        // Server range is [from, to): `to` is the day after Sunday.
        #expect(range.from == "2026-07-27")
        #expect(range.to == "2026-08-03")
    }

    @Test func pagingMovesOneWeek() {
        let logic = makeLogic()
        let anchor = date(logic, 2026, 7, 29)
        let next = logic.calendar.date(byAdding: .day, value: 7, to: anchor)!
        let previous = logic.calendar.date(byAdding: .day, value: -7, to: anchor)!
        #expect(logic.dayString(logic.weekStart(containing: next)) == "2026-08-03")
        #expect(logic.dayString(logic.weekStart(containing: previous)) == "2026-07-20")
    }

    // MARK: occursOn — timed

    @Test func singleTimedEventOnItsLocalDay() {
        let logic = makeLogic()
        // 14:00Z = 16:00 Berlin, same local day.
        let occurrence = timed("2026-07-27T14:00:00Z", "2026-07-27T15:00:00Z")
        #expect(logic.occursOn(day: "2026-07-27", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-26", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-28", occurrence: occurrence))
    }

    // D02: day membership is decided in the injected (household) zone.
    @Test func timedEventUsesHouseholdZoneNotUTC() {
        let logic = makeLogic()
        // 23:30Z on the 27th is already 01:30 on the 28th in Berlin.
        let occurrence = timed("2026-07-27T23:30:00Z", "2026-07-27T23:45:00Z")
        #expect(logic.occursOn(day: "2026-07-28", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-27", occurrence: occurrence))
    }

    // D02: household Chicago vs device New York — a Saturday 11:30 PM
    // (Chicago) event belongs to the household's Saturday; the device frame
    // would push it to Sunday and (via queryRange) drop it from the week.
    @Test func householdFrameKeepsLateSaturdayEventOnSaturday() {
        let household = makeLogic(zone: "America/Chicago")
        let device = makeLogic(zone: "America/New_York")
        // 2026-08-02T04:30Z = Sat Aug 1, 23:30 Chicago = Sun Aug 2, 00:30 NY.
        let occurrence = timed("2026-08-02T04:30:00Z", "2026-08-02T04:45:00Z")
        #expect(household.occursOn(day: "2026-08-01", occurrence: occurrence))
        #expect(!household.occursOn(day: "2026-08-02", occurrence: occurrence))
        #expect(device.occursOn(day: "2026-08-02", occurrence: occurrence))
    }

    // D02: near household midnight the two frames disagree about which WEEK
    // it is — the query range must follow the household.
    @Test func queryRangeFollowsTheHouseholdWeek() {
        let household = makeLogic(firstWeekday: 2, zone: "America/Chicago")
        let device = makeLogic(firstWeekday: 2, zone: "America/New_York")
        // 2026-08-03T04:30Z = Sun Aug 2, 23:30 Chicago / Mon Aug 3, 00:30 NY.
        let instant = Date(timeIntervalSince1970: 1_785_731_400)
        let range = household.queryRange(anchor: instant)
        #expect(range.from == "2026-07-27")
        #expect(range.to == "2026-08-03")
        let deviceRange = device.queryRange(anchor: instant)
        #expect(deviceRange.from == "2026-08-03") // the wrong week, if used
    }

    @Test func crossMidnightTimedEventOnBothDays() {
        let logic = makeLogic()
        // 22:00 Berlin on the 27th → 02:30 on the 28th.
        let occurrence = timed("2026-07-27T20:00:00Z", "2026-07-28T00:30:00Z")
        #expect(logic.occursOn(day: "2026-07-27", occurrence: occurrence))
        #expect(logic.occursOn(day: "2026-07-28", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-26", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-29", occurrence: occurrence))
    }

    @Test func timedEventEndingAtMidnightStaysOnPreviousDay() {
        let logic = makeLogic()
        // Ends 22:00Z = exactly 00:00 Berlin on the 28th — end-exclusive.
        let occurrence = timed("2026-07-27T20:00:00Z", "2026-07-27T22:00:00Z")
        #expect(logic.occursOn(day: "2026-07-27", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-28", occurrence: occurrence))
    }

    // MARK: occursOn — all-day

    @Test func singleAllDayEndDateExclusive() {
        let logic = makeLogic()
        let occurrence = allDay("2026-07-27", "2026-07-28")
        #expect(logic.occursOn(day: "2026-07-27", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-28", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-26", occurrence: occurrence))
    }

    @Test func multiDayAllDayCoversEveryDayButTheExclusiveEnd() {
        let logic = makeLogic()
        let occurrence = allDay("2026-07-27", "2026-07-30")
        #expect(logic.occursOn(day: "2026-07-27", occurrence: occurrence))
        #expect(logic.occursOn(day: "2026-07-28", occurrence: occurrence))
        #expect(logic.occursOn(day: "2026-07-29", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-30", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-26", occurrence: occurrence))
    }

    @Test func allDayWithoutEndDateIsSingleDay() {
        let logic = makeLogic()
        let occurrence = allDay("2026-07-27", nil)
        #expect(logic.occursOn(day: "2026-07-27", occurrence: occurrence))
        #expect(!logic.occursOn(day: "2026-07-28", occurrence: occurrence))
    }

    // MARK: Agenda sorting & dots

    @Test func agendaPutsAllDayFirstThenTimedByStart() {
        let logic = makeLogic()
        let events = [
            timed("2026-07-27T16:00:00Z", "2026-07-27T17:00:00Z", summary: "Late"),
            allDay("2026-07-27", "2026-07-28", summary: "Holiday"),
            timed("2026-07-27T08:00:00Z", "2026-07-27T09:00:00Z", summary: "Early"),
            timed("2026-07-30T08:00:00Z", "2026-07-30T09:00:00Z", summary: "OtherDay"),
        ]
        let rows = logic.agenda(day: "2026-07-27", events: events)
        #expect(rows.map(\.summary) == ["Holiday", "Early", "Late"])
    }

    @Test func agendaBreaksStartTiesBySummary() {
        let logic = makeLogic()
        let events = [
            timed("2026-07-27T08:00:00Z", "2026-07-27T09:00:00Z", summary: "Bravo"),
            timed("2026-07-27T08:00:00Z", "2026-07-27T09:00:00Z", summary: "Alpha"),
        ]
        let rows = logic.agenda(day: "2026-07-27", events: events)
        #expect(rows.map(\.summary) == ["Alpha", "Bravo"])
    }

    @Test func daysWithEventsMarksEveryCoveredDay() {
        let logic = makeLogic()
        let days = ["2026-07-27", "2026-07-28", "2026-07-29", "2026-07-30", "2026-07-31", "2026-08-01", "2026-08-02"]
        let events = [
            allDay("2026-07-28", "2026-07-30"),
            timed("2026-08-01T10:00:00Z", "2026-08-01T11:00:00Z"),
        ]
        #expect(logic.daysWithEvents(days: days, events: events) == ["2026-07-28", "2026-07-29", "2026-08-01"])
    }

    // MARK: Time label

    @Test func timeLabelFormatsLocalRange() {
        let logic = makeLogic()
        let occurrence = timed("2026-07-27T14:00:00Z", "2026-07-27T15:30:00Z")
        #expect(logic.timeLabel(for: occurrence) == "16:00–17:30")
        #expect(logic.timeLabel(for: allDay("2026-07-27", "2026-07-28")) == "all day")
    }

    // MARK: Commit gate

    // D14: a finished load may only commit when the strip still shows the
    // week it fetched and the task wasn't cancelled — otherwise week A's
    // events would land under week B's key.
    @Test func staleOrCancelledLoadsNeverCommit() {
        #expect(CalendarWeekLogic.shouldCommit(fetched: "2026-07-27", current: "2026-07-27", cancelled: false))
        #expect(!CalendarWeekLogic.shouldCommit(fetched: "2026-07-27", current: "2026-08-03", cancelled: false))
        #expect(!CalendarWeekLogic.shouldCommit(fetched: "2026-07-27", current: "2026-07-27", cancelled: true))
    }
}
