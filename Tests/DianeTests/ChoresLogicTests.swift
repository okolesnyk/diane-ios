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

    // MARK: D08 — cancellation is not failure

    @Test func taskCancellationIsNotAFailure() {
        // D08: SwiftUI task-id churn must never paint the error screen.
        #expect(isTaskCancellation(CancellationError()))
        #expect(isTaskCancellation(URLError(.cancelled)))
        #expect(!isTaskCancellation(URLError(.notConnectedToInternet)))
    }
}
