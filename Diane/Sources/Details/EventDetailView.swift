import DianeKit
import SwiftUI

// MARK: - Pure display logic (nonisolated, tested in DetailsLogicTests)

/// Formatting rules for the event detail sheet. Every date is framed by the
/// HOUSEHOLD timezone passed in — the device zone never decides anything.
enum EventDetailLogic {
    typealias Occurrence = Components.Schemas.EventOccurrence

    /// Synced = the calendar mirrors a CalDAV account; local rows have none.
    static func isSynced(_ calendar: Components.Schemas.Calendar) -> Bool {
        calendar.accountId != nil
    }

    /// R9: Edit/Delete never wait on the calendar list — an unknown calendar
    /// (still loading, or the fetch failed) is assumed editable and the
    /// server's 409 is the authority.
    static func offersContentActions(for calendar: Components.Schemas.Calendar?) -> Bool {
        calendar.map { !isSynced($0) } ?? true
    }

    /// R2: the picked ids in display order — EMPTY means whole family, and it
    /// must travel as `[]`. `EventMembersUpdate.memberIds` is `[String]?` with
    /// a synthesized Codable, so nil omits the required key → server 422.
    static func memberIdsPayload(selected: Set<String>, order: [String]) -> [String] {
        order.filter { selected.contains($0) }
    }

    /// "17:00–18:00 · Mon, Jul 27", "All day · Mon, Jul 27", an all-day range
    /// shown human-INCLUSIVE (the wire endDate is end-exclusive), or a
    /// cross-day timed range ("Mon, Jul 27 23:30 – Tue, Jul 28 09:00").
    static func whenLine(for occurrence: Occurrence, timeZone: TimeZone) -> String {
        if occurrence.allDay {
            return allDayLine(startDate: occurrence.startDate, endDate: occurrence.endDate)
        }
        guard let startsAt = occurrence.startsAt, let start = parseInstant(startsAt) else { return "" }
        let day = formatter("EEE, MMM d", timeZone)
        let time = formatter("HH:mm", timeZone)
        guard let endsAt = occurrence.endsAt, let end = parseInstant(endsAt) else {
            return "\(time.string(from: start)) · \(day.string(from: start))"
        }
        let ymd = formatter("yyyy-MM-dd", timeZone)
        if ymd.string(from: start) == ymd.string(from: end) {
            return "\(time.string(from: start))–\(time.string(from: end)) · \(day.string(from: start))"
        }
        return "\(day.string(from: start)) \(time.string(from: start)) – \(day.string(from: end)) \(time.string(from: end))"
    }

    /// Humanized recurrence: "Repeats every 2 weeks on Mo, We · until Aug 30".
    static func recurrenceLine(_ recurrence: Occurrence.RecurrencePayload?) -> String? {
        guard let recurrence else { return nil }
        let interval = recurrence.interval ?? 1
        var line: String
        switch recurrence.freq {
        case .daily:
            line = interval == 1 ? "Repeats daily" : "Repeats every \(interval) days"
        case .weekly:
            line = interval == 1 ? "Repeats weekly" : "Repeats every \(interval) weeks"
            if let days = weekdayList(recurrence.byWeekday) { line += " on \(days)" }
        case .monthly:
            line = interval == 1 ? "Repeats monthly" : "Repeats every \(interval) months"
            if let day = recurrence.byMonthDay { line += " on day \(day)" }
        case .yearly:
            line = interval == 1 ? "Repeats yearly" : "Repeats every \(interval) years"
        }
        if let until = recurrence.until { line += " · until \(mediumDate(until))" }
        return line
    }

    /// "2026-08-30" → "Aug 30" (raw string when malformed, never a crash).
    static func mediumDate(_ ymd: String) -> String {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return ymd }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(months[parts[1] - 1]) \(parts[2])"
    }

    // MARK: Internals

    /// Week-ordered "Mo, We" list; nil when the set is absent or empty.
    private static func weekdayList(_ days: Occurrence.RecurrencePayload.ByWeekdayPayload?) -> String? {
        guard let days, !days.isEmpty else { return nil }
        let order: [Occurrence.RecurrencePayload.ByWeekdayPayloadPayload] = [.mo, .tu, .we, .th, .fr, .sa, .su]
        return days
            .sorted { (order.firstIndex(of: $0) ?? 0) < (order.firstIndex(of: $1) ?? 0) }
            .map { $0.rawValue.capitalized }
            .joined(separator: ", ")
    }

    private static func allDayLine(startDate: String?, endDate: String?) -> String {
        guard let startDate, let start = ymdDate(startDate) else { return "" }
        let day = formatter("EEE, MMM d", .gmt)
        var last = start
        // Wire range is [startDate, endDate) — subtract a day for human display.
        if let endDate, let end = ymdDate(endDate),
           let inclusive = utcCalendar.date(byAdding: .day, value: -1, to: end),
           inclusive > start {
            last = inclusive
        }
        if last == start { return "All day · \(day.string(from: start))" }
        return "All day · \(day.string(from: start)) – \(day.string(from: last))"
    }

    // All-day dates are zone-free day labels; UTC keeps parse + format aligned.
    private static var utcCalendar: Foundation.Calendar {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private static func ymdDate(_ ymd: String) -> Date? {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func parseInstant(_ instant: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: instant) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: instant)
    }

    private static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - Sheet

/// Density contract: rows run edge-to-edge with a 16pt gutter.
private let eventDetailRowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)

/// Tap-an-event detail sheet. Local events offer Edit + Delete; synced
/// (CalDAV) events offer ONLY the member assignment (Diane-local metadata the
/// server accepts for both kinds) — the server 409s content edits/deletes.
struct EventDetailView: View {
    let context: SignedInContext
    let occurrence: Components.Schemas.EventOccurrence
    let members: [Components.Schemas.Member]
    let onChanged: () -> Void
    /// Pushed as a page (nav rule 2: drill-downs push) — no own stack, no
    /// Done button; the sheet presentation keeps both.
    var asPage = false

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock

    @State private var calendars: Loadable<[Components.Schemas.Calendar]> = .loading
    @State private var selectedMemberIds: Set<String>
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var busy = false
    @State private var errorMessage: String?
    /// Notifications v1: the lead override, editable on ANY event — synced
    /// included (Diane-side metadata, the /reminder sub-route).
    @State private var reminderLead: Int?
    @State private var reminderSeeded = false

    init(
        context: SignedInContext,
        occurrence: Components.Schemas.EventOccurrence,
        members: [Components.Schemas.Member],
        onChanged: @escaping () -> Void,
        asPage: Bool = false
    ) {
        self.context = context
        self.occurrence = occurrence
        self.members = members
        self.asPage = asPage
        self.onChanged = onChanged
        _selectedMemberIds = State(initialValue: Set(occurrence.memberIds ?? []))
    }

    private var calendar: Components.Schemas.Calendar? {
        calendars.value?.first { $0.id == occurrence.calendarId }
    }

    private var sortedMembers: [Components.Schemas.Member] {
        members.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    var body: some View {
        Group {
            if asPage { detailList } else { NavigationStack { detailList } }
        }
    }

    /// Picking IS the save — the sub-route write works for synced events too.
    private var reminderSection: some View {
        Section {
            Picker("Reminder", selection: $reminderLead) {
                Text("Default").tag(Int?.none)
                Text("At start").tag(Int?.some(0))
                ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                    Text("\(minutes) min before").tag(Int?.some(minutes))
                }
            }
            .listRowInsets(eventDetailRowInsets)
            .onChange(of: reminderLead) { previous, next in
                guard reminderSeeded, previous != next else { return }
                Task { await saveReminder(next) }
            }
        }
    }

    private func saveReminder(_ minutes: Int?) async {
        do {
            let output = try await context.client.api.updateEventReminder(.init(
                path: .init(id: occurrence.eventId),
                body: .json(.init(reminderLeadMinutes: minutes))
            ))
            switch output {
            case .ok: onChanged()
            case .unauthorized: appState.handleUnauthorized()
            default: errorMessage = "That didn't save. Try again?"
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }

    private var detailList: some View {
            List {
                headerSection
                if let location = occurrence.location, !location.isEmpty {
                    Section {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .listRowInsets(eventDetailRowInsets)
                    }
                }
                membersSection
                if !occurrence.allDay { reminderSection }
                actionsSection
            }
            .listStyle(.plain)
            .navigationTitle("Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !asPage {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
            }
            .task { await loadCalendars() }
            .onAppear {
                guard !reminderSeeded else { return }
                reminderSeeded = true
                reminderLead = occurrence.reminderLeadMinutes
            }
            .alert(errorMessage ?? "Something went wrong.", isPresented: errorShown) {
                Button("OK", role: .cancel) {}
            }
            .alert(
                "Delete this event?",
                isPresented: $confirmingDelete
            ) {
                Button("Yes, delete", role: .destructive) {
                    Task { await deleteEvent() }
                }
                Button("Keep it", role: .cancel) {}
            }
            .sheet(isPresented: $editing) {
                EventFormView(context: context, members: members, mode: .edit(occurrence)) {
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
                Text(occurrence.summary)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                Text(EventDetailLogic.whenLine(for: occurrence, timeZone: clock.timeZone))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let line = EventDetailLogic.recurrenceLine(occurrence.recurrence) {
                    Label(line, systemImage: "repeat")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                calendarChip
            }
            .padding(.vertical, 4)
            .listRowInsets(eventDetailRowInsets)
        }
    }

    @ViewBuilder
    private var calendarChip: some View {
        switch calendars {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed:
            Button("Couldn't load the calendar — try again") {
                calendars = .loading
                Task { await loadCalendars() }
            }
            .font(.caption)
        case .loaded:
            if let calendar {
                HStack(spacing: 6) {
                    Circle()
                        .fill(chipColor(calendar))
                        .frame(width: 10, height: 10)
                    Text(calendar.displayName)
                        .font(.caption.weight(.medium))
                    Text(EventDetailLogic.isSynced(calendar) ? "Synced" : "Local")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chipColor(_ calendar: Components.Schemas.Calendar) -> Color {
        let hex = calendar.color ?? calendar.providerColor ?? occurrence.color
        return hex.map { Color(hex: $0) } ?? .gray
    }

    /// Synced events edit members inline (the ONE thing the server allows);
    /// local events just show who's tagged — the Edit form owns changes.
    @ViewBuilder
    private var membersSection: some View {
        if let calendar, EventDetailLogic.isSynced(calendar) {
            Section {
                ForEach(sortedMembers, id: \.id) { member in
                    memberToggleRow(member)
                }
                if selectedMemberIds.isEmpty {
                    Label("No one picked — shows for the whole family.", systemImage: "house")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowInsets(eventDetailRowInsets)
                }
                Button {
                    Task { await saveMembers() }
                } label: {
                    if busy {
                        ProgressView()
                    } else {
                        Text("Save")
                            .fontWeight(.semibold)
                    }
                }
                .disabled(busy || selectedMemberIds == Set(occurrence.memberIds ?? []))
                .listRowInsets(eventDetailRowInsets)
            } header: {
                sectionHeader("Who's this for?")
            }
        } else {
            Section {
                assignedRow
            } header: {
                sectionHeader("Who")
            }
        }
    }

    private func memberToggleRow(_ member: Components.Schemas.Member) -> some View {
        Button {
            if selectedMemberIds.contains(member.id) {
                selectedMemberIds.remove(member.id)
            } else {
                selectedMemberIds.insert(member.id)
            }
        } label: {
            HStack(spacing: 10) {
                MemberAvatarView(name: member.name, colorHex: member.color, avatar: member.avatar, size: 32)
                Text(member.name)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: selectedMemberIds.contains(member.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectedMemberIds.contains(member.id) ? Color.accentColor : Color.secondary)
            }
            .frame(minHeight: 44)  // HIG tap target
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .listRowInsets(eventDetailRowInsets)
    }

    @ViewBuilder
    private var assignedRow: some View {
        let assigned = sortedMembers.filter { (occurrence.memberIds ?? []).contains($0.id) }
        if assigned.isEmpty {
            Label("Whole family", systemImage: "house.fill")
                .foregroundStyle(.secondary)
                .listRowInsets(eventDetailRowInsets)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(assigned, id: \.id) { member in
                        VStack(spacing: 4) {
                            MemberAvatarView(name: member.name, colorHex: member.color, avatar: member.avatar, size: 44)
                            Text(member.name)
                                .font(.caption)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowInsets(eventDetailRowInsets)
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        // R9: shown from the first frame — a slow or failed calendar fetch used
        // to hide these forever. A synced write comes back 409 and says so.
        if EventDetailLogic.offersContentActions(for: calendar) {
            Section {
                Button("Edit") { editing = true }
                    .disabled(busy)
                    .listRowInsets(eventDetailRowInsets)
                Button("Delete", role: .destructive) { confirmingDelete = true }
                    .disabled(busy)
                    .listRowInsets(eventDetailRowInsets)
            }
        } else {
            Section {
                // Server 409s content edits/deletes on CalDAV events.
                Text("Synced from your calendar app — edit everything else there.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowInsets(eventDetailRowInsets)
            }
        }
    }

    // MARK: Data + actions

    private var errorShown: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func loadCalendars() async {
        do {
            switch try await context.client.api.listCalendars(.init()) {
            case .ok(let ok):
                calendars = .loaded(try ok.body.json.calendars)
            case .unauthorized:
                appState.handleUnauthorized()
            default:
                if calendars.value == nil { calendars = .failed("The calendar list didn't load.") }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            if calendars.value == nil { calendars = .failed("Couldn't reach your home server.") }
        }
    }

    private func deleteEvent() async {
        busy = true
        defer { busy = false }
        do {
            switch try await context.client.api.deleteEvent(.init(path: .init(id: occurrence.eventId))) {
            case .noContent:
                onChanged()
                dismiss()
            case .unauthorized:
                appState.handleUnauthorized()
            case .conflict:
                errorMessage = "Synced events can only be removed in the calendar app they come from."
            case .notFound:
                // Already gone — treat as done.
                onChanged()
                dismiss()
            default:
                errorMessage = "That didn't work. Check the connection and try again."
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }

    private func saveMembers() async {
        busy = true
        defer { busy = false }
        // R2: empty selection = whole family, sent as [] (nil omits the key → 422).
        let body = Components.Schemas.EventMembersUpdate(
            memberIds: EventDetailLogic.memberIdsPayload(
                selected: selectedMemberIds,
                order: sortedMembers.map(\.id)
            )
        )
        do {
            switch try await context.client.api.updateEventMembers(
                .init(path: .init(id: occurrence.eventId), body: .json(body))
            ) {
            case .ok:
                onChanged()
                dismiss()
            case .unauthorized:
                appState.handleUnauthorized()
            case .notFound:
                errorMessage = "This event is gone — it may have been removed."
                onChanged()
            case .unprocessableContent:
                errorMessage = "That family member no longer exists."
                onChanged()
            default:
                errorMessage = "That didn't work. Check the connection and try again."
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }
}
