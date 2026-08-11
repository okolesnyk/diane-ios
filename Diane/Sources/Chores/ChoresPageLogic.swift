import DianeKit
import Foundation

/// Page 5 (M9e design): the Chores module — All · Scheduled · Anytime, with
/// ONE chip filter over all three, a red Catch up first, the Anytime shelf
/// promoted above the days, then Today through the week and Later.
///
/// Pure math only; the view owns presentation. Two fetches feed it: the
/// actionable view (no from/to — late rows, the undated shelf, and deadlines
/// beyond the week) and a one-week window (the dated day groups, completions
/// included). They never overlap: late rows anchor before today, the window
/// starts at today, and Later only takes what the window can't reach.
enum ChoresPageLogic {
    typealias Occurrence = Components.Schemas.ChoreOccurrence
    typealias Member = Components.Schemas.Member

    /// The "Anyone" pseudo-member — the dashed chip at the end of the family
    /// row. It rides in the shared MemberFilterStore alongside real member
    /// ids; pages without a pool chip never pass it in `all`, so their member
    /// math is untouched.
    static let poolID = "__anyone__"

    /// Three tabs, All default (owner's structure, rev 3).
    enum Tab: String, CaseIterable, Identifiable {
        case all = "All"
        case scheduled = "Scheduled"
        case anytime = "Anytime"
        var id: String { rawValue }
    }

    /// Day groups cover Today through the week; everything dated beyond it
    /// collapses into Later.
    static let weekSpanDays = 6

    /// How far Later can see. "All" has to mean all (owner 2026-08-06), so
    /// the window reaches a quarter out — far enough that a monthly or
    /// quarterly chore always has a row somewhere on this page. Later shows
    /// each chore's NEXT date only, so the extra reach costs rows, not noise.
    static let laterSpanDays = 89

    /// The page paints from the week, then fills Later in behind it — the
    /// quarter sweep is the big fetch and nothing on screen waits for it.
    static func weekRange(today: String) -> (from: String, to: String) {
        (today, DayLogic.addDays(today, weekSpanDays))
    }

    static func laterRange(today: String) -> (from: String, to: String) {
        (DayLogic.addDays(today, weekSpanDays + 1), DayLogic.addDays(today, laterSpanDays))
    }

    // MARK: - Rows (a shared chore is ONE row)

    /// One visible row. The engine gives every assignee their own occurrence,
    /// so a shared chore arrives as N rows; the page folds them back into one
    /// with a facepile — and one tap completes them all, which is exactly what
    /// the server does in a single transaction (owner ruling, rev 7).
    struct Row: Identifiable, Equatable {
        let occurrences: [Occurrence]

        var lead: Occurrence { occurrences[0] }
        var id: String { occurrences.map(\.id).joined(separator: "+") }
        var choreId: String { lead.choreId }
        var title: String { lead.title }
        var emoji: String? { lead.emoji }
        var starValue: Int { lead.starValue }
        var dueDate: String? { lead.dueDate }
        var dueTime: String? { lead.dueTime }
        var dueMode: Occurrence.DueModePayload? { lead.dueMode }

        /// Claimer first, then assignee; empty = the pool.
        var owners: [String] {
            occurrences.compactMap { $0.claimedByMemberId ?? $0.assigneeMemberId }
        }
        var isPool: Bool { owners.isEmpty }
        /// A shared row reads done only when everyone named is done.
        var completed: Bool { occurrences.allSatisfy { $0.status == .completed } }
        var late: Bool { occurrences.contains { $0.late && $0.status == .open } }
        /// Whoever the stars went to — the owners, or the tapper on a pool row.
        var credited: [String] {
            owners.isEmpty ? occurrences.compactMap(\.completedByMemberId) : owners
        }
    }

    /// Fold occurrences into rows, grouping a shared chore's per-assignee
    /// occurrences by (chore, date). Input order decides row order.
    static func rows(_ occurrences: [Occurrence]) -> [Row] {
        var order: [String] = []
        var groups: [String: [Occurrence]] = [:]
        for occurrence in occurrences {
            let key = "\(occurrence.choreId)|\(occurrence.dueDate ?? "")"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(occurrence)
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            return Row(occurrences: group.sorted { $0.id < $1.id })
        }
    }

    /// Catch up reads oldest debt first (owner 2026-08-10 — the pages
    /// disagreed): date, then time, then title — pool rows sink last, the
    /// standing rule.
    static func debtSorted(_ rows: [Row]) -> [Row] {
        let sorted = rows.sorted {
            ($0.dueDate ?? "", $0.dueTime ?? "99:99", $0.title, $0.id)
                < ($1.dueDate ?? "", $1.dueTime ?? "99:99", $1.title, $1.id)
        }
        return sorted.filter { !$0.isPool } + sorted.filter(\.isPool)
    }

    /// Timed first in clock order, then untimed by title. Deterministic.
    static func order(_ a: Row, _ b: Row) -> Bool {
        (a.dueTime ?? "99:99", a.title, a.id) < (b.dueTime ?? "99:99", b.title, b.id)
    }

    // MARK: - Filter

    /// `effective` is the resolved chip set (never empty — "everyone" is
    /// expanded by the caller) and carries `poolID` when Anyone is on.
    /// Soloing a member keeps the pool visible: unowned chores are everyone's
    /// business, the Today page's rule.
    static func isVisible(_ row: Row, effective: Set<String>) -> Bool {
        row.isPool
            ? effective.contains(poolID)
            : row.owners.contains { effective.contains($0) }
    }

    /// The badge on the Anyone chip: open chores nobody owns yet.
    static func poolCount(_ occurrences: [Occurrence]) -> Int {
        rows(occurrences).count { $0.isPool && !$0.completed }
    }

    // MARK: - Sections

    struct Section: Identifiable, Equatable {
        enum Kind: Equatable { case catchUp, anytime, day, later }

        let id: String
        let title: String
        let kind: Kind
        let rows: [Row]
        /// A cleared day wears a ✓ on its header.
        let allDone: Bool
        /// The date a "+ New chore" here prefills (nil = undated).
        let newChoreDate: String?

        /// A dotted add-row ends every section except Catch up — you don't
        /// plan new work inside a debt (owner verdict 2026-08-04).
        var showsAddRow: Bool { kind != .catchUp }
    }

    /// The graced rule, row-level: late server-side OR >15 min past a
    /// same-day at/due time (the display twin of the server's constant).
    static func effectivelyLate(_ row: Row, today: String, minute: String?) -> Bool {
        guard let minute else { return row.late }
        return row.late || row.occurrences.contains {
            DayLogic.effectivelyLate($0, today: today, minute: minute)
        }
    }

    static func sections(
        tab: Tab,
        actionable: [Occurrence],
        window: [Occurrence],
        today: String,
        effective: Set<String>,
        minute: String? = nil
    ) -> [Section] {
        let weekEnd = DayLogic.addDays(today, weekSpanDays)
        let live = rows(actionable).filter { isVisible($0, effective: effective) }
        let dated = rows(window).filter { isVisible($0, effective: effective) }

        var out: [Section] = []

        // Catch up — every late chore, pulled out of its day group (the day
        // pages' pattern; the owner asked for it on All as well as Scheduled).
        if tab != .anytime {
            let late = debtSorted(live.filter {
                effectivelyLate($0, today: today, minute: minute) && !$0.completed
            })
            if !late.isEmpty {
                out.append(.init(
                    id: "catchup", title: "Catch up", kind: .catchUp,
                    rows: late, allDone: false, newChoreDate: nil
                ))
            }
        }

        // The Anytime shelf, promoted above the days (owner's fix for "it
        // gets lost down the bottom"). Undated only — a deadline is dated.
        if tab != .scheduled {
            let shelf = live.filter { $0.dueDate == nil }.sorted(by: order)
            if !shelf.isEmpty {
                out.append(.init(
                    id: "anytime", title: "Anytime", kind: .anytime,
                    rows: shelf, allDone: shelf.allSatisfy(\.completed), newChoreDate: nil
                ))
            }
        }

        guard tab != .anytime else { return out }

        // Today through the week, empty days skipped. A row that went late
        // lives in Catch up ONLY — today's group must not show its twin.
        let grouped = dated.filter {
            $0.dueDate != nil && !(effectivelyLate($0, today: today, minute: minute) && !$0.completed)
        }
        let byDate = Dictionary(grouping: grouped) { $0.dueDate! }
        for offset in 0...weekSpanDays {
            let date = DayLogic.addDays(today, offset)
            guard let dayRows = byDate[date], !dayRows.isEmpty else { continue }
            let sorted = dayRows.sorted(by: order)
            out.append(.init(
                id: date,
                title: dayTitle(date, today: today),
                kind: .day,
                rows: sorted,
                allDone: sorted.allSatisfy(\.completed),
                newChoreDate: date
            ))
        }

        // Later — everything dated past the week: deadlines, and the next
        // date of anything that recurs more slowly than the window shows.
        // ONE row per chore (its soonest), never a daily chore fanned out
        // across three months. The actionable view chips in whatever sits
        // beyond even the window's reach.
        let windowEnd = DayLogic.addDays(today, laterSpanDays)
        let beyond = dated.filter { $0.dueDate.map { $0 > weekEnd } ?? false }
            + live.filter { row in !row.late && (row.dueDate.map { $0 > windowEnd } ?? false) }
        var seenChores: Set<String> = []
        let later = beyond
            .sorted { ($0.dueDate ?? "", $0.title, $0.id) < ($1.dueDate ?? "", $1.title, $1.id) }
            .filter { seenChores.insert($0.choreId).inserted }
        if !later.isEmpty {
            out.append(.init(
                id: "later", title: "Later", kind: .later,
                rows: later, allDone: later.allSatisfy(\.completed), newChoreDate: nil
            ))
        }
        return out
    }

    /// The empty-state line, scoped to the tab that came up dry.
    static func emptyLine(for tab: Tab) -> String {
        switch tab {
        case .all: "Nothing for this filter."
        case .scheduled: "Nothing scheduled for this filter."
        case .anytime: "Nothing anytime for this filter."
        }
    }

    // MARK: - Day titles

    /// "Today — Friday 31 July" / "Tomorrow — …" / "Sunday 2 August".
    static func dayTitle(_ date: String, today: String) -> String {
        let long = longDate(date)
        if date == today { return long.isEmpty ? "Today" : "Today — \(long)" }
        if date == DayLogic.addDays(today, 1) {
            return long.isEmpty ? "Tomorrow" : "Tomorrow — \(long)"
        }
        return long.isEmpty ? date : long
    }

    /// Weekday + day + month, ordered by the reader's locale.
    static func longDate(_ date: String) -> String {
        let parts = date.split(separator: "-").compactMap { Int(String($0)) }
        guard parts.count == 3 else { return "" }
        var components = DateComponents()
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let day = calendar.date(from: components) else { return "" }
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMMM d")
        return formatter.string(from: day)
    }

    // MARK: - Row copy

    /// The plain-words sub under the title. Never the owner's name — the
    /// facepile already says who (rev 6 row anatomy).
    static func subtitle(_ row: Row, today: String, names: [String: String]) -> String? {
        if row.completed {
            guard let completer = row.occurrences.compactMap(\.completedByMemberId).first,
                  !row.owners.contains(completer),
                  let name = names[completer]
            else { return nil }
            return "done by \(name)"
        }
        // The day pages' exact grammar, no "Late —" prefix (owner
        // 2026-08-10 — the two Catch ups disagreed): "Due yesterday 16:00",
        // "Due Thu, Jun 18"; the red lane already says late.
        if row.late {
            return DayLogic.dueOrigin(row.lead, today: today)
        }
        // Just the date (owner 2026-08-10 — "flexible until then" was noise).
        if row.dueMode == .by, let due = row.dueDate {
            return "By \(ChoresManageLogic.monthDay(due))"
        }
        // Undated rows carry no sub — the Anytime lane already says it
        // (owner 2026-08-10).
        return row.dueTime
    }

    /// The cross-member un-check confirm (owner approved): un-checking your
    /// own reverts instantly, someone else's asks first and names the cost.
    static func undoPrompt(_ row: Row, names: [String: String]) -> String {
        let credited = row.credited.compactMap { names[$0] }
        guard !credited.isEmpty else { return "Undo this check?" }
        return "Undo \(credited.joined(separator: " & "))'s check?"
    }

    static func undoDetail(_ row: Row, names: [String: String]) -> String {
        let credited = row.credited.compactMap { names[$0] }
        let stars = row.starValue == 1 ? "1 ★" : "\(row.starValue) ★"
        if credited.count > 1 { return "They each lose \(stars)." }
        guard let name = credited.first else { return "Those stars go back." }
        return "\(name) loses \(stars)."
    }

    /// Whose check is this? Reverting someone else's is the one that confirms.
    static func needsUndoConfirm(_ row: Row, me: String) -> Bool {
        !row.credited.isEmpty && row.credited.contains { $0 != me }
    }
}
