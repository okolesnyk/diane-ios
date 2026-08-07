import DianeKit
import Foundation

/// Page 1 (M9e design): the pure math behind My Day — the 7-day strip, the
/// Catch up / Timeline / No set time partition, the merged event+chore
/// timeline with the hairline now-line, and the calendar-color rails.
/// Nonisolated on purpose: Views inherit @MainActor, logic must not.
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

    /// The fetch window backing the strip: the visible week plus a week of
    /// slack each side, so paging never shows an empty strip while it loads
    /// (events [from,to) is end-exclusive → to = last + 1).
    static func fetchRange(centeredOn center: String) -> (from: String, to: String) {
        let week = weekDays(containing: center)
        let first = week.first?.date ?? center
        let last = week.last?.date ?? center
        return (addDays(first, -7), addDays(last, 8))
    }

    // MARK: - Mine-ness

    /// My Day shows MY business: chores I own (assigned to me, or pool rows I
    /// claimed/completed). The unclaimed pool is family business — it lives
    /// on Family Day and in the Chores module, not here.
    static func isMine(_ chore: Chore, me: String) -> Bool {
        (chore.claimedByMemberId ?? chore.assigneeMemberId) == me
    }

    /// "Whole family includes me, so it must be on my day" (owner rule):
    /// nil/empty memberIds = family-wide. Otherwise membership decides.
    static func isMyEvent(_ event: Event, me: String) -> Bool {
        guard let members = event.memberIds, !members.isEmpty else { return true }
        return members.contains(me)
    }

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

    // MARK: - The section partition

    struct Sections: Equatable {
        /// Late, red, today only — the day's debts.
        var catchUp: [Chore] = []
        /// Timed chores, merged into the event timeline.
        var timed: [Chore] = []
        /// Dated-but-untimed for the day, plus (today) anytime/byDate rows.
        var noSetTime: [Chore] = []
    }

    static func sections(_ occurrences: [Chore], me: String, phase: DayPhase) -> Sections {
        var out = Sections()
        for chore in occurrences where isMine(chore, me: me) {
            if phase == .today && chore.late && chore.status == .open {
                out.catchUp.append(chore)
            } else if chore.dueTime != nil {
                out.timed.append(chore)
            } else {
                out.noSetTime.append(chore)
            }
        }
        return out
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

    /// Events + TIMED chores, one time-ordered river ("a chore due at 18:00
    /// belongs at 18:00, not in a separate silo" — the approved design).
    static func timeline(
        events: [Event],
        timedChores: [Chore],
        timeZone: TimeZone
    ) -> [TimelineItem] {
        let items = events.map(TimelineItem.event) + timedChores.map(TimelineItem.chore)
        return items.sorted { lhs, rhs in
            let l = lhs.sortKey(timeZone: timeZone)
            let r = rhs.sortKey(timeZone: timeZone)
            return l == r ? lhs.id < rhs.id : l < r
        }
    }

    /// Where the hairline now-line sits: the index of the first item after
    /// the current minute (nil off-today — the line only exists on today).
    static func nowLineIndex(items: [TimelineItem], minute: String, timeZone: TimeZone) -> Int? {
        guard let now = TodayLogic.minutes(minute) else { return nil }
        for (index, item) in items.enumerated() where item.sortKey(timeZone: timeZone) > now {
            return index
        }
        return items.count
    }

    /// "due yesterday 20:05" — the debt's origin on a Catch up row.
    static func dueOrigin(_ chore: Chore, today: String) -> String? {
        guard let due = chore.dueDate else { return nil }
        let dayPart: String
        if due == addDays(today, -1) {
            dayPart = "due yesterday"
        } else if due == today {
            dayPart = "due today"
        } else {
            dayPart = "due \(NavigationLogic.myDayTitle(for: due))"
        }
        guard let time = chore.dueTime else { return dayPart }
        return "\(dayPart) \(time)"
    }

    /// "with Marta" — the shared-event sub (the page's one member carrier).
    static func withSub(_ event: Event, me: String, names: [String: String]) -> String? {
        guard let ids = event.memberIds, !ids.isEmpty else { return nil }
        let others = ids.filter { $0 != me }.compactMap { names[$0] }
        guard !others.isEmpty, ids.contains(me) else { return nil }
        return "with \(others.joined(separator: ", "))"
    }

    // MARK: - Calendar-color rails (owner rule: strip = calendar, tint = member)

    static func railColorHex(for event: Event, calendars: [CalendarInfo]) -> String? {
        guard let calendar = calendars.first(where: { $0.id == event.calendarId }) else {
            return nil
        }
        return calendar.color ?? calendar.providerColor
    }

    // MARK: - Strip dots (blue events / orange chores preview)

    struct DayDots: Equatable {
        var hasEvents = false
        var hasChores = false
    }

    static func dots(
        for date: String,
        events: [Event],
        chores: [Chore],
        me: String,
        timeZone: TimeZone
    ) -> DayDots {
        DayDots(
            hasEvents: events.contains { isMyEvent($0, me: me) && onDay($0, date: date, timeZone: timeZone) },
            hasChores: chores.contains { isMine($0, me: me) && $0.dueDate == date }
        )
    }
}
