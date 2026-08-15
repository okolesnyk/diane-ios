import DianeKit
import SwiftUI

/// Page 5 (M9e design): the Chores module — the whole workspace. The Family
/// Day chip row (rings, late dots, tap/solo) sits above three tabs and
/// filters all of them; every row wears the approved day-page
/// anatomy — check circle leading, emoji inline, facepile, orange star — so
/// this reads as one application, not two.
struct ChoresPageView: View {
    let context: SignedInContext
    /// The page's stack owner pushes detail routes (nav rule 2).
    let open: (DetailRoute) -> Void

    @Environment(AppState.self) private var appState
    @Environment(SyncSignals.self) private var signals
    @Environment(HouseholdClock.self) private var clock
    @Environment(MemberFilterStore.self) private var filter
    @AppStorage("timeFormat") private var timeFormat = "system"

    @State private var tab = ChoresPageView.launchTab
    @State private var data: Loadable<PageData> = .loading
    @State private var inFlight: Set<String> = []
    @State private var actionError: String?
    @State private var confirmDismiss: ChoresPageLogic.Row?
    @State private var confirmUndo: ChoresPageLogic.Row?
    @State private var newChore: NewChore?
    /// The one earned moment: a star floats up off the row just completed.
    @State private var floatingStar: String?

    /// Member tint — the same device-local switch the Today page reads.
    @AppStorage("memberTint") private var tintOn = true
    @Environment(\.colorScheme) private var colorScheme

    private let rowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

    struct PageData: Equatable {
        var actionable: [ChoresPageLogic.Occurrence]
        var window: [ChoresPageLogic.Occurrence]
        var board: [Components.Schemas.RoutineBoardEntry]
        var members: [Components.Schemas.Member]
    }

    /// A "+ New chore" carries the section it was tapped in.
    private struct NewChore: Identifiable {
        let date: String?
        var id: String { date ?? "anytime" }
    }

    /// Screenshot hook, twin of RootTabView's -uiTab: simctl can capture the
    /// screen but cannot tap a segment. Never compiled into release.
    static var launchTab: ChoresPageLogic.Tab {
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiChoresTab"),
           index + 1 < ProcessInfo.processInfo.arguments.count,
           let tab = ChoresPageLogic.Tab(rawValue: ProcessInfo.processInfo.arguments[index + 1]) {
            return tab
        }
        #endif
        return .all
    }

    private var me: String { context.session.memberID }
    private var members: [Components.Schemas.Member] { data.value?.members ?? [] }
    private var allIDs: [String] { members.map(\.id) + [ChoresPageLogic.poolID] }
    private var effective: Set<String> { filter.effective(all: allIDs) }

    private var reloadKey: String {
        "\(signals.version(of: [.chores, .members, .stars, .routines]))|\(clock.today)"
    }

    var body: some View {
        VStack(spacing: 0) {
            chips
            Picker("Scope", selection: $tab) {
                ForEach(ChoresPageLogic.Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            content
        }
        .navigationTitle("Chores")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadKey) { await load() }
        // Mounted here, not on the stack: this page holds the members the
        // detail needs, and the stack itself belongs to the caller.
        .dianeDetailDestinations(
            context: context,
            members: members,
            onChanged: { Task { await load() } }
        )
        .sheet(item: $newChore) { target in
            ChoreFormView(
                context: context,
                members: members,
                mode: .create,
                defaultDate: target.date,
                onSaved: { Task { await load() } }
            )
        }
        .alert(
            TimeLogic.dismissPrompt(confirmDismiss?.title ?? ""),
            isPresented: Binding(get: { confirmDismiss != nil }, set: { if !$0 { confirmDismiss = nil } })
        ) {
            Button("Dismiss", role: .destructive) {
                if let row = confirmDismiss { Task { await act(.dismiss, on: row) } }
                confirmDismiss = nil
            }
        } message: {
            Text("No stars for it — and you can bring it back from History.")
        }
        // Your own check reverts instantly; someone else's asks first and
        // names the cost (owner approved, rev 7).
        .alert(
            confirmUndo.map { ChoresPageLogic.undoPrompt($0, names: memberNames) } ?? "",
            isPresented: Binding(get: { confirmUndo != nil }, set: { if !$0 { confirmUndo = nil } })
        ) {
            Button("Undo check", role: .destructive) {
                if let row = confirmUndo { Task { await act(.uncomplete, on: row) } }
                confirmUndo = nil
            }
        } message: {
            Text(confirmUndo.map { ChoresPageLogic.undoDetail($0, names: memberNames) } ?? "")
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

    // MARK: - Chips (the Today page's row, plus the Anyone pseudo-member)

    private var chips: some View {
        let live = data.value?.actionable ?? []
        return HStack(spacing: 14) {
            ForEach(members, id: \.id) { member in
                let chip = TodayLogic.chip(
                    for: member.id,
                    chores: live,
                    board: data.value?.board ?? []
                )
                memberChip(member, chip: chip)
            }
            anyoneChip(count: ChoresPageLogic.poolCount(live))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func memberChip(
        _ member: Components.Schemas.Member,
        chip: TodayLogic.ChipState
    ) -> some View {
        let isOn = effective.contains(member.id)
        return VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: chip.progress)
                    .stroke(
                        Color(hex: member.color),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                MemberAvatarView(
                    name: member.name,
                    colorHex: member.color,
                    avatar: member.avatar,
                    size: 38
                )
                if chip.hasLate {
                    Circle().fill(.red).frame(width: 8, height: 8).offset(x: 16, y: -16)
                }
            }
            .frame(width: 46, height: 46)
            Text(member.name).font(.caption2).lineLimit(1)
        }
        .opacity(isOn ? 1 : 0.35)
        .contentShape(Rectangle())
        // Double-tap OR long-press solos — both on trial (owner 2026-08-08);
        // solo keeps Anyone on: unowned chores stay everyone's business.
        .onTapGesture(count: 2) { filter.solo([member.id, ChoresPageLogic.poolID]) }
        .onTapGesture { filter.toggle(member.id, all: allIDs) }
        .onLongPressGesture { filter.solo([member.id, ChoresPageLogic.poolID]) }
        .accessibilityLabel(
            "\(member.name), \(Int(chip.progress * 100)) percent done\(chip.hasLate ? ", has late chores" : "")"
        )
    }

    /// The Today page's pool language verbatim: dashed and colorless, no hue.
    private func anyoneChip(count: Int) -> some View {
        let isOn = effective.contains(ChoresPageLogic.poolID)
        return VStack(spacing: 3) {
            ZStack {
                Circle()
                    .strokeBorder(
                        Color.secondary,
                        style: StrokeStyle(lineWidth: 2, dash: [4, 3])
                    )
                Text("✋").font(.system(size: 17))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Color(.systemBackground))
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Color.secondary, in: Capsule())
                        .offset(x: 18, y: -16)
                }
            }
            .frame(width: 46, height: 46)
            Text("Anyone").font(.caption2).lineLimit(1)
        }
        .opacity(isOn ? 1 : 0.35)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { filter.solo([ChoresPageLogic.poolID]) }
        .onTapGesture { filter.toggle(ChoresPageLogic.poolID, all: allIDs) }
        .onLongPressGesture { filter.solo([ChoresPageLogic.poolID]) }
        .accessibilityLabel("Anyone, \(count) chores waiting")
    }

    // MARK: - Content

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
                Label("Couldn't load the chores", systemImage: "wifi.slash")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
            }
            Spacer()
        case .loaded(let loaded):
            board(loaded)
        }
    }

    private func board(_ loaded: PageData) -> some View {
        let sections = ChoresPageLogic.sections(
            tab: tab,
            actionable: loaded.actionable,
            window: loaded.window,
            today: clock.today,
            effective: effective,
            minute: clock.minute
        )
        return List {
            if sections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(.secondary)
                    Text(ChoresPageLogic.emptyLine(for: tab))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
                .listRowSeparator(.hidden)
                addRow(date: nil)
            }
            ForEach(sections) { section in
                Section {
                    ForEach(section.rows) { row in choreRow(row) }
                    if section.showsAddRow { addRow(date: section.newChoreDate) }
                } header: {
                    header(section)
                }
            }
            // No footer explainer (owner 2026-08-07) — the dashed circle
            // speaks for itself.
        }
        .listStyle(.plain)
        .contentMargins(.top, 0, for: .scrollContent)
        .fontDesign(.rounded)
        .refreshable { await load() }
    }

    private func header(_ section: ChoresPageLogic.Section) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(section.kind == .catchUp ? Color.red : Color.secondary)
            if section.allDone {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Row (the day-page anatomy, verbatim)

    private func choreRow(_ row: ChoresPageLogic.Row) -> some View {
        HStack(spacing: 10) {
            CheckCircle(
                completed: row.completed,
                late: row.late,
                locked: false,
                inFlight: inFlight.contains(row.id),
                pool: row.isPool
            ) {
                tapCircle(row)
            }
            DetailRow(route: .chore(row.lead), open: open) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let emoji = row.emoji { Text(emoji) }
                            Text(row.title)
                                .strikethrough(row.completed, color: .secondary)
                                .foregroundStyle(row.completed ? Color.secondary : Color.primary)
                        }
                        if let sub = ChoresPageLogic.subtitle(row, today: clock.today, names: memberNames, use24: DisplayPrefs.uses24Hour(timeFormat)) {
                            Text(sub)
                                .font(.caption)
                                .foregroundStyle(row.late ? Color.red : Color.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            whoBadge(owners: row.owners)
            if row.starValue > 0 {
                Text("★ \(row.starValue)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(row.completed ? Color.secondary : Color.orange)
            }
        }
        // Done = the whole row goes gray — circle, avatar, star, wash
        // (owner 2026-08-08).
        .grayscale(row.completed ? 1 : 0)
        .opacity(row.completed ? 0.6 : 1)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .listRowInsets(rowInsets)
        .listRowBackground(tintWash(owners: row.owners).grayscale(row.completed ? 1 : 0))
        .overlay(alignment: .trailing) {
            if floatingStar == row.id {
                StarFloat(text: "+\(row.starValue) ★")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !row.completed {
                Button("Dismiss") { confirmDismiss = row }
                    .tint(.orange)
            }
        }
    }

    /// The Today page's furniture: facepile for owned rows, nothing for the pool
    /// — its dashed circle already says "anyone's".
    @ViewBuilder
    private func whoBadge(owners: [String]) -> some View {
        if !owners.isEmpty {
            HStack(spacing: -7) {
                ForEach(owners.prefix(3), id: \.self) { id in
                    if let member = memberLookup[id] {
                        MemberAvatarView(
                            name: member.name,
                            colorHex: member.color,
                            avatar: nil,
                            size: 22
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tintWash(owners: [String]) -> some View {
        if tintOn, !owners.isEmpty {
            let colors = owners.compactMap { memberLookup[$0]?.color }.compactMap { Color(hex: $0) }
            if let style = bandedTint(colors, opacity: washOpacity(colorScheme)) {
                Rectangle().fill(style)
            }
        }
    }

    private func addRow(date: String?) -> some View {
        Button { newChore = NewChore(date: date) } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("New chore")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 40)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.tertiary)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(rowInsets)
        .listRowSeparator(.hidden)
    }

    /// History lives at the foot of the workspace, not in the bar: the top
    /// bar carries the title and the avatar and nothing else (nav rule 1,
    /// reaffirmed by the owner 2026-08-06). The mock's clock icon would have
    /// been the only page with a third bar item.
    // MARK: - Actions

    private enum Call: String { case complete, uncomplete, dismiss }

    private func tapCircle(_ row: ChoresPageLogic.Row) {
        if row.completed {
            if ChoresPageLogic.needsUndoConfirm(row, me: me) {
                confirmUndo = row
            } else {
                Task { await act(.uncomplete, on: row) }
            }
        } else {
            Task { await act(.complete, on: row) }
        }
    }

    /// One tap acts on the whole row: the server completes, uncompletes and
    /// dismisses every assignee of a shared chore in one transaction, so the
    /// lead occurrence is the only id we need to send.
    private func act(_ call: Call, on row: ChoresPageLogic.Row) async {
        inFlight.insert(row.id)
        defer { inFlight.remove(row.id) }
        // The mock's build note: earning is a success, undoing is a nudge.
        switch call {
        case .complete:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if row.starValue > 0 { flashStar(row) }
        case .uncomplete:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .dismiss:
            break
        }
        do {
            let id = row.lead.id
            switch call {
            case .complete:
                let output = try await context.client.api.completeChoreOccurrence(.init(path: .init(id: id)))
                if case .conflict(let conflict) = output {
                    actionError = TimeLogic.conflictMessage(code: try? conflict.body.json.error)
                }
            case .uncomplete:
                let output = try await context.client.api.uncompleteChoreOccurrence(.init(path: .init(id: id)))
                if case .conflict(let conflict) = output {
                    actionError = TimeLogic.conflictMessage(code: try? conflict.body.json.error)
                }
            case .dismiss:
                let output = try await context.client.api.dismissChoreOccurrence(.init(path: .init(id: id)))
                if case .conflict(let conflict) = output {
                    actionError = TimeLogic.conflictMessage(code: try? conflict.body.json.error)
                }
            }
            await load()
        } catch {
            guard !isTaskCancellation(error) else { return }
            actionError = "Check the connection and try again."
        }
    }

    private func flashStar(_ row: ChoresPageLogic.Row) {
        floatingStar = row.id
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            if floatingStar == row.id { floatingStar = nil }
        }
    }

    // MARK: - Data

    private var memberLookup: [String: Components.Schemas.Member] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
    }

    private var memberNames: [String: String] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.name) })
    }

    private func load() async {
        if data.value == nil { data = .loading }
        let week = ChoresPageLogic.weekRange(today: clock.today)
        do {
            async let actionableCall = context.client.api.listChoreOccurrences(.init())
            async let windowCall = context.client.api.listChoreOccurrences(
                .init(query: .init(from: week.from, to: week.to))
            )
            async let boardCall = context.client.api.getRoutineBoard(.init())
            async let membersCall = context.client.api.listMembers(.init())

            var loaded = PageData(actionable: [], window: [], board: [], members: [])
            switch try await actionableCall {
            case .ok(let ok): loaded.actionable = try ok.body.json.occurrences
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await windowCall {
            case .ok(let ok): loaded.window = try ok.body.json.occurrences
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await boardCall {
            case .ok(let ok): loaded.board = try ok.body.json.entries
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            switch try await membersCall {
            case .ok(let ok): loaded.members = try ok.body.json.members
            case .unauthorized: appState.handleUnauthorized(); return
            default: fail(); return
            }
            data = .loaded(loaded)
            await fillLater()
        } catch {
            guard !isTaskCancellation(error) else { return }
            fail()
        }
    }

    /// The quarter sweep behind Later. It runs AFTER the page has painted:
    /// it is by far the biggest response, and nothing on screen waits for
    /// it. A failure here leaves the week intact and Later simply thinner.
    private func fillLater() async {
        let range = ChoresPageLogic.laterRange(today: clock.today)
        do {
            let output = try await context.client.api.listChoreOccurrences(
                .init(query: .init(from: range.from, to: range.to))
            )
            guard case .ok(let ok) = output, case .loaded(var loaded) = data else { return }
            loaded.window += try ok.body.json.occurrences
            data = .loaded(loaded)
        } catch {
            return  // Later stays short; the week is what matters.
        }
    }

    private func fail() {
        if data.value == nil { data = .failed("Check the connection and try again.") }
    }
}

/// The one earned moment: the star value lifts off the row and fades.
struct StarFloat: View {
    let text: String
    @State private var lift = false

    var body: some View {
        Text(text)
            .font(.callout.weight(.heavy))
            .foregroundStyle(.orange)
            .offset(y: lift ? -38 : 0)
            .opacity(lift ? 0 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                withAnimation(.easeOut(duration: 1.3)) { lift = true }
            }
    }
}
