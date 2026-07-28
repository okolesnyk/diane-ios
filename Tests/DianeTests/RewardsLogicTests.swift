import DianeKit
import Foundation
import Testing

@testable import Diane

@Suite struct RewardsLogicTests {
    // MARK: Fixtures

    private func redemption(
        id: String = "r1",
        memberId: String = "kid",
        status: Components.Schemas.RewardRedemption.StatusPayload = .redeemed,
        fulfilledAt: String? = nil
    ) -> Components.Schemas.RewardRedemption {
        .init(
            id: id,
            rewardId: "reward-1",
            memberId: memberId,
            title: "Movie night",
            emoji: "🍿",
            costStars: 10,
            status: status,
            redeemedByMemberId: memberId,
            fulfilledByMemberId: status == .fulfilled ? "mom" : nil,
            fulfilledAt: fulfilledAt,
            createdAt: "2026-07-26T18:00:00Z"
        )
    }

    // MARK: Affordability

    @Test func affordableWhenBalanceCoversCost() {
        #expect(RewardsLogic.starsShort(balance: 10, cost: 10) == nil)
        #expect(RewardsLogic.starsShort(balance: 11, cost: 10) == nil)
    }

    @Test func needsNMoreMathIsExact() {
        #expect(RewardsLogic.starsShort(balance: 3, cost: 10) == 7)
        #expect(RewardsLogic.starsShort(balance: 9, cost: 10) == 1)
        #expect(RewardsLogic.starsShort(balance: 0, cost: 1) == 1)
    }

    @Test func balanceLookupFindsMineAndDefaultsToZero() {
        let balances: [Components.Schemas.StarBalance] = [
            .init(memberId: "kid", balance: 7),
            .init(memberId: "mom", balance: 42),
        ]
        #expect(RewardsLogic.balance(of: "kid", in: balances) == 7)
        #expect(RewardsLogic.balance(of: "stranger", in: balances) == 0)
        #expect(RewardsLogic.balance(of: "kid", in: []) == 0)
    }

    // MARK: Visibility filtering

    // D22: Done stays scoped — kids their own, admins the household's.
    @Test func kidSeesOnlyTheirOwnDoneRedemptions() {
        let all = [
            redemption(id: "a", memberId: "kid", status: .fulfilled, fulfilledAt: "2026-07-27T09:00:00Z"),
            redemption(id: "b", memberId: "sibling", status: .fulfilled, fulfilledAt: "2026-07-27T09:00:00Z"),
            redemption(id: "c", memberId: "kid", status: .fulfilled, fulfilledAt: "2026-07-27T09:00:00Z"),
        ]
        let visible = RewardsLogic.doneVisible(all, memberID: "kid", isAdmin: false)
        #expect(visible.map(\.id) == ["a", "c"])
    }

    @Test func adminSeesEveryonesDoneRedemptions() {
        let all = [
            redemption(id: "a", memberId: "kid", status: .fulfilled, fulfilledAt: "2026-07-27T09:00:00Z"),
            redemption(id: "b", memberId: "sibling", status: .fulfilled, fulfilledAt: "2026-07-27T09:00:00Z"),
        ]
        let visible = RewardsLogic.doneVisible(all, memberID: "mom", isAdmin: true)
        #expect(visible.map(\.id) == ["a", "b"])
    }

    // D25: the waiting queue is household-visible to everyone — the split
    // guards status only, never the member.
    @Test func waitingQueueKeepsSiblingsRowsForKids() {
        let all = [
            redemption(id: "a", memberId: "kid"),
            redemption(id: "b", memberId: "sibling"),
        ]
        #expect(RewardsLogic.waiting(all).map(\.id) == ["a", "b"])
    }

    // MARK: Waiting vs done split

    @Test func waitingAndDoneSplitByStatus() {
        let mixed = [
            redemption(id: "a", status: .redeemed),
            redemption(id: "b", status: .fulfilled, fulfilledAt: "2026-07-27T09:00:00Z"),
            redemption(id: "c", status: .redeemed),
        ]
        #expect(RewardsLogic.waiting(mixed).map(\.id) == ["a", "c"])
        #expect(RewardsLogic.done(mixed).map(\.id) == ["b"])
    }

    // MARK: Query scoping (D22)

    // D22: Waiting is the fulfill queue — full household at the server max.
    @Test func waitingQueriesTheServerMaximum() {
        #expect(RewardsLogic.waitingLimit == "200")
        #expect(RewardsLogic.doneLimit == "20")
    }

    // D22: kids query Done with their own memberId; admins household-wide.
    @Test func doneQueryScopesKidsToTheirOwnMemberId() {
        #expect(RewardsLogic.doneMemberID(memberID: "kid", isAdmin: false) == "kid")
        #expect(RewardsLogic.doneMemberID(memberID: "mom", isAdmin: true) == nil)
    }

    // MARK: Fulfill/return capability

    @Test func onlyAdminsCanFulfillWaitingRedemptions() {
        let waiting = redemption(status: .redeemed)
        #expect(RewardsLogic.canFulfill(waiting, isAdmin: true))
        #expect(!RewardsLogic.canFulfill(waiting, isAdmin: false))
    }

    // D25: Return is everyone's mis-click undo (server has no admin gate).
    @Test func anyoneCanReturnAWaitingRedemption() {
        #expect(RewardsLogic.canReturn(redemption(status: .redeemed)))
        #expect(RewardsLogic.canReturn(redemption(memberId: "sibling", status: .redeemed)))
    }

    @Test func fulfilledRedemptionsAreNeverActionable() {
        let done = redemption(status: .fulfilled, fulfilledAt: "2026-07-27T09:00:00Z")
        #expect(!RewardsLogic.canFulfill(done, isAdmin: true))
        #expect(!RewardsLogic.canReturn(done))
    }

    // MARK: Redeem busy lock (D12)

    // D12: while a redeem is in flight every card locks, even affordable ones.
    @Test func storeLocksWhileRedeemInFlight() {
        #expect(RewardsLogic.storeCardDisabled(starsShort: nil, redeemBusy: true))
        #expect(RewardsLogic.storeCardDisabled(starsShort: 3, redeemBusy: false))
        #expect(RewardsLogic.storeCardDisabled(starsShort: 3, redeemBusy: true))
        #expect(!RewardsLogic.storeCardDisabled(starsShort: nil, redeemBusy: false))
    }

    // MARK: Instant parsing (fulfilledAt)

    @Test func instantParsesWithAndWithoutFractionalSeconds() {
        let plain = RewardsLogic.instant("2026-07-27T09:15:00Z")
        let fractional = RewardsLogic.instant("2026-07-27T09:15:00.250Z")
        #expect(plain != nil)
        #expect(fractional != nil)
        if let plain, let fractional {
            #expect(abs(fractional.timeIntervalSince(plain) - 0.25) < 0.001)
        }
        #expect(RewardsLogic.instant("not-a-date") == nil)
    }
}
