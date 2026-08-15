import DianeKit
import Foundation
import Testing

@testable import Diane

/// M9e page 5 — the Chores module's section math: shared-chore folding, the
/// three tabs, Catch up / Anytime / the days / Later, and the filter's pool
/// pseudo-member.
struct ChoresPageLogicTests {
    typealias Occurrence = Components.Schemas.ChoreOccurrence

    private let today = "2026-08-06"
    private let me = "m-alex"
    private let kid = "m-maya"
    private let sib = "m-bruno"

    private func occ(
        id: String,
        choreId: String = "c1",
        title: String = "Chore",
        stars: Int = 2,
        dueDate: String? = nil,
        dueMode: Occurrence.DueModePayload? = nil,
        dueTime: String? = nil,
        status: Occurrence.StatusPayload = .open,
        late: Bool = false,
        assignee: String? = nil,
        claimedBy: String? = nil,
        completedBy: String? = nil
    ) -> Occurrence {
        .init(
            id: id,
            choreId: choreId,
            title: title,
            emoji: nil,
            notes: nil,
            starValue: stars,
            upForGrabs: assignee == nil && claimedBy == nil,
            dueDate: dueDate,
            dueMode: dueMode,
            dueTime: dueTime,
            status: status,
            late: late,
            assigneeMemberId: assignee,
            claimedByMemberId: claimedBy,
            completedByMemberId: completedBy,
            completedAt: status == .completed ? "2026-08-06T09:00:00.000Z" : nil
        )
    }

    private var everyone: Set<String> {
        [me, kid, sib, ChoresPageLogic.poolID]
    }

    // MARK: Shared-chore folding

    @Test func sharedChoreFoldsIntoOneRow() {
        let rows = ChoresPageLogic.rows([
            occ(id: "rake|bruno", choreId: "rake", dueDate: today, assignee: sib),
            occ(id: "rake|maya", choreId: "rake", dueDate: today, assignee: kid),
        ])
        #expect(rows.count == 1)
        #expect(Set(rows[0].owners) == [sib, kid])
        #expect(!rows[0].isPool)
    }

    @Test func sameChoreOnDifferentDaysStaysTwoRows() {
        let rows = ChoresPageLogic.rows([
            occ(id: "cat|today", choreId: "cat", dueDate: today, assignee: kid),
            occ(id: "cat|tomorrow", choreId: "cat", dueDate: "2026-08-07", assignee: kid),
        ])
        #expect(rows.count == 2)
    }

    @Test func sharedRowIsDoneOnlyWhenEveryoneIsDone() {
        let half = ChoresPageLogic.rows([
            occ(id: "a", choreId: "rake", dueDate: today, status: .completed, assignee: sib, completedBy: sib),
            occ(id: "b", choreId: "rake", dueDate: today, assignee: kid),
        ])[0]
        #expect(!half.completed)

        let both = ChoresPageLogic.rows([
            occ(id: "a", choreId: "rake", dueDate: today, status: .completed, assignee: sib, completedBy: sib),
            occ(id: "b", choreId: "rake", dueDate: today, status: .completed, assignee: kid, completedBy: kid),
        ])[0]
        #expect(both.completed)
    }

    @Test func poolRowHasNoOwners() {
        let row = ChoresPageLogic.rows([occ(id: "p", choreId: "windows")])[0]
        #expect(row.isPool)
        #expect(row.owners.isEmpty)
    }

    // MARK: Sections

    private func sections(
        tab: ChoresPageLogic.Tab = .all,
        actionable: [Occurrence] = [],
        window: [Occurrence] = [],
        effective: Set<String>? = nil
    ) -> [ChoresPageLogic.Section] {
        ChoresPageLogic.sections(
            tab: tab,
            actionable: actionable,
            window: window,
            today: today,
            effective: effective ?? everyone
        )
    }

    @Test func allTabOrdersCatchUpThenAnytimeThenTheDays() {
        let out = sections(
            actionable: [
                occ(id: "late", choreId: "kit", dueDate: "2026-08-05", late: true, assignee: sib),
                occ(id: "shelf", choreId: "windows"),
            ],
            window: [occ(id: "cat", choreId: "cat", dueDate: today, assignee: kid)]
        )
        #expect(out.map(\.kind) == [.catchUp, .anytime, .day])
        #expect(out[0].title == "Catch up")
        #expect(out[1].title == "Anytime")
        #expect(out[2].title.hasPrefix("Today — "))
    }

    @Test func scheduledTabDropsTheAnytimeShelfButKeepsCatchUp() {
        let out = sections(
            tab: .scheduled,
            actionable: [
                occ(id: "late", choreId: "kit", dueDate: "2026-08-05", late: true, assignee: sib),
                occ(id: "shelf", choreId: "windows"),
            ],
            window: [occ(id: "cat", choreId: "cat", dueDate: today, assignee: kid)]
        )
        #expect(out.map(\.kind) == [.catchUp, .day])
    }

    @Test func anytimeTabIsTheShelfAlone() {
        let out = sections(
            tab: .anytime,
            actionable: [
                occ(id: "late", choreId: "kit", dueDate: "2026-08-05", late: true, assignee: sib),
                occ(id: "shelf", choreId: "windows"),
            ],
            window: [occ(id: "cat", choreId: "cat", dueDate: today, assignee: kid)]
        )
        #expect(out.map(\.kind) == [.anytime])
    }

    /// A deadline is dated — it belongs in a day group, never on the shelf.
    @Test func byDateDeadlineIsNotAnytime() {
        let out = sections(
            actionable: [
                occ(id: "garage", choreId: "garage", dueDate: "2026-08-09", dueMode: .by),
            ],
            window: [occ(id: "garage", choreId: "garage", dueDate: "2026-08-09", dueMode: .by)]
        )
        #expect(out.map(\.kind) == [.day])
    }

    @Test func deadlineBeyondTheWeekLandsInLater() {
        let far = occ(id: "garage", choreId: "garage", dueDate: "2026-09-15", dueMode: .by)
        let out = sections(actionable: [far], window: [far])
        #expect(out.map(\.kind) == [.later])
        #expect(out[0].title == "Later")
    }

    /// "All" has to mean all: a chore that recurs past even the window's
    /// reach still gets its row, from the actionable view.
    @Test func aDateBeyondTheWholeWindowStillReachesLater() {
        let out = sections(
            actionable: [occ(id: "boiler", choreId: "boiler", dueDate: "2027-03-01", dueMode: .by)]
        )
        #expect(out.map(\.kind) == [.later])
    }

    /// Later shows each chore's NEXT date only — a daily chore must never
    /// fan out across the quarter.
    @Test func laterCollapsesAChoreToItsSoonestDate() {
        let out = sections(window: [
            occ(id: "cat|0820", choreId: "cat", dueDate: "2026-08-20", assignee: kid),
            occ(id: "cat|0814", choreId: "cat", dueDate: "2026-08-14", assignee: kid),
            occ(id: "cat|0901", choreId: "cat", dueDate: "2026-09-01", assignee: kid),
            occ(id: "bins|0825", choreId: "bins", dueDate: "2026-08-25", assignee: me),
        ])
        #expect(out.map(\.kind) == [.later])
        #expect(out[0].rows.count == 2)
        #expect(out[0].rows.map(\.dueDate) == ["2026-08-14", "2026-08-25"])
    }

    /// A chore inside the week keeps its day group AND may still show its
    /// next date in Later — but only once, and only beyond the week.
    @Test func theWeekIsNotDuplicatedIntoLater() {
        let out = sections(window: [
            occ(id: "cat|today", choreId: "cat", dueDate: today, assignee: kid),
            occ(id: "cat|0901", choreId: "cat", dueDate: "2026-09-01", assignee: kid),
        ])
        #expect(out.map(\.kind) == [.day, .later])
        #expect(out[0].rows.map(\.dueDate) == [today])
        #expect(out[1].rows.map(\.dueDate) == ["2026-09-01"])
    }

    @Test func lateRowsAreOnlyEverInCatchUp() {
        let out = sections(
            actionable: [occ(id: "late", choreId: "kit", dueDate: "2026-08-05", late: true, assignee: sib)],
            window: []
        )
        #expect(out.count == 1)
        #expect(out[0].kind == .catchUp)
    }

    @Test func emptyDaysAreSkippedAndTomorrowIsNamed() {
        let out = sections(window: [occ(id: "lawn", choreId: "lawn", dueDate: "2026-08-07", assignee: me)])
        #expect(out.count == 1)
        #expect(out[0].title.hasPrefix("Tomorrow — "))
    }

    @Test func aClearedDayWearsItsCheck() {
        let out = sections(window: [
            occ(id: "a", choreId: "cat", dueDate: today, status: .completed, assignee: kid, completedBy: kid),
        ])
        #expect(out[0].allDone)
    }

    @Test func catchUpTakesNoAddRow() {
        let out = sections(
            actionable: [occ(id: "late", choreId: "kit", dueDate: "2026-08-05", late: true, assignee: sib)]
        )
        #expect(!out[0].showsAddRow)
    }

    @Test func dayAddRowsPrefillTheirOwnDate() {
        let out = sections(window: [occ(id: "lawn", choreId: "lawn", dueDate: "2026-08-07", assignee: me)])
        #expect(out[0].newChoreDate == "2026-08-07")
        #expect(out[0].showsAddRow)
    }

    /// Owner 2026-08-08: >15 min past a same-day at/due time = Catch up,
    /// and today's group must not show the twin.
    @Test func timeLateRowsMoveToCatchUpOnly() {
        let timed = occ(id: "t", choreId: "t", dueDate: today, dueTime: "22:00", assignee: sib)
        let out = ChoresPageLogic.sections(
            tab: .all, actionable: [timed], window: [timed],
            today: today, effective: everyone, minute: "22:20"
        )
        #expect(out.map(\.kind) == [.catchUp])
        // Inside the grace it stays a normal Today row.
        let calm = ChoresPageLogic.sections(
            tab: .all, actionable: [timed], window: [timed],
            today: today, effective: everyone, minute: "22:10"
        )
        #expect(calm.map(\.kind) == [.day])
    }

    // MARK: Filter

    @Test func soloingAMemberKeepsThePoolVisible() {
        let solo: Set<String> = [kid, ChoresPageLogic.poolID]
        let mine = ChoresPageLogic.rows([occ(id: "a", choreId: "cat", dueDate: today, assignee: kid)])[0]
        let theirs = ChoresPageLogic.rows([occ(id: "b", choreId: "kit", dueDate: today, assignee: sib)])[0]
        let pool = ChoresPageLogic.rows([occ(id: "c", choreId: "windows")])[0]
        #expect(ChoresPageLogic.isVisible(mine, effective: solo))
        #expect(!ChoresPageLogic.isVisible(theirs, effective: solo))
        #expect(ChoresPageLogic.isVisible(pool, effective: solo))
    }

    @Test func soloingAnyoneHidesEveryOwnedRow() {
        let solo: Set<String> = [ChoresPageLogic.poolID]
        let mine = ChoresPageLogic.rows([occ(id: "a", choreId: "cat", dueDate: today, assignee: kid)])[0]
        let pool = ChoresPageLogic.rows([occ(id: "c", choreId: "windows")])[0]
        #expect(!ChoresPageLogic.isVisible(mine, effective: solo))
        #expect(ChoresPageLogic.isVisible(pool, effective: solo))
    }

    @Test func aSharedRowSurvivesIfAnyOwnerIsOn() {
        let row = ChoresPageLogic.rows([
            occ(id: "a", choreId: "rake", dueDate: today, assignee: sib),
            occ(id: "b", choreId: "rake", dueDate: today, assignee: kid),
        ])[0]
        #expect(ChoresPageLogic.isVisible(row, effective: [kid]))
        #expect(!ChoresPageLogic.isVisible(row, effective: [me]))
    }

    @Test func poolCountIgnoresDoneAndOwnedRows() {
        let count = ChoresPageLogic.poolCount([
            occ(id: "a", choreId: "windows"),
            occ(id: "b", choreId: "filter", assignee: me),
            occ(id: "c", choreId: "garage", status: .completed, completedBy: me),
        ])
        #expect(count == 1)
    }

    @Test func filterHidesSectionsThatGoEmpty() {
        let out = sections(
            actionable: [occ(id: "late", choreId: "kit", dueDate: "2026-08-05", late: true, assignee: sib)],
            window: [occ(id: "cat", choreId: "cat", dueDate: today, assignee: kid)],
            effective: [me]
        )
        #expect(out.isEmpty)
    }

    // MARK: Copy

    @Test func todayAndTomorrowAreNamed() {
        #expect(ChoresPageLogic.dayTitle(today, today: today).hasPrefix("Today — "))
        #expect(ChoresPageLogic.dayTitle("2026-08-07", today: today).hasPrefix("Tomorrow — "))
        let later = ChoresPageLogic.dayTitle("2026-08-09", today: today)
        #expect(!later.hasPrefix("Today"))
        #expect(!later.hasPrefix("Tomorrow"))
        #expect(!later.isEmpty)
    }

    /// Owner 2026-08-10: both Catch ups read oldest debt first, pool last.
    @Test func catchUpReadsOldestDebtFirstPoolLast() {
        let out = sections(actionable: [
            occ(id: "new", choreId: "new", dueDate: "2026-08-05", dueTime: "16:00", late: true, assignee: sib),
            occ(id: "old", choreId: "old", dueDate: "2026-06-18", late: true, assignee: kid),
            occ(id: "pool-old", choreId: "pool", dueDate: "2026-06-01", late: true),
        ])
        #expect(out[0].kind == .catchUp)
        #expect(out[0].rows.map(\.id) == ["old", "new", "pool-old"])
    }

    @Test func subtitleNamesTheDeadlineAndTheLateOrigin() {
        let deadline = ChoresPageLogic.rows([
            occ(id: "g", choreId: "garage", dueDate: "2026-08-15", dueMode: .by),
        ])[0]
        #expect(ChoresPageLogic.subtitle(deadline, today: today, names: [:], use24: true) == "By Aug 15")

        let late = ChoresPageLogic.rows([
            occ(id: "k", choreId: "kit", dueDate: "2026-08-05", late: true, assignee: sib),
        ])[0]
        #expect(ChoresPageLogic.subtitle(late, today: today, names: [:], use24: true) == "Due Wed, Aug 5")

        let shelf = ChoresPageLogic.rows([occ(id: "w", choreId: "windows")])[0]
        #expect(ChoresPageLogic.subtitle(shelf, today: today, names: [:], use24: true) == nil)
    }

    /// D06's rule, kept: a done row names the helper only when it wasn't the
    /// owner's own work.
    @Test func doneSubtitleNamesOnlyAStandIn() {
        let names = [me: "Alex", kid: "Maya"]
        let ownWork = ChoresPageLogic.rows([
            occ(id: "a", choreId: "cat", dueDate: today, status: .completed, assignee: kid, completedBy: kid),
        ])[0]
        #expect(ChoresPageLogic.subtitle(ownWork, today: today, names: names, use24: true) == nil)

        let helped = ChoresPageLogic.rows([
            occ(id: "b", choreId: "cat", dueDate: today, status: .completed, assignee: kid, completedBy: me),
        ])[0]
        #expect(ChoresPageLogic.subtitle(helped, today: today, names: names, use24: true) == "done by Alex")
    }

    @Test func crossMemberUnchecksConfirmAndNameTheCost() {
        let names = [me: "Alex", kid: "Maya", sib: "Bruno"]
        let theirs = ChoresPageLogic.rows([
            occ(id: "a", choreId: "cat", dueDate: today, status: .completed, assignee: kid, completedBy: kid),
        ])[0]
        #expect(ChoresPageLogic.needsUndoConfirm(theirs, me: me))
        #expect(ChoresPageLogic.undoPrompt(theirs, names: names) == "Undo Maya's check?")
        #expect(ChoresPageLogic.undoDetail(theirs, names: names) == "Maya loses 2 ★.")

        let mine = ChoresPageLogic.rows([
            occ(id: "b", choreId: "cat", dueDate: today, status: .completed, assignee: me, completedBy: me),
        ])[0]
        #expect(!ChoresPageLogic.needsUndoConfirm(mine, me: me))

        let shared = ChoresPageLogic.rows([
            occ(id: "c", choreId: "rake", dueDate: today, status: .completed, assignee: kid, completedBy: kid),
            occ(id: "d", choreId: "rake", dueDate: today, status: .completed, assignee: sib, completedBy: sib),
        ])[0]
        #expect(ChoresPageLogic.undoDetail(shared, names: names) == "They each lose 2 ★.")
    }

    /// A pool row's stars go to whoever tapped it, so undoing your own is
    /// still instant.
    @Test func poolRowCreditsTheTapper() {
        let row = ChoresPageLogic.rows([
            occ(id: "p", choreId: "windows", status: .completed, completedBy: me),
        ])[0]
        #expect(row.credited == [me])
        #expect(!ChoresPageLogic.needsUndoConfirm(row, me: me))
        #expect(ChoresPageLogic.needsUndoConfirm(row, me: kid))
    }

    // MARK: History

    @Test func historyPeriodsWindowBackwardFromToday() {
        #expect(ChoreHistoryLogic.range(.today, today: today)?.from == today)
        #expect(ChoreHistoryLogic.range(.week, today: today)?.from == "2026-07-31")
        #expect(ChoreHistoryLogic.range(.month, today: today)?.from == "2026-07-08")
        #expect(ChoreHistoryLogic.range(.all, today: today) == nil)
    }

    @Test func historyGroupsByLocalDayAndMergesSharedChoreDays() {
        // A shared chore-day (same chore + action + dueDate) is ONE row with
        // both entries (owner 2026-08-09, like Family Day); the same chore's
        // dismissal — and any other day — stays its own row.
        let entries: [ChoreHistoryLogic.Entry] = [
            .init(
                id: "1", choreId: "cat", title: "Feed the cat", emoji: nil, action: .completed,
                occurredAt: "2026-08-06T19:26:00.000Z", dueDate: today, memberId: kid,
                completedByMemberId: kid, starsAwarded: 1
            ),
            .init(
                id: "1b", choreId: "cat", title: "Feed the cat", emoji: nil, action: .completed,
                occurredAt: "2026-08-06T07:26:00.000Z", dueDate: today, memberId: me,
                completedByMemberId: me, starsAwarded: 1
            ),
            .init(
                id: "2", choreId: "plants", title: "Water the plants", emoji: nil, action: .dismissed,
                occurredAt: "2026-08-05T20:00:00.000Z", dueDate: "2026-08-05", memberId: me,
                completedByMemberId: nil, starsAwarded: 0
            ),
        ]
        let groups = ChoreHistoryLogic.groups(entries, timeZone: TimeZone(identifier: "UTC")!)
        #expect(groups.map(\.date) == ["2026-08-06", "2026-08-05"])
        #expect(groups[0].rows.map { $0.entries.map(\.id) } == [["1", "1b"]])
        #expect(groups[0].rows[0].stars == 2)
        #expect(groups[1].rows.map(\.id) == ["2"])
    }

    /// Owner 2026-08-09: History undo always asks (the status circle is the
    /// control, like the WebUI) — the prompt names the whole crew and the
    /// per-head cost; dismissals read as "bring back".
    @Test func historyUndoConfirmsCrossMemberAndNamesTheStars() {
        let names = [me: "Alex", kid: "Maya"]
        let theirs = ChoreHistoryLogic.Entry(
            id: "1", choreId: "cat", title: "Feed the cat", emoji: nil, action: .completed,
            occurredAt: "2026-08-06T07:26:00.000Z", dueDate: today, memberId: kid,
            completedByMemberId: kid, starsAwarded: 1, undoable: true
        )
        let solo = ChoreHistoryLogic.Row(entries: [theirs])
        #expect(ChoreHistoryLogic.undoPrompt(solo, names: names) == "Undo Maya's check? They lose 1 ★.")

        let mine = ChoreHistoryLogic.Entry(
            id: "1b", choreId: "cat", title: "Feed the cat", emoji: nil, action: .completed,
            occurredAt: "2026-08-06T06:26:00.000Z", dueDate: today, memberId: me,
            completedByMemberId: me, starsAwarded: 1, undoable: true
        )
        let shared = ChoreHistoryLogic.Row(entries: [theirs, mine])
        #expect(
            ChoreHistoryLogic.undoPrompt(shared, names: names)
                == "Undo Maya & Alex's checks? They each lose 1 ★."
        )

        let dismissed = ChoreHistoryLogic.Entry(
            id: "2", choreId: "porch", title: "Tidy the porch", emoji: nil, action: .dismissed,
            occurredAt: "2026-08-06T07:26:00.000Z", dueDate: today, memberId: me,
            completedByMemberId: nil, starsAwarded: 0, undoable: true
        )
        #expect(
            ChoreHistoryLogic.undoPrompt(.init(entries: [dismissed]), names: names)
                == "Bring Tidy the porch back?"
        )
    }

    @Test func historyFilterFollowsTheSharedChips() {
        let entry = ChoreHistoryLogic.Entry(
            id: "1", choreId: "cat", title: "Feed the cat", emoji: nil, action: .completed,
            occurredAt: "2026-08-06T07:26:00.000Z", dueDate: today, memberId: kid,
            completedByMemberId: kid, starsAwarded: 1
        )
        #expect(ChoreHistoryLogic.isVisible(entry, effective: [kid]))
        #expect(!ChoreHistoryLogic.isVisible(entry, effective: [me]))
    }
}
