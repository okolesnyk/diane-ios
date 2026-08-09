import Foundation
import Testing
@testable import Diane
import DianeKit

// Page 3 (M9e): month grid + day-block lane math.
@Suite struct CalendarPageLogicTests {
    private func logic(firstWeekday: Int = 2) -> CalendarPageLogic {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = firstWeekday
        return CalendarPageLogic(calendar: calendar)
    }

    private func date(_ day: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: "\(day) 12:00")!
    }

    private func event(
        id: String,
        start: String,
        end: String? = nil,
        allDay: Bool = false
    ) -> Components.Schemas.EventOccurrence {
        Components.Schemas.EventOccurrence(
            id: id, eventId: "e-\(id)", calendarId: "cal", summary: id, location: nil,
            allDay: allDay, startsAt: allDay ? nil : "\(start):00.000Z",
            endsAt: end.map { "\($0):00.000Z" }, startDate: allDay ? start : nil,
            endDate: allDay ? end : nil, memberIds: nil
        )
    }

    @Test func monthGridIs42CellsAlignedToTheWeekStart() {
        // August 2026 starts on a Saturday; Monday-start grid begins Jul 27.
        let cells = logic().monthCells(containing: date("2026-08-15"))
        #expect(cells.count == 42)
        #expect(cells.first?.day == "2026-07-27")
        #expect(!cells[0].inMonth)
        #expect(cells.first(where: { $0.day == "2026-08-01" })?.inMonth == true)
        #expect(cells.last?.day == "2026-09-06")
        // Sunday-start shifts the origin.
        let sunday = logic(firstWeekday: 1).monthCells(containing: date("2026-08-15"))
        #expect(sunday.first?.day == "2026-07-26")
    }

    @Test func monthQueryRangeCoversTheWholeGridEndExclusive() {
        let range = logic().monthQueryRange(containing: date("2026-08-15"))
        #expect(range.from == "2026-07-27")
        #expect(range.to == "2026-09-07")
    }

    @Test func dayBlocksAssignOverlapLanes() {
        let blocks = logic().dayBlocks(day: "2026-08-06", events: [
            event(id: "a", start: "2026-08-06T09:00", end: "2026-08-06T10:00"),
            event(id: "b", start: "2026-08-06T09:30", end: "2026-08-06T10:30"),
            event(id: "c", start: "2026-08-06T11:00", end: "2026-08-06T12:00"),
        ])
        let a = blocks.first(where: { $0.id == "a" })!
        let b = blocks.first(where: { $0.id == "b" })!
        let c = blocks.first(where: { $0.id == "c" })!
        // a and b overlap → two lanes; c stands alone → full width again.
        #expect(a.lane == 0 && b.lane == 1)
        #expect(a.laneCount == 2 && b.laneCount == 2)
        #expect(c.lane == 0 && c.laneCount == 1)
        #expect(a.startMinutes == 9 * 60 && a.durationMinutes == 60)
    }

    @Test func dayBlocksClampSpansAndEnforceMinimumHeight() {
        let blocks = logic().dayBlocks(day: "2026-08-06", events: [
            // Started yesterday, ends 01:00 today → clamped to 00:00–01:00.
            event(id: "span", start: "2026-08-05T22:00", end: "2026-08-06T01:00"),
            // Zero-length → 30-minute visual minimum.
            event(id: "dot", start: "2026-08-06T14:00", end: "2026-08-06T14:00"),
        ])
        let span = blocks.first(where: { $0.id == "span" })!
        #expect(span.startMinutes == 0 && span.durationMinutes == 60)
        let dot = blocks.first(where: { $0.id == "dot" })!
        #expect(dot.durationMinutes == 30)
    }

    @Test func fullDayGridOpensAtTheUsefulHour() {
        // All 24 hours exist (owner 2026-08-07); this decides where the
        // scroll LANDS. Today: a little above now.
        #expect(CalendarPageLogic.initialScrollHour(blocks: [], isToday: true, nowMinutes: 14 * 60 + 30) == 12)
        // Early morning clamps to midnight, never negative.
        #expect(CalendarPageLogic.initialScrollHour(blocks: [], isToday: true, nowMinutes: 40) == 0)
        // Another day: an hour above its first event.
        let blocks = logic().dayBlocks(day: "2026-08-06", events: [
            event(id: "dawn", start: "2026-08-06T05:15", end: "2026-08-06T06:00"),
            event(id: "late", start: "2026-08-06T22:30", end: "2026-08-06T23:15"),
        ])
        #expect(CalendarPageLogic.initialScrollHour(blocks: blocks, isToday: false, nowMinutes: nil) == 4)
        // No events at all: the waking morning.
        #expect(CalendarPageLogic.initialScrollHour(blocks: [], isToday: false, nowMinutes: nil) == 7)
    }

    @Test func slotSnappingClampsAndRounds() {
        #expect(CalendarPageLogic.snappedSlot(minutes: 585) == "09:30")
        #expect(CalendarPageLogic.snappedSlot(minutes: 0) == "00:00")
        #expect(CalendarPageLogic.snappedSlot(minutes: -20) == "00:00")
        #expect(CalendarPageLogic.snappedSlot(minutes: 5000) == "23:30")
    }
}
