import DianeKit
import SwiftUI

// MARK: - Shared form plumbing (nonisolated, tested in FormsLogicTests)

/// Wall-clock <-> wire conversions for the create/edit forms. Every function
/// takes an explicit zone — the HOUSEHOLD zone in the app — so the device
/// zone never decides anything (M9 rule).
enum FormDates {
    static func calendar(_ timeZone: TimeZone) -> Foundation.Calendar {
        var calendar = Foundation.Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// "YYYY-MM-DD" of an instant, in the given zone.
    static func ymd(_ date: Date, timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "HH:mm" of an instant, in the given zone.
    static func hm(_ date: Date, timeZone: TimeZone) -> String {
        let c = calendar(timeZone).dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// The instant at local wall clock `ymd` + `hm` in the given zone.
    static func instant(ymd: String, hm: String = "12:00", timeZone: TimeZone) -> Date? {
        let d = ymd.split(separator: "-").compactMap { Int($0) }
        let t = hm.split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count == 2 else { return nil }
        let components = DateComponents(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1])
        return calendar(timeZone).date(from: components)
    }

    /// Local-date +/- N days — pure date-domain math, no zone involved.
    static func addDays(_ ymd: String, _ days: Int) -> String {
        guard let noon = instant(ymd: ymd, hm: "12:00", timeZone: .gmt),
              let moved = calendar(.gmt).date(byAdding: .day, value: days, to: noon)
        else { return ymd }
        return Self.ymd(moved, timeZone: .gmt)
    }

    /// R1 Whole days from `from` to `to` (negative when `to` is earlier) —
    /// the date-domain length an anchor-seeded edit has to preserve.
    static func daysBetween(_ from: String, _ to: String) -> Int {
        guard let a = instant(ymd: from, hm: "12:00", timeZone: .gmt),
              let b = instant(ymd: to, hm: "12:00", timeZone: .gmt)
        else { return 0 }
        return calendar(.gmt).dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// A local date as the family reads it, for the forms' explanatory notes.
    static func mediumDateText(_ ymd: String, timeZone: TimeZone) -> String {
        guard let date = instant(ymd: ymd, hm: "12:00", timeZone: timeZone) else { return ymd }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    /// ISO-8601 UTC instant (with or without fractional seconds) -> Date.
    static func parseInstant(_ instant: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: instant) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: instant)
    }

    /// Binds a "YYYY-MM-DD" state string to a date picker, in the given zone.
    static func dayBinding(_ text: Binding<String>, timeZone: TimeZone) -> Binding<Date> {
        Binding(
            get: { instant(ymd: text.wrappedValue, timeZone: timeZone) ?? Date() },
            set: { text.wrappedValue = ymd($0, timeZone: timeZone) }
        )
    }

    /// Binds an "HH:mm" state string to an hour-and-minute picker.
    static func timeBinding(_ text: Binding<String>, timeZone: TimeZone) -> Binding<Date> {
        Binding(
            get: { instant(ymd: "2001-01-01", hm: text.wrappedValue, timeZone: timeZone) ?? Date() },
            set: { text.wrappedValue = hm($0, timeZone: timeZone) }
        )
    }
}

/// M9c The app-wide row density: full width on a 16pt gutter, no card inset.
/// The forms keep Form's section semantics but share the same gutter, so a
/// full-width control lines up with every list row elsewhere in the app.
enum FormDensity {
    static let rowInsets = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
}

/// R14 The spec's maxLength caps, enforced AS YOU TYPE so the common
/// over-long field never reaches the server's zod at all.
enum FormLimits {
    static let eventSummary = 200
    static let eventLocation = 200
    static let title = 120
    static let notes = 1000
    static let emoji = 16

    /// R14 Truncates to `max` UTF-16 units — zod's maxLength counts JS string
    /// length, so an emoji costs two — never splitting a grapheme.
    static func capped(_ text: String, _ max: Int) -> String {
        guard text.utf16.count > max else { return text }
        var result = ""
        for character in text {
            if result.utf16.count + character.utf16.count > max { break }
            result.append(character)
        }
        return result
    }

    /// A text binding that caps on every write.
    static func capping(_ text: Binding<String>, _ max: Int) -> Binding<String> {
        Binding(get: { text.wrappedValue }, set: { text.wrappedValue = capped($0, max) })
    }
}

/// R14 Server 422s arrive as `validation_failed (path.to.field)` — raw zod
/// paths must never reach the family. Each form maps the field to its own copy.
enum FormErrors {
    /// nil = not a validation failure; "" = one with no field named; otherwise
    /// the FIRST path segment (`recurrence.byWeekday.0` -> "recurrence").
    static func validationField(_ code: String?) -> String? {
        guard let code, code.hasPrefix("validation_failed") else { return nil }
        guard let open = code.firstIndex(of: "("),
              let close = code.lastIndex(of: ")"),
              open < close
        else { return "" }
        let path = code[code.index(after: open)..<close]
        return path.split(separator: ".").first.map(String.init) ?? ""
    }
}

/// The wire's two-letter weekday codes, in canonical mo..su order.
enum FormWeekday: String, CaseIterable, Identifiable {
    case mo, tu, we, th, fr, sa, su

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mo: "Mon"
        case .tu: "Tue"
        case .we: "Wed"
        case .th: "Thu"
        case .fr: "Fri"
        case .sa: "Sat"
        case .su: "Sun"
        }
    }

    /// Canonical mo..su order regardless of tap order, so an edit round-trips
    /// byte-identical to what the server stored.
    static func sorted(_ set: Set<FormWeekday>) -> [FormWeekday] {
        allCases.filter(set.contains)
    }
}

// MARK: - Event form logic

enum EventFormLogic {
    enum Repeat: String, CaseIterable, Identifiable {
        case none, daily, weekly, monthly, yearly

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: "Does not repeat"
            case .daily: "Daily"
            case .weekly: "Weekly"
            case .monthly: "Monthly"
            case .yearly: "Yearly"
            }
        }

        /// "week"/"weeks" for the interval stepper line.
        func unit(_ interval: Int) -> String {
            let units: (String, String) = switch self {
            case .none: ("", "")
            case .daily: ("day", "days")
            case .weekly: ("week", "weeks")
            case .monthly: ("month", "months")
            case .yearly: ("year", "years")
            }
            return interval == 1 ? units.0 : units.1
        }
    }

    /// Everything the form edits. Timed bounds are INSTANTS (the pickers run
    /// in the household zone); all-day bounds are local dates, END-INCLUSIVE
    /// here ("Last day") and converted to the wire's exclusive endDate.
    struct State: Equatable {
        var summary = ""
        var location = ""
        var calendarId = ""
        var allDay = false
        var start = Date()
        var end = Date()
        /// All-day first day, "YYYY-MM-DD".
        var firstDay = ""
        var multiDay = false
        /// All-day INCLUSIVE last day (only meaningful when multiDay).
        var lastDay = ""
        /// Empty = the whole family (sent as nil).
        var memberIds: Set<String> = []
        var repeats: Repeat = .none
        var interval = 1
        var byWeekday: Set<FormWeekday> = []
        /// Monthly only; nil = the start date's day.
        var byMonthDay: Int?
        var hasUntil = false
        /// Inclusive local date, "YYYY-MM-DD".
        var until = ""
        /// Reminder lead override in minutes; nil = the household default
        /// (notifications v1). -1 is never stored — the picker maps it.
        var reminderLeadMinutes: Int?
    }

    static func initial(
        defaultDate: String,
        calendarId: String,
        timeZone: TimeZone,
        defaultTime: String? = nil,
        defaultEnd: String? = nil
    ) -> State {
        var state = State()
        state.calendarId = calendarId
        state.start = FormDates.instant(ymd: defaultDate, hm: defaultTime ?? "09:00", timeZone: timeZone) ?? Date()
        // A drawn end wins; otherwise an hour after the start.
        state.end = defaultEnd.flatMap { FormDates.instant(ymd: defaultDate, hm: $0, timeZone: timeZone) }
            ?? state.start.addingTimeInterval(3600)
        state.firstDay = defaultDate
        state.lastDay = defaultDate
        state.until = defaultDate
        return state
    }

    /// R1 The master DTSTART of a recurring occurrence. A PATCH replaces the
    /// WHOLE series, so seeding the When fields from the tapped occurrence
    /// re-anchors DTSTART forward and silently deletes every earlier one —
    /// live-reproduced: a 5-week series edited via occurrence 3 came back with 3.
    struct SeriesAnchor: Equatable {
        /// Timed series: the master start instant.
        var startsAt: Date?
        /// All-day series: the master local start date, "YYYY-MM-DD".
        var startDate: String?
    }

    /// R1 nil for one-off events and when the server reported no anchor (older
    /// server, unparseable ICS) — callers then keep the occurrence-seeded
    /// behavior rather than guessing.
    static func seriesAnchor(_ occurrence: Components.Schemas.EventOccurrence) -> SeriesAnchor? {
        guard occurrence.recurrence != nil else { return nil }
        if occurrence.allDay {
            guard let startDate = occurrence.seriesStartDate, !startDate.isEmpty else { return nil }
            return SeriesAnchor(startDate: startDate)
        }
        guard let startsAt = occurrence.seriesStartsAt.flatMap(FormDates.parseInstant) else { return nil }
        return SeriesAnchor(startsAt: startsAt)
    }

    /// R1 The local date the SERIES starts — what the When fields are seeded
    /// from in edit mode — for the form's explanatory note. nil = nothing to say.
    static func seriesStartLocalDate(
        _ occurrence: Components.Schemas.EventOccurrence,
        timeZone: TimeZone
    ) -> String? {
        guard let anchor = seriesAnchor(occurrence) else { return nil }
        if let startDate = anchor.startDate { return startDate }
        return anchor.startsAt.map { FormDates.ymd($0, timeZone: timeZone) }
    }

    /// Edit prefill from the tapped occurrence, incl. its recurrence and
    /// memberIds, so re-submitting round-trips the SAME series (web parity).
    /// R1 When the occurrence belongs to a series, the WHEN fields come from
    /// the series anchor instead — keeping this occurrence's duration.
    static func seed(from occurrence: Components.Schemas.EventOccurrence, timeZone: TimeZone) -> State {
        var state = State()
        state.summary = occurrence.summary
        state.location = occurrence.location ?? ""
        state.calendarId = occurrence.calendarId
        state.memberIds = Set(occurrence.memberIds ?? [])
        state.reminderLeadMinutes = occurrence.reminderLeadMinutes
        if let recurrence = occurrence.recurrence {
            state.repeats = Repeat(rawValue: recurrence.freq.rawValue) ?? .none
            state.interval = recurrence.interval ?? 1
            state.byWeekday = Set((recurrence.byWeekday ?? []).compactMap { FormWeekday(rawValue: $0.rawValue) })
            state.byMonthDay = recurrence.byMonthDay
            if let until = recurrence.until {
                state.hasUntil = true
                state.until = until
            }
        }
        let anchor = seriesAnchor(occurrence)
        if occurrence.allDay, let startDate = occurrence.startDate {
            state.allDay = true
            // Wire endDate is END-EXCLUSIVE; show the inclusive last day.
            let lastDay = occurrence.endDate.map { FormDates.addDays($0, -1) } ?? startDate
            // R1 The occurrence's length in days, kept across the re-anchor.
            let span = max(0, FormDates.daysBetween(startDate, lastDay))
            let firstDay = anchor?.startDate ?? startDate
            state.firstDay = firstDay
            state.lastDay = FormDates.addDays(firstDay, span)
            state.multiDay = span > 0
        } else if let startsAt = occurrence.startsAt, let occurrenceStart = FormDates.parseInstant(startsAt) {
            let occurrenceEnd = occurrence.endsAt.flatMap(FormDates.parseInstant)
                ?? occurrenceStart.addingTimeInterval(3600)
            // R1 The occurrence's duration, kept across the re-anchor.
            let duration = occurrenceEnd.timeIntervalSince(occurrenceStart)
            let start = anchor?.startsAt ?? occurrenceStart
            state.start = start
            state.end = start.addingTimeInterval(duration > 0 ? duration : 3600)
            state.firstDay = FormDates.ymd(start, timeZone: timeZone)
            state.lastDay = state.firstDay
        }
        // Sensible values for whichever fields the seeded mode left blank, so
        // toggling all-day mid-edit never shows a zeroed picker.
        if state.firstDay.isEmpty { state.firstDay = FormDates.ymd(Date(), timeZone: timeZone) }
        if state.lastDay.isEmpty { state.lastDay = state.firstDay }
        if occurrence.allDay {
            state.start = FormDates.instant(ymd: state.firstDay, hm: "09:00", timeZone: timeZone) ?? Date()
            state.end = FormDates.instant(ymd: state.firstDay, hm: "10:00", timeZone: timeZone) ?? Date()
        }
        if state.until.isEmpty { state.until = state.firstDay }
        return state
    }

    /// R4 Anything typed since the form was seeded — the discard guard.
    static func isDirty(_ state: State, original: State) -> Bool {
        state != original
    }

    /// The local "YYYY-MM-DD" the When section currently shows as the start.
    static func startLocalDate(_ state: State, timeZone: TimeZone) -> String {
        state.allDay ? state.firstDay : FormDates.ymd(state.start, timeZone: timeZone)
    }

    /// R5 The date a monthly series REALLY begins: step `interval` months from
    /// the start's month and take the first `day` that isn't before the start.
    /// Months without that day are skipped — verified against the server's
    /// expansion (byMonthDay 31 from Sep 5 first lands on Oct 31; byMonthDay 5
    /// every 2 months from Jul 27 first lands on Sep 5, not Aug 5).
    static func firstMonthlyDate(start: String, day: Int, interval: Int) -> String? {
        guard (1...31).contains(day), interval >= 1,
              let startNoon = FormDates.instant(ymd: start, hm: "12:00", timeZone: .gmt)
        else { return nil }
        let calendar = FormDates.calendar(.gmt)
        var month = calendar.dateComponents([.year, .month], from: startNoon)
        for _ in 0..<120 {
            let firstOfMonth = DateComponents(year: month.year, month: month.month, day: 1, hour: 12)
            guard let monthStart = calendar.date(from: firstOfMonth) else { return nil }
            let candidateParts = DateComponents(year: month.year, month: month.month, day: day, hour: 12)
            if calendar.range(of: .day, in: .month, for: monthStart)?.contains(day) == true,
               let candidate = calendar.date(from: candidateParts), candidate >= startNoon {
                return FormDates.ymd(candidate, timeZone: .gmt)
            }
            guard let stepped = calendar.date(byAdding: .month, value: interval, to: monthStart) else { return nil }
            month = calendar.dateComponents([.year, .month], from: stepped)
        }
        return nil
    }

    /// R5 nil when the start the form SHOWS is the series' first occurrence;
    /// otherwise the date it really begins. A monthly byMonthDay that differs
    /// from the start's day is legal (the server accepts it) but silently moves
    /// the first occurrence — say so rather than contradict the "Starts" line.
    static func monthlyStartMismatch(_ state: State, timeZone: TimeZone) -> String? {
        guard state.repeats == .monthly, let day = state.byMonthDay else { return nil }
        let start = startLocalDate(state, timeZone: timeZone)
        guard let first = firstMonthlyDate(start: start, day: day, interval: max(1, state.interval)),
              first != start
        else { return nil }
        return first
    }

    /// nil = submittable; otherwise the message to show.
    static func validate(_ state: State) -> String? {
        if state.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the event a title."
        }
        if state.calendarId.isEmpty { return "Pick a calendar." }
        if state.allDay {
            if state.multiDay, state.lastDay < state.firstDay {
                return "The last day can't be before the first day."
            }
            return nil
        }
        if state.end <= state.start { return "The end must be after the start." }
        return nil
    }

    /// The recurrence fields as plain values (nil = does not repeat) —
    /// mapped into the per-operation generated payload types below.
    struct RecurrenceParts: Equatable {
        var freq: String
        var interval: Int?
        var byWeekday: [String]?
        var byMonthDay: Int?
        var until: String?
    }

    static func recurrenceParts(_ state: State) -> RecurrenceParts? {
        guard state.repeats != .none else { return nil }
        var parts = RecurrenceParts(freq: state.repeats.rawValue)
        if state.interval > 1 { parts.interval = state.interval }
        if state.repeats == .weekly, !state.byWeekday.isEmpty {
            parts.byWeekday = FormWeekday.sorted(state.byWeekday).map(\.rawValue)
        }
        if state.repeats == .monthly, let day = state.byMonthDay {
            parts.byMonthDay = day
        }
        if state.hasUntil { parts.until = state.until }
        return parts
    }

    /// Empty selection = the whole family = nil on the wire.
    static func memberIdsWire(_ state: State) -> [String]? {
        state.memberIds.isEmpty ? nil : state.memberIds.sorted()
    }

    /// The wire's exclusive endDate: shown-inclusive last day + 1.
    static func exclusiveEndDate(_ state: State) -> String {
        FormDates.addDays(state.multiDay ? state.lastDay : state.firstDay, 1)
    }

    private static func createRecurrence(
        _ parts: RecurrenceParts?
    ) -> Components.Schemas.EventCreate.RecurrencePayload? {
        guard let parts else { return nil }
        typealias Payload = Components.Schemas.EventCreate.RecurrencePayload
        return Payload(
            freq: Payload.FreqPayload(rawValue: parts.freq) ?? .daily,
            interval: parts.interval,
            byWeekday: parts.byWeekday.map { days in
                days.compactMap { Payload.ByWeekdayPayloadPayload(rawValue: $0) }
            },
            byMonthDay: parts.byMonthDay,
            until: parts.until
        )
    }

    private static func updateRecurrence(
        _ parts: RecurrenceParts?
    ) -> Components.Schemas.EventUpdate.RecurrencePayload? {
        guard let parts else { return nil }
        typealias Payload = Components.Schemas.EventUpdate.RecurrencePayload
        return Payload(
            freq: Payload.FreqPayload(rawValue: parts.freq) ?? .daily,
            interval: parts.interval,
            byWeekday: parts.byWeekday.map { days in
                days.compactMap { Payload.ByWeekdayPayloadPayload(rawValue: $0) }
            },
            byMonthDay: parts.byMonthDay,
            until: parts.until
        )
    }

    static func createBody(_ state: State) -> Components.Schemas.EventCreate {
        var body = Components.Schemas.EventCreate(
            calendarId: state.calendarId,
            summary: state.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            location: trimmedOrNil(state.location),
            memberIds: memberIdsWire(state),
            allDay: state.allDay,
            recurrence: createRecurrence(recurrenceParts(state)),
            reminderLeadMinutes: state.reminderLeadMinutes
        )
        if state.allDay {
            body.startDate = state.firstDay
            body.endDate = exclusiveEndDate(state)
        } else {
            body.startsAt = state.start
            body.endsAt = state.end
        }
        return body
    }

    /// PATCH body: a full replacement, same fields minus calendarId
    /// (events can't switch calendars).
    static func updateBody(_ state: State) -> Components.Schemas.EventUpdate {
        var body = Components.Schemas.EventUpdate(
            summary: state.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            location: trimmedOrNil(state.location),
            memberIds: memberIdsWire(state),
            allDay: state.allDay,
            recurrence: updateRecurrence(recurrenceParts(state)),
            reminderLeadMinutes: state.reminderLeadMinutes
        )
        if state.allDay {
            body.startDate = state.firstDay
            body.endDate = exclusiveEndDate(state)
        } else {
            body.startsAt = state.start
            body.endsAt = state.end
        }
        return body
    }

    private static func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Create can target any WRITABLE calendar (local first, synced allowed —
    /// creates push to CalDAV by design).
    static func writableCalendars(_ calendars: [Components.Schemas.Calendar]) -> [Components.Schemas.Calendar] {
        calendars.filter(\.writable)
    }

    /// First LOCAL calendar (accountId nil), else the first writable one.
    static func defaultCalendarId(_ calendars: [Components.Schemas.Calendar]) -> String? {
        let writable = writableCalendars(calendars)
        return (writable.first { $0.accountId == nil } ?? writable.first)?.id
    }

    /// Picker label; synced and hidden calendars are visible choices.
    static func calendarLabel(_ calendar: Components.Schemas.Calendar) -> String {
        var label = calendar.displayName
        if calendar.accountId != nil { label += " (synced)" }
        if !calendar.enabled { label += " (hidden)" }
        return label
    }

    /// R10 POST /events answers 404 when the CALENDAR is gone — the same
    /// `not_found` code the update route uses for a missing event. An event
    /// can't be missing before it exists, so remap it on create.
    static func createErrorCode(_ code: String?) -> String? {
        code == "not_found" ? "unknown_calendar" : code
    }

    /// Server error code -> honest copy (web form.ts parity + CalDAV 409s).
    static func friendlyError(_ code: String?) -> String {
        // R14 Raw zod paths ("validation_failed (summary)") never reach the family.
        if let field = FormErrors.validationField(code) { return validationCopy(field) }
        switch code {
        case "invalid_times": return "The end must be after the start."
        case "invalid_recurrence": return "That repeat rule isn't valid."
        case "calendar_readonly":
            return "This calendar is managed by its provider and can't be edited here."
        case "caldav_readonly", "caldav_event":
            return "Managed in iCloud — title, time and repeats change in the source calendar."
        case "unknown_calendar": return "That calendar no longer exists — pick another one."
        case "unknown_member": return "One of the selected members no longer exists."
        case "network_not_allowed": return "This change is only allowed from the home network."
        case "not_found": return "This event no longer exists — it may have just been deleted."
        default: return "That didn't work. Check the connection and try again."
        }
    }

    /// R14 Per-field copy for a 422, generic when the field isn't one we show.
    static func validationCopy(_ field: String) -> String {
        switch field {
        case "summary": "The title needs to be 1 to \(FormLimits.eventSummary) characters."
        case "location": "The location needs to be 1 to \(FormLimits.eventLocation) characters."
        case "recurrence": "That repeat rule isn't valid."
        case "startsAt", "endsAt", "startDate", "endDate": "Those dates aren't valid."
        case "memberIds": "One of the selected members isn't valid."
        case "calendarId": "That calendar isn't valid."
        default: "Something about the event isn't valid. Check the fields and try again."
        }
    }
}

// MARK: - Shared form controls

/// Multi-select avatar chips — the "who" control of all three forms.
struct FormMemberChips: View {
    let members: [Components.Schemas.Member]
    @Binding var selected: Set<String>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(members.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }, id: \.id) { member in
                    chip(member)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ member: Components.Schemas.Member) -> some View {
        let isOn = selected.contains(member.id)
        return Button {
            if isOn { selected.remove(member.id) } else { selected.insert(member.id) }
        } label: {
            HStack(spacing: 6) {
                MemberAvatarView(name: member.name, colorHex: member.color, avatar: member.avatar, size: 28)
                Text(member.name)
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(isOn ? Color.white : .primary)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)  // HIG tap target
            .background(isOn ? Color.accentColor : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color.secondary.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(member.name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Seven weekday toggles in canonical order.
struct FormWeekdayChips: View {
    @Binding var selected: Set<FormWeekday>

    var body: some View {
        HStack(spacing: 4) {
            ForEach(FormWeekday.allCases) { day in
                let isOn = selected.contains(day)
                Button {
                    if isOn { selected.remove(day) } else { selected.insert(day) }
                } label: {
                    Text(day.label)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)  // HIG tap target
                        .background(
                            isOn ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(isOn ? Color.white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.label)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }
}

// MARK: - Screen

enum EventFormMode {
    /// Times are "HH:mm" or nil — the day-grid drag passes the drawn slot
    /// so the form opens with those times filled in (the mock's contract).
    case create(defaultDate: String, defaultTime: String?, defaultEnd: String?)
    case edit(Components.Schemas.EventOccurrence)

    /// The plain-date spelling every ghost row uses.
    static func create(defaultDate: String) -> EventFormMode {
        .create(defaultDate: defaultDate, defaultTime: nil, defaultEnd: nil)
    }
}

/// Create/edit sheet for events — EVERY member may use it (kiosk trust,
/// web parity). Synced events never reach the full edit (the detail sheet
/// gates it), but a raced 409 still gets honest copy.
struct EventFormView: View {
    let context: SignedInContext
    let members: [Components.Schemas.Member]
    let mode: EventFormMode
    let onSaved: () -> Void

    init(
        context: SignedInContext,
        members: [Components.Schemas.Member],
        mode: EventFormMode,
        onSaved: @escaping () -> Void
    ) {
        self.context = context
        self.members = members
        self.mode = mode
        self.onSaved = onSaved
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(HouseholdClock.self) private var clock

    @State private var state = EventFormLogic.State()
    /// R4 The seeded snapshot the dirty check compares against.
    @State private var original = EventFormLogic.State()
    /// Create only: the writable calendars to pick from.
    @State private var calendars: Loadable<[Components.Schemas.Calendar]> = .loading
    @State private var seeded = false
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var confirmingDiscard = false

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// R4 Typed edits would be lost by a swipe-down or a bare Cancel.
    private var isDirty: Bool {
        seeded && EventFormLogic.isDirty(state, original: original)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(isEdit ? "Edit event" : "New event")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { cancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if saving {
                            ProgressView()
                        } else {
                            Button("Save") { Task { await save() } }
                                .disabled(!canSave)
                        }
                    }
                }
                // R4 Confirm before throwing away what's been typed.
                // .alert, not confirmationDialog: iOS 26 anchors dialogs
                // to their source with a pointer bubble — the owner wants a
                // plain centered modal (2026-08-09).
                .alert("Discard changes?", isPresented: $confirmingDiscard) {
                    Button("Discard changes", role: .destructive) { dismiss() }
                    Button("Keep editing", role: .cancel) {}
                }
        }
        .interactiveDismissDisabled(saving || isDirty)  // R4
        .task { await prepare() }
    }

    /// R4 A dirty form asks first; a pristine one just closes.
    private func cancel() {
        if isDirty { confirmingDiscard = true } else { dismiss() }
    }

    @ViewBuilder
    private var content: some View {
        if !seeded {
            switch calendars {
            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't reach home", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { Task { await prepare() } }
                        .buttonStyle(.borderedProminent)
                }
            default:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                // R14 Capped as you type — the spec's maxLength, never a 422.
                TextField("Title", text: FormLimits.capping($state.summary, FormLimits.eventSummary))
                if !isEdit {
                    calendarPicker
                }
            }

            whenSection

            reminderSection

            Section {
                TextField("Location", text: FormLimits.capping($state.location, FormLimits.eventLocation))
            }

            Section {
                FormMemberChips(members: members, selected: $state.memberIds)
                    .listRowInsets(FormDensity.rowInsets)
            } header: {
                Text("Who")
            } footer: {
                if state.memberIds.isEmpty {
                    Text("No one picked — shows for everyone.")
                }
            }

            repeatSection

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .disabled(saving)
        // All pickers run on the household's wall clock, not the device's.
        .environment(\.timeZone, clock.timeZone)
    }

    @ViewBuilder
    private var calendarPicker: some View {
        if let loaded = calendars.value {
            if loaded.isEmpty {
                Text("There's no writable calendar yet. Create a family calendar in Settings first.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Calendar", selection: $state.calendarId) {
                    ForEach(loaded, id: \.id) { calendar in
                        Text(EventFormLogic.calendarLabel(calendar)).tag(calendar.id)
                    }
                }
            }
        }
    }

    /// R1 In edit mode the When fields show the SERIES start (the anchor), not
    /// the tapped day — the family needs to be told, because saving moves the
    /// whole series if they change it.
    private var seriesStartNote: String? {
        guard case .edit(let occurrence) = mode,
              let date = EventFormLogic.seriesStartLocalDate(occurrence, timeZone: clock.timeZone)
        else { return nil }
        return FormDates.mediumDateText(date, timeZone: clock.timeZone)
    }

    private var whenSection: some View {
        Section {
            Toggle("All day", isOn: $state.allDay)
            if state.allDay {
                DatePicker(
                    "First day",
                    selection: FormDates.dayBinding($state.firstDay, timeZone: clock.timeZone),
                    displayedComponents: .date
                )
                Toggle("More than one day", isOn: $state.multiDay)
                if state.multiDay {
                    DatePicker(
                        "Last day",
                        selection: FormDates.dayBinding($state.lastDay, timeZone: clock.timeZone),
                        displayedComponents: .date
                    )
                }
            } else {
                DatePicker("Starts", selection: $state.start, displayedComponents: [.date, .hourAndMinute])
                DatePicker("Ends", selection: $state.end, displayedComponents: [.date, .hourAndMinute])
            }
        } header: {
            Text("When")
        } footer: {
            if let seriesStartNote {
                Text("This repeats — editing changes the whole series, which starts \(seriesStartNote).")
            }
        }
    }

    /// Notifications v1: the per-event lead override. All-day events have no
    /// instant to ring at, so the row hides with them.
    @ViewBuilder
    private var reminderSection: some View {
        if !state.allDay {
            Section {
                Picker("Reminder", selection: $state.reminderLeadMinutes) {
                    Text("Default").tag(Int?.none)
                    Text("At start").tag(Int?.some(0))
                    ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text("\(minutes) min before").tag(Int?.some(minutes))
                    }
                }
            } footer: {
                Text("Default follows the household's reminder lead in Settings.")
            }
        }
    }

    private var repeatSection: some View {
        Section {
            Picker("Repeat", selection: $state.repeats) {
                ForEach(EventFormLogic.Repeat.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            if state.repeats != .none {
                Stepper(value: $state.interval, in: 1...99) {
                    Text("Every \(state.interval) \(state.repeats.unit(state.interval))")
                }
                if state.repeats == .weekly {
                    FormWeekdayChips(selected: $state.byWeekday)
                        .listRowInsets(FormDensity.rowInsets)
                }
                if state.repeats == .monthly {
                    Picker("Day of month", selection: $state.byMonthDay) {
                        Text("Same as start").tag(Int?.none)
                        ForEach(1...31, id: \.self) { day in
                            Text("\(day)").tag(Int?.some(day))
                        }
                    }
                }
                Toggle("Ends on a date", isOn: $state.hasUntil)
                if state.hasUntil {
                    DatePicker(
                        "Until",
                        selection: FormDates.dayBinding($state.until, timeZone: clock.timeZone),
                        displayedComponents: .date
                    )
                }
            }
        } header: {
            Text("Repeat")
        } footer: {
            // R5 A day of month away from the start moves the first occurrence.
            if let first = EventFormLogic.monthlyStartMismatch(state, timeZone: clock.timeZone) {
                Text(
                    "That day doesn't fall on the start above, so the first one is "
                        + FormDates.mediumDateText(first, timeZone: clock.timeZone)
                        + "."
                )
            }
        }
    }

    private var canSave: Bool {
        EventFormLogic.validate(state) == nil
    }

    // MARK: Data

    private func prepare() async {
        guard !seeded else { return }
        switch mode {
        case .edit(let occurrence):
            state = EventFormLogic.seed(from: occurrence, timeZone: clock.timeZone)
            original = state  // R4
            seeded = true
        case .create(let defaultDate, let defaultTime, let defaultEnd):
            calendars = .loading
            do {
                switch try await context.client.api.listCalendars(.init()) {
                case .ok(let ok):
                    let writable = EventFormLogic.writableCalendars(try ok.body.json.calendars)
                    calendars = .loaded(writable)
                    state = EventFormLogic.initial(
                        defaultDate: defaultDate,
                        calendarId: EventFormLogic.defaultCalendarId(writable) ?? "",
                        timeZone: clock.timeZone,
                        defaultTime: defaultTime,
                        defaultEnd: defaultEnd
                    )
                    original = state  // R4
                    seeded = true
                case .unauthorized:
                    appState.handleUnauthorized()
                default:
                    calendars = .failed("The calendars didn't load. Try again in a moment.")
                }
            } catch {
                guard !isTaskCancellation(error) else { return }
                calendars = .failed("Couldn't reach your home server.")
            }
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        errorMessage = nil
        do {
            switch mode {
            case .create:
                let body = EventFormLogic.createBody(state)
                switch try await context.client.api.createEvent(.init(body: .json(body))) {
                case .created:
                    onSaved()
                    dismiss()
                case .unauthorized:
                    appState.handleUnauthorized()
                case .conflict(let response):
                    errorMessage = EventFormLogic.friendlyError((try? response.body.json)?.error)
                case .unprocessableContent(let response):
                    errorMessage = EventFormLogic.friendlyError((try? response.body.json)?.error)
                case .notFound(let response):
                    // R10 On create a 404 is the CALENDAR, never the event.
                    errorMessage = EventFormLogic.friendlyError(
                        EventFormLogic.createErrorCode((try? response.body.json)?.error)
                    )
                default:
                    errorMessage = "That didn't work. Check the connection and try again."
                }
            case .edit(let occurrence):
                let body = EventFormLogic.updateBody(state)
                switch try await context.client.api.updateEvent(
                    .init(path: .init(id: occurrence.eventId), body: .json(body))
                ) {
                case .ok:
                    onSaved()
                    dismiss()
                case .unauthorized:
                    appState.handleUnauthorized()
                case .conflict(let response):
                    errorMessage = EventFormLogic.friendlyError((try? response.body.json)?.error)
                case .unprocessableContent(let response):
                    errorMessage = EventFormLogic.friendlyError((try? response.body.json)?.error)
                case .notFound(let response):
                    errorMessage = EventFormLogic.friendlyError((try? response.body.json)?.error)
                default:
                    errorMessage = "That didn't work. Check the connection and try again."
                }
            }
        } catch {
            guard !isTaskCancellation(error) else { return }
            errorMessage = "Couldn't reach your home server."
        }
    }
}
