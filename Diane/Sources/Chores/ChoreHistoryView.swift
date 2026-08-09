import DianeKit
import SwiftUI

/// The chore feed behind History (M9e page 5, unchanged from rev 1): period
/// chips, the shared member filter, a day-grouped feed, dismissals gray.
/// A feed, not a scoreboard — no per-member totals, ever.
enum ChoreHistoryLogic {
    typealias Entry = Components.Schemas.ChoreHistoryEntry

    /// The mock's period chips, as the stock segmented control so the module
    /// has one scope idiom.
    enum Period: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "Week"
        case month = "Month"
        case all = "All"
        var id: String { rawValue }
    }

    /// nil = no window at all (the All chip pages back through everything).
    static func range(_ period: Period, today: String) -> (from: String, to: String)? {
        switch period {
        case .today: (today, today)
        case .week: (MyDayLogic.addDays(today, -6), today)
        case .month: (MyDayLogic.addDays(today, -29), today)
        case .all: nil
        }
    }

    /// Who this entry belongs to: its owner, else whoever did it.
    static func owner(of entry: Entry) -> String? {
        entry.memberId ?? entry.completedByMemberId
    }

    static func isVisible(_ entry: Entry, effective: Set<String>) -> Bool {
        guard let owner = owner(of: entry) else { return effective.contains(ChoresPageLogic.poolID) }
        return effective.contains(owner)
    }

    struct DayGroup: Identifiable, Equatable {
        let date: String
        let entries: [Entry]
        var id: String { date }
    }

    /// Newest day first, entries newest first inside it. The server already
    /// sorts; grouping preserves that order.
    static func groups(_ entries: [Entry], timeZone: TimeZone) -> [DayGroup] {
        var order: [String] = []
        var byDay: [String: [Entry]] = [:]
        for entry in entries {
            let day = TodayLogic.parseInstant(entry.occurredAt)
                .map { TodayLogic.dateString(for: $0, timeZone: timeZone) }
                ?? entry.dueDate ?? ""
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.compactMap { day in
            byDay[day].map { DayGroup(date: day, entries: $0) }
        }
    }

    /// "Maya · 7:26" — who, and when they did it.
    static func attribution(_ entry: Entry, names: [String: String], timeZone: TimeZone) -> String {
        let who = (entry.completedByMemberId ?? entry.memberId).flatMap { names[$0] }
        let time = TodayLogic.timeLabel(entry.occurredAt, timeZone: timeZone)
        if entry.action == .dismissed {
            return who.map { "dismissed · \($0)" } ?? "dismissed"
        }
        return [who, time].compactMap { $0 }.joined(separator: " · ")
    }
}

struct ChoreHistoryView: View {
    let context: SignedInContext

    @Environment(AppState.self) private var appState
    @Environment(SyncSignals.self) private var signals
    @Environment(HouseholdClock.self) private var clock
    @Environment(MemberFilterStore.self) private var filter

    @State private var period: ChoreHistoryLogic.Period = .week
    @State private var data: Loadable<Loaded> = .loading
    @State private var loadingMore = false

    private let rowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    /// One screenful and change. History is the one list here that grows
    /// without a bound, so it pages instead of fetching the lot.
    private let pageSize = 60

    struct Loaded: Equatable {
        var entries: [ChoreHistoryLogic.Entry]
        var members: [Components.Schemas.Member]
        /// The server's cursor for older entries; nil = that's the lot.
        var nextBefore: String?
    }

    private var members: [Components.Schemas.Member] { data.value?.members ?? [] }
    private var allIDs: [String] { members.map(\.id) + [ChoresPageLogic.poolID] }
    private var effective: Set<String> { filter.effective(all: allIDs) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Period", selection: $period) {
                ForEach(ChoreHistoryLogic.Period.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            content
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(signals.version(of: [.chores, .members]))|\(clock.today)|\(period.rawValue)") {
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch data {
        case .loading:
            Spacer()
            ProgressView()
            Spacer()
        case .failed(let message):
            Spacer()
            ContentUnavailableView {
                Label("Couldn't load history", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
            Spacer()
        case .loaded(let loaded):
            feed(loaded)
        }
    }

    private func feed(_ loaded: Loaded) -> some View {
        let visible = loaded.entries.filter { ChoreHistoryLogic.isVisible($0, effective: effective) }
        let groups = ChoreHistoryLogic.groups(visible, timeZone: clock.timeZone)
        return List {
            if groups.isEmpty {
                Text("Nothing here yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .listRowSeparator(.hidden)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.entries, id: \.id) { entry in row(entry) }
                } header: {
                    Text(ChoresPageLogic.dayTitle(group.date, today: clock.today))
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                }
            }
            // Scrolling to the end asks for the next page — no button, no
            // page numbers, the feed just keeps going. No footer copy at
            // the end either (owner 2026-08-07).
            if loaded.nextBefore != nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .frame(minHeight: 44)
                .listRowSeparator(.hidden)
                .onAppear { Task { await loadMore() } }
            }
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .fontDesign(.rounded)
        .refreshable { await load() }
    }

    private func row(_ entry: ChoreHistoryLogic.Entry) -> some View {
        let dismissed = entry.action == .dismissed
        return HStack(spacing: 10) {
            Image(systemName: dismissed ? "slash.circle" : "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(dismissed ? Color.secondary : Color.green)
                .frame(width: 20)
            if let emoji = entry.emoji { Text(emoji) }
            Text(entry.title)
                .foregroundStyle(dismissed ? Color.secondary : Color.primary)
            Spacer(minLength: 8)
            Text(ChoreHistoryLogic.attribution(entry, names: memberNames, timeZone: clock.timeZone))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if entry.starsAwarded > 0 {
                Text("+\(entry.starsAwarded) ★")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .listRowInsets(rowInsets)
    }

    private var memberNames: [String: String] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.name) })
    }

    private func load() async {
        if data.value == nil { data = .loading }
        let range = ChoreHistoryLogic.range(period, today: clock.today)
        do {
            async let historyCall = context.client.api.listChoreHistory(
                .init(query: .init(from: range?.from, to: range?.to, limit: "\(pageSize)"))
            )
            async let membersCall = context.client.api.listMembers(.init())

            var loaded = Loaded(entries: [], members: [], nextBefore: nil)
            switch try await historyCall {
            case .ok(let ok):
                let body = try ok.body.json
                loaded.entries = body.entries
                loaded.nextBefore = body.nextBefore
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await membersCall {
            case .ok(let ok): loaded.members = try ok.body.json.members
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            data = .loaded(loaded)
        } catch {
            guard !isTaskCancellation(error) else { return }
            fail()
        }
    }

    /// The next page, appended. Guarded so the spinner appearing twice (or a
    /// bounce at the end of the list) can't fire two requests for one cursor.
    private func loadMore() async {
        guard case .loaded(let current) = data,
              let cursor = current.nextBefore,
              !loadingMore
        else { return }
        loadingMore = true
        defer { loadingMore = false }
        let range = ChoreHistoryLogic.range(period, today: clock.today)
        do {
            let output = try await context.client.api.listChoreHistory(
                .init(query: .init(
                    from: range?.from,
                    to: range?.to,
                    limit: "\(pageSize)",
                    before: cursor
                ))
            )
            switch output {
            case .ok(let ok):
                let body = try ok.body.json
                // The cursor may have moved on while we waited — only append
                // to the page we actually asked from.
                guard case .loaded(var loaded) = data, loaded.nextBefore == cursor else { return }
                let known = Set(loaded.entries.map(\.id))
                loaded.entries += body.entries.filter { !known.contains($0.id) }
                loaded.nextBefore = body.nextBefore
                data = .loaded(loaded)
            case .unauthorized:
                appState.handleUnauthorized()
            default:
                // Stop asking rather than spin forever against a broken page.
                if case .loaded(var loaded) = data {
                    loaded.nextBefore = nil
                    data = .loaded(loaded)
                }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
        }
    }

    private func fail() {
        if data.value == nil { data = .failed("Check the connection and try again.") }
    }
}
