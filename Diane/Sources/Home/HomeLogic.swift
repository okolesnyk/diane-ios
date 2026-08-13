import DianeKit
import Foundation

/// The Home tiles' pulse (owner 2026-08-10, rev 5 of the design doc): ONE
/// count line per module tile — just numbers, no named things. Counts are
/// FAMILY-WIDE (owner verdict 2026-08-10): the tile is the household's
/// pulse, whatever the member filter says — member detail lives one tap
/// away on the pages built for it. Lines are recomputed from a cached
/// snapshot, so window and late boundaries ride the household clock's
/// existing minute tick — no new timers, no refetching on the clock.
/// Nonisolated on purpose: Views inherit @MainActor, logic must not.
enum HomeLogic {
    /// Everything one pulse needs, fetched once and recomputed cheaply.
    struct Snapshot: Equatable {
        var events: [DayLogic.Event] = []
        var chores: [DayLogic.Chore] = []
        var board: [Components.Schemas.RoutineBoardEntry] = []
        /// Redemptions awaiting a parent (the fetch is already status-scoped).
        var waiting = 0
        var lists: [Components.Schemas.List] = []
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
        var lists: Line?

        func line(for module: DianeModule) -> Line? {
            switch module {
            case .calendar: calendar
            case .chores: chores
            case .routines: routines
            case .rewards: rewards
            case .lists: lists
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
        timeZone: TimeZone
    ) -> Pulse {
        Pulse(
            calendar: calendarLine(events: snapshot.events, today: today, timeZone: timeZone),
            chores: choresLine(chores: snapshot.chores, today: today, minute: minute),
            routines: routinesLine(board: snapshot.board),
            rewards: rewardsLine(waiting: snapshot.waiting),
            lists: listsLine(lists: snapshot.lists)
        )
    }

    /// "4 today" — every event on the household-local today.
    static func calendarLine(
        events: [DayLogic.Event],
        today: String,
        timeZone: TimeZone
    ) -> Line? {
        let count = events.count { DayLogic.onDay($0, date: today, timeZone: timeZone) }
        return count > 0 ? Line(count: "\(count) today") : nil
    }

    /// "3 open · 1 late" — actionable chore ROWS, folded exactly as the
    /// Chores page lists them (a shared chore is one row). Late is the day
    /// pages' display twin, so the dot moves at the same minute the rows do.
    static func choresLine(
        chores: [DayLogic.Chore],
        today: String,
        minute: String
    ) -> Line? {
        let rows = ChoresPageLogic.rows(chores)
        let open = rows.count { row in row.occurrences.contains { $0.status == .open } }
        guard open > 0 else { return nil }
        let late = rows.count { row in
            row.occurrences.contains { DayLogic.effectivelyLate($0, today: today, minute: minute) }
        }
        return Line(count: "\(open) open", late: late > 0 ? "\(late) late" : nil)
    }

    /// "3 today" — how many family ROUTINES are scheduled today (owner
    /// 2026-08-10: "just a number of family routines today", not tasks, not
    /// windows). A shared routine counts once, whoever it belongs to; the
    /// count holds all day. No routines scheduled → a quiet door.
    static func routinesLine(board: [Components.Schemas.RoutineBoardEntry]) -> Line? {
        let count = Set(board.map(\.routineId)).count
        return count > 0 ? Line(count: "\(count) today") : nil
    }

    /// "1 waiting" — redemptions awaiting a parent, household-wide.
    static func rewardsLine(waiting: Int) -> Line? {
        waiting > 0 ? Line(count: "\(waiting) waiting") : nil
    }

    /// "Costco · 14 to buy" — the busiest grocery list (design doc: the tile
    /// badge is the shopping pulse). Nothing left to buy anywhere → quiet.
    static func listsLine(lists: [Components.Schemas.List]) -> Line? {
        let busiest = lists
            .filter { $0._type == .grocery }
            .map { (name: $0.name, toBuy: $0.itemCount - $0.checkedCount) }
            .filter { $0.toBuy > 0 }
            .max { $0.toBuy < $1.toBuy }
        guard let busiest else { return nil }
        return Line(count: "\(busiest.name) · \(busiest.toBuy) to buy")
    }
}
