import DianeKit
import SwiftUI

// MARK: - Pure board logic (nonisolated, unit-tested)

/// Which board the segmented picker shows.
enum ChoresTab: String, CaseIterable {
    case mine = "Mine"
    case everyone = "Everyone"
}

/// Section builder + per-row action rules for the chore board.
enum ChoreBoard {
    typealias Occurrence = Components.Schemas.ChoreOccurrence

    struct Mine: Equatable {
        var late: [Occurrence] = []
        var today: [Occurrence] = []
        var dueSoon: [Occurrence] = []  // D07: deadline ("by") chores, web parity
        var anytime: [Occurrence] = []
        var pool: [Occurrence] = []
        var doneToday: [Occurrence] = []
        var isEmpty: Bool {
            late.isEmpty && today.isEmpty && dueSoon.isEmpty && anytime.isEmpty
                && pool.isEmpty && doneToday.isEmpty
        }
    }

    struct MemberSection: Equatable {
        let member: Components.Schemas.Member
        var open: [Occurrence] = []
    }

    struct Everyone: Equatable {
        var members: [MemberSection] = []
        var pool: [Occurrence] = []
        var doneToday: [Occurrence] = []
    }

    /// What the row's controls and context menu may offer.
    struct RowActions: Equatable {
        var canComplete = false
        var canUncomplete = false
        var canClaim = false
        var canPutBack = false
        var canDismiss = false
    }

    /// Owner = claimer, else assignee; both nil = up-for-grabs pool.
    static func owner(of occurrence: Occurrence) -> String? {
        occurrence.claimedByMemberId ?? occurrence.assigneeMemberId
    }

    static func isPool(_ occurrence: Occurrence) -> Bool {
        occurrence.assigneeMemberId == nil && occurrence.claimedByMemberId == nil
    }

    /// D06: a completed row belongs to its OWNER; an ownerless pool row to its completer.
    static func doneOwner(of occurrence: Occurrence) -> String? {
        owner(of: occurrence) ?? occurrence.completedByMemberId
    }

    /// D06: the completer's id when someone other than the owner checked it off.
    static func completedByOther(_ occurrence: Occurrence) -> String? {
        guard let completer = occurrence.completedByMemberId,
              let owner = owner(of: occurrence),
              completer != owner
        else { return nil }
        return completer
    }

    static func mine(_ occurrences: [Occurrence], myID: String) -> Mine {
        var board = Mine()
        for occurrence in occurrences {
            if occurrence.status == .completed {
                if doneOwner(of: occurrence) == myID {  // D06: owner keeps the done row
                    board.doneToday.append(occurrence)
                }
            } else if isPool(occurrence) {
                board.pool.append(occurrence)
            } else if owner(of: occurrence) == myID {
                if occurrence.late {
                    board.late.append(occurrence)
                } else if occurrence.dueMode == .by {
                    board.dueSoon.append(occurrence)  // D07: a deadline isn't "Today"
                } else if occurrence.dueDate != nil {
                    board.today.append(occurrence)
                } else {
                    board.anytime.append(occurrence)
                }
            }
        }
        board.late.sort(by: openOrder)
        board.today.sort(by: openOrder)
        board.dueSoon.sort(by: openOrder)
        board.anytime.sort(by: openOrder)
        board.pool.sort(by: openOrder)
        board.doneToday.sort(by: doneOrder)
        return board
    }

    static func everyone(_ occurrences: [Occurrence], members: [Components.Schemas.Member]) -> Everyone {
        var board = Everyone()
        var openByOwner: [String: [Occurrence]] = [:]
        for occurrence in occurrences {
            if occurrence.status == .completed {
                board.doneToday.append(occurrence)
            } else if isPool(occurrence) {
                board.pool.append(occurrence)
            } else if let owner = owner(of: occurrence) {
                openByOwner[owner, default: []].append(occurrence)
            }
        }
        board.members = members
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .map { .init(member: $0, open: (openByOwner[$0.id] ?? []).sorted(by: openOrder)) }
        board.pool.sort(by: openOrder)
        board.doneToday.sort(by: doneOrder)
        return board
    }

    static func actions(for occurrence: Occurrence) -> RowActions {
        var actions = RowActions()
        guard occurrence.status == .open else {
            actions.canUncomplete = true
            return actions
        }
        actions.canComplete = true
        actions.canClaim = isPool(occurrence)
        // D27: anyone may put a claimed pool row back (shared kiosk trust).
        actions.canPutBack = occurrence.claimedByMemberId != nil
        // D23: the server dismisses any open row, dated or not (null anchor is designed).
        actions.canDismiss = true
        return actions
    }

    /// D24: dismiss is permanent — the confirm dialog names the chore.
    static func dismissPrompt(_ title: String) -> String {
        "Dismiss \u{201C}\(title)\u{201D}?"
    }

    /// Short human copy for a 409 code (nil = the row changed under us).
    /// D21: exactly the codes the server emits — no phantom entries.
    static func conflictCopy(_ code: String?) -> String {
        switch code {
        case "already_claimed": "Someone already grabbed this one."
        case "not_claimable": "That one's assigned, not up for grabs."
        case "not_actionable": "That one isn't up right now."
        case "already_completed": "Already done — uncomplete it instead."
        case "insufficient_stars": "Can't undo that — those stars are already spent."
        default: "That didn't go through. The board will catch up."
        }
    }

    /// Late first, then by due date + time (anytime last), then title.
    private static func openOrder(_ a: Occurrence, _ b: Occurrence) -> Bool {
        sortKey(a) < sortKey(b)
    }

    private static func sortKey(_ o: Occurrence) -> (Int, String, String, String, String) {
        (o.late ? 0 : 1, o.dueDate ?? "9999-99-99", o.dueTime ?? "99:99", o.title, o.id)
    }

    /// Newest completion first (ISO-8601 Z instants sort lexically).
    private static func doneOrder(_ a: Occurrence, _ b: Occurrence) -> Bool {
        (a.completedAt ?? "", a.id) > (b.completedAt ?? "", b.id)
    }
}

/// One fetch pass; both tabs render from it.
struct ChoresData {
    var occurrences: [ChoreBoard.Occurrence]
    var members: [Components.Schemas.Member]
}

extension Components.Schemas.ChoreActionResult.OccurrencePayload {
    /// Same wire shape as ChoreOccurrence; the generator can't share inline schemas.
    fileprivate var asOccurrence: Components.Schemas.ChoreOccurrence {
        .init(
            id: id,
            choreId: choreId,
            title: title,
            emoji: emoji,
            notes: notes,
            starValue: starValue,
            upForGrabs: upForGrabs,
            dueDate: dueDate,
            dueMode: dueMode.flatMap { .init(rawValue: $0.rawValue) },
            dueTime: dueTime,
            status: .init(rawValue: status.rawValue) ?? .open,
            late: late,
            assigneeMemberId: assigneeMemberId,
            claimedByMemberId: claimedByMemberId,
            completedByMemberId: completedByMemberId,
            completedAt: completedAt
        )
    }
}

// MARK: - Screen

struct ChoresView: View {
    let context: SignedInContext
    @Environment(SyncSignals.self) private var signals
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock

    @State private var data: Loadable<ChoresData> = .loading
    @State private var tab: ChoresTab = .mine
    @State private var busyIDs: Set<String> = []
    @State private var alertMessage: String?
    @State private var pendingDismiss: ChoreBoard.Occurrence?  // D24

    private var myID: String { context.session.memberID }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Board", selection: $tab) {
                    ForEach(ChoresTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 6)

                content
            }
            .navigationTitle("Chores")
            .navigationBarTitleDisplayMode(.inline)
        }
        // clock.today in the key refetches at household midnight (M9 spine).
        .task(id: "\(signals.version(of: [.chores, .members, .stars]))|\(clock.today)") { await load() }
        .alert(alertMessage ?? "Something went wrong.", isPresented: alertShown) {
            Button("OK", role: .cancel) {}
        }
        // D24: dismiss never resurfaces, so it always confirms first.
        .confirmationDialog(
            ChoreBoard.dismissPrompt(pendingDismiss?.title ?? ""),
            isPresented: dismissShown,
            titleVisibility: .visible,
            presenting: pendingDismiss
        ) { occurrence in
            Button("Dismiss", role: .destructive) {
                Task { await perform(.dismiss, on: occurrence) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It goes away for good — no stars, and it won't come back.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch data {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't reach home", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
        case .loaded(let loaded):
            boardList(loaded)
        }
    }

    @ViewBuilder
    private func boardList(_ loaded: ChoresData) -> some View {
        let byID = Dictionary(uniqueKeysWithValues: loaded.members.map { ($0.id, $0) })
        switch tab {
        case .mine:
            let board = ChoreBoard.mine(loaded.occurrences, myID: myID)
            if board.isEmpty {
                emptyBoard
            } else {
                List {
                    choreSection("Late", board.late, accent: .red)
                    choreSection("Today", board.today)
                    choreSection("Due soon", board.dueSoon)  // D07
                    choreSection("Anytime", board.anytime)
                    choreSection("Up for grabs", board.pool)
                    Section {
                        ForEach(board.doneToday, id: \.id) { occurrence in
                            // D06: my done row notes who else checked it off.
                            row(occurrence, completedByName: completerName(occurrence, byID: byID))
                        }
                    } header: {
                        if !board.doneToday.isEmpty { Text("Done today") }
                    }
                }
                .refreshable { await load() }
            }
        case .everyone:
            if loaded.occurrences.isEmpty {
                emptyBoard
            } else {
                let board = ChoreBoard.everyone(loaded.occurrences, members: loaded.members)
                List {
                    ForEach(board.members, id: \.member.id) { section in
                        memberSection(section)
                    }
                    choreSection("Up for grabs", board.pool)
                    Section {
                        ForEach(board.doneToday, id: \.id) { occurrence in
                            // D06: attribute the done row to its OWNER, note the completer.
                            row(
                                occurrence,
                                attribution: ChoreBoard.doneOwner(of: occurrence).flatMap { byID[$0] },
                                completedByName: completerName(occurrence, byID: byID)
                            )
                        }
                    } header: {
                        if !board.doneToday.isEmpty { Text("Done today") }
                    }
                }
                .refreshable { await load() }
            }
        }
    }

    /// D06: the completer's name, only when it wasn't the owner's own work.
    private func completerName(
        _ occurrence: ChoreBoard.Occurrence,
        byID: [String: Components.Schemas.Member]
    ) -> String? {
        ChoreBoard.completedByOther(occurrence).flatMap { byID[$0]?.name }
    }

    private var emptyBoard: some View {
        ContentUnavailableView {
            Label("Nothing to do", systemImage: "sparkles")
        } description: {
            Text("All clear. Enjoy!")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func choreSection(_ title: String, _ rows: [ChoreBoard.Occurrence], accent: Color? = nil) -> some View {
        if !rows.isEmpty {
            Section {
                ForEach(rows, id: \.id) { row($0) }
            } header: {
                if let accent {
                    Text(title).foregroundStyle(accent).fontWeight(.semibold)
                } else {
                    Text(title)
                }
            }
        }
    }

    private func memberSection(_ section: ChoreBoard.MemberSection) -> some View {
        Section {
            if section.open.isEmpty {
                Text("All done. Nice!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(section.open, id: \.id) { row($0) }
            }
        } header: {
            HStack(spacing: 8) {
                MemberAvatarView(
                    name: section.member.name,
                    colorHex: section.member.color,
                    avatar: section.member.avatar,
                    size: 24
                )
                Text(section.member.name)
            }
            .textCase(nil)
        }
    }

    // MARK: Row

    private func row(
        _ occurrence: ChoreBoard.Occurrence,
        attribution: Components.Schemas.Member? = nil,
        completedByName: String? = nil
    ) -> some View {
        let completed = occurrence.status == .completed
        let actions = ChoreBoard.actions(for: occurrence)
        return HStack(spacing: 12) {
            Group {
                if let emoji = occurrence.emoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 30))
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(occurrence.title)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .strikethrough(completed)
                    .foregroundStyle(completed ? Color.secondary : Color.primary)
                metaLine(occurrence, attribution: attribution, completedByName: completedByName)
            }

            Spacer(minLength: 8)

            if actions.canClaim {
                capsuleButton("Claim", occurrence: occurrence) {
                    Task { await perform(.claim, on: occurrence) }
                }
            }
            if actions.canPutBack {
                // D27: visible undo of Claim — no long-press hunting.
                capsuleButton("Put back", occurrence: occurrence) {
                    Task { await perform(.unclaim, on: occurrence) }
                }
            }

            Text("★ \(occurrence.starValue)")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(completed ? Color.secondary : Color.orange)

            completeButton(occurrence, completed: completed)
        }
        .contextMenu { contextMenu(for: occurrence, actions: actions) }
        // D27: swipe mirrors the row's actions.
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if actions.canClaim {
                Button { Task { await perform(.claim, on: occurrence) } } label: {
                    Label("Claim", systemImage: "hand.raised")
                }
                .tint(.blue)
            }
            if actions.canPutBack {
                Button { Task { await perform(.unclaim, on: occurrence) } } label: {
                    Label("Put back", systemImage: "arrow.uturn.backward")
                }
                .tint(.indigo)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if actions.canComplete {
                Button { Task { await perform(.complete, on: occurrence) } } label: {
                    Label("Complete", systemImage: "checkmark.circle")
                }
                .tint(.green)
            }
            if actions.canUncomplete {
                Button { Task { await perform(.uncomplete, on: occurrence) } } label: {
                    Label("Uncomplete", systemImage: "arrow.uturn.backward")
                }
                .tint(.orange)
            }
            if actions.canDismiss {
                Button { pendingDismiss = occurrence } label: {  // D24: confirms first
                    Label("Dismiss", systemImage: "xmark.circle")
                }
                .tint(.red)
            }
        }
    }

    private func capsuleButton(
        _ title: String,
        occurrence: ChoreBoard.Occurrence,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .disabled(busyIDs.contains(occurrence.id))
    }

    @ViewBuilder
    private func metaLine(
        _ occurrence: ChoreBoard.Occurrence,
        attribution: Components.Schemas.Member?,
        completedByName: String?
    ) -> some View {
        HStack(spacing: 6) {
            if occurrence.status == .open, occurrence.late {
                chip("late", .red)
            }
            if let time = occurrence.dueTime {
                chip(time, .secondary)
            }
            if occurrence.dueMode == .by, let due = occurrence.dueDate {
                Text("by \(Self.shortDate(due))")  // D07: deadline visible on the row
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let attribution {
                Text(attribution.name)
                    .font(.caption)
                    .foregroundStyle(Color(hex: attribution.color))
            }
            if let completedByName {
                Text("by \(completedByName)")  // D06
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func completeButton(_ occurrence: ChoreBoard.Occurrence, completed: Bool) -> some View {
        Button {
            // D27: tapping a checked circle un-checks it — no long-press hunting.
            Task { await perform(completed ? .uncomplete : .complete, on: occurrence) }
        } label: {
            Image(systemName: completed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(completed ? Color.green : Color.secondary)
                .frame(width: 44, height: 44)  // D27: HIG minimum tap target
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(busyIDs.contains(occurrence.id))
        .accessibilityLabel(completed ? "Uncomplete \(occurrence.title)" : "Complete \(occurrence.title)")
    }

    @ViewBuilder
    private func contextMenu(for occurrence: ChoreBoard.Occurrence, actions: ChoreBoard.RowActions) -> some View {
        if actions.canUncomplete {
            Button("Uncomplete", systemImage: "arrow.uturn.backward") {
                Task { await perform(.uncomplete, on: occurrence) }
            }
        }
        if actions.canClaim {
            Button("Claim", systemImage: "hand.raised") {
                Task { await perform(.claim, on: occurrence) }
            }
        }
        if actions.canPutBack {
            Button("Put back", systemImage: "arrow.uturn.backward") {
                Task { await perform(.unclaim, on: occurrence) }
            }
        }
        if actions.canDismiss {
            Button("Dismiss", systemImage: "xmark.circle", role: .destructive) {
                pendingDismiss = occurrence  // D24: confirm before the permanent dismiss
            }
        }
    }

    // MARK: Data + actions

    private var alertShown: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    private var dismissShown: Binding<Bool> {
        Binding(
            get: { pendingDismiss != nil },
            set: { if !$0 { pendingDismiss = nil } }
        )
    }

    private func load() async {
        do {
            async let occurrencesCall = context.client.api.listChoreOccurrences(.init())
            async let membersCall = context.client.api.listMembers(.init())
            let (occurrencesOut, membersOut) = try await (occurrencesCall, membersCall)

            if case .unauthorized = occurrencesOut { appState.handleUnauthorized(); return }
            if case .unauthorized = membersOut { appState.handleUnauthorized(); return }
            guard case .ok(let occurrencesOK) = occurrencesOut,
                  case .ok(let membersOK) = membersOut
            else {
                fail()
                return
            }
            data = .loaded(.init(
                occurrences: try occurrencesOK.body.json.occurrences,
                members: try membersOK.body.json.members
            ))
        } catch {
            guard !isTaskCancellation(error) else { return }  // D08
            fail()
        }
    }

    /// A failed refresh keeps stale data on screen; only an empty screen fails hard.
    private func fail() {
        if data.value == nil {
            data = .failed("The home server isn't answering right now.")
        }
    }

    private enum RowCall {
        case complete, uncomplete, claim, unclaim, dismiss
    }

    private enum CallOutcome {
        case ok(Components.Schemas.ChoreActionResult)
        case unauthorized
        case conflict(String?)
        case failed
    }

    private func perform(_ call: RowCall, on occurrence: ChoreBoard.Occurrence) async {
        guard busyIDs.insert(occurrence.id).inserted else { return }
        defer { busyIDs.remove(occurrence.id) }
        switch await send(call, id: occurrence.id) {
        case .ok(let result):
            apply(result, replacing: occurrence.id)
        case .unauthorized:
            appState.handleUnauthorized()
        case .conflict(let code):
            alertMessage = ChoreBoard.conflictCopy(code)
            await load()
        case .failed:
            alertMessage = "That didn't work. Check the connection and try again."
        }
    }

    /// Maps the five per-operation Output enums onto one outcome. 404 = the
    /// synthetic id went stale under us, so treat it like a conflict: refetch.
    private func send(_ call: RowCall, id: String) async -> CallOutcome {
        let api = context.client.api
        do {
            switch call {
            case .complete:
                switch try await api.completeChoreOccurrence(.init(path: .init(id: id))) {
                case .ok(let ok): return .ok(try ok.body.json)
                case .unauthorized: return .unauthorized
                // D21: the semantic code is the Error body's `error` field.
                case .conflict(let conflict): return .conflict((try? conflict.body.json)?.error)
                case .notFound: return .conflict(nil)
                default: return .failed
                }
            case .uncomplete:
                switch try await api.uncompleteChoreOccurrence(.init(path: .init(id: id))) {
                case .ok(let ok): return .ok(try ok.body.json)
                case .unauthorized: return .unauthorized
                case .conflict(let conflict): return .conflict((try? conflict.body.json)?.error)  // D21
                case .notFound: return .conflict(nil)
                default: return .failed
                }
            case .claim:
                switch try await api.claimChoreOccurrence(.init(path: .init(id: id))) {
                case .ok(let ok): return .ok(try ok.body.json)
                case .unauthorized: return .unauthorized
                case .conflict(let conflict): return .conflict((try? conflict.body.json)?.error)  // D21
                case .notFound: return .conflict(nil)
                default: return .failed
                }
            case .unclaim:
                // D21: unclaim declares no 409 — a raced put-back is a server no-op 200.
                switch try await api.unclaimChoreOccurrence(.init(path: .init(id: id))) {
                case .ok(let ok): return .ok(try ok.body.json)
                case .unauthorized: return .unauthorized
                case .notFound: return .conflict(nil)
                default: return .failed
                }
            case .dismiss:
                switch try await api.dismissChoreOccurrence(.init(path: .init(id: id))) {
                case .ok(let ok): return .ok(try ok.body.json)
                case .unauthorized: return .unauthorized
                case .conflict(let conflict): return .conflict((try? conflict.body.json)?.error)  // D21
                case .notFound: return .conflict(nil)
                default: return .failed
                }
            }
        } catch {
            return .failed
        }
    }

    /// Optimistic apply; the SSE bump refetches the truth right after. A claim
    /// changes the synthetic id, so replace by the acted-on row's id.
    private func apply(_ result: Components.Schemas.ChoreActionResult, replacing id: String) {
        guard case .loaded(var loaded) = data else { return }
        if let updated = result.occurrence?.asOccurrence {
            if let index = loaded.occurrences.firstIndex(where: { $0.id == id }) {
                loaded.occurrences[index] = updated
            } else {
                loaded.occurrences.append(updated)
            }
        } else {
            loaded.occurrences.removeAll { $0.id == id }
        }
        data = .loaded(loaded)
    }

    /// "2026-07-30" → "Jul 30", built in the local calendar (never via UTC).
    private static func shortDate(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return ymd }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
