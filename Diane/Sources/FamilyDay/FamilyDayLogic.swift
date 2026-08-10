import DianeKit
import Foundation

/// Page 2 (M9e design): the pure math behind Family Day — member chips with
/// progress rings + late dots, the river (one time-ordered family stream,
/// whole-family rows once, morning fold for the finished past), catch up,
/// the up-for-grabs pool, and the member tint washes. Reuses MyDayLogic for
/// date math, day membership, rails, and the strip.
enum FamilyDayLogic {
    typealias Event = MyDayLogic.Event
    typealias Chore = MyDayLogic.Chore
    typealias Member = Components.Schemas.Member

    // MARK: - Chips (progress rings + late dots; tap = filter, double = solo)

    struct ChipState: Equatable, Identifiable {
        let memberID: String
        /// 0…1 — the member's day: completed / (completed + open) over their
        /// chores ON the shown day. No chores → 0 (an empty ring, not a full one).
        let progress: Double
        let hasLate: Bool
        var id: String { memberID }
    }

    /// Ring = the member's WHOLE day: chores + routine tasks (routines never
    /// appear as river rows but count toward the ring — the mock's rule).
    static func chip(
        for memberID: String,
        chores: [Chore],
        board: [Components.Schemas.RoutineBoardEntry] = []
    ) -> ChipState {
        let mine = chores.filter { ($0.claimedByMemberId ?? $0.assigneeMemberId) == memberID }
        let tasks = board.filter { $0.memberId == memberID }.flatMap(\.tasks)
        let done = mine.count(where: { $0.status == .completed })
            + tasks.count(where: { $0.status != .open })
        let total = mine.count + tasks.count
        return ChipState(
            memberID: memberID,
            progress: total == 0 ? 0 : Double(done) / Double(total),
            hasLate: mine.contains { $0.late && $0.status == .open }
        )
    }

    /// Tap = toggle membership in the filter; emptying the set means
    /// "everyone" again. Double-tap = solo (remember the pre-tap set so a
    /// second double-tap restores it) — handled by the view; this is the
    /// toggle math only.
    static func toggledFilter(_ selected: Set<String>, all: [String], tapping id: String) -> Set<String> {
        var next = selected
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        return next.isEmpty || next.count == all.count ? Set(all) : next
    }

    // MARK: - Row visibility (family rows ignore every filter)

    static func visible(_ event: Event, selected: Set<String>) -> Bool {
        guard let members = event.memberIds, !members.isEmpty else { return true }
        return members.contains { selected.contains($0) }
    }

    static func visible(_ chore: Chore, selected: Set<String>) -> Bool {
        guard let owner = chore.claimedByMemberId ?? chore.assigneeMemberId else { return true }
        return selected.contains(owner)
    }

    // MARK: - The river partition

    /// A river entry: an event, or ONE row per shared chore. The engine
    /// emits an occurrence per assignee; the family page folds them back
    /// together exactly like the Chores module (owner 2026-08-08 — a shared
    /// chore was showing once per member).
    enum RiverItem: Equatable, Identifiable {
        case event(Event)
        case chores(ChoresPageLogic.Row)

        var id: String {
            switch self {
            case .event(let event): "ev-\(event.id)"
            case .chores(let row): "ch-\(row.id)"
            }
        }

        func sortKey(timeZone: TimeZone) -> Int {
            switch self {
            case .event(let event): MyDayLogic.TimelineItem.event(event).sortKey(timeZone: timeZone)
            case .chores(let row): MyDayLogic.TimelineItem.chore(row.lead).sortKey(timeZone: timeZone)
            }
        }

    }

    struct River: Equatable {
        /// Late rows — the family's debts (today AND past-day views; a late
        /// pool row is everyone's debt too — owner 2026-08-10).
        var catchUp: [ChoresPageLogic.Row] = []
        /// The whole timed day, time-ordered: events (ended ones grey in
        /// place, they never hide — owner 2026-08-07) + timed chore rows,
        /// pool included. The bold "Today's Timeline" section's top band.
        var flowing: [RiverItem] = []
        /// Rows DUE the viewed day but clockless — the middle band, behind
        /// a dashed hint (owner 2026-08-10).
        var dueToday: [ChoresPageLogic.Row] = []
        /// Undated rows — the bottom band, behind a second dashed hint
        /// (owner 2026-08-10); only the real today shows them.
        var anytime: [ChoresPageLogic.Row] = []
        /// The NEXT day's rows (window feed — recurring previews included).
        var tomorrow: [ChoresPageLogic.Row] = []
        /// Dated beyond tomorrow, within 30 days — the "Next 30 days"
        /// shelf (owner 2026-08-10), dates on the rows; one-offs only (a
        /// daily chore would spam it). Pool last, as everywhere. The
        /// Chores page owns the far future.
        var later: [ChoresPageLogic.Row] = []
    }

    static func visible(_ row: ChoresPageLogic.Row, selected: Set<String>) -> Bool {
        row.owners.isEmpty || row.owners.contains { selected.contains($0) }
    }

    /// Split the family's day. Nothing folds away any more (owner
    /// 2026-08-07): finished things grey out where they stand — the view
    /// asks `hasEnded` per event. Shared chores arrive per-assignee and
    /// leave as one row each. The pool has no shelf of its own any more
    /// (owner 2026-08-09): up-for-grabs rows spread through the same
    /// sections by date and time — late is everyone's debt, timed joins
    /// the timeline, dated lands on Due today, undated in Anytime —
    /// always AFTER the owned rows of their section and always immune to
    /// the member filter.
    static func river(
        events: [Event],
        chores: [Chore],
        window: [Chore] = [],
        actionable: [Chore] = [],
        selected: Set<String>,
        phase: MyDayLogic.DayPhase,
        minute: String,
        timeZone: TimeZone,
        today: String? = nil,
        day: String? = nil
    ) -> River {
        var out = River()
        var poolCatchUp: [ChoresPageLogic.Row] = []
        var poolDueToday: [ChoresPageLogic.Row] = []
        var poolAnytime: [ChoresPageLogic.Row] = []
        let viewed = day ?? today
        let next = MyDayLogic.addDays(viewed ?? "", 1)

        for row in ChoresPageLogic.rows(chores) {
            let pool = row.isPool
            if !pool {
                guard visible(row, selected: selected) else { continue }
            }
            // Late-done rows stay too (owner 2026-08-09): a checked catch-up
            // reads as "the catch-up got done", not a fresh on-time ✓.
            let rowLate = row.occurrences.contains {
                MyDayLogic.effectivelyLate($0, today: today ?? "", minute: minute)
                    || MyDayLogic.lateWhenDone($0, timeZone: timeZone)
            }
            if phase != .future && rowLate {
                if pool { poolCatchUp.append(row) } else { out.catchUp.append(row) }
            } else if row.dueTime != nil && row.dueDate == viewed {
                out.flowing.append(.chores(row))
            } else if row.dueDate != nil && row.dueDate == viewed {
                if pool { poolDueToday.append(row) } else { out.dueToday.append(row) }
            } else if row.dueDate == nil {
                if pool { poolAnytime.append(row) } else { out.anytime.append(row) }
            }
            // Dated for another day: Tomorrow and Later own those below.
        }
        out.catchUp += poolCatchUp
        out.dueToday += poolDueToday
        out.anytime += poolAnytime

        // Tomorrow reads the WINDOW so recurring previews show; Later reads
        // the live board (one-offs only — the window would spam repeats).
        // Pool rows stay filter-immune and sink to each section's bottom.
        func poolLast(_ rows: [ChoresPageLogic.Row]) -> [ChoresPageLogic.Row] {
            rows.filter { !$0.isPool && visible($0, selected: selected) }
                + rows.filter(\.isPool)
        }
        let horizon = MyDayLogic.addDays(viewed ?? "", 30)
        out.tomorrow = poolLast(ChoresPageLogic.rows(window.filter { $0.dueDate == next }))
        out.later = poolLast(ChoresPageLogic.rows(
            actionable
                .filter { ($0.dueDate ?? "") > next && ($0.dueDate ?? "") <= horizon }
                .sorted { ($0.dueDate ?? "", $0.id) < ($1.dueDate ?? "", $1.id) }
        ))

        for event in events where visible(event, selected: selected) {
            out.flowing.append(.event(event))
        }

        out.flowing.sort {
            let l = $0.sortKey(timeZone: timeZone)
            let r = $1.sortKey(timeZone: timeZone)
            return l == r ? $0.id < $1.id : l < r
        }
        return out
    }

    /// Where the hairline sits among river items (mirrors My Day's rule).
    static func nowIndex(items: [RiverItem], minute: String, timeZone: TimeZone) -> Int? {
        guard let now = TodayLogic.minutes(minute) else { return nil }
        for (index, item) in items.enumerated() where item.sortKey(timeZone: timeZone) > now {
            return index
        }
        return items.count
    }

    /// Has a timed event fully ended by `minute` on `day`? Drives the grey
    /// (never hides). All-day events don't end mid-day; a missing end reads
    /// as an instant event ending at its start.
    static func hasEnded(_ event: Event, minute: Int, day: String, timeZone: TimeZone) -> Bool {
        guard !event.allDay else { return false }
        guard let endInstant = event.endsAt ?? event.startsAt,
              let end = TodayLogic.parseInstant(endInstant)
        else { return false }
        let endDay = TodayLogic.dateString(for: end, timeZone: timeZone)
        if endDay > day { return false } // still running into a later day
        if endDay < day { return true }
        return TodayLogic.clockMinutes(of: end, timeZone: timeZone) <= minute
    }

    // MARK: - Member tint (device-local setting; wash rows in owner colors)

    /// The hex colors a row washes in: solid for one owner, diagonal bands
    /// for shared, empty for whole-family and pool rows (neutral).
    static func tintColors(forOwners owners: [String], members: [Member]) -> [String] {
        owners.compactMap { id in members.first(where: { $0.id == id })?.color }
    }

    static func owners(of event: Event) -> [String] {
        event.memberIds ?? []
    }

    static func owners(of chore: Chore) -> [String] {
        (chore.claimedByMemberId ?? chore.assigneeMemberId).map { [$0] } ?? []
    }

    // MARK: - Strip dots (family-wide: anyone's load counts)

    static func familyDots(
        for date: String,
        events: [Event],
        chores: [Chore],
        timeZone: TimeZone
    ) -> MyDayLogic.DayDots {
        MyDayLogic.DayDots(
            hasEvents: events.contains { MyDayLogic.onDay($0, date: date, timeZone: timeZone) },
            hasChores: chores.contains { $0.dueDate == date }
        )
    }
}
