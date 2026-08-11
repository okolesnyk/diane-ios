import DianeKit
import SwiftUI

// MARK: - Pure display logic (nonisolated, tested in DetailsLogicTests)

/// Status and schedule lines for the chore detail sheet. The household `today`
/// and timezone are injected — the device clock never decides anything.
enum ChoreDetailLogic {
    typealias Occurrence = Components.Schemas.ChoreOccurrence

    enum Status: Equatable {
        case open
        case late
        case done
    }

    /// R11: what a refreshed board means for the sheet showing one of its rows.
    enum Resync: Equatable {
        case replace(Occurrence)
        case gone
    }

    /// Completed wins over the (stale-on-completion) late flag.
    static func status(of occurrence: Occurrence) -> Status {
        if occurrence.status == .completed { return .done }
        return occurrence.late ? .late : .open
    }

    /// R11: take the row the server has now (the synthetic id is the handle);
    /// no match means it left the board and the sheet has nothing left to show.
    static func resync(id: String, from occurrences: [Occurrence]) -> Resync {
        occurrences.first { $0.id == id }.map { .replace($0) } ?? .gone
    }

    /// "Done ✓ by Ann · 17:42" — completion instant shown in the household tz.
    static func doneLine(byName name: String?, completedAt: String?, timeZone: TimeZone) -> String {
        var line = "Done ✓"
        if let name { line += " by \(name)" }
        if let completedAt, let instant = parseInstant(completedAt) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "HH:mm"
            line += " · \(formatter.string(from: instant))"
        }
        return line
    }

    /// "Jun 18, 2026" — the details sheet always carries the year (owner
    /// 2026-08-10): a detail surface is where ambiguity goes to die.
    static func fullDate(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return ymd }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[parts[1] - 1]) \(parts[2]), \(parts[0])"
    }

    /// "Due today at 18:00" / "Due Aug 15" / "By Aug 15" / "Anytime" from the
    /// occurrence's dueDate + dueMode + dueTime against household today.
    static func scheduleLine(
        dueDate: String?,
        dueMode: Occurrence.DueModePayload?,
        dueTime: String?,
        today: String
    ) -> String {
        guard let dueDate else { return "Anytime" }
        var line: String
        if dueMode == .by {
            line = "By \(fullDate(dueDate))"  // deadline, not a day plan
        } else if dueDate == today {
            line = "Due today"
        } else {
            line = "Due \(fullDate(dueDate))"
        }
        if let dueTime { line += " at \(dueTime)" }
        return line
    }

    private static func parseInstant(_ instant: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: instant) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: instant)
    }
}

// MARK: - Sheet

/// Density contract: rows run edge-to-edge with a 16pt gutter.
private let choreDetailRowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

/// Tap-a-chore detail sheet: READ + navigate, never act. Completing, claiming,
/// putting back and dismissing all live on the list rows (circle + swipe); the
/// sheet offers the full story, admin Edit, and Done.
struct ChoreDetailView: View {
    let context: SignedInContext
    let members: [Components.Schemas.Member]
    let onChanged: () -> Void
    /// Pushed as a page (nav rule 2: drill-downs push) — no own stack, no
    /// Done button; the sheet presentation keeps both.
    var asPage = false

    @State private var occurrence: Components.Schemas.ChoreOccurrence

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock

    @State private var alertMessage: String?
    @State private var editing = false
    @State private var closeOnAlertDismiss = false  // R11
    /// The chore DEFINITION — the occurrence names one assignee, but a
    /// shared chore has several and the detail must show them all (owner
    /// 2026-08-08). listChores is any-session on the server.
    @State private var definition: Components.Schemas.Chore?

    init(
        context: SignedInContext,
        occurrence: Components.Schemas.ChoreOccurrence,
        members: [Components.Schemas.Member],
        onChanged: @escaping () -> Void,
        asPage: Bool = false
    ) {
        self.context = context
        self.members = members
        self.onChanged = onChanged
        self.asPage = asPage
        _occurrence = State(initialValue: occurrence)
    }

    private var membersByID: [String: Components.Schemas.Member] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
    }

    var body: some View {
        Group {
            if asPage { detailList } else { NavigationStack { detailList } }
        }
    }

    private var detailList: some View {
            List {
                headerSection
                if let notes = occurrence.notes, !notes.isEmpty {
                    Section {
                        Text(notes)
                            .listRowInsets(choreDetailRowInsets)
                    } header: {
                        sectionHeader("Notes")
                    }
                }
                Section {
                    Label(
                        ChoreDetailLogic.scheduleLine(
                            dueDate: occurrence.dueDate,
                            dueMode: occurrence.dueMode,
                            dueTime: occurrence.dueTime,
                            today: clock.today
                        ),
                        systemImage: "calendar"
                    )
                    .listRowInsets(choreDetailRowInsets)
                }
                peopleSection
            }
            .listStyle(.plain)
            .navigationTitle("Chore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !asPage {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                if context.session.isAdmin {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Edit") { editing = true }
                    }
                }
            }
            .task { await refresh() }
            .alert(alertMessage ?? "Something went wrong.", isPresented: alertShown) {
                // R11: the row is gone from the board — close once acknowledged.
                Button("OK", role: .cancel) {
                    if closeOnAlertDismiss { dismiss() }
                }
            }
            .sheet(isPresented: $editing) {
                ChoreFormView(context: context, members: members, mode: .edit(choreId: occurrence.choreId)) {
                    // The occurrence on screen is now stale — hand back to the list.
                    onChanged()
                    dismiss()
                }
            }
    }

    // MARK: Sections

    /// Small uppercase header, flush with the same 16pt gutter as the rows.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 12) {
                    if let emoji = occurrence.emoji, !emoji.isEmpty {
                        Text(emoji).font(.system(size: 48))
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(occurrence.title)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text("★ \(occurrence.starValue)")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
                statusLine
            }
            .padding(.vertical, 4)
            .listRowInsets(choreDetailRowInsets)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch ChoreDetailLogic.status(of: occurrence) {
        case .open:
            Text("Open")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        case .late:
            Text("Late")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
        case .done:
            Text(ChoreDetailLogic.doneLine(
                byName: occurrence.completedByMemberId.flatMap { membersByID[$0]?.name },
                completedAt: occurrence.completedAt,
                timeZone: clock.timeZone
            ))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.green)
            .monospacedDigit()
        }
    }

    /// Every assignee: the definition's full list when we have it, else the
    /// one this occurrence names.
    private var assignees: [Components.Schemas.Member] {
        let ids = definition.map(\.assigneeIds)
            ?? occurrence.assigneeMemberId.map { [$0] } ?? []
        return ids.compactMap { membersByID[$0] }
    }

    private var peopleSection: some View {
        Section {
            if !assignees.isEmpty {
                ForEach(assignees, id: \.id) { member in
                    personRow("Assigned to", member)
                }
            } else if occurrence.claimedByMemberId == nil {
                Label("Up for grabs", systemImage: "hand.raised")
                    .foregroundStyle(.secondary)
                    .listRowInsets(choreDetailRowInsets)
            }
            if let claimer = occurrence.claimedByMemberId.flatMap({ membersByID[$0] }) {
                personRow("Claimed by", claimer)
            }
            if let completer = occurrence.completedByMemberId.flatMap({ membersByID[$0] }) {
                personRow("Done by", completer)
            }
        } header: {
            sectionHeader("People")
        }
    }

    private func personRow(_ label: String, _ member: Components.Schemas.Member) -> some View {
        HStack(spacing: 10) {
            MemberAvatarView(name: member.name, colorHex: member.color, avatar: member.avatar, size: 32)
            Text(member.name)
            Spacer()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .listRowInsets(choreDetailRowInsets)
    }

    // MARK: Data

    private var alertShown: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    /// R11: the sheet can't act any more, so it refreshes instead — adopt the
    /// row the server has now, or say so when it left the board and close.
    private func refresh() async {
        // The definition fills in the FULL assignee list; a failure just
        // leaves the occurrence's single name standing.
        if case .ok(let ok)? = try? await context.client.api.listChores(.init()),
           let chores = try? ok.body.json.chores {
            definition = chores.first { $0.id == occurrence.choreId }
        }
        do {
            switch try await context.client.api.listChoreOccurrences(.init()) {
            case .ok(let ok):
                switch ChoreDetailLogic.resync(id: occurrence.id, from: try ok.body.json.occurrences) {
                case .replace(let fresh):
                    occurrence = fresh
                case .gone:
                    alertMessage = "That chore isn't on the board any more."
                    closeOnAlertDismiss = true
                    onChanged()  // the list behind us is stale too
                }
            case .unauthorized:
                appState.handleUnauthorized()
            default:
                break  // keep the row we were handed — never blank a loaded sheet
            }
        } catch {
            // Offline: the snapshot we opened with is still the best we have.
            guard !isTaskCancellation(error) else { return }
        }
    }
}
