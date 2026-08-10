import DianeKit
import Foundation

/// The day pages' shared math (M9e; My Day itself retired owner 2026-08-10):
/// local-date arithmetic, the 7-day strip, late display twins, timeline sort
/// keys, due-origin captions, the future routine board, and the
/// calendar-color rails. Nonisolated on purpose: Views inherit @MainActor,
/// logic must not.
enum MyDayLogic {
    typealias Event = Components.Schemas.EventOccurrence
    typealias Chore = Components.Schemas.ChoreOccurrence
    typealias CalendarInfo = Components.Schemas.Calendar

    // MARK: - Local-date math (string domain, never through UTC)

    static func addDays(_ date: String, _ days: Int) -> String {
        let parts = date.split(separator: "-").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return date }
        var components = DateComponents()
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2] + days)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let d = calendar.date(from: components) else { return date }
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    enum DayPhase: Equatable { case past, today, future }

    static func phase(of date: String, today: String) -> DayPhase {
        if date < today { return .past }
        if date > today { return .future }
        return .today
    }

    // MARK: - The 7-day strip (a window, not a wall — it re-centers)

    struct StripDay: Equatable, Identifiable {
        let date: String
        /// "M" / "T" … — one-letter weekday.
        let weekdayInitial: String
        /// "5", "31" — day of month.
        let dayNumber: String
        var id: String { date }
    }

    /// The seven days of the WEEK containing `date` — a fixed week, like the
    /// Calendar's row. It does NOT re-center on every tap (owner 2026-08-06:
    /// that made picking a day lurch); swiping the strip pages a whole week.
    static func weekDays(
        containing date: String,
        firstWeekday: Int = Foundation.Calendar.current.firstWeekday,
        locale: Locale = .current
    ) -> [StripDay] {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.firstWeekday = firstWeekday
        guard let parsed = localDate(date) else { return [] }
        let weekday = calendar.component(.weekday, from: parsed)
        let offsetIntoWeek = ((weekday - firstWeekday) + 7) % 7
        let start = addDays(date, -offsetIntoWeek)
        return (0..<7).map { index in
            let day = addDays(start, index)
            return StripDay(
                date: day,
                weekdayInitial: weekdayInitial(of: day, locale: locale),
                dayNumber: String(Int(day.suffix(2)) ?? 0)
            )
        }
    }

    /// "YYYY-MM-DD" → a UTC-noon Date for weekday math (never for display).
    static func localDate(_ date: String) -> Date? {
        let parts = date.split(separator: "-").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        components.hour = 12
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: components)
    }

    static func weekdayInitial(of date: String, locale: Locale = .current) -> String {
        let parts = date.split(separator: "-").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return "" }
        var components = DateComponents()
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        calendar.locale = locale
        guard let d = calendar.date(from: components) else { return "" }
        let symbols = calendar.shortWeekdaySymbols
        let weekday = calendar.component(.weekday, from: d)
        return symbols[(weekday - 1) % symbols.count]
    }

    /// Where a strip swipe lands (owner 2026-08-08): the day nearest to
    /// where you came from — forward = the NEXT week's first day, back =
    /// the PREVIOUS week's last. Pure week-edge math: one past the current
    /// week's last day, or one before its first.
    static func pagedStripTarget(
        from day: String,
        forward: Bool,
        firstWeekday: Int = Foundation.Calendar.current.firstWeekday
    ) -> String {
        let week = weekDays(containing: day, firstWeekday: firstWeekday)
        guard let first = week.first?.date, let last = week.last?.date else { return day }
        return forward ? addDays(last, 1) : addDays(first, -1)
    }

    /// The fetch window backing the strip: the visible week plus a week of
    /// slack each side, so paging never shows an empty strip while it loads
    /// (events [from,to) is end-exclusive → to = last + 1).
    static func fetchRange(centeredOn center: String) -> (from: String, to: String) {
        let week = weekDays(containing: center)
        let first = week.first?.date ?? center
        let last = week.last?.date ?? center
        return (addDays(first, -7), addDays(last, 8))
    }

    // MARK: - The future routine board (scheduled reality, computed here)

    /// The server's weekday codes for a local date. Pure Gregorian math —
    /// weekday needs no timezone once the date string is local.
    static func weekdayCode(of date: String) -> String? {
        guard let day = localDate(date) else { return nil }
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let codes = ["su", "mo", "tu", "we", "th", "fr", "sa"]
        return codes[calendar.component(.weekday, from: day) - 1]
    }

    /// The board the server can't serve: routine cards for a FUTURE day,
    /// synthesized from the definitions ("future days show scheduled
    /// reality" — the mock's rule; the board endpoint refuses future dates
    /// because actions can't land there). All tasks open, no streak claims.
    static func futureBoard(
        routines: [Components.Schemas.Routine],
        day: String
    ) -> [Components.Schemas.RoutineBoardEntry] {
        guard let code = weekdayCode(of: day) else { return [] }
        return routines
            .filter { routine in
                guard let byWeekday = routine.byWeekday, !byWeekday.isEmpty else { return true }
                return byWeekday.contains { $0.rawValue == code }
            }
            .flatMap { routine in
                routine.assigneeIds.map { memberId in
                    Components.Schemas.RoutineBoardEntry(
                        routineId: routine.id,
                        title: routine.title,
                        emoji: routine.emoji,
                        windowStart: routine.windowStart,
                        windowEnd: routine.windowEnd,
                        memberId: memberId,
                        complete: false,
                        streak: 0,
                        tasks: routine.tasks
                            .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
                            .map { task in
                                .init(
                                    taskId: task.id,
                                    title: task.title,
                                    emoji: task.emoji,
                                    starValue: task.starValue,
                                    status: .open,
                                    completedByMemberId: nil,
                                    completedAt: nil
                                )
                            }
                    )
                }
            }
    }

    // MARK: - Day membership

    /// Does an event belong on this local day? Timed events localize their
    /// start instant; all-day events span [startDate, endDate) end-exclusive.
    static func onDay(_ event: Event, date: String, timeZone: TimeZone) -> Bool {
        if event.allDay {
            guard let start = event.startDate else { return false }
            let end = event.endDate ?? addDays(start, 1)
            return start <= date && date < end
        }
        guard let startsAt = event.startsAt, let instant = TodayLogic.parseInstant(startsAt) else {
            return false
        }
        return TodayLogic.dateString(for: instant, timeZone: timeZone) == date
    }

    // MARK: - Late math (display twin of the server's rule)

    /// Minutes past a timed chore's at/due time before it reads late on its
    /// own day — the SERVER owns this rule (packages/chores LATE_GRACE_MINUTES);
    /// this display twin moves rows at the right minute between refetches.
    static let lateGraceMinutes = 15

    static func effectivelyLate(_ chore: Chore, today: String, minute: String) -> Bool {
        guard chore.status == .open else { return false }
        if chore.late { return true }
        guard chore.dueDate == today,
              let time = chore.dueTime, let due = TodayLogic.minutes(time),
              let now = TodayLogic.minutes(minute)
        else { return false }
        return now >= due + lateGraceMinutes
    }

    /// Was this ✓ a catch-up — checked after its due day, or past its own-day
    /// time + grace? A checked late chore STAYS in Catch Up as a truthful
    /// late-done (owner 2026-08-09) instead of jumping to its schedule
    /// section. Display twin of the server rule (done rows now carry `late`);
    /// the local computation also covers an api that predates it.
    static func lateWhenDone(_ chore: Chore, timeZone: TimeZone) -> Bool {
        guard chore.status == .completed else { return false }
        if chore.late { return true }
        guard let dueDate = chore.dueDate,
              let completedAt = chore.completedAt,
              let instant = TodayLogic.parseInstant(completedAt)
        else { return false }
        let doneDay = TodayLogic.dateString(for: instant, timeZone: timeZone)
        if dueDate < doneDay { return true }
        guard dueDate == doneDay,
              let time = chore.dueTime, let due = TodayLogic.minutes(time)
        else { return false }
        return TodayLogic.clockMinutes(of: instant, timeZone: timeZone) >= due + lateGraceMinutes
    }

    // MARK: - The merged timeline

    enum TimelineItem: Equatable, Identifiable {
        case event(Event)
        case chore(Chore)

        var id: String {
            switch self {
            case .event(let event): "ev-\(event.id)"
            case .chore(let chore): "ch-\(chore.id)"
            }
        }

        /// Minutes-of-day sort key; all-day events float to the top.
        func sortKey(timeZone: TimeZone) -> Int {
            switch self {
            case .event(let event):
                if event.allDay { return -1 }
                guard let startsAt = event.startsAt, let instant = TodayLogic.parseInstant(startsAt)
                else { return Int.max }
                return TodayLogic.clockMinutes(of: instant, timeZone: timeZone)
            case .chore(let chore):
                guard let time = chore.dueTime, let minutes = TodayLogic.minutes(time) else {
                    return Int.max
                }
                return minutes
            }
        }

    }

    /// "due yesterday 20:05" — the debt's origin on a Catch up row.
    static func dueOrigin(_ chore: Chore, today: String) -> String? {
        guard let due = chore.dueDate else { return nil }
        var dayPart: String
        if due == addDays(today, -1) {
            dayPart = "due yesterday"
        } else if due == today {
            dayPart = "due today"
        } else {
            dayPart = "due \(NavigationLogic.myDayTitle(for: due))"
            // Another year's date says so (owner 2026-08-10) — "Aug 11"
            // alone could be next year's.
            if due.prefix(4) != today.prefix(4) { dayPart += ", \(due.prefix(4))" }
        }
        guard let time = chore.dueTime else { return dayPart }
        return "\(dayPart) \(time)"
    }

    // MARK: - Calendar-color rails (owner rule: strip = calendar, tint = member)

    static func railColorHex(for event: Event, calendars: [CalendarInfo]) -> String? {
        guard let calendar = calendars.first(where: { $0.id == event.calendarId }) else {
            return nil
        }
        return calendar.color ?? calendar.providerColor
    }

    // MARK: - Strip dots (blue events / orange chores; Family Day fills them)

    struct DayDots: Equatable {
        var hasEvents = false
        var hasChores = false
    }
}
