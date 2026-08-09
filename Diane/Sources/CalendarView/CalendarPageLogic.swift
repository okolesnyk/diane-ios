import DianeKit
import Foundation

/// Page 3 (M9e design): the math behind the Apple-familiar calendar — the
/// collapsible month↔week header, the agenda below it, and the day grid's
/// block layout. Wraps a CalendarWeekLogic (week math, day membership,
/// agenda shaping stay authoritative there).
struct CalendarPageLogic {
    let week: CalendarWeekLogic
    let calendar: Foundation.Calendar

    init(calendar: Foundation.Calendar) {
        self.calendar = calendar
        week = CalendarWeekLogic(calendar: calendar)
    }

    // MARK: - Month grid (the expanded header)

    struct MonthCell: Equatable, Identifiable {
        let day: String
        let dayNumber: Int
        /// Leading/trailing filler from the neighbouring months renders dim.
        let inMonth: Bool
        var id: String { day }
    }

    /// The 42-cell (6-week) grid of the month containing `anchor`, aligned to
    /// the calendar's firstWeekday. Always 42 cells so months don't jump height.
    func monthCells(containing anchor: Date) -> [MonthCell] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: anchor) else { return [] }
        let firstOfMonth = monthInterval.start
        let gridStart = week.weekStart(containing: firstOfMonth)
        let month = calendar.component(.month, from: firstOfMonth)
        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return MonthCell(
                day: week.dayString(date),
                dayNumber: calendar.component(.day, from: date),
                inMonth: calendar.component(.month, from: date) == month
            )
        }
    }

    /// "August 2026" for the header title.
    func monthTitle(_ anchor: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter.string(from: anchor)
    }

    /// Three-letter weekday headers (Sun–Sat) in firstWeekday order — the
    /// same grammar the day strips use; single letters repeat (T/T, S/S).
    func weekdayHeaders(locale: Locale = .current) -> [String] {
        var cal = calendar
        cal.locale = locale
        let symbols = cal.shortWeekdaySymbols
        let first = cal.firstWeekday - 1
        return (0..<7).map { symbols[(first + $0) % 7] }
    }

    func page(_ anchor: Date, byMonths months: Int) -> Date {
        calendar.date(byAdding: .month, value: months, to: anchor) ?? anchor
    }

    func page(_ anchor: Date, byWeeks weeks: Int) -> Date {
        calendar.date(byAdding: .day, value: weeks * 7, to: anchor) ?? anchor
    }

    func day(_ anchor: Date, plus days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: anchor) ?? anchor
    }

    /// The listEvents [from, to) window for the expanded grid (42 cells).
    func monthQueryRange(containing anchor: Date) -> (from: String, to: String) {
        guard let monthInterval = calendar.dateInterval(of: .month, for: anchor) else {
            return week.queryRange(anchor: anchor)
        }
        let gridStart = week.weekStart(containing: monthInterval.start)
        let afterEnd = calendar.date(byAdding: .day, value: 42, to: gridStart) ?? gridStart
        return (week.dayString(gridStart), week.dayString(afterEnd))
    }

    // MARK: - Day grid (the day view's positioned blocks)

    struct DayBlock: Equatable, Identifiable {
        let event: Components.Schemas.EventOccurrence
        /// Minutes from the grid's first hour to the block top.
        let startMinutes: Int
        let durationMinutes: Int
        /// Overlap lane: 0-based column index and the total lane count, so
        /// side-by-side events split the width (the web TimeGrid's rule).
        let lane: Int
        let laneCount: Int
        var id: String { event.id }
    }

    /// Timed events of `day` laid into overlap lanes. All-day events are the
    /// caller's bar, not blocks. Minimum visual duration 30 min.
    func dayBlocks(day: String, events: [Components.Schemas.EventOccurrence]) -> [DayBlock] {
        struct Placed {
            let event: Components.Schemas.EventOccurrence
            let start: Int
            let end: Int
            var lane = 0
        }
        var placed: [Placed] = events
            .filter { !$0.allDay && week.occursOn(day: day, occurrence: $0) }
            .compactMap { event in
                guard let startsAt = event.startsAt, let start = week.parseInstant(startsAt) else {
                    return nil
                }
                // Clamp to this day: a spanning event starts at 00:00 here.
                let sameDay = week.localDay(ofInstant: startsAt) == day
                let startMin = sameDay ? minutesIntoDay(start) : 0
                var endMin = startMin + 30
                if let endsAt = event.endsAt, let end = week.parseInstant(endsAt) {
                    let endSameDay = week.localDay(ofInstant: endsAt) == day
                    endMin = endSameDay ? max(minutesIntoDay(end), startMin + 30) : 24 * 60
                }
                return Placed(event: event, start: startMin, end: min(endMin, 24 * 60))
            }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        // Greedy lane assignment within overlap clusters.
        var laneEnds: [Int] = []
        var clusterStart = 0
        var clusterMaxLanes = 0
        var out: [DayBlock] = []
        func flushCluster(upTo index: Int) {
            for i in clusterStart..<index {
                out.append(DayBlock(
                    event: placed[i].event,
                    startMinutes: placed[i].start,
                    durationMinutes: placed[i].end - placed[i].start,
                    lane: placed[i].lane,
                    laneCount: max(clusterMaxLanes, 1)
                ))
            }
        }
        for index in placed.indices {
            if let maxEnd = laneEnds.max(), placed[index].start >= maxEnd {
                flushCluster(upTo: index)
                clusterStart = index
                laneEnds = []
                clusterMaxLanes = 0
            }
            if let free = laneEnds.firstIndex(where: { $0 <= placed[index].start }) {
                placed[index].lane = free
                laneEnds[free] = placed[index].end
            } else {
                placed[index].lane = laneEnds.count
                laneEnds.append(placed[index].end)
            }
            clusterMaxLanes = max(clusterMaxLanes, laneEnds.count)
        }
        flushCluster(upTo: placed.count)
        return out
    }

    private func minutesIntoDay(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// "yyyy-MM-01" for a month-picker jump; the current month jumps to today.
    static func monthJumpTarget(year: Int, month: Int, today: String) -> String {
        let first = String(format: "%04d-%02d-01", year, month)
        return today.hasPrefix(String(format: "%04d-%02d", year, month)) ? today : first
    }

    /// The day grid's hour window. The mock runs 07:00–22:00 (H0/H1) — a
    /// family's waking day, not 24 rows of empty night — widened only when
    /// real events fall outside it.
    static let defaultGridStartHour = 7

    /// The full-day grid scrolls (owner 2026-08-07: all 24 hours exist —
    /// the old 07–22 window read as a lost two-thirds of the day). This is
    /// where it OPENS: today lands a little above the now-line; other days
    /// at the first event, else the waking morning.
    static func initialScrollHour(blocks: [DayBlock], isToday: Bool, nowMinutes: Int?) -> Int {
        if isToday, let now = nowMinutes {
            return max(0, now / 60 - 2)
        }
        if let first = blocks.map(\.startMinutes).min() {
            return max(0, first / 60 - 1)
        }
        return defaultGridStartHour
    }

    /// Snap a drag's grid offset to a 30-minute slot ("HH:mm").
    static func snappedSlot(minutes: Int) -> String {
        let clamped = min(max(minutes, 0), 23 * 60 + 30)
        let snapped = (clamped / 30) * 30
        return String(format: "%02d:%02d", snapped / 60, snapped % 60)
    }
}
