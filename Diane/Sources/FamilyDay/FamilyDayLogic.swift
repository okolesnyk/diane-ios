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
        /// Finished business that folds away: completed chores + past events.
        var folded: [MyDayLogic.TimelineItem] = []
        /// The live stream: upcoming events + open timed chores, time-ordered.
        var flowing: [MyDayLogic.TimelineItem] = []
        /// Open untimed chores for the day (all selected members').
        var noSetTime: [Chore] = []
        /// Unclaimed up-for-grabs — everyone's business, immune to the filter.
        var pool: [Chore] = []
    }

    /// Split the family's day. `minute` is the household clock ("HH:mm");
    /// off-today the fold takes completed chores only (events just render in
    /// place — the past day IS the record, the future has nothing to fold).
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
        let now = TodayLogic.minutes(minute) ?? 0

        for chore in chores {
            let owner = chore.claimedByMemberId ?? chore.assigneeMemberId
            if owner == nil && chore.status == .open && chore.claimedByMemberId == nil {
                out.pool.append(chore)
                continue
            }
            guard visible(chore, selected: selected) else { continue }
            if phase == .today && chore.late && chore.status == .open {
                out.catchUp.append(chore)
            } else if chore.status == .completed {
                out.folded.append(.chore(chore))
            } else if chore.dueTime != nil {
                out.flowing.append(.chore(chore))
            } else {
                out.noSetTime.append(chore)
            }
        }

        for event in events where visible(event, selected: selected) {
            let item = MyDayLogic.TimelineItem.event(event)
            // Today: an event folds only 15 min after it ENDED — an ongoing
            // event never hides (owner rule 2026-08-06). All-day never folds.
            if phase == .today && foldsAway(event, minute: now, day: today ?? "", timeZone: timeZone) {
                out.folded.append(item)
            } else {
                out.flowing.append(item)
            }
        }

        out.folded.sort { $0.sortKey(timeZone: timeZone) < $1.sortKey(timeZone: timeZone) }
        out.flowing.sort { $0.sortKey(timeZone: timeZone) < $1.sortKey(timeZone: timeZone) }
        return out
    }

    static func foldLabel(_ folded: [MyDayLogic.TimelineItem]) -> String {
        "Complete / Past events — \(folded.count) done"
    }

    /// Minutes of grace after an event ENDS before it folds away (owner rule
    /// 2026-08-06: never hide an ongoing event; hide it 15 min after it
    /// finished).
    static let foldGraceMinutes = 15

    /// Does a timed event fold into "Earlier" at `minute` on `day`? Only
    /// once its END (not start) is `foldGraceMinutes` behind the clock;
    /// missing end reads as an instant event ending at its start.
    static func foldsAway(_ event: Event, minute: Int, day: String, timeZone: TimeZone) -> Bool {
        guard !event.allDay else { return false }
        guard let endInstant = event.endsAt ?? event.startsAt,
              let end = TodayLogic.parseInstant(endInstant)
        else { return false }
        let endDay = TodayLogic.dateString(for: end, timeZone: timeZone)
        if endDay > day { return false } // still running into a later day
        if endDay < day { return true }
        return TodayLogic.clockMinutes(of: end, timeZone: timeZone) + foldGraceMinutes <= minute
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
