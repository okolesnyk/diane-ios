import DianeKit
import SwiftUI

// MARK: - Pure logic (nonisolated, tested in RewardsLogicTests)

/// Data-shaping rules for the rewards screen.
enum RewardsLogic {
    /// nil when affordable; otherwise how many more stars are needed.
    static func starsShort(balance: Int, cost: Int) -> Int? {
        cost > balance ? cost - balance : nil
    }

    /// My balance from the household list (0 when the member has no entry).
    static func balance(of memberID: String, in balances: [Components.Schemas.StarBalance]) -> Int {
        balances.first(where: { $0.memberId == memberID })?.balance ?? 0
    }

    /// D22: "Waiting" is the fulfill queue and must be complete (server max).
    static let waitingLimit = "200"
    /// Done is a bounded recent list.
    static let doneLimit = "20"

    /// D22: kids fetch their own Done server-side; admins the household's.
    static func doneMemberID(memberID: String, isAdmin: Bool) -> String? {
        isAdmin ? nil : memberID
    }

    /// D22: client-side guard mirroring the Done query scope.
    static func doneVisible(
        _ redemptions: [Components.Schemas.RewardRedemption],
        memberID: String,
        isAdmin: Bool
    ) -> [Components.Schemas.RewardRedemption] {
        isAdmin ? redemptions : redemptions.filter { $0.memberId == memberID }
    }

    /// Waiting = redeemed. Household-visible to everyone (kiosk parity, D25);
    /// only the status is guarded, never the member.
    static func waiting(_ redemptions: [Components.Schemas.RewardRedemption]) -> [Components.Schemas.RewardRedemption] {
        redemptions.filter { $0.status == .redeemed }
    }

    /// Done = fulfilled (permanent).
    static func done(_ redemptions: [Components.Schemas.RewardRedemption]) -> [Components.Schemas.RewardRedemption] {
        redemptions.filter { $0.status == .fulfilled }
    }

    /// Fulfill is the one admin-gated move; only waiting rows are actionable.
    static func canFulfill(_ redemption: Components.Schemas.RewardRedemption, isAdmin: Bool) -> Bool {
        isAdmin && redemption.status == .redeemed
    }

    /// D25: Return is everyone's mis-click undo (server has no admin gate).
    static func canReturn(_ redemption: Components.Schemas.RewardRedemption) -> Bool {
        redemption.status == .redeemed
    }

    /// D12: store cards lock while a redeem is in flight.
    static func storeCardDisabled(starsShort: Int?, redeemBusy: Bool) -> Bool {
        starsShort != nil || redeemBusy
    }

    /// ISO-8601 UTC instant (with or without fractional seconds) → Date.
    static func instant(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// Everything the screen shows, loaded as one unit.
struct RewardsData {
    var balance: Int
    var rewards: [Components.Schemas.Reward]
    var waiting: [Components.Schemas.RewardRedemption]
    var done: [Components.Schemas.RewardRedemption]
    var membersByID: [String: Components.Schemas.Member]
}

// MARK: - Screen

struct RewardsView: View {
    let context: SignedInContext
    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState

    @State private var data: Loadable<RewardsData> = .loading
    @State private var confirmingReward: Components.Schemas.Reward?
    @State private var redeemInFlightID: String?  // D12
    @State private var errorMessage: String?
    @State private var celebratedRewardID: String?
    @State private var celebrationCount = 0

    var body: some View {
        Group { // M9e: the caller owns the NavigationStack (tab wrap or Apps push)
            content
                .navigationTitle("Rewards")
                .task(id: signals.version(of: [.rewards, .stars, .members])) { await load() }
                .refreshable { await load() }
        }
        .sensoryFeedback(.success, trigger: celebrationCount)
        .alert(
            confirmingReward.map { "Redeem \($0.title) for ★\($0.costStars)?" } ?? "",
            isPresented: confirmationShown
        ) {
            if let reward = confirmingReward {
                Button("Redeem") { Task { await redeem(reward) } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            errorMessage ?? "Something went wrong.",
            isPresented: alertShown
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    @ViewBuilder private var content: some View {
        switch data {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't reach home", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        case .loaded(let loaded):
            loadedList(loaded)
        }
    }

    /// M9c: plain edge-to-edge list; hairlines group, no cards.
    private func loadedList(_ loaded: RewardsData) -> some View {
        List {
            Section {
                balanceHeader(loaded.balance)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            Section {
                if loaded.rewards.isEmpty {
                    Text("No rewards in the store yet.")
                        .foregroundStyle(.secondary)
                        .listRowInsets(Self.rowInsets)
                } else {
                    // Not a list — the grid keeps its two columns but runs
                    // edge-to-edge like everything else.
                    storeGrid(loaded)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                        .listRowSeparator(.hidden)
                }
            } header: {
                sectionHeader("Store")
            }

            if !loaded.waiting.isEmpty {
                Section {
                    ForEach(loaded.waiting, id: \.id) { redemption in
                        waitingRow(redemption, members: loaded.membersByID)
                            .listRowInsets(Self.rowInsets)
                    }
                } header: {
                    sectionHeader("Waiting")
                } footer: {
                    if !context.session.isAdmin {
                        Text("A parent will make it happen ✨")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 12, trailing: 16))
                    }
                }
            }

            if !loaded.done.isEmpty {
                Section {
                    ForEach(loaded.done, id: \.id) { redemption in
                        doneRow(redemption, members: loaded.membersByID)
                            .listRowInsets(Self.rowInsets)
                    }
                } header: {
                    sectionHeader("Done")
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
    }

    // MARK: Sections

    /// Shared density contract: rows flush to the screen edge.
    private static var rowInsets: EdgeInsets { EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16) }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
    }

    private func balanceHeader(_ balance: Int) -> some View {
        VStack(spacing: 2) {
            Text("★ \(balance)")
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .foregroundStyle(.orange)
                .contentTransition(.numericText())
                .animation(.snappy, value: balance)
            Text("Your stars")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func storeGrid(_ loaded: RewardsData) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            ForEach(loaded.rewards, id: \.id) { reward in
                let short = RewardsLogic.starsShort(balance: loaded.balance, cost: reward.costStars)
                Button {
                    confirmingReward = reward
                } label: {
                    RewardCard(
                        reward: reward,
                        starsShort: short,
                        celebrating: celebratedRewardID == reward.id,
                        redeeming: redeemInFlightID == reward.id  // D12
                    )
                }
                .buttonStyle(.plain)
                // D12: all cards lock while a redeem is in flight.
                .disabled(RewardsLogic.storeCardDisabled(starsShort: short, redeemBusy: redeemInFlightID != nil))
            }
        }
    }

    private func waitingRow(_ redemption: Components.Schemas.RewardRedemption, members: [String: Components.Schemas.Member]) -> some View {
        HStack(spacing: 12) {
            // D25: the waiting queue is household-visible — names and
            // avatars for everyone, like the kiosk.
            if let member = members[redemption.memberId] {
                MemberAvatarView(name: member.name, colorHex: member.color, avatar: member.avatar, size: 36)
            }
            RewardEmojiView(emoji: redemption.emoji, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(redemption.title)
                    .font(.system(.body, design: .rounded, weight: .medium))
                Text(members[redemption.memberId]?.name ?? "Someone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("★ \(redemption.costStars)")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(.orange)
        }
        .frame(minHeight: 44)  // D27
        .contentShape(.rect)
        // M9c: swipe is the one action surface — no duplicate inline buttons.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if RewardsLogic.canFulfill(redemption, isAdmin: context.session.isAdmin) {
                Button {
                    Task { await fulfill(redemption) }
                } label: {
                    Label("Mark done", systemImage: "checkmark.circle")
                }
                .tint(.green)
                .accessibilityLabel("Mark \(redemption.title) done")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // D25: Return is everyone's mis-click undo — the leading edge, like
            // every other un-do in the app. Reversible, so no dialog.
            if RewardsLogic.canReturn(redemption) {
                Button {
                    Task { await returnStars(redemption) }
                } label: {
                    Label("Return stars", systemImage: "arrow.uturn.backward")
                }
                .tint(.blue)
                .accessibilityLabel("Return stars for \(redemption.title)")
            }
        }
    }

    private func doneRow(_ redemption: Components.Schemas.RewardRedemption, members: [String: Components.Schemas.Member]) -> some View {
        HStack(spacing: 12) {
            RewardEmojiView(emoji: redemption.emoji, size: 24)
                .grayscale(1)
                .opacity(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(redemption.title)
                    .font(.system(.subheadline, design: .rounded))
                if context.session.isAdmin, let name = members[redemption.memberId]?.name {
                    Text(name)
                        .font(.caption2)
                }
            }
            Spacer()
            if let at = redemption.fulfilledAt, let date = RewardsLogic.instant(at) {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Bindings

    private var confirmationShown: Binding<Bool> {
        Binding(
            get: { confirmingReward != nil },
            set: { if !$0 { confirmingReward = nil } }
        )
    }

    private var alertShown: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    // MARK: Data

    private func load() async {
        do {
            async let balancesCall = context.client.api.getStarBalances(.init())
            async let rewardsCall = context.client.api.listRewards(.init())
            // D22: Waiting is the fulfill queue and must be complete — full
            // household at the server max, never the default newest-50.
            async let waitingCall = context.client.api.listRewardRedemptions(
                .init(query: .init(status: .redeemed, limit: RewardsLogic.waitingLimit))
            )
            // D22: Done is server-scoped — kids their own, admins household.
            async let doneCall = context.client.api.listRewardRedemptions(
                .init(query: .init(
                    memberId: RewardsLogic.doneMemberID(
                        memberID: context.session.memberID, isAdmin: context.session.isAdmin
                    ),
                    status: .fulfilled,
                    limit: RewardsLogic.doneLimit
                ))
            )

            var loaded = RewardsData(balance: 0, rewards: [], waiting: [], done: [], membersByID: [:])

            switch try await balancesCall {
            case .ok(let ok):
                loaded.balance = RewardsLogic.balance(of: context.session.memberID, in: try ok.body.json.balances)
            case .unauthorized:
                appState.handleUnauthorized()
                return
            default:
                fail()
                return
            }

            switch try await rewardsCall {
            case .ok(let ok):
                loaded.rewards = try ok.body.json.rewards
            case .unauthorized:
                appState.handleUnauthorized()
                return
            default:
                fail()
                return
            }

            switch try await waitingCall {
            case .ok(let ok):
                // D25: household-visible to everyone — no member filter.
                loaded.waiting = RewardsLogic.waiting(try ok.body.json.redemptions)
            case .unauthorized:
                appState.handleUnauthorized()
                return
            default:
                fail()
                return
            }

            switch try await doneCall {
            case .ok(let ok):
                loaded.done = RewardsLogic.doneVisible(
                    RewardsLogic.done(try ok.body.json.redemptions),
                    memberID: context.session.memberID,
                    isAdmin: context.session.isAdmin
                )
            case .unauthorized:
                appState.handleUnauthorized()
                return
            default:
                fail()
                return
            }

            // D25: everyone needs names/avatars for the household queue.
            switch try await context.client.api.listMembers(.init()) {
            case .ok(let ok):
                loaded.membersByID = Dictionary(
                    uniqueKeysWithValues: try ok.body.json.members.map { ($0.id, $0) }
                )
            case .unauthorized:
                appState.handleUnauthorized()
                return
            default:
                break // Names degrade gracefully; keep the screen up.
            }

            data = .loaded(loaded)
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            fail()
        }
    }

    /// Keep stale-but-real data on refetch failure; only empty screens go red.
    private func fail() {
        if data.value == nil {
            data = .failed("Your home server didn't answer. Pull to try again.")
        }
    }

    // MARK: Actions (refetch after every action; SSE bumps too)

    private func redeem(_ reward: Components.Schemas.Reward) async {
        // D12: redeem is not idempotent server-side — one at a time, with
        // the store locked until the response (and refetch) lands.
        guard redeemInFlightID == nil else { return }
        redeemInFlightID = reward.id
        defer { redeemInFlightID = nil }
        do {
            let output = try await context.client.api.redeemReward(
                .init(path: .init(id: reward.id), body: .json(.init()))
            )
            switch output {
            case .ok(let ok):
                let result = try ok.body.json
                if var current = data.value {
                    current.balance = result.balance
                    data = .loaded(current)
                }
                celebrate(reward.id)
            case .unauthorized:
                appState.handleUnauthorized()
            case .conflict:
                errorMessage = "Not enough stars yet."
            case .notFound:
                errorMessage = "That reward is gone from the store."
            default:
                errorMessage = "That didn't work. Try again?"
            }
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            errorMessage = "Your home server didn't answer."
        }
        await load()
    }

    private func fulfill(_ redemption: Components.Schemas.RewardRedemption) async {
        do {
            switch try await context.client.api.fulfillRedemption(.init(path: .init(id: redemption.id))) {
            case .ok:
                break // Idempotent server-side.
            case .unauthorized:
                appState.handleUnauthorized()
            case .forbidden:
                errorMessage = "Only a parent can do that."
            case .notFound:
                errorMessage = "That one's already gone."
            default:
                errorMessage = "That didn't work. Try again?"
            }
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            errorMessage = "Your home server didn't answer."
        }
        await load()
    }

    private func returnStars(_ redemption: Components.Schemas.RewardRedemption) async {
        do {
            switch try await context.client.api.returnRedemption(.init(path: .init(id: redemption.id))) {
            case .ok:
                break // Stars refunded; refetch shows the new balance.
            case .unauthorized:
                appState.handleUnauthorized()
            case .conflict:
                errorMessage = "Already marked done — fix it with a star adjustment."
            case .notFound:
                errorMessage = "That one's already gone."
            default:
                errorMessage = "That didn't work. Try again?"
            }
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            errorMessage = "Your home server didn't answer."
        }
        await load()
    }

    private func celebrate(_ rewardID: String) {
        celebrationCount += 1
        withAnimation(.bouncy) { celebratedRewardID = rewardID }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if celebratedRewardID == rewardID {
                withAnimation(.easeOut) { celebratedRewardID = nil }
            }
        }
    }
}

// MARK: - Pieces

/// Big reward emoji with the gift-symbol fallback.
private struct RewardEmojiView: View {
    let emoji: String?
    var size: CGFloat = 40

    var body: some View {
        if let emoji {
            Text(emoji).font(.system(size: size))
        } else {
            Image(systemName: "gift.fill")
                .font(.system(size: size * 0.82))
                .foregroundStyle(.orange)
        }
    }
}

private struct RewardCard: View {
    let reward: Components.Schemas.Reward
    let starsShort: Int?
    let celebrating: Bool
    let redeeming: Bool  // D12

    var body: some View {
        VStack(spacing: 6) {
            RewardEmojiView(emoji: reward.emoji, size: 42)
                .frame(height: 48)
            Text(reward.title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("★ \(reward.costStars)")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(.orange)
            if let starsShort {
                Text("Needs \(starsShort) more ★")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        // Plain lists sit on systemBackground — the tile needs the grey.
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .opacity(starsShort == nil ? 1 : 0.55)
        .overlay {
            // D12: in-flight redeem shows on the card itself.
            if redeeming {
                ProgressView()
                    .controlSize(.regular)
                    .padding(10)
                    .background(.thinMaterial, in: .circle)
            }
        }
        .overlay {
            if celebrating {
                Text("★")
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(.orange)
                    .shadow(color: .orange.opacity(0.5), radius: 8)
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
        }
        .scaleEffect(celebrating ? 1.06 : 1)
    }
}
