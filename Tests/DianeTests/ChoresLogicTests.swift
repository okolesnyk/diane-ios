import DianeKit
import Foundation
import Testing

@testable import Diane

@Suite struct ChoresLogicTests {
    typealias Occurrence = Components.Schemas.ChoreOccurrence

    // MARK: Fixtures

    private func occ(
        id: String,
        title: String = "Dishes",
        status: Occurrence.StatusPayload = .open,
        late: Bool = false,
        dueDate: String? = nil,
        dueMode: Occurrence.DueModePayload? = nil,
        dueTime: String? = nil,
        assignee: String? = nil,
        claimedBy: String? = nil,
        completedBy: String? = nil,
        completedAt: String? = nil,
        upForGrabs: Bool = false
    ) -> Occurrence {
        .init(
            id: id,
            choreId: "chore-\(id)",
            title: title,
            emoji: nil,
            notes: nil,
            starValue: 2,
            upForGrabs: upForGrabs,
            dueDate: dueDate,
            dueMode: dueMode,
            dueTime: dueTime,
            status: status,
            late: late,
            assigneeMemberId: assignee,
            claimedByMemberId: claimedBy,
            completedByMemberId: completedBy,
            completedAt: completedAt
        )
    }

    private func member(_ id: String, name: String, sortOrder: Int) -> Components.Schemas.Member {
        .init(
            id: id,
            name: name,
            color: "#3B82F6",
            role: .kid,
            sortOrder: sortOrder,
            hasPassword: false,
            hasPasskeys: false,
            passwordResetRequired: false,
            createdAt: "2026-01-01T00:00:00Z"
        )
    }

    private let me = "m-me"
    private let sibling = "m-sib"
    private let parent = "m-parent"

    // MARK: Mine partition

    @Test func minePartitionsIntoTheSixSections() {
        let board = ChoreBoard.mine(
            [
                occ(id: "late", late: true, dueDate: "2026-07-26", assignee: me),
                occ(id: "today", dueDate: "2026-07-27", assignee: me),
                occ(id: "deadline", dueDate: "2026-08-15", dueMode: .by, assignee: me),  // D07
                occ(id: "anytime", assignee: me),
                occ(id: "pool", dueDate: "2026-07-27", upForGrabs: true),
                occ(id: "done", status: .completed, assignee: me, completedBy: me, completedAt: "2026-07-27T09:00:00Z"),
                occ(id: "siblings", dueDate: "2026-07-27", assignee: sibling),
                occ(id: "sibling-done", status: .completed, assignee: sibling, completedBy: sibling),
            ],
            myID: me
        )

        #expect(board.late.map(\.id) == ["late"])
        #expect(board.today.map(\.id) == ["today"])
        #expect(board.dueSoon.map(\.id) == ["deadline"])
        #expect(board.anytime.map(\.id) == ["anytime"])
        #expect(board.pool.map(\.id) == ["pool"])
        #expect(board.doneToday.map(\.id) == ["done"])
    }

    // D07: an open "by a date" chore is Due soon, never "Today"; overdue goes Late.
    @Test func byDateChoresFileUnderDueSoonNotToday() {
        let board = ChoreBoard.mine(
            [
                occ(id: "far", dueDate: "2026-08-15", dueMode: .by, assignee: me),
                occ(id: "near", dueDate: "2026-07-28", dueMode: .by, claimedBy: me),
                occ(id: "overdue", late: true, dueDate: "2026-07-20", dueMode: .by, assignee: me),
                occ(
                    id: "done-by", status: .completed, dueDate: "2026-08-01", dueMode: .by,
                    assignee: me, completedBy: me, completedAt: "2026-07-27T10:00:00Z"
                ),
            ],
            myID: me
        )

        #expect(board.today.isEmpty)
        #expect(board.dueSoon.map(\.id) == ["near", "far"])  // sorted by deadline
        #expect(board.late.map(\.id) == ["overdue"])
        #expect(board.doneToday.map(\.id) == ["done-by"])
        #expect(board.isEmpty == false)
    }

    @Test func poolChoreClaimedByMeBecomesMineNotPool() {
        let board = ChoreBoard.mine(
            [
                occ(id: "claimed-anytime", claimedBy: me, upForGrabs: true),
                occ(id: "claimed-dated", dueDate: "2026-07-27", claimedBy: me, upForGrabs: true),
                occ(id: "claimed-by-sib", claimedBy: sibling, upForGrabs: true),
            ],
            myID: me
        )

        #expect(board.anytime.map(\.id) == ["claimed-anytime"])
        #expect(board.today.map(\.id) == ["claimed-dated"])
        #expect(board.pool.isEmpty)  // claimed by sibling: theirs, not the pool's
        #expect(board.isEmpty == false)
    }

    @Test func mineSortsDatedByTimeAndDoneNewestFirst() {
        let board = ChoreBoard.mine(
            [
                occ(id: "noon", dueDate: "2026-07-27", dueTime: "12:00", assignee: me),
                occ(id: "morning", dueDate: "2026-07-27", dueTime: "08:00", assignee: me),
                occ(id: "untimed", dueDate: "2026-07-27", assignee: me),
                occ(id: "old-done", status: .completed, assignee: me, completedBy: me, completedAt: "2026-07-27T08:00:00Z"),
                occ(id: "new-done", status: .completed, assignee: me, completedBy: me, completedAt: "2026-07-27T18:00:00Z"),
            ],
            myID: me
        )

        #expect(board.today.map(\.id) == ["morning", "noon", "untimed"])
        #expect(board.doneToday.map(\.id) == ["new-done", "old-done"])
    }

    // MARK: D06 — done-today attribution (owner over completer)

    @Test func parentCompletedChoreStaysOnMyDoneBoard() {
        // D06: Mom checks off my chore — it stays MY done row, not hers.
        let board = ChoreBoard.mine(
            [occ(id: "fed-cat", status: .completed, assignee: me, completedBy: parent, completedAt: "2026-07-27T08:00:00Z")],
            myID: me
        )
        #expect(board.doneToday.map(\.id) == ["fed-cat"])
    }

    @Test func choreICompletedForSiblingIsNotMyDoneRow() {
        // D06: completing a sibling's chore must not land in MY "Done today".
        let rows = [occ(id: "sib-row", status: .completed, assignee: sibling, completedBy: me, completedAt: "2026-07-27T08:00:00Z")]
        #expect(ChoreBoard.mine(rows, myID: me).doneToday.isEmpty)
        #expect(ChoreBoard.mine(rows, myID: sibling).doneToday.map(\.id) == ["sib-row"])
    }

    @Test func ownerlessPoolRowBelongsToItsCompleter() {
        // D06: pool rows (no assignee, no claimer) fall back to the completer.
        let rows = [occ(id: "pool-done", status: .completed, completedBy: me, completedAt: "2026-07-27T08:00:00Z")]
        #expect(ChoreBoard.mine(rows, myID: me).doneToday.map(\.id) == ["pool-done"])
        #expect(ChoreBoard.mine(rows, myID: sibling).doneToday.isEmpty)
    }

    @Test func doneAttributionMatrix() {
        // D06: doneOwner = owner else completer; completedByOther only when they differ.
        let mine = occ(id: "a", status: .completed, assignee: me, completedBy: me)
        let helped = occ(id: "b", status: .completed, assignee: me, completedBy: parent)
        let claimed = occ(id: "c", status: .completed, claimedBy: me, completedBy: parent, upForGrabs: true)
        let pool = occ(id: "d", status: .completed, completedBy: parent)

        #expect(ChoreBoard.doneOwner(of: mine) == me)
        #expect(ChoreBoard.doneOwner(of: helped) == me)
        #expect(ChoreBoard.doneOwner(of: claimed) == me)  // claimer wins over completer
        #expect(ChoreBoard.doneOwner(of: pool) == parent)

        #expect(ChoreBoard.completedByOther(mine) == nil)
        #expect(ChoreBoard.completedByOther(helped) == parent)
        #expect(ChoreBoard.completedByOther(claimed) == parent)
        #expect(ChoreBoard.completedByOther(pool) == nil)  // completer IS the owner here
    }

    // MARK: Everyone grouping

    @Test func everyoneGroupsByOwnerInMemberSortOrder() {
        let board = ChoreBoard.everyone(
            [
                occ(id: "sib-open", dueDate: "2026-07-27", assignee: sibling),
                occ(id: "my-open", assignee: me),
                occ(id: "pool", upForGrabs: true),
                occ(id: "my-done", status: .completed, assignee: me, completedBy: me, completedAt: "2026-07-27T10:00:00Z"),
                occ(id: "sib-done", status: .completed, completedBy: sibling, completedAt: "2026-07-27T11:00:00Z"),
            ],
            // Out of order on purpose: sortOrder must win.
            members: [member(me, name: "Zoe", sortOrder: 2), member(sibling, name: "Ada", sortOrder: 1)]
        )

        #expect(board.members.map(\.member.id) == [sibling, me])
        #expect(board.members[0].open.map(\.id) == ["sib-open"])
        #expect(board.members[1].open.map(\.id) == ["my-open"])
        #expect(board.pool.map(\.id) == ["pool"])
        // Everyone's completions fold into one section, newest first.
        #expect(board.doneToday.map(\.id) == ["sib-done", "my-done"])
    }

    @Test func everyoneDoneRowsAttributeToTheOwnerNotTheCompleter() {
        // D06: a parent-completed kid chore is the KID's done item.
        let row = occ(id: "kid-row", status: .completed, assignee: me, completedBy: parent, completedAt: "2026-07-27T10:00:00Z")
        let board = ChoreBoard.everyone([row], members: [member(me, name: "Ben", sortOrder: 1)])

        #expect(board.doneToday.map(\.id) == ["kid-row"])
        #expect(ChoreBoard.doneOwner(of: row) == me)
        #expect(ChoreBoard.completedByOther(row) == parent)
    }

    @Test func everyoneShowsClaimedPoolChoreUnderTheClaimer() {
        let board = ChoreBoard.everyone(
            [occ(id: "claimed", claimedBy: sibling, upForGrabs: true)],
            members: [member(me, name: "Zoe", sortOrder: 1), member(sibling, name: "Ada", sortOrder: 2)]
        )

        #expect(board.members.first { $0.member.id == sibling }?.open.map(\.id) == ["claimed"])
        #expect(board.members.first { $0.member.id == me }?.open.isEmpty == true)
        #expect(board.pool.isEmpty)
    }

    @Test func everyoneKeepsMembersWithNothingToDo() {
        let board = ChoreBoard.everyone(
            [],
            members: [member(me, name: "Zoe", sortOrder: 1)]
        )

        #expect(board.members.map(\.member.id) == [me])
        #expect(board.members[0].open.isEmpty)
    }

    // MARK: Row action rules

    @Test func openAssignedDatedRowCompletesAndDismisses() {
        let actions = ChoreBoard.actions(for: occ(id: "a", dueDate: "2026-07-27", assignee: me))
        #expect(actions == .init(canComplete: true, canDismiss: true))
    }

    @Test func anytimeRowCanBeDismissed() {
        // D23: the server dismisses undated chores fine — the old gate misread the contract.
        let actions = ChoreBoard.actions(for: occ(id: "a", assignee: me))
        #expect(actions == .init(canComplete: true, canDismiss: true))
    }

    @Test func openPoolRowOffersClaim() {
        let actions = ChoreBoard.actions(for: occ(id: "a", dueDate: "2026-07-27", upForGrabs: true))
        #expect(actions == .init(canComplete: true, canClaim: true, canDismiss: true))
    }

    @Test func rowClaimedByMeOffersPutBack() {
        let actions = ChoreBoard.actions(for: occ(id: "a", claimedBy: me, upForGrabs: true))
        #expect(actions == .init(canComplete: true, canPutBack: true, canDismiss: true))
    }

    @Test func rowClaimedBySiblingStillOffersPutBack() {
        // D27: kiosk trust — anyone may put back anyone's claim (matches the web).
        let actions = ChoreBoard.actions(for: occ(id: "a", claimedBy: sibling, upForGrabs: true))
        #expect(actions == .init(canComplete: true, canPutBack: true, canDismiss: true))
    }

    @Test func completedRowOnlyUncompletes() {
        // D27: the checked circle taps through to uncomplete — this gate feeds it.
        let actions = ChoreBoard.actions(
            for: occ(id: "a", status: .completed, dueDate: "2026-07-27", assignee: me, completedBy: me)
        )
        #expect(actions == .init(canUncomplete: true))
    }

    // MARK: M9c — two action surfaces (circle + swipe), nothing stranded

    @Test func circleTogglesCompletionOnEveryRowIncludingDoneOnes() {
        // M9c: the circle is the ONLY complete/uncomplete surface now.
        #expect(ChoreBoard.circleAction(for: occ(id: "a", assignee: me)) == .complete)
        #expect(ChoreBoard.circleAction(for: occ(id: "b", upForGrabs: true)) == .complete)
        #expect(ChoreBoard.circleAction(for: occ(id: "c", claimedBy: sibling, upForGrabs: true)) == .complete)
        #expect(
            ChoreBoard.circleAction(for: occ(id: "d", status: .completed, assignee: me, completedBy: parent))
                == .uncomplete
        )
    }

    @Test func swipeMatrixCoversEveryRowState() {
        // M9c: claim, put back and dismiss are reachable by swipe alone —
        // the row context menu and the inline capsules are gone.
        let assigned = occ(id: "a", dueDate: "2026-07-27", assignee: me)
        #expect(ChoreBoard.leadingSwipes(for: assigned).isEmpty)
        #expect(ChoreBoard.trailingSwipes(for: assigned) == [.dismiss])

        let pool = occ(id: "b", upForGrabs: true)
        #expect(ChoreBoard.leadingSwipes(for: pool) == [.claim])
        #expect(ChoreBoard.trailingSwipes(for: pool) == [.dismiss])

        let mineClaimed = occ(id: "c", claimedBy: me, upForGrabs: true)
        #expect(ChoreBoard.leadingSwipes(for: mineClaimed) == [.putBack])
        #expect(ChoreBoard.trailingSwipes(for: mineClaimed) == [.dismiss])

        // D27: kiosk trust — a sibling's claim is put back the same way.
        let theirClaim = occ(id: "d", claimedBy: sibling, upForGrabs: true)
        #expect(ChoreBoard.leadingSwipes(for: theirClaim) == [.putBack])
        #expect(ChoreBoard.trailingSwipes(for: theirClaim) == [.dismiss])
    }

    @Test func completedRowOffersNoSwipeOnlyTheCircle() {
        // A done row can't be dismissed or claimed; un-completing it is the circle.
        let done = occ(id: "a", status: .completed, assignee: me, completedBy: me)
        #expect(ChoreBoard.leadingSwipes(for: done).isEmpty)
        #expect(ChoreBoard.trailingSwipes(for: done).isEmpty)
        #expect(ChoreBoard.circleAction(for: done) == .uncomplete)
    }

    @Test func claimAndPutBackNeverAppearOnTheSameRow() {
        // The leading edge shows one or the other — a row is claimed or it isn't.
        for row in [
            occ(id: "a", assignee: me),
            occ(id: "b", upForGrabs: true),
            occ(id: "c", claimedBy: me, upForGrabs: true),
            occ(id: "d", status: .completed, assignee: me, completedBy: me),
        ] {
            #expect(ChoreBoard.leadingSwipes(for: row).count <= 1)
        }
    }

    // MARK: D24 — dismiss confirmation

    @Test func dismissPromptNamesTheChore() {
        // D24: the confirm dialog must say which chore is about to vanish for good.
        #expect(ChoreBoard.dismissPrompt("Tidy the playroom").contains("Tidy the playroom"))
        #expect(ChoreBoard.dismissPrompt("X").hasPrefix("Dismiss"))
    }

    // MARK: D21 — 409 copy map

    @Test func conflictCopyCoversExactlyTheEmittedCodes() {
        // D21: the server's real 409 set, each with dedicated copy.
        let generic = ChoreBoard.conflictCopy(nil)
        for code in ["not_actionable", "already_claimed", "not_claimable", "already_completed", "insufficient_stars"] {
            #expect(ChoreBoard.conflictCopy(code) != generic, "no dedicated copy for \(code)")
        }
        // D21: chore_archived is never emitted — the phantom entry is gone.
        #expect(ChoreBoard.conflictCopy("chore_archived") == generic)
        // Unknown/missing codes still read like a sentence, not an enum.
        #expect(generic.isEmpty == false)
    }

    // MARK: Sheet identity

    @Test func sheetIdentityIsStablePerRowAndDistinctFromCreate() {
        let sheet = ChoreSheet.detail(occ(id: "a"))
        // Same row = same identity, so a refetch never re-presents the sheet.
        #expect(sheet.id == ChoreSheet.detail(occ(id: "a", title: "Renamed")).id)
        #expect(sheet.id != ChoreSheet.detail(occ(id: "b")).id)
        #expect(sheet.id != ChoreSheet.create.id)
    }

    // MARK: R7 — admin "All chores" list (off-day definitions)

    private func chore(
        id: String = "c1",
        title: String = "Feed the cat",
        emoji: String? = nil,
        stars: Int = 2,
        upForGrabs: Bool = false,
        assignees: [String] = ["m-me"],
        dueDate: String? = nil,
        dueMode: Components.Schemas.Chore.DueModePayload? = nil,
        dueTime: String? = nil,
        recurrence: Components.Schemas.Chore.RecurrencePayload? = nil,
        sortOrder: Int = 0
    ) -> Components.Schemas.Chore {
        .init(
            id: id,
            title: title,
            notes: nil,
            emoji: emoji,
            starValue: stars,
            upForGrabs: upForGrabs,
            dueDate: dueDate,
            dueMode: dueMode,
            dueTime: dueTime,
            recurrence: recurrence,
            assigneeIds: assignees,
            sortOrder: sortOrder,
            createdAt: "2026-01-01T00:00:00Z"
        )
    }

    private func recurrence(
        freq: Components.Schemas.Chore.RecurrencePayload.FreqPayload,
        interval: Int? = nil,
        byWeekday: [Components.Schemas.Chore.RecurrencePayload.ByWeekdayPayloadPayload]? = nil,
        byMonthDay: Int? = nil,
        startDate: String = "2026-07-01",
        endDate: String? = nil
    ) -> Components.Schemas.Chore.RecurrencePayload {
        .init(
            freq: freq,
            interval: interval,
            byWeekday: byWeekday,
            byMonthDay: byMonthDay,
            startDate: startDate,
            endDate: endDate
        )
    }

    @Test func scheduleSummaryCoversTheFourShapes() {
        // R7: the Manage row must say WHEN a chore happens — its whole point
        // is chores that never appear on today's board.
        #expect(ChoresManageLogic.scheduleSummary(chore()) == "Anytime")
        #expect(ChoresManageLogic.scheduleSummary(chore(dueDate: "2026-08-15")) == "Aug 15")
        // dueMode 'on' is the same one-off shape as an absent dueMode.
        #expect(ChoresManageLogic.scheduleSummary(chore(dueDate: "2026-08-15", dueMode: .on)) == "Aug 15")
        #expect(ChoresManageLogic.scheduleSummary(chore(dueDate: "2026-08-15", dueMode: .by)) == "By Aug 15")
        #expect(
            ChoresManageLogic.scheduleSummary(chore(recurrence: recurrence(freq: .daily))) == "Daily"
        )
    }

    @Test func scheduleSummaryAppendsTheDueTime() {
        // R7: the due time rides on every dated/recurring shape.
        #expect(
            ChoresManageLogic.scheduleSummary(chore(dueDate: "2026-08-15", dueTime: "07:30"))
                == "Aug 15 at 07:30"
        )
        #expect(
            ChoresManageLogic.scheduleSummary(
                chore(dueDate: "2026-08-15", dueMode: .by, dueTime: "18:00")
            ) == "By Aug 15 at 18:00"
        )
        #expect(
            ChoresManageLogic.scheduleSummary(
                chore(dueTime: "07:30", recurrence: recurrence(freq: .daily))
            ) == "Daily at 07:30"
        )
    }

    @Test func recurringSummariesMatchTheWebCopy() {
        // R7: web scheduleSummary parity, including the absent-field rules.
        func summary(_ payload: Components.Schemas.Chore.RecurrencePayload) -> String {
            ChoresManageLogic.scheduleSummary(chore(recurrence: payload))
        }
        #expect(summary(recurrence(freq: .daily, interval: 3)) == "Every 3 days")
        #expect(summary(recurrence(freq: .weekly)) == "Weekly")
        #expect(summary(recurrence(freq: .weekly, byWeekday: [.we, .mo])) == "Every Mon, Wed")
        #expect(summary(recurrence(freq: .weekly, byWeekday: [])) == "Weekly")
        #expect(
            summary(recurrence(freq: .weekly, interval: 2, byWeekday: [.mo]))
                == "Every 2 weeks on Mon"
        )
        #expect(summary(recurrence(freq: .weekly, interval: 2)) == "Every 2 weeks")
        // No byMonthDay = "the start date's day" (server rule) — don't invent one.
        #expect(summary(recurrence(freq: .monthly)) == "Monthly")
        #expect(summary(recurrence(freq: .monthly, byMonthDay: 15)) == "Monthly on day 15")
        #expect(
            summary(recurrence(freq: .monthly, interval: 2, byMonthDay: 15))
                == "Every 2 months on day 15"
        )
        #expect(summary(recurrence(freq: .monthly, interval: 2)) == "Every 2 months")
    }

    @Test func manageSubtitleNamesWhoDoesIt() {
        // R7: schedule + assignee count, with the empty selection reading as pool.
        #expect(ChoresManageLogic.who(chore(assignees: ["m-me"])) == "1 member")
        #expect(ChoresManageLogic.who(chore(assignees: ["m-me", "m-sib"])) == "2 members")
        #expect(ChoresManageLogic.who(chore(upForGrabs: true, assignees: [])) == "Up for grabs")
        // Defensive: an assignee-less row is the pool even if the flag lags.
        #expect(ChoresManageLogic.who(chore(assignees: [])) == "Up for grabs")
        #expect(
            ChoresManageLogic.subtitle(chore(assignees: ["m-me"], dueDate: "2026-08-15"))
                == "Aug 15 · 1 member"
        )
    }

    @Test func manageListSortsBySortOrderThenTitle() {
        // R7: admin order is canonical; ties break deterministically.
        let sorted = ChoresManageLogic.sorted([
            chore(id: "c", title: "Zebra", sortOrder: 1),
            chore(id: "a", title: "Apple", sortOrder: 2),
            chore(id: "b", title: "Apple", sortOrder: 1),
        ])
        #expect(sorted.map(\.id) == ["b", "c", "a"])
    }

    @Test func monthDayFormatsAndPassesThroughGarbage() {
        #expect(ChoresManageLogic.monthDay("2026-01-05") == "Jan 5")
        #expect(ChoresManageLogic.monthDay("2026-12-31") == "Dec 31")
        #expect(ChoresManageLogic.monthDay("2026-13-01") == "2026-13-01")
        #expect(ChoresManageLogic.monthDay("nope") == "nope")
    }

    // MARK: R13 — rows are announced as buttons

    @Test func rowAccessibilityLabelSpeaksTheWholeRow() {
        // R13: the chips and star Text are hidden, so this line carries them.
        let late = occ(id: "a", title: "Dishes", late: true, dueDate: "2026-07-26", dueTime: "08:00", assignee: me)
        #expect(
            ChoreBoard.rowAccessibilityLabel(late) == "Dishes, late, at 08:00, 2 stars"
        )
        let deadline = occ(id: "b", title: "Tidy", dueDate: "2026-08-15", dueMode: .by, assignee: me)
        #expect(ChoreBoard.rowAccessibilityLabel(deadline) == "Tidy, by Aug 15, 2 stars")
    }

    @Test func rowAccessibilityLabelReportsDoneAndAttribution() {
        // R13: a done row says so once — never "late" as well — and names who.
        let done = occ(
            id: "a", title: "Dishes", status: .completed, late: true,
            assignee: me, completedBy: parent, completedAt: "2026-07-27T09:00:00Z"
        )
        let label = ChoreBoard.rowAccessibilityLabel(done, attribution: "Ben", completedByName: "Mom")
        #expect(label == "Dishes, done, 2 stars, Ben, completed by Mom")
        #expect(!label.contains("late"))
    }

    @Test func rowAccessibilityLabelSingularizesOneStar() {
        let one = Occurrence(
            id: "a", choreId: "c", title: "Water the garden", emoji: nil, notes: nil,
            starValue: 1, upForGrabs: false, dueDate: nil, dueMode: nil, dueTime: nil,
            status: .open, late: false, assigneeMemberId: me, claimedByMemberId: nil,
            completedByMemberId: nil, completedAt: nil
        )
        #expect(ChoreBoard.rowAccessibilityLabel(one) == "Water the garden, 1 star")
    }

    // MARK: Sheet identity (R7 manage case)

    @Test func manageSheetHasItsOwnIdentity() {
        // R7: Manage must not collide with create or any detail row.
        #expect(ChoreSheet.manage.id != ChoreSheet.create.id)
        #expect(ChoreSheet.manage.id != ChoreSheet.detail(occ(id: "a")).id)
    }

    // MARK: D08 — cancellation is not failure

    @Test func taskCancellationIsNotAFailure() {
        // D08: SwiftUI task-id churn must never paint the error screen.
        #expect(isTaskCancellation(CancellationError()))
        #expect(isTaskCancellation(URLError(.cancelled)))
        #expect(!isTaskCancellation(URLError(.notConnectedToInternet)))
    }
}
