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
        case .week: (DayLogic.addDays(today, -6), today)
        case .month: (DayLogic.addDays(today, -29), today)
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

    /// One feed row — a shared chore-day is ONE row wearing every member's
    /// circle (owner 2026-08-09, like the Family Day view). The grouping key
    /// (chore + action + due date) mirrors the server's undo sibling group,
    /// so undoing the row undoes exactly what it shows.
    struct Row: Identifiable, Equatable {
        let entries: [Entry]
        var lead: Entry { entries[0] }
        var id: String { entries[0].id }
        var stars: Int { entries.reduce(0) { $0 + $1.starsAwarded } }
    }

    struct DayGroup: Identifiable, Equatable {
        let date: String
        let rows: [Row]
        var id: String { date }
    }

    /// Newest day first, rows newest first inside it (a group sits where its
    /// newest entry does — the server already sorts).
    static func groups(_ entries: [Entry], timeZone: TimeZone) -> [DayGroup] {
        var order: [String] = []
        var byDay: [String: [Entry]] = [:]
        for entry in entries {
            let day = TimeLogic.parseInstant(entry.occurredAt)
                .map { TimeLogic.dateString(for: $0, timeZone: timeZone) }
                ?? entry.dueDate ?? ""
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.compactMap { day in
            byDay[day].map { DayGroup(date: day, rows: rows($0)) }
        }
    }

    /// Merge one day's entries into shared rows, preserving feed order.
    static func rows(_ entries: [Entry]) -> [Row] {
        var order: [String] = []
        var byKey: [String: [Entry]] = [:]
        for entry in entries {
            let key = "\(entry.choreId)|\(entry.action.rawValue)|\(entry.dueDate ?? "")"
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(entry)
        }
        return order.compactMap { key in byKey[key].map(Row.init) }
    }

    /// 'Ada' · 'Ada & Ben' · 'Ada, Ben & Cal' — for the undo prompts.
    static func joinNames(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " & " + names[names.count - 1]
    }

    /// The undo prompt — the status circle always asks first (owner
    /// 2026-08-09, matching the WebUI; yours included), naming the whole
    /// crew of a shared row and the per-head stars at stake.
    static func undoPrompt(_ row: Row, names: [String: String]) -> String {
        let lead = row.lead
        if lead.action == .dismissed { return "Bring \(lead.title) back?" }
        let crew = row.entries.compactMap { actor($0).flatMap { names[$0] } }
        let who = crew.isEmpty ? "their" : joinNames(crew)
        let checks = crew.count > 1 ? "checks" : "check"
        guard lead.starsAwarded > 0 else { return "Undo \(who)'s \(checks)?" }
        let lose = crew.count > 1 ? "They each lose" : "They lose"
        return "Undo \(who)'s \(checks)? \(lose) \(lead.starsAwarded) ★."
    }

    /// Who acted: the completer, else the owner (nil = a pool dismissal).
    static func actor(_ entry: Entry) -> String? {
        entry.completedByMemberId ?? entry.memberId
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
    @State private var confirmUndo: ChoreHistoryLogic.Row?
    /// The 409 fallback: undo again with every star award left standing.
    @State private var confirmKeepStars: ChoreHistoryLogic.Row?
    @State private var actionError: String?
    @State private var undoing: Set<String> = []

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
        .alert(
            confirmUndo.map { ChoreHistoryLogic.undoPrompt($0, names: memberNames) } ?? "",
            isPresented: Binding(get: { confirmUndo != nil }, set: { if !$0 { confirmUndo = nil } })
        ) {
            Button("Undo", role: .destructive) {
                if let row = confirmUndo { Task { await undo(row, keepStars: false) } }
                confirmUndo = nil
            }
            Button("Cancel", role: .cancel) {}
        }
        // The owner's rule: not enough stars to take back → ask, and yes
        // keeps EVERYONE's stars untouched while the chore still returns.
        .alert(
            "Not enough stars to take back.",
            isPresented: Binding(get: { confirmKeepStars != nil }, set: { if !$0 { confirmKeepStars = nil } })
        ) {
            Button("Undo, keep stars", role: .destructive) {
                if let row = confirmKeepStars { Task { await undo(row, keepStars: true) } }
                confirmKeepStars = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Someone already spent them. Undo without changing any balances?")
        }
        .alert(
            "That didn't work",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
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
                    ForEach(group.rows) { row in rowView(row) }
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

    private func rowView(_ row: ChoreHistoryLogic.Row) -> some View {
        let lead = row.lead
        let dismissed = lead.action == .dismissed
        // Every actor of the shared group, one circle each (owner 2026-08-09,
        // like the Today page) — deduped, never a typed name.
        var seen: Set<String> = []
        let crew = row.entries.compactMap { entry in
            ChoreHistoryLogic.actor(entry).flatMap { id in
                seen.insert(id).inserted ? members.first(where: { $0.id == id }) : nil
            }
        }
        return HStack(spacing: 10) {
            statusCircle(row, dismissed: dismissed)
            if let emoji = lead.emoji { Text(emoji) }
            Text(lead.title)
                .foregroundStyle(dismissed ? Color.secondary : Color.primary)
            Spacer(minLength: 8)
            Text(TimeLogic.timeLabel(lead.occurredAt, timeZone: clock.timeZone) ?? "")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            HStack(spacing: crew.count > 1 ? -6 : 0) {
                ForEach(crew, id: \.id) { member in
                    MemberAvatarView(name: member.name, colorHex: member.color, avatar: nil, size: 22)
                }
            }
            if row.stars > 0 {
                Text("+\(row.stars) ★")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .grayscale(dismissed ? 1 : 0)
        .listRowInsets(rowInsets)
    }

    /// The status circle IS the undo control (owner 2026-08-09, matching the
    /// WebUI): a checked circle for completed, the slashed one for dismissed.
    /// Tapping an undoable row always asks first — yours included; the
    /// server says which entries still qualify (within the repeat frame) and
    /// undoes the whole shared group as one.
    @ViewBuilder
    private func statusCircle(_ row: ChoreHistoryLogic.Row, dismissed: Bool) -> some View {
        let symbol = Image(systemName: dismissed ? "slash.circle" : "checkmark.circle.fill")
            .font(.system(size: 26))
            .foregroundStyle(dismissed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
        if row.lead.undoable == true {
            Button { confirmUndo = row } label: {
                symbol.frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo \(row.lead.title)")
        } else {
            symbol.frame(width: 40, height: 40)
        }
    }

    private func undo(_ row: ChoreHistoryLogic.Row, keepStars: Bool) async {
        guard undoing.insert(row.id).inserted else { return }
        defer { undoing.remove(row.id) }
        do {
            let output = try await context.client.api.undoChoreHistory(
                .init(path: .init(id: row.lead.id), body: .json(.init(keepStars: keepStars)))
            )
            switch output {
            case .ok:
                await load()  // the row (its whole shared group) is gone
            case .conflict:
                confirmKeepStars = row  // spent stars — ask the owner's question
            case .unprocessableContent:
                actionError = "That one can't be undone any more — its next round has already started."
                await load()
            case .unauthorized:
                appState.handleUnauthorized()
            case .notFound:
                await load()  // undone elsewhere already
            default:
                actionError = "Check the connection and try again."
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            actionError = "Check the connection and try again."
        }
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
