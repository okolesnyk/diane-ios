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

    struct River: Equatable {
        /// Selected members' late chores (today only) — My Day's pattern.
        var catchUp: [Chore] = []
        /// The whole timed day, time-ordered: events (ended ones grey in
        /// place, they never hide — owner 2026-08-07) + timed chores
        /// (completed ones crossed and grey in place).
        var flowing: [MyDayLogic.TimelineItem] = []
        /// Untimed chores for the day, done ones crossed in place.
        var noSetTime: [Chore] = []
        /// Unclaimed up-for-grabs — everyone's business, immune to the filter.
        var pool: [Chore] = []
    }

    /// Split the family's day. Nothing folds away any more (owner
    /// 2026-08-07): finished things grey out where they stand — the view
    /// asks `hasEnded` per event.
    static func river(
        events: [Event],
        chores: [Chore],
        selected: Set<String>,
        phase: MyDayLogic.DayPhase,
        minute: String,
        timeZone: TimeZone,
        today: String? = nil
    ) -> River {
        var out = River()

        for chore in chores {
            let owner = chore.claimedByMemberId ?? chore.assigneeMemberId
            if owner == nil && chore.status == .open && chore.claimedByMemberId == nil {
                out.pool.append(chore)
                continue
            }
            guard visible(chore, selected: selected) else { continue }
            if phase == .today && chore.late && chore.status == .open {
                out.catchUp.append(chore)
            } else if chore.dueTime != nil {
                out.flowing.append(.chore(chore))
            } else {
                out.noSetTime.append(chore)
            }
        }

        for event in events where visible(event, selected: selected) {
            out.flowing.append(.event(event))
        }

        out.flowing.sort { $0.sortKey(timeZone: timeZone) < $1.sortKey(timeZone: timeZone) }
        return out
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
