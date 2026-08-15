import DianeKit
import Foundation

/// The M9e Routines page (mock page 6, rev 3): FAMILY cards — one routine x
/// one member, exactly the board's grain — bucketed Now / Later today /
/// Earlier today on the household clock. Cards in the live window come
/// expanded, the rest fold to headers; windows are display, not locks.
/// Nonisolated on purpose: Views inherit @MainActor, logic must not.
enum RoutinesPageLogic {
    typealias Entry = Components.Schemas.RoutineBoardEntry

    /// One foldable card's identity — the board's (routine, member) grain.
    static func cardKey(_ entry: Entry) -> String {
        "\(entry.routineId)|\(entry.memberId)"
    }

    struct Bucket: Equatable {
        let phase: RoutinesBoardLogic.Phase
        let entries: [Entry]

        var label: String {
            switch phase {
            case .now: "Now"
            case .laterToday: "Later today"
            case .earlier: "Earlier today"
            }
        }
    }

    /// Non-empty buckets in Now / Later / Earlier order, filtered by the
    /// app-wide member filter, each sorted window / title / member.
    static func buckets(
        entries: [Entry],
        now: String,
        selected: Set<String>
    ) -> [Bucket] {
        var grouped: [RoutinesBoardLogic.Phase: [Entry]] = [:]
        for entry in entries where selected.contains(entry.memberId) {
            let phase = RoutinesBoardLogic.phase(
                windowStart: entry.windowStart, windowEnd: entry.windowEnd, now: now
            )
            grouped[phase, default: []].append(entry)
        }
        return RoutinesBoardLogic.Phase.allCases.compactMap { phase in
            guard var list = grouped[phase], !list.isEmpty else { return nil }
            list.sort {
                ($0.windowStart, $0.title, $0.memberId) < ($1.windowStart, $1.title, $1.memberId)
            }
            return Bucket(phase: phase, entries: list)
        }
    }

    /// The card sub-line (mock grammar). `lateCount` > 0 means the trailing
    /// "N still open" clause wears red in the view.
    struct Sub: Equatable {
        var text: String
        var done = false
        var stillOpen: Int = 0
    }

    static func sub(_ entry: Entry, phase: RoutinesBoardLogic.Phase, use24: Bool) -> Sub {
        guard !entry.tasks.isEmpty else {
            return Sub(text: "No tasks yet — tap the routine to edit")
        }
        let counted = entry.tasks.count(where: { $0.status != .open })
        let total = entry.tasks.count
        let complete = counted == total
        switch phase {
        case .now:
            return complete
                ? Sub(text: "Done for today ✓", done: true)
                : Sub(text: "Until \(ClockDisplay.label(entry.windowEnd, use24: use24)) · \(counted) of \(total)")
        case .laterToday:
            return Sub(text: ClockDisplay.range(entry.windowStart, entry.windowEnd, use24: use24))
        case .earlier:
            return complete
                ? Sub(text: "All \(total) done ✓", done: true)
                : Sub(text: "\(counted) of \(total)", stillOpen: total - counted)
        }
    }

    /// Displayed streak = the walk's base plus today, computed at read (the
    /// Today page's exact rule) — a zero-task card banks nothing.
    static func displayedStreak(_ entry: Entry) -> Int {
        let counted = entry.tasks.count(where: { $0.status != .open })
        let completeToday = !entry.tasks.isEmpty && counted == entry.tasks.count
        return entry.streak + (completeToday ? 1 : 0)
    }

    /// Chip ring = the member's share of today's routine tasks (skips count:
    /// they complete the day). No tasks → an empty ring.
    static func progress(for memberID: String, entries: [Entry]) -> Double {
        let mine = entries.filter { $0.memberId == memberID }.flatMap(\.tasks)
        guard !mine.isEmpty else { return 0 }
        return Double(mine.count(where: { $0.status != .open })) / Double(mine.count)
    }

    /// Chip late dot = a window that CLOSED with something still open.
    static func hasLate(memberID: String, entries: [Entry], now: String) -> Bool {
        entries.contains { entry in
            entry.memberId == memberID
                && !entry.tasks.isEmpty
                && RoutinesBoardLogic.phase(
                    windowStart: entry.windowStart, windowEnd: entry.windowEnd, now: now
                ) == .earlier
                && entry.tasks.contains { $0.status == .open }
        }
    }

    /// Cards in the live window start expanded; everything else folded.
    static func defaultExpanded(entries: [Entry], now: String) -> Set<String> {
        Set(entries.filter {
            RoutinesBoardLogic.phase(windowStart: $0.windowStart, windowEnd: $0.windowEnd, now: now) == .now
        }.map(cardKey))
    }

    /// Cross-member reverts confirm (undo AND skip-reopen — a skip guards
    /// someone's completed day); your own are instant. A session with no
    /// member (family/kiosk) always confirms.
    static func revertNeedsConfirm(cardMemberID: String, sessionMemberID: String) -> Bool {
        sessionMemberID.isEmpty || cardMemberID != sessionMemberID
    }

    /// The last 7 household-local days, newest first — the past screen's
    /// spine ("yesterday got away from us" is the common heal case).
    static func pastDays(today: String) -> [String] {
        (1...7).map { DayLogic.addDays(today, -$0) }
    }
}
