import DianeKit
import Foundation

/// The Home tiles' pulse (owner 2026-08-10, rev 5 of the design doc): ONE
/// count line per module tile — just numbers, no named things. Counts are
/// FILTER-AWARE: computed over the app-wide member filter's effective set,
/// so a tile always describes what its door opens onto (the one-filter
/// rule). Rewards is the exception — "waiting" is a to-do for the viewing
/// parent, never filtered. Lines are recomputed from a cached snapshot, so
/// window and late boundaries ride the household clock's existing minute
/// tick — no new timers, no refetching on the clock. Nonisolated on
/// purpose: Views inherit @MainActor, logic must not.
enum HomeLogic {
    /// Everything one pulse needs, fetched once and recomputed cheaply.
    struct Snapshot: Equatable {
        var events: [DayLogic.Event] = []
        var chores: [DayLogic.Chore] = []
        var board: [Components.Schemas.RoutineBoardEntry] = []
        /// Redemptions awaiting a parent (the fetch is already status-scoped).
        var waiting = 0
        var memberIds: [String] = []
    }

    /// One tile's line: the emphasised count ("3 open") and, on Chores, the
    /// red late part ("1 late"). A nil line is a quiet door.
    struct Line: Equatable {
        var count: String
        var late: String?
    }

    struct Pulse: Equatable {
        var calendar: Line?
        var chores: Line?
        var routines: Line?
        var rewards: Line?

        func line(for module: DianeModule) -> Line? {
            switch module {
            case .calendar: calendar
            case .chores: chores
            case .routines: routines
            case .rewards: rewards
            }
        }

        /// The red corner dot mirrors the late part — never color alone,
        /// "1 late" sits in text on the same tile.
        func showsDot(for module: DianeModule) -> Bool {
            module == .chores && chores?.late != nil
        }
    }

    static func pulse(
        _ snapshot: Snapshot,
        today: String,
        minute: String,
        timeZone: TimeZone,
        selected: Set<String>
    ) -> Pulse {
        Pulse(
            calendar: calendarLine(
                events: snapshot.events, today: today, timeZone: timeZone, selected: selected
            ),
            chores: choresLine(
                chores: snapshot.chores, today: today, minute: minute, selected: selected
            ),
            routines: routinesLine(board: snapshot.board, minute: minute, selected: selected),
            rewards: rewardsLine(waiting: snapshot.waiting)
        )
    }

    /// "4 today" — events on the household-local today. Whole-family events
    /// (no member list) always count, like on every filtered page.
    static func calendarLine(
        events: [DayLogic.Event],
        today: String,
        timeZone: TimeZone,
        selected: Set<String>
    ) -> Line? {
        let count = events.count {
            DayLogic.onDay($0, date: today, timeZone: timeZone)
                && TodayLogic.visible($0, selected: selected)
        }
        return count > 0 ? Line(count: "\(count) today") : nil
    }

    /// "3 open · 1 late" — actionable chore ROWS, folded exactly as the
    /// Chores page lists them (a shared chore is one row; pool rows count
    /// for everyone). Late is the day pages' display twin, so the dot moves
    /// at the same minute the rows do.
    static func choresLine(
        chores: [DayLogic.Chore],
        today: String,
        minute: String,
        selected: Set<String>
    ) -> Line? {
        let rows = ChoresPageLogic.rows(chores).filter { TodayLogic.visible($0, selected: selected) }
        let open = rows.count { row in row.occurrences.contains { $0.status == .open } }
        guard open > 0 else { return nil }
        let late = rows.count { row in
            row.occurrences.contains { DayLogic.effectivelyLate($0, today: today, minute: minute) }
        }
        return Line(count: "\(open) open", late: late > 0 ? "\(late) late" : nil)
    }

    /// "3 left" — open tasks on board entries whose window is RUNNING at
    /// `minute` (start inclusive, end exclusive). Outside every window, or
    /// with nothing left, the door stays quiet.
    static func routinesLine(
        board: [Components.Schemas.RoutineBoardEntry],
        minute: String,
        selected: Set<String>
    ) -> Line? {
        guard let now = TimeLogic.minutes(minute) else { return nil }
        let left = board
            .filter { selected.contains($0.memberId) }
            .filter { entry in
                guard let start = TimeLogic.minutes(entry.windowStart),
                      let end = TimeLogic.minutes(entry.windowEnd)
                else { return false }
                return start <= now && now < end
            }
            .reduce(0) { $0 + $1.tasks.count(where: { $0.status == .open }) }
        return left > 0 ? Line(count: "\(left) left") : nil
    }

    /// "1 waiting" — redemptions awaiting a parent, household-wide by
    /// design: hiding a kid's pending reward would only delay it.
    static func rewardsLine(waiting: Int) -> Line? {
        waiting > 0 ? Line(count: "\(waiting) waiting") : nil
    }
}
