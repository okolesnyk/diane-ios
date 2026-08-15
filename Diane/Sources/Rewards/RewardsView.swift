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

    /// Returning someone ELSE's redemption confirms; your own is instant —
    /// the app-wide own-revert rule. No member (family session) → confirm.
    static func returnNeedsConfirm(redemptionMemberID: String, sessionMemberID: String) -> Bool {
        sessionMemberID.isEmpty || redemptionMemberID != sessionMemberID
    }

    /// The store is personal only when exactly ONE member is soloed —
    /// a family view showing four "can afford" states per tile is noise.
    static func soloID(effective: Set<String>) -> String? {
        effective.count == 1 ? effective.first : nil
    }

    /// Who-picker order (mock): currently-selected members first, then the
    /// rest, both in the household's member order.
    static func pickerOrder(
        members: [Components.Schemas.Member],
        effective: Set<String>
    ) -> [Components.Schemas.Member] {
        members.filter { effective.contains($0.id) } + members.filter { !effective.contains($0.id) }
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
    var balances: [Components.Schemas.StarBalance]
    var rewards: [Components.Schemas.Reward]
    var waiting: [Components.Schemas.RewardRedemption]
    var done: [Components.Schemas.RewardRedemption]
    var members: [Components.Schemas.Member]
}

// MARK: - Screen (M9e-7, mock page 6 rev 3: Store · Activity)

/// The one module where the number is the point: the chip row wears each
/// member's bank (balances live HERE and Settings, nowhere else — standing
/// rule) and drops the ring entirely (owner 2026-08-05: an empty arc next
/// to a balance would read as "nothing done"). The store is a 2-across tile
/// grid; redeeming walks confirm → celebration → the Waiting feed, whose
/// rows speak the single action model: the circle marks done (asking first,
/// done is permanent), the leading swipe Returns. No member tint — nothing
/// here is owned.
struct RewardsView: View {
    let context: SignedInContext
    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock
    @Environment(MemberFilterStore.self) private var filter
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("timeFormat") private var timeFormat = "system"

    @State private var data: Loadable<RewardsData> = .loading
    @State private var segment: Segment = .store
    /// Redeem walk: tile tap → (who?) → confirm → redeem.
    @State private var pickingWho: PickingWho?
    @State private var confirmingRedeem: PendingRedeem?
    @State private var confirmingFulfill: Components.Schemas.RewardRedemption?
    @State private var confirmingReturn: Components.Schemas.RewardRedemption?
    @State private var creatingReward = false
    @State private var redeemBusy = false  // D12
    @State private var errorMessage: String?
    @State private var celebratedRewardID: String?
    @State private var celebrationCount = 0

    enum Segment: Hashable {
        case store
        case activity
    }

    /// Identifiable wrapper — the generated Reward type isn't.
    struct PickingWho: Identifiable {
        let reward: Components.Schemas.Reward
        var id: String { reward.id }
    }

    struct PendingRedeem: Identifiable {
        let reward: Components.Schemas.Reward
        let memberID: String
        var id: String { "\(reward.id)|\(memberID)" }
    }

    private var members: [Components.Schemas.Member] { data.value?.members ?? [] }
    private var allIDs: [String] { members.map(\.id) }
    private var effective: Set<String> { filter.effective(all: allIDs) }

    var body: some View {
        Group { // M9e: the caller owns the NavigationStack (tab wrap or Home push)
            content
                .task(id: signals.version(of: [.rewards, .stars, .members])) { await load() }
                .refreshable { await load() }
        }
        .sensoryFeedback(.success, trigger: celebrationCount)
        .sheet(item: $pickingWho) { picking in
            whoPicker(picking.reward)
        }
        .sheet(isPresented: $creatingReward) {
            RewardFormView(context: context) { Task { await load() } }
        }
        // .alert, not confirmationDialog: iOS 26 anchors dialogs to their
        // source with a pointer bubble — the owner wants a plain centered
        // modal (2026-08-09, re-affirmed 2026-08-10).
        .alert(
            confirmingRedeem.map { "Redeem \($0.reward.title)?" } ?? "",
            isPresented: shown($confirmingRedeem),
        ) {
            if let pending = confirmingRedeem {
                Button("Redeem — ★ \(pending.reward.costStars)") {
                    let target = pending
                    confirmingRedeem = nil
                    Task { await redeem(target.reward, memberID: target.memberID) }
                }
                Button("Cancel", role: .cancel) { confirmingRedeem = nil }
            }
        } message: {
            if let pending = confirmingRedeem { Text(redeemMessage(pending)) }
        }
        // .alert, not confirmationDialog: iOS 26 anchors dialogs to their
        // source with a pointer bubble — the owner wants a plain centered
        // modal (2026-08-09, re-affirmed 2026-08-10).
        .alert(
            confirmingFulfill.map { "Mark \($0.title) done?" } ?? "",
            isPresented: shown($confirmingFulfill),
        ) {
            if let redemption = confirmingFulfill {
                Button("Mark done") {
                    confirmingFulfill = nil
                    Task { await fulfill(redemption) }
                }
                Button("Cancel", role: .cancel) { confirmingFulfill = nil }
            }
        } message: {
            if let redemption = confirmingFulfill {
                Text("Done is permanent — if plans changed, Return it instead and \(name(of: redemption.memberId)) gets the ★ \(redemption.costStars) back.")
            }
        }
        // .alert, not confirmationDialog: iOS 26 anchors dialogs to their
        // source with a pointer bubble — the owner wants a plain centered
        // modal (2026-08-09, re-affirmed 2026-08-10).
        .alert(
            confirmingReturn.map { "Return \($0.title)?" } ?? "",
            isPresented: shown($confirmingReturn),
        ) {
            if let redemption = confirmingReturn {
                Button("Return — ★ \(redemption.costStars) back") {
                    confirmingReturn = nil
                    Task { await returnStars(redemption) }
                }
                Button("Cancel", role: .cancel) { confirmingReturn = nil }
            }
        } message: {
            if let redemption = confirmingReturn {
                Text("\(name(of: redemption.memberId)) gets the ★ \(redemption.costStars) back.")
            }
        }
        .alert(
            errorMessage ?? "Something went wrong.",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    private func shown<T>(_ binding: Binding<T?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
    }

    private func name(of memberID: String) -> String {
        members.first(where: { $0.id == memberID })?.name ?? "They"
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch data {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't load rewards", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
        case .loaded(let loaded):
            VStack(spacing: 0) {
                chips(loaded)
                Picker("Section", selection: $segment) {
                    Text("Store").tag(Segment.store)
                    Text(loaded.waiting.isEmpty ? "Activity" : "Activity · \(loaded.waiting.count)")
                        .tag(Segment.activity)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                switch segment {
                case .store: store(loaded)
                case .activity: activity(loaded)
                }
            }
        }
    }

    // MARK: - Chips: face, name, BANK — and no ring at all (owner 2026-08-05)

    private func chips(_ loaded: RewardsData) -> some View {
        HStack(spacing: 14) {
            ForEach(loaded.members, id: \.id) { member in
                let balance = RewardsLogic.balance(of: member.id, in: loaded.balances)
                let isOn = effective.contains(member.id)
                VStack(spacing: 3) {
                    MemberAvatarView(
                        name: member.name, colorHex: member.color, avatar: member.avatar, size: 42
                    )
                    Text(member.name).font(.caption2).lineLimit(1)
                    Text("★ \(balance)")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.orange)
                        .monospacedDigit()
                }
                .opacity(isOn ? 1 : 0.35)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { filter.solo(member.id) }
                .onTapGesture { filter.toggle(member.id, all: allIDs) }
                .onLongPressGesture { filter.solo(member.id) }
                .accessibilityLabel("\(member.name)")
                .accessibilityValue("\(balance) stars")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Store: 2-across tiles, priced in orange

    private func store(_ loaded: RewardsData) -> some View {
        let solo = RewardsLogic.soloID(effective: effective)
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(loaded.rewards, id: \.id) { reward in
                    tile(reward, loaded: loaded, solo: solo)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            if context.session.isAdmin {
                Button {
                    creatingReward = true
                } label: {
                    GhostLabel(title: "New reward")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            Spacer(minLength: 24)
        }
    }

    private func tile(
        _ reward: Components.Schemas.Reward,
        loaded: RewardsData,
        solo: String?
    ) -> some View {
        let short = solo.flatMap { soloID in
            RewardsLogic.starsShort(
                balance: RewardsLogic.balance(of: soloID, in: loaded.balances),
                cost: reward.costStars
            )
        }
        let pending = loaded.waiting.contains { $0.rewardId == reward.id }
        return Button {
            guard !redeemBusy else { return }
            if let solo {
                if short == nil {
                    confirmingRedeem = PendingRedeem(reward: reward, memberID: solo)
                }
                // Out of reach: the tile's "needs N more" line is the answer.
            } else {
                pickingWho = PickingWho(reward: reward)
            }
        } label: {
            VStack(spacing: 4) {
                RewardEmojiView(emoji: reward.emoji, size: 34)
                    .opacity(short != nil ? 0.4 : 1)
                    .saturation(short != nil ? 0.2 : 1)
                Text(reward.title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text("★ \(reward.costStars)")
                    .font(.footnote.weight(.heavy))
                    .foregroundStyle(short != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .monospacedDigit()
                // Out of reach: dim the picture, never the words.
                if let short, let solo {
                    Text("\(name(of: solo)) needs \(short) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 108)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if pending {
                    Text("WAITING")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                        .padding(6)
                }
            }
            .scaleEffect(celebratedRewardID == reward.id ? 1.06 : 1)
            .overlay {
                if celebratedRewardID == reward.id {
                    Text("🎉 −★ \(reward.costStars)")
                        .font(.headline)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(reward.title), \(reward.costStars) stars"
                + (short != nil ? ", out of reach" : "")
                + (pending ? ", one waiting" : "")
        )
    }

    // MARK: - Who is redeeming? (the family-view path)

    private func whoPicker(_ reward: Components.Schemas.Reward) -> some View {
        NavigationStack {
            List {
                ForEach(RewardsLogic.pickerOrder(members: members, effective: effective), id: \.id) { member in
                    let balance = RewardsLogic.balance(of: member.id, in: data.value?.balances ?? [])
                    let short = RewardsLogic.starsShort(balance: balance, cost: reward.costStars)
                    Button {
                        guard short == nil else { return }
                        pickingWho = nil
                        confirmingRedeem = PendingRedeem(reward: reward, memberID: member.id)
                    } label: {
                        HStack(spacing: 10) {
                            MemberAvatarView(
                                name: member.name, colorHex: member.color,
                                avatar: member.avatar, size: 30
                            )
                            Text(member.name)
                            Spacer()
                            Text(short.map { "needs \($0) more" } ?? "★ \(balance)")
                                .font(.footnote.weight(short == nil ? .bold : .semibold))
                                .foregroundStyle(short == nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                                .monospacedDigit()
                        }
                        .opacity(short == nil ? 1 : 0.5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(short != nil)
                    .accessibilityLabel(
                        "\(member.name), " + (short.map { "needs \($0) more stars" } ?? "\(balance) stars")
                    )
                }
            }
            .navigationTitle("Who is redeeming?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { pickingWho = nil }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func redeemMessage(_ pending: PendingRedeem) -> String {
        let balance = RewardsLogic.balance(of: pending.memberID, in: data.value?.balances ?? [])
        let kept = balance - pending.reward.costStars
        return "\(name(of: pending.memberID)) spends ★ \(pending.reward.costStars) and keeps ★ \(max(kept, 0)). A parent makes it real and marks it done under Activity."
    }

    // MARK: - Activity: Waiting (actionable) + Done (the record)

    private func activity(_ loaded: RewardsData) -> some View {
        let waiting = loaded.waiting.filter { effective.contains($0.memberId) }
        let done = loaded.done.filter { effective.contains($0.memberId) }
        return List {
            Section {
                if waiting.isEmpty {
                    Text("Nothing waiting.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(waiting, id: \.id) { redemption in
                        waitingRow(redemption)
                    }
                }
            } header: {
                Text("Waiting — a parent marks it done").font(.caption.weight(.semibold))
            }
            if !done.isEmpty {
                Section {
                    ForEach(done, id: \.id) { redemption in
                        doneRow(redemption)
                    }
                } header: {
                    Text("Done").font(.caption.weight(.semibold))
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
    }

    private func waitingRow(_ redemption: Components.Schemas.RewardRedemption) -> some View {
        let fulfillable = RewardsLogic.canFulfill(redemption, isAdmin: context.session.isAdmin)
        return HStack(spacing: 10) {
            Button {
                confirmingFulfill = redemption
            } label: {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(fulfillable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!fulfillable)
            .accessibilityLabel("Mark \(redemption.title) done — asks first, done is permanent")
            RewardEmojiView(emoji: redemption.emoji, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(redemption.title).font(.subheadline)
                Text("\(name(of: redemption.memberId)) · \(whenLabel(redemption.createdAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("★ \(redemption.costStars)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .monospacedDigit()
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // The blue un-do side, as everywhere (owner rev 3).
            Button {
                if RewardsLogic.returnNeedsConfirm(
                    redemptionMemberID: redemption.memberId,
                    sessionMemberID: context.session.memberID
                ) {
                    confirmingReturn = redemption
                } else {
                    Task { await returnStars(redemption) }
                }
            } label: {
                Label("Return", systemImage: "arrow.uturn.backward")
            }
            .tint(.blue)
            .accessibilityLabel("Return \(redemption.title), \(redemption.costStars) stars back")
        }
        .accessibilityElement(children: .combine)
    }

    private func doneRow(_ redemption: Components.Schemas.RewardRedemption) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.green)
                .frame(width: 20)
            Text(redemption.title).font(.subheadline)
            Spacer()
            Text("\(name(of: redemption.memberId)) · \(whenLabel(redemption.fulfilledAt ?? redemption.createdAt))")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("−★ \(redemption.costStars)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    /// "Aug 10 · 18:05" / "Aug 10 · 6:05 PM" in the household's zone.
    private func whenLabel(_ instant: String?) -> String {
        guard let instant, let date = RewardsLogic.instant(instant) else { return "" }
        let formatter = DateFormatter()
        formatter.timeZone = clock.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        let time = ClockDisplay.time(
            date, timeZone: clock.timeZone, use24: DisplayPrefs.uses24Hour(timeFormat)
        )
        return "\(formatter.string(from: date)) · \(time)"
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
            // Done is household-wide here — the chips filter it live
            // (mock: the feed obeys the chip row, not the session).
            async let doneCall = context.client.api.listRewardRedemptions(
                .init(query: .init(status: .fulfilled, limit: RewardsLogic.doneLimit))
            )
            async let membersCall = context.client.api.listMembers(.init())

            var loaded = RewardsData(balances: [], rewards: [], waiting: [], done: [], members: [])
            switch try await membersCall {
            case .ok(let ok): loaded.members = try ok.body.json.members
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await balancesCall {
            case .ok(let ok): loaded.balances = try ok.body.json.balances
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await rewardsCall {
            case .ok(let ok): loaded.rewards = try ok.body.json.rewards
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await waitingCall {
            case .ok(let ok): loaded.waiting = RewardsLogic.waiting(try ok.body.json.redemptions)
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await doneCall {
            case .ok(let ok): loaded.done = RewardsLogic.done(try ok.body.json.redemptions)
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            data = .loaded(loaded)
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            fail()
        }
    }

    private func fail() {
        if data.value == nil { data = .failed("Check the connection and try again.") }
    }

    // MARK: Actions

    private func redeem(_ reward: Components.Schemas.Reward, memberID: String) async {
        // D12: redeem is not idempotent server-side — one at a time.
        guard !redeemBusy else { return }
        redeemBusy = true
        defer { redeemBusy = false }
        do {
            let output = try await context.client.api.redeemReward(
                .init(path: .init(id: reward.id), body: .json(.init(memberId: memberID)))
            )
            switch output {
            case .ok:
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
        if let emoji, !emoji.isEmpty {
            Text(emoji).font(.system(size: size))
        } else {
            Image(systemName: "gift")
                .font(.system(size: size * 0.8))
                .foregroundStyle(.secondary)
        }
    }
}

/// New reward (parents): emoji + name + cost, 1–500 ★ (mock).
@MainActor
private struct RewardFormView: View {
    let context: SignedInContext
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var title = ""
    @State private var emoji = ""
    @State private var emojiFocused = false
    @State private var cost = 25
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        // The well, not a bare field: sparkles on a tinted
                        // slot so it reads as the emoji picker it is (owner
                        // 2026-08-14 — it looked like stray padding).
                        EmojiWell(emoji: $emoji, focused: $emojiFocused)
                        TextField("Reward name", text: $title)
                    }
                    Stepper(value: $cost, in: 1...500, step: 1) {
                        HStack {
                            Text("Cost")
                            Spacer()
                            Text("★ \(cost)")
                                .foregroundStyle(.orange)
                                .fontWeight(.bold)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .navigationTitle("New reward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
            .alert(
                errorMessage ?? "Something went wrong.",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let body = Components.Schemas.RewardCreate(
                title: title.trimmingCharacters(in: .whitespaces),
                emoji: emoji.isEmpty ? nil : emoji,
                costStars: cost
            )
            switch try await context.client.api.createReward(.init(body: .json(body))) {
            case .created:
                onSaved()
                dismiss()
            case .unauthorized:
                appState.handleUnauthorized()
            case .forbidden:
                errorMessage = "Only a parent can add rewards."
            default:
                errorMessage = "That didn't save. Try again?"
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Your home server didn't answer."
        }
    }
}
