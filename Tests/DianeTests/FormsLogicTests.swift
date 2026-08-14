import DianeKit
import Foundation
import Testing

@testable import Diane

// NON-device zones on purpose: Kolkata (+05:30, no DST) pins instant math,
// Auckland (+12/+13) pins cross-day behavior.
private let kolkata = TimeZone(identifier: "Asia/Kolkata")!
private let auckland = TimeZone(identifier: "Pacific/Auckland")!

/// Encoded JSON as a dictionary, so explicit nulls are observable (NSNull).
private func json(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Pure form logic behind the three create/edit sheets.
@Suite struct FormsLogicTests {

    // MARK: - FormDates

    @Suite struct Dates {
        @Test func instantComposesInGivenZoneNotDeviceZone() throws {
            // 09:00 in Kolkata (+05:30) is the same instant as 03:30 UTC.
            let inKolkata = try #require(FormDates.instant(ymd: "2026-07-27", hm: "09:00", timeZone: kolkata))
            let inUTC = try #require(FormDates.instant(ymd: "2026-07-27", hm: "03:30", timeZone: .gmt))
            #expect(inKolkata == inUTC)
        }

        @Test func instantCrossesTheDateLine() throws {
            // Auckland runs DST in January (+13): 23:30 local is 10:30 UTC same day.
            let instant = try #require(FormDates.instant(ymd: "2026-01-10", hm: "23:30", timeZone: auckland))
            #expect(FormDates.ymd(instant, timeZone: .gmt) == "2026-01-10")
            #expect(FormDates.hm(instant, timeZone: .gmt) == "10:30")
        }

        @Test func wallClockRoundTrips() throws {
            let instant = try #require(FormDates.instant(ymd: "2026-03-08", hm: "07:45", timeZone: auckland))
            #expect(FormDates.ymd(instant, timeZone: auckland) == "2026-03-08")
            #expect(FormDates.hm(instant, timeZone: auckland) == "07:45")
        }

        @Test func addDaysCrossesMonthAndYearEnds() {
            #expect(FormDates.addDays("2026-01-31", 1) == "2026-02-01")
            #expect(FormDates.addDays("2026-12-31", 1) == "2027-01-01")
            #expect(FormDates.addDays("2028-02-28", 1) == "2028-02-29")  // leap
            #expect(FormDates.addDays("2027-02-28", 1) == "2027-03-01")  // non-leap
            #expect(FormDates.addDays("2026-03-01", -1) == "2026-02-28")
            #expect(FormDates.addDays("2027-01-01", -1) == "2026-12-31")
        }

        @Test func parseInstantHandlesBothPrecisions() throws {
            let plain = try #require(FormDates.parseInstant("2026-07-27T03:30:00Z"))
            let fractional = try #require(FormDates.parseInstant("2026-07-27T03:30:00.000Z"))
            #expect(plain == fractional)
        }

        // R1 The span an anchor-seeded all-day edit has to preserve.
        @Test func daysBetweenSpansMonthsAndGoesNegative() {
            #expect(FormDates.daysBetween("2026-07-27", "2026-07-27") == 0)
            #expect(FormDates.daysBetween("2026-07-27", "2026-07-28") == 1)
            #expect(FormDates.daysBetween("2026-08-10", "2026-09-02") == 23)
            #expect(FormDates.daysBetween("2026-08-10", "2026-08-09") == -1)
        }
    }

    // MARK: - R14 shared error + length plumbing

    @Suite struct FormPlumbing {
        // R14 Raw zod paths must never be shown as-is.
        @Test func validationFieldPullsTheFirstPathSegment() {
            #expect(FormErrors.validationField("validation_failed (emoji)") == "emoji")
            #expect(FormErrors.validationField("validation_failed (tasks.0.title)") == "tasks")
            #expect(FormErrors.validationField("validation_failed (recurrence.byWeekday.0)") == "recurrence")
            #expect(FormErrors.validationField("validation_failed") == "")  // no field named
            #expect(FormErrors.validationField("invalid_times") == nil)  // not a validation failure
            #expect(FormErrors.validationField(nil) == nil)
        }

        // R14 zod's maxLength counts UTF-16 units, so an emoji costs two.
        @Test func cappedCountsUtf16WithoutSplittingGraphemes() {
            #expect(FormLimits.capped("hello", 10) == "hello")
            #expect(FormLimits.capped("hello", 3) == "hel")
            // Family emoji: ONE Character, eleven UTF-16 units — the cut never
            // splits it, so two of them come back as one.
            let family = "👨‍👩‍👧‍👦"
            #expect(family.count == 1)
            #expect(family.utf16.count == 11)
            #expect(FormLimits.capped(family + family, FormLimits.emoji) == family)
            // Eight simple emoji is exactly 16 UTF-16 units; the ninth is cut.
            let eight = String(repeating: "🧹", count: 8)
            #expect(eight.utf16.count == FormLimits.emoji)
            #expect(FormLimits.capped(eight + "🧹", FormLimits.emoji) == eight)
            #expect(FormLimits.capped(String(repeating: "a", count: 300), FormLimits.title).count == 120)
        }
    }

    // MARK: - R4b Emoji field input rules

    /// The emoji field raises the EMOJI keyboard, but the family can remove
    /// that keyboard in Settings — then it is the normal one, and anything at
    /// all can be typed. These rules are the only gate (the server just checks
    /// 1...16 characters), so they carry the weight.
    @Suite struct EmojiField {
        // Empty (and whitespace-only) clears the pick back to None.
        @Test func emptyClearsToNone() {
            #expect(EmojiInput.accept("") == "")
            #expect(EmojiInput.accept("   ") == "")
            #expect(EmojiInput.accept("\n") == "")
        }

        // nil = refuse the edit and keep what was there — never store a letter
        // as an "emoji".
        @Test func lettersAndDigitsAreRefused() {
            #expect(EmojiInput.accept("a") == nil)
            #expect(EmojiInput.accept("cat") == nil)
            #expect(EmojiInput.accept("7") == nil)
            #expect(EmojiInput.accept("#") == nil)
            #expect(EmojiInput.accept("*") == nil)
            #expect(EmojiInput.accept("→") == nil)
            // A digit is Emoji=Yes only as a keycap; the bare one stays refused
            // while the keycap sequence is accepted whole.
            #expect(EmojiInput.accept("1️⃣") == "1️⃣")
            // Text presentation (VS15) is a glyph, not an emoji.
            #expect(EmojiInput.accept("❤\u{FE0E}") == nil)
            // A trailing letter refuses the WHOLE edit, emoji earlier or not.
            #expect(EmojiInput.accept("🧹a") == nil)
        }

        // A paste (or a second tap on the emoji keyboard) keeps the LAST one.
        @Test func multipleEmojiCollapseToTheLast() {
            #expect(EmojiInput.accept("🧹") == "🧹")
            #expect(EmojiInput.accept("🧹🧽") == "🧽")
            #expect(EmojiInput.accept("🧹🧽🧼") == "🧼")
            #expect(EmojiInput.accept("  🧹🧽  ") == "🧽")
            #expect(EmojiInput.accept("cat 🐈") == "🐈")
        }

        // A ZWJ family is ONE grapheme with many scalars — taking "the last
        // one" must not shear it into a lone 👧.
        @Test func zwjSequencesSurviveAsOne() {
            let family = "👨‍👩‍👧"
            #expect(family.count == 1)
            #expect(EmojiInput.accept(family) == family)
            #expect(EmojiInput.accept("🧹" + family) == family)
            let four = "👨‍👩‍👧‍👦"
            #expect(EmojiInput.accept(four) == four)
        }

        // The skin-tone modifier rides on the same grapheme.
        @Test func skinToneModifiersSurvive() {
            #expect(EmojiInput.accept("👍🏽") == "👍🏽")
            #expect(EmojiInput.accept("👍") == "👍")
            #expect(EmojiInput.accept("👍👍🏿") == "👍🏿")
            // A flag is two regional indicators, still one grapheme.
            #expect(EmojiInput.accept("🇸🇪") == "🇸🇪")
        }

        // Text-default emoji wear a VS16 (☀️, 🗑️) and presentation-default
        // ones don't (🐕, 🐈) — the keyboard types both, and both must pass.
        @Test func bothEmojiPresentationFormsAreAcceptedUnchanged() {
            for option in ["🧹", "🗑️", "♻️", "🐕", "🐈", "🍽️", "✏️", "🛒"] {
                #expect(EmojiInput.accept(option) == option, "\(option) was rejected")
                #expect(option.count == 1, "\(option) is not one grapheme")
                // R14 And each fits the spec's 16 UTF-16 unit cap untouched.
                #expect(FormLimits.capped(option, FormLimits.emoji) == option)
            }
        }

        @Test func variationSelectorFormsAreAccepted() {
            #expect(EmojiInput.accept("☀️") == "☀️")
            #expect(EmojiInput.accept("♻️") == "♻️")
            #expect(EmojiInput.accept("‼️") == "‼️")
        }
    }

    // MARK: - Event form

    @Suite struct EventForm {
        private func occurrence(
            allDay: Bool = false,
            startsAt: String? = nil,
            endsAt: String? = nil,
            startDate: String? = nil,
            endDate: String? = nil,
            memberIds: [String]? = nil,
            recurrence: Components.Schemas.EventOccurrence.RecurrencePayload? = nil,
            seriesStartsAt: String? = nil,
            seriesStartDate: String? = nil
        ) -> Components.Schemas.EventOccurrence {
            .init(
                id: "o1",
                eventId: "e1",
                calendarId: "cal1",
                summary: "Swimming",
                location: nil,
                allDay: allDay,
                startsAt: startsAt,
                endsAt: endsAt,
                startDate: startDate,
                endDate: endDate,
                memberIds: memberIds,
                color: nil,
                recurrence: recurrence,
                seriesStartsAt: seriesStartsAt,
                seriesStartDate: seriesStartDate
            )
        }

        /// The live repro's series: weekly Mondays 14:00–15:30 UTC from Jul 27,
        /// opened via its THIRD occurrence (Aug 10).
        private var weekly: Components.Schemas.EventOccurrence.RecurrencePayload {
            .init(freq: .weekly, byWeekday: [.mo], until: "2026-08-24")
        }

        @Test func allDaySingleDaySendsExclusiveEndAcrossMonthEnd() {
            var state = EventFormLogic.initial(defaultDate: "2026-01-31", calendarId: "cal1", timeZone: kolkata)
            state.summary = "Trip"
            state.allDay = true
            let body = EventFormLogic.createBody(state)
            #expect(body.allDay == true)
            #expect(body.startDate == "2026-01-31")
            #expect(body.endDate == "2026-02-01")  // inclusive last day + 1
            #expect(body.startsAt == nil)
            #expect(body.endsAt == nil)
        }

        @Test func allDayMultiDaySendsExclusiveEndAcrossYearEnd() {
            var state = EventFormLogic.initial(defaultDate: "2026-12-30", calendarId: "cal1", timeZone: kolkata)
            state.summary = "Trip"
            state.allDay = true
            state.multiDay = true
            state.lastDay = "2026-12-31"
            let body = EventFormLogic.createBody(state)
            #expect(body.startDate == "2026-12-30")
            #expect(body.endDate == "2027-01-01")
        }

        @Test func timedBodyCarriesHouseholdZoneInstants() throws {
            var state = EventFormLogic.initial(defaultDate: "2026-07-27", calendarId: "cal1", timeZone: kolkata)
            state.summary = "Swim"
            let body = EventFormLogic.createBody(state)
            // The 09:00/10:00 defaults were composed in Kolkata, not the device zone.
            #expect(body.startsAt == FormDates.instant(ymd: "2026-07-27", hm: "09:00", timeZone: kolkata))
            #expect(body.endsAt == FormDates.instant(ymd: "2026-07-27", hm: "10:00", timeZone: kolkata))
            #expect(body.startDate == nil)
            #expect(body.endDate == nil)
        }

        @Test func emptyMemberSelectionMeansWholeFamily() {
            var state = EventFormLogic.initial(defaultDate: "2026-07-27", calendarId: "cal1", timeZone: kolkata)
            #expect(EventFormLogic.memberIdsWire(state) == nil)
            state.memberIds = ["m2", "m1"]
            #expect(EventFormLogic.memberIdsWire(state) == ["m1", "m2"])
        }

        @Test func recurrenceParts() {
            var state = EventFormLogic.initial(defaultDate: "2026-07-27", calendarId: "cal1", timeZone: kolkata)
            #expect(EventFormLogic.recurrenceParts(state) == nil)  // does not repeat

            state.repeats = .weekly
            state.interval = 2
            state.byWeekday = [.we, .mo]
            var parts = EventFormLogic.recurrenceParts(state)
            #expect(parts?.freq == "weekly")
            #expect(parts?.interval == 2)
            #expect(parts?.byWeekday == ["mo", "we"])  // canonical order
            #expect(parts?.byMonthDay == nil)
            #expect(parts?.until == nil)

            state.interval = 1  // the default interval is omitted
            parts = EventFormLogic.recurrenceParts(state)
            #expect(parts?.interval == nil)

            state.repeats = .monthly
            state.byMonthDay = 15
            parts = EventFormLogic.recurrenceParts(state)
            #expect(parts?.byWeekday == nil)  // weekday chips are weekly-only
            #expect(parts?.byMonthDay == 15)

            state.repeats = .yearly
            state.byMonthDay = nil
            state.hasUntil = true
            state.until = "2027-07-27"
            parts = EventFormLogic.recurrenceParts(state)
            #expect(parts?.freq == "yearly")
            #expect(parts?.until == "2027-07-27")
        }

        @Test func seedShowsInclusiveLastDay() {
            // Wire endDate "2026-07-22" (exclusive) = last day Jul 21.
            let multi = EventFormLogic.seed(
                from: occurrence(allDay: true, startDate: "2026-07-20", endDate: "2026-07-22"),
                timeZone: kolkata
            )
            #expect(multi.allDay == true)
            #expect(multi.firstDay == "2026-07-20")
            #expect(multi.lastDay == "2026-07-21")
            #expect(multi.multiDay == true)

            let single = EventFormLogic.seed(
                from: occurrence(allDay: true, startDate: "2026-07-20", endDate: "2026-07-21"),
                timeZone: kolkata
            )
            #expect(single.lastDay == "2026-07-20")
            #expect(single.multiDay == false)
        }

        @Test func seedTimedFramesDaysInHouseholdZone() throws {
            let seeded = EventFormLogic.seed(
                from: occurrence(startsAt: "2026-07-27T03:30:00Z", endsAt: "2026-07-27T04:30:00Z"),
                timeZone: kolkata
            )
            #expect(seeded.start == FormDates.parseInstant("2026-07-27T03:30:00Z"))
            #expect(seeded.end == FormDates.parseInstant("2026-07-27T04:30:00Z"))
            #expect(seeded.firstDay == "2026-07-27")  // 09:00 Kolkata wall clock
        }

        @Test func seedRoundTripsTheRecurrence() {
            let seeded = EventFormLogic.seed(
                from: occurrence(
                    startsAt: "2026-07-27T03:30:00Z",
                    endsAt: "2026-07-27T04:30:00Z",
                    memberIds: ["m1"],
                    recurrence: .init(freq: .weekly, interval: 2, byWeekday: [.mo, .we], until: "2026-09-01")
                ),
                timeZone: kolkata
            )
            #expect(seeded.memberIds == ["m1"])
            let parts = EventFormLogic.recurrenceParts(seeded)
            #expect(parts == EventFormLogic.RecurrenceParts(
                freq: "weekly",
                interval: 2,
                byWeekday: ["mo", "we"],
                byMonthDay: nil,
                until: "2026-09-01"
            ))
        }

        @Test func validateRules() {
            var state = EventFormLogic.initial(defaultDate: "2026-07-27", calendarId: "cal1", timeZone: kolkata)
            #expect(EventFormLogic.validate(state) == "Give the event a title.")
            state.summary = "Swim"
            #expect(EventFormLogic.validate(state) == nil)

            state.end = state.start  // end must be strictly after
            #expect(EventFormLogic.validate(state) == "The end must be after the start.")

            state.allDay = true
            #expect(EventFormLogic.validate(state) == nil)  // timed bounds ignored
            state.multiDay = true
            state.lastDay = "2026-07-26"
            #expect(EventFormLogic.validate(state) == "The last day can't be before the first day.")

            state.calendarId = ""
            #expect(EventFormLogic.validate(state) == "Pick a calendar.")
        }

        private func calendar(
            _ id: String,
            accountId: String? = nil,
            writable: Bool = true,
            enabled: Bool = true
        ) -> Components.Schemas.Calendar {
            .init(
                id: id,
                accountId: accountId,
                displayName: "Cal \(id)",
                enabled: enabled,
                writable: writable,
                eventCount: 0,
                createdAt: "2026-01-01T00:00:00Z"
            )
        }

        @Test func defaultCalendarPrefersLocalThenAnyWritable() {
            // Local = accountId nil; synced writable is allowed but not default.
            #expect(EventFormLogic.defaultCalendarId([
                calendar("synced", accountId: "acc1"),
                calendar("local"),
            ]) == "local")
            #expect(EventFormLogic.defaultCalendarId([
                calendar("synced", accountId: "acc1"),
                calendar("local", writable: false),
            ]) == "synced")
            #expect(EventFormLogic.defaultCalendarId([calendar("ro", writable: false)]) == nil)
        }

        @Test func calendarLabelsTagSyncedAndHidden() {
            #expect(EventFormLogic.calendarLabel(calendar("a")) == "Cal a")
            #expect(EventFormLogic.calendarLabel(calendar("b", accountId: "acc1")) == "Cal b (synced)")
            #expect(EventFormLogic.calendarLabel(calendar("c", enabled: false)) == "Cal c (hidden)")
        }

        @Test func updateBodyClearsTheSeriesWhenRepeatIsNone() {
            var state = EventFormLogic.initial(defaultDate: "2026-07-27", calendarId: "cal1", timeZone: kolkata)
            state.summary = "Swim"
            state.repeats = .none
            // Full replacement: nil recurrence on the wire ends the series.
            #expect(EventFormLogic.updateBody(state).recurrence == nil)
            state.repeats = .daily
            #expect(EventFormLogic.updateBody(state).recurrence?.freq == .daily)
        }

        @Test func caldavConflictGetsHonestCopy() {
            #expect(EventFormLogic.friendlyError("caldav_event")
                == "Managed in iCloud — title, time and repeats change in the source calendar.")
            #expect(EventFormLogic.friendlyError("caldav_readonly")
                == EventFormLogic.friendlyError("caldav_event"))
        }

        // MARK: R1 — series anchor seeding

        // R1 One-off events have no anchor; a series without one (older server,
        // unparseable ICS) must fall back rather than guess.
        @Test func seriesAnchorOnlyExistsForARecurringOccurrenceThatReportsOne() {
            #expect(EventFormLogic.seriesAnchor(
                occurrence(startsAt: "2026-08-10T14:00:00Z", seriesStartsAt: "2026-07-27T14:00:00Z")
            ) == nil)  // not recurring
            #expect(EventFormLogic.seriesAnchor(
                occurrence(startsAt: "2026-08-10T14:00:00Z", recurrence: weekly)
            ) == nil)  // recurring, no anchor reported
            #expect(EventFormLogic.seriesAnchor(
                occurrence(
                    startsAt: "2026-08-10T14:00:00Z",
                    recurrence: weekly,
                    seriesStartsAt: "2026-07-27T14:00:00Z"
                )
            ) == EventFormLogic.SeriesAnchor(startsAt: FormDates.parseInstant("2026-07-27T14:00:00Z")))
            #expect(EventFormLogic.seriesAnchor(
                occurrence(
                    allDay: true,
                    startDate: "2026-08-10",
                    endDate: "2026-08-12",
                    recurrence: weekly,
                    seriesStartDate: "2026-07-27"
                )
            ) == EventFormLogic.SeriesAnchor(startDate: "2026-07-27"))
        }

        // R1 THE BUG: seeding a timed series from the TAPPED occurrence re-anchors
        // DTSTART, and the PATCH (a full ICS replace) drops every earlier one —
        // live-reproduced 5 -> 3. The anchor + this occurrence's duration fix it.
        @Test func timedSeriesEditSeedsFromTheAnchorKeepingDuration() throws {
            let third = occurrence(
                startsAt: "2026-08-10T14:00:00Z",
                endsAt: "2026-08-10T15:30:00Z",
                recurrence: weekly,
                seriesStartsAt: "2026-07-27T14:00:00Z"
            )
            let seeded = EventFormLogic.seed(from: third, timeZone: kolkata)
            #expect(seeded.start == FormDates.parseInstant("2026-07-27T14:00:00Z"))
            #expect(seeded.end == FormDates.parseInstant("2026-07-27T15:30:00Z"))  // 90 min kept

            // What actually goes on the wire — the master DTSTART is unmoved, so
            // the series round-trips whole.
            let body = EventFormLogic.updateBody(seeded)
            #expect(body.startsAt == FormDates.parseInstant("2026-07-27T14:00:00Z"))
            #expect(body.endsAt == FormDates.parseInstant("2026-07-27T15:30:00Z"))
            #expect(body.recurrence?.freq == .weekly)
        }

        // R1 Same for all-day: the anchor date plus this occurrence's span in days
        // (wire endDate is exclusive, the form's lastDay is inclusive).
        @Test func allDaySeriesEditSeedsFromTheAnchorKeepingSpan() {
            let third = occurrence(
                allDay: true,
                startDate: "2026-08-10",
                endDate: "2026-08-12",  // exclusive -> a 2-day occurrence
                recurrence: weekly,
                seriesStartDate: "2026-07-27"
            )
            let seeded = EventFormLogic.seed(from: third, timeZone: kolkata)
            #expect(seeded.allDay == true)
            #expect(seeded.firstDay == "2026-07-27")
            #expect(seeded.lastDay == "2026-07-28")  // 2 days, inclusive
            #expect(seeded.multiDay == true)

            let body = EventFormLogic.updateBody(seeded)
            #expect(body.startDate == "2026-07-27")
            #expect(body.endDate == "2026-07-29")  // exclusive again
        }

        // R1 No anchor = today's behavior, unchanged.
        @Test func aMissingAnchorFallsBackToTheOccurrence() {
            let timed = EventFormLogic.seed(
                from: occurrence(
                    startsAt: "2026-08-10T14:00:00Z",
                    endsAt: "2026-08-10T15:30:00Z",
                    recurrence: weekly
                ),
                timeZone: kolkata
            )
            #expect(timed.start == FormDates.parseInstant("2026-08-10T14:00:00Z"))
            #expect(timed.end == FormDates.parseInstant("2026-08-10T15:30:00Z"))

            let allDay = EventFormLogic.seed(
                from: occurrence(allDay: true, startDate: "2026-08-10", endDate: "2026-08-12", recurrence: weekly),
                timeZone: kolkata
            )
            #expect(allDay.firstDay == "2026-08-10")
            #expect(allDay.lastDay == "2026-08-11")
        }

        // R1 A one-off event still seeds from itself even when a stray anchor rides along.
        @Test func aOneOffEventIsNeverReAnchored() {
            let seeded = EventFormLogic.seed(
                from: occurrence(
                    startsAt: "2026-08-10T14:00:00Z",
                    endsAt: "2026-08-10T15:30:00Z",
                    seriesStartsAt: "2026-07-27T14:00:00Z"
                ),
                timeZone: kolkata
            )
            #expect(seeded.start == FormDates.parseInstant("2026-08-10T14:00:00Z"))
        }

        // R1 The note's date is framed in the HOUSEHOLD zone.
        @Test func seriesStartLocalDateFramesInTheHouseholdZone() {
            // 2026-07-27T20:00Z is already the 28th in Auckland (+12).
            let occ = occurrence(
                startsAt: "2026-08-10T20:00:00Z",
                endsAt: "2026-08-10T21:00:00Z",
                recurrence: weekly,
                seriesStartsAt: "2026-07-27T20:00:00Z"
            )
            #expect(EventFormLogic.seriesStartLocalDate(occ, timeZone: kolkata) == "2026-07-28")
            #expect(EventFormLogic.seriesStartLocalDate(occ, timeZone: auckland) == "2026-07-28")
            #expect(EventFormLogic.seriesStartLocalDate(occ, timeZone: .gmt) == "2026-07-27")
            // Nothing to explain for a one-off.
            #expect(EventFormLogic.seriesStartLocalDate(
                occurrence(startsAt: "2026-08-10T20:00:00Z"), timeZone: kolkata
            ) == nil)
        }

        // MARK: R5 — monthly day of month

        // R5 The four cases probed against the live server's expansion.
        @Test func firstMonthlyDateMatchesTheServersExpansion() {
            #expect(EventFormLogic.firstMonthlyDate(start: "2026-07-27", day: 15, interval: 1) == "2026-08-15")
            #expect(EventFormLogic.firstMonthlyDate(start: "2026-07-27", day: 27, interval: 1) == "2026-07-27")
            #expect(EventFormLogic.firstMonthlyDate(start: "2026-07-31", day: 31, interval: 1) == "2026-07-31")
            // September has no 31st — skipped.
            #expect(EventFormLogic.firstMonthlyDate(start: "2026-09-05", day: 31, interval: 1) == "2026-10-31")
            // Every 2 months from July: Jul 5 is past, so Sep 5 — NOT Aug 5.
            #expect(EventFormLogic.firstMonthlyDate(start: "2026-07-27", day: 5, interval: 2) == "2026-09-05")
            #expect(EventFormLogic.firstMonthlyDate(start: "2026-07-27", day: 0, interval: 1) == nil)
        }

        // R5 The form used to show a "Starts" that the series never lands on.
        @Test func monthlyStartMismatchNamesTheRealFirstDate() {
            var state = EventFormLogic.initial(defaultDate: "2026-07-27", calendarId: "cal1", timeZone: kolkata)
            state.summary = "Rent"
            state.repeats = .monthly
            #expect(EventFormLogic.monthlyStartMismatch(state, timeZone: kolkata) == nil)  // day follows the start

            state.byMonthDay = 27  // same as the start's day — still nothing to say
            #expect(EventFormLogic.monthlyStartMismatch(state, timeZone: kolkata) == nil)

            state.byMonthDay = 15
            #expect(EventFormLogic.monthlyStartMismatch(state, timeZone: kolkata) == "2026-08-15")

            // Weekly/daily never show the note, even with a stale byMonthDay.
            state.repeats = .weekly
            #expect(EventFormLogic.monthlyStartMismatch(state, timeZone: kolkata) == nil)

            // All-day reads firstDay, not the timed pickers.
            state.repeats = .monthly
            state.allDay = true
            state.firstDay = "2026-09-05"
            state.byMonthDay = 31
            #expect(EventFormLogic.monthlyStartMismatch(state, timeZone: kolkata) == "2026-10-31")
        }

        // MARK: R4 / R10 / R14

        // R4 Every seeded field has to move the dirty needle.
        @Test func dirtyTracksEveryEditedField() {
            let original = EventFormLogic.initial(
                defaultDate: "2026-07-27", calendarId: "cal1", timeZone: kolkata
            )
            #expect(EventFormLogic.isDirty(original, original: original) == false)

            var edited = original
            edited.summary = "Swim"
            #expect(EventFormLogic.isDirty(edited, original: original))

            edited = original
            edited.memberIds = ["m1"]
            #expect(EventFormLogic.isDirty(edited, original: original))

            edited = original
            edited.end = original.end.addingTimeInterval(600)
            #expect(EventFormLogic.isDirty(edited, original: original))

            edited = original
            edited.repeats = .weekly
            #expect(EventFormLogic.isDirty(edited, original: original))

            edited = original
            edited.byMonthDay = 3
            #expect(EventFormLogic.isDirty(edited, original: original))

            edited = original
            edited.location = "Pool"
            #expect(EventFormLogic.isDirty(edited, original: original))
        }

        // R10 POST /events answers `not_found` for a missing CALENDAR — the
        // old copy claimed the event was gone before it ever existed.
        @Test func createNotFoundBlamesTheCalendarNotTheEvent() {
            #expect(EventFormLogic.createErrorCode("not_found") == "unknown_calendar")
            #expect(EventFormLogic.friendlyError(EventFormLogic.createErrorCode("not_found"))
                == "That calendar no longer exists — pick another one.")
            // Edit keeps the event wording.
            #expect(EventFormLogic.friendlyError("not_found")
                == "This event no longer exists — it may have just been deleted.")
            // Other codes pass through untouched.
            #expect(EventFormLogic.createErrorCode("calendar_readonly") == "calendar_readonly")
        }

        // R14 "validation_failed (summary)" used to be shown verbatim.
        @Test func zodCodesNeverReachTheFamily() {
            #expect(EventFormLogic.friendlyError("validation_failed (summary)")
                == "The title needs to be 1 to 200 characters.")
            #expect(EventFormLogic.friendlyError("validation_failed (recurrence.byWeekday.0)")
                == "That repeat rule isn't valid.")
            #expect(EventFormLogic.friendlyError("validation_failed (sortOrder)")
                == "Something about the event isn't valid. Check the fields and try again.")
            #expect(EventFormLogic.friendlyError("validation_failed")
                == "Something about the event isn't valid. Check the fields and try again.")
            // An unknown/absent code must never render as a raw code either.
            #expect(EventFormLogic.friendlyError("e_teapot")
                == "That didn't work. Check the connection and try again.")
            #expect(EventFormLogic.friendlyError(nil)
                == "That didn't work. Check the connection and try again.")
        }
    }

    // MARK: - Chore form

    @Suite struct ChoreForm {
        private func chore(
            dueDate: String? = nil,
            dueMode: Components.Schemas.Chore.DueModePayload? = nil,
            dueTime: String? = nil,
            recurrence: Components.Schemas.Chore.RecurrencePayload? = nil,
            assigneeIds: [String] = ["m1"]
        ) -> Components.Schemas.Chore {
            .init(
                id: "c1",
                title: "Feed the cat",
                starValue: 2,
                upForGrabs: assigneeIds.isEmpty,
                dueDate: dueDate,
                dueMode: dueMode,
                dueTime: dueTime,
                recurrence: recurrence,
                assigneeIds: assigneeIds,
                sortOrder: 0,
                createdAt: "2026-01-01T00:00:00Z"
            )
        }

        private func baseState(shape: ChoreFormLogic.Shape) -> ChoreFormLogic.State {
            var state = ChoreFormLogic.State()
            state.title = "Feed the cat"
            state.shape = shape
            state.dueDate = "2026-07-30"
            state.startDate = "2026-07-27"
            return state
        }

        @Test func anytimeSendsNoScheduleFieldsAtAll() {
            var state = baseState(shape: .anytime)
            state.hasDueTime = true  // leftover from a shape switch — dropped
            let body = ChoreFormLogic.createBody(state)
            #expect(body.dueDate == nil)
            #expect(body.dueMode == nil)
            #expect(body.dueTime == nil)
            #expect(body.recurrence == nil)
        }

        /// Owner 2026-08-10: "On a day" is retired — every dated chore is a
        /// due date, written as dueMode "by".
        @Test func datedSendsDueModeBy() {
            var state = baseState(shape: .byDate)
            state.hasDueTime = true
            state.dueTime = "08:30"
            let body = ChoreFormLogic.createBody(state)
            #expect(body.dueDate == "2026-07-30")
            #expect(body.dueMode == .by)
            #expect(body.dueTime == "08:30")
            #expect(body.recurrence == nil)
        }

        @Test func repeatsSendsRecurrenceOnly() {
            var state = baseState(shape: .repeats)
            state.freq = .weekly
            state.interval = 2
            state.byWeekday = [.sa, .mo]
            state.hasEndDate = true
            state.endDate = "2026-12-31"
            let body = ChoreFormLogic.createBody(state)
            #expect(body.dueDate == nil)
            #expect(body.dueMode == nil)
            let recurrence = body.recurrence
            #expect(recurrence?.freq == .weekly)
            #expect(recurrence?.interval == 2)
            #expect(recurrence?.byWeekday == [.mo, .sa])  // canonical order
            #expect(recurrence?.startDate == "2026-07-27")
            #expect(recurrence?.endDate == "2026-12-31")
        }

        @Test func monthlyDayOfMonthOnlyForMonthly() {
            var state = baseState(shape: .repeats)
            state.freq = .monthly
            state.byMonthDay = 15
            #expect(ChoreFormLogic.createBody(state).recurrence?.byMonthDay == 15)
            state.freq = .weekly
            #expect(ChoreFormLogic.createBody(state).recurrence?.byMonthDay == nil)
        }

        @Test func upForGrabsIsDerivedFromTheSelection() {
            var state = baseState(shape: .anytime)
            #expect(ChoreFormLogic.upForGrabs(state) == true)
            var body = ChoreFormLogic.createBody(state)
            #expect(body.upForGrabs == true)
            #expect(body.assigneeIds == [])

            state.assigneeIds = ["m2", "m1"]
            body = ChoreFormLogic.createBody(state)
            #expect(body.upForGrabs == false)
            #expect(body.assigneeIds == ["m1", "m2"])
        }

        @Test func patchIsAFullReplacementWithExplicitNulls() throws {
            // Flipping to anytime must CLEAR the schedule: literal nulls on the
            // wire — an omitted key would keep the old value (server merge).
            let dict = try json(ChoreFormLogic.patchBody(baseState(shape: .anytime)))
            #expect(dict["title"] as? String == "Feed the cat")
            #expect(dict["starValue"] as? Int == 1)
            #expect(dict["upForGrabs"] as? Bool == true)
            #expect(dict["dueDate"] is NSNull)
            #expect(dict["dueMode"] is NSNull)
            #expect(dict["dueTime"] is NSNull)
            #expect(dict["recurrence"] is NSNull)
            #expect(dict["notes"] is NSNull)
            #expect(dict["emoji"] is NSNull)
        }

        @Test func patchKeepsTheSelectedShapeFields() throws {
            var state = baseState(shape: .byDate)
            state.hasDueTime = true
            state.dueTime = "17:00"
            state.emoji = "🐈"
            let dict = try json(ChoreFormLogic.patchBody(state))
            #expect(dict["dueDate"] as? String == "2026-07-30")
            #expect(dict["dueMode"] as? String == "by")
            #expect(dict["dueTime"] as? String == "17:00")
            #expect(dict["recurrence"] is NSNull)
            #expect(dict["emoji"] as? String == "🐈")

            var repeating = baseState(shape: .repeats)
            repeating.freq = .daily
            let repeatingDict = try json(ChoreFormLogic.patchBody(repeating))
            #expect(repeatingDict["dueDate"] is NSNull)
            let recurrence = try #require(repeatingDict["recurrence"] as? [String: Any])
            #expect(recurrence["freq"] as? String == "daily")
            #expect(recurrence["startDate"] as? String == "2026-07-27")
            #expect(recurrence["interval"] == nil)  // canonical: defaults omitted
        }

        @Test func seedDetectsAllFourShapes() {
            #expect(ChoreFormLogic.seed(from: chore()).shape == .anytime)
            // Legacy "on" chores seed as Due date too (owner 2026-08-10).
            #expect(ChoreFormLogic.seed(from: chore(dueDate: "2026-07-30")).shape == .byDate)
            #expect(ChoreFormLogic.seed(from: chore(dueDate: "2026-07-30", dueMode: .by)).shape == .byDate)
            let recurring = chore(recurrence: .init(freq: .weekly, byWeekday: [.mo], startDate: "2026-07-01"))
            let seeded = ChoreFormLogic.seed(from: recurring)
            #expect(seeded.shape == .repeats)
            #expect(seeded.freq == .weekly)
            #expect(seeded.byWeekday == [.mo])
            #expect(seeded.startDate == "2026-07-01")
        }

        @Test func seedPrefillsUpForGrabsAsEmptySelection() {
            let seeded = ChoreFormLogic.seed(from: chore(assigneeIds: []))
            #expect(seeded.assigneeIds.isEmpty)
            #expect(ChoreFormLogic.upForGrabs(seeded) == true)
        }

        @Test func validateRules() {
            var state = baseState(shape: .anytime)
            state.title = "  "
            #expect(ChoreFormLogic.validate(state) == "Give the chore a title.")

            state = baseState(shape: .repeats)
            state.hasEndDate = true
            state.endDate = "2026-07-01"  // before the start
            #expect(ChoreFormLogic.validate(state) == "The end date can't be before the start date.")
            state.endDate = "2026-08-01"
            #expect(ChoreFormLogic.validate(state) == nil)
        }

        // R4 Every seeded field has to move the dirty needle.
        @Test func dirtyTracksEveryEditedField() {
            let original = ChoreFormLogic.seed(from: chore(dueDate: "2026-07-30"))
            #expect(ChoreFormLogic.isDirty(original, original: original) == false)

            var edited = original
            edited.title += "!"
            #expect(ChoreFormLogic.isDirty(edited, original: original))

            edited = original
            edited.emoji = "🐈"
            #expect(ChoreFormLogic.isDirty(edited, original: original))

            edited = original
            edited.notes = "after breakfast"
            #expect(ChoreFormLogic.isDirty(edited, original: original))

            edited = original
            edited.stars += 1
            #expect(ChoreFormLogic.isDirty(edited, original: original))

            edited = original
            edited.assigneeIds = []
            #expect(ChoreFormLogic.isDirty(edited, original: original))

            edited = original
            edited.shape = .repeats
            #expect(ChoreFormLogic.isDirty(edited, original: original))

            edited = original
            edited.hasDueTime = true
            #expect(ChoreFormLogic.isDirty(edited, original: original))
        }

        // R14 "validation_failed (emoji)" was shown verbatim.
        @Test func zodCodesNeverReachTheFamily() {
            #expect(ChoreFormLogic.friendlyError("validation_failed (emoji)")
                == "That emoji isn't one the server accepts — pick another, or none.")
            #expect(ChoreFormLogic.friendlyError("validation_failed (title)")
                == "The title needs to be 1 to 120 characters.")
            #expect(ChoreFormLogic.friendlyError("validation_failed (recurrence.interval)")
                == "That schedule isn't valid — check the date and repeat settings.")
            #expect(ChoreFormLogic.friendlyError("validation_failed (sortOrder)")
                == "Something about the chore isn't valid. Check the fields and try again.")
            #expect(ChoreFormLogic.friendlyError("e_teapot")
                == "That didn't work. Check the connection and try again.")
            #expect(ChoreFormLogic.friendlyError(nil)
                == "That didn't work. Check the connection and try again.")
        }
    }

    // MARK: - Routine form

    @Suite struct RoutineForm {
        private func routine(
            byWeekday: Components.Schemas.Routine.ByWeekdayPayload? = nil,
            tasks: [Components.Schemas.RoutineTask] = []
        ) -> Components.Schemas.Routine {
            .init(
                id: "r1",
                title: "Morning",
                emoji: "☀️",
                windowStart: "06:00",
                windowEnd: "12:00",
                byWeekday: byWeekday,
                assigneeIds: ["m1"],
                tasks: tasks,
                sortOrder: 0,
                createdAt: "2026-01-01T00:00:00Z"
            )
        }

        private func serverTask(_ id: String, _ title: String, sortOrder: Int) -> Components.Schemas.RoutineTask {
            .init(id: id, title: title, starValue: 1, sortOrder: sortOrder)
        }

        @Test func allSevenWeekdaysMeanDaily() {
            #expect(RoutineFormLogic.byWeekdayWire(Set(FormWeekday.allCases)) == nil)
            #expect(RoutineFormLogic.byWeekdayWire([.we, .mo]) == ["mo", "we"])  // canonical order
            #expect(RoutineFormLogic.byWeekdayWire([]) == [])
        }

        @Test func seedSortsTasksAndKeepsServerIds() {
            let seeded = RoutineFormLogic.seed(from: routine(tasks: [
                serverTask("t2", "Dress", sortOrder: 1),
                serverTask("t1", "Brush teeth", sortOrder: 0),
            ]))
            #expect(seeded.tasks.map(\.serverId) == ["t1", "t2"])
            #expect(seeded.tasks.map(\.title) == ["Brush teeth", "Dress"])
            // byWeekday null = daily = all seven chips.
            #expect(seeded.byWeekday == Set(FormWeekday.allCases))
        }

        @Test func patchKeepsIdsThroughRenameAndReorder() throws {
            var state = RoutineFormLogic.seed(from: routine(tasks: [
                serverTask("t1", "Brush teeth", sortOrder: 0),
                serverTask("t2", "Dress", sortOrder: 1),
            ]))
            state.tasks[0].title = "Brush teeth well"  // rename keeps the id
            state.tasks.swapAt(0, 1)  // visual order IS sortOrder
            state.tasks.append(RoutineFormLogic.TaskRow(title: "Pack bag", stars: 2))

            let body = RoutineFormLogic.patchBody(state)
            #expect(body.tasks.map(\.id) == ["t2", "t1", nil])
            #expect(body.tasks.map(\.title) == ["Dress", "Brush teeth well", "Pack bag"])

            // On the wire: kept rows carry their id, the NEW row has NO id key
            // (a null id is rejected), and an empty task emoji is a null.
            let dict = try json(body)
            let tasks = try #require(dict["tasks"] as? [[String: Any]])
            #expect(tasks[0]["id"] as? String == "t2")
            #expect(tasks[1]["id"] as? String == "t1")
            #expect(tasks[2]["id"] == nil)
            #expect(tasks[2]["emoji"] is NSNull)
        }

        @Test func patchSendsExplicitNulls() throws {
            var state = RoutineFormLogic.seed(from: routine())
            state.emoji = ""  // cleared -> literal null, not an omitted key
            let dict = try json(RoutineFormLogic.patchBody(state))
            #expect(dict["emoji"] is NSNull)
            #expect(dict["byWeekday"] is NSNull)  // all seven = daily = null
            #expect(dict["windowStart"] as? String == "06:00")
            #expect(dict["assigneeIds"] as? [String] == ["m1"])

            state.byWeekday = [.mo, .fr]
            let scheduled = try json(RoutineFormLogic.patchBody(state))
            #expect(scheduled["byWeekday"] as? [String] == ["mo", "fr"])
        }

        @Test func createBodySendsNilWeekdaysWhenDaily() {
            var state = RoutineFormLogic.State()
            state.title = "Evening"
            state.assigneeIds = ["m2", "m1"]
            state.tasks = [RoutineFormLogic.TaskRow(title: "Tidy up", emoji: "🧸", stars: 1)]
            let body = RoutineFormLogic.createBody(state)
            #expect(body.byWeekday == nil)
            #expect(body.assigneeIds == ["m1", "m2"])
            #expect(body.tasks?.count == 1)
            #expect(body.tasks?.first?.emoji == "🧸")
        }

        @Test func presetMatching() {
            #expect(RoutineFormLogic.Preset.matching(start: "06:00", end: "12:00") == .morning)
            #expect(RoutineFormLogic.Preset.matching(start: "12:00", end: "18:00") == .afternoon)
            #expect(RoutineFormLogic.Preset.matching(start: "18:00", end: "23:59") == .evening)
            #expect(RoutineFormLogic.Preset.matching(start: "07:00", end: "12:00") == .custom)
        }

        @Test func validateRules() {
            var state = RoutineFormLogic.State()
            state.title = "Morning"
            state.assigneeIds = ["m1"]
            #expect(RoutineFormLogic.validate(state) == nil)

            state.windowStart = "12:00"  // window must be ordered
            #expect(RoutineFormLogic.validate(state) == "The window must end after it starts.")
            state.windowStart = "06:00"

            state.byWeekday = []
            #expect(RoutineFormLogic.validate(state) == "Pick at least one day.")
            state.byWeekday = [.mo]

            // The server 422s empty assignees (invalid_assignees) — mirrored here.
            state.assigneeIds = []
            #expect(RoutineFormLogic.validate(state) == "Pick at least one member.")
            state.assigneeIds = ["m1"]

            state.tasks = [RoutineFormLogic.TaskRow(title: "  ")]
            #expect(RoutineFormLogic.validate(state) == "Every task needs a title.")
        }

        // R4 Every seeded field has to move the dirty needle — including a task
        // rename, a reorder and a delete, which live inside the tasks array.
        @Test func dirtyTracksEveryEditedField() {
            let original = RoutineFormLogic.seed(from: routine(tasks: [
                serverTask("t1", "Brush teeth", sortOrder: 0),
                serverTask("t2", "Dress", sortOrder: 1),
            ]))
            #expect(RoutineFormLogic.isDirty(original, original: original) == false)

            var edited = original
            edited.title += "!"
            #expect(RoutineFormLogic.isDirty(edited, original: original))

            edited = original
            edited.emoji = ""
            #expect(RoutineFormLogic.isDirty(edited, original: original))

            edited = original
            edited.windowStart = "07:00"
            #expect(RoutineFormLogic.isDirty(edited, original: original))

            edited = original
            edited.byWeekday = [.mo]
            #expect(RoutineFormLogic.isDirty(edited, original: original))

            edited = original
            edited.assigneeIds = ["m2"]
            #expect(RoutineFormLogic.isDirty(edited, original: original))

            edited = original
            edited.tasks[0].title = "Brush teeth well"
            #expect(RoutineFormLogic.isDirty(edited, original: original))

            edited = original
            edited.tasks.swapAt(0, 1)  // reorder IS a change (array order = sortOrder)
            #expect(RoutineFormLogic.isDirty(edited, original: original))

            edited = original
            edited.tasks.removeLast()
            #expect(RoutineFormLogic.isDirty(edited, original: original))

            edited = original
            edited.tasks.append(RoutineFormLogic.TaskRow(title: "Pack bag"))
            #expect(RoutineFormLogic.isDirty(edited, original: original))
        }

        // R14 zod paths reach three levels deep here (tasks.0.title).
        @Test func zodCodesNeverReachTheFamily() {
            #expect(RoutineFormLogic.friendlyError("validation_failed (tasks.0.title)")
                == "One of the tasks isn't valid — check its title, emoji and stars.")
            #expect(RoutineFormLogic.friendlyError("validation_failed (emoji)")
                == "That emoji isn't one the server accepts — pick another, or none.")
            #expect(RoutineFormLogic.friendlyError("validation_failed (windowEnd)")
                == "The window must end after it starts.")
            #expect(RoutineFormLogic.friendlyError("validation_failed (sortOrder)")
                == "Something about the routine isn't valid. Check the fields and try again.")
            #expect(RoutineFormLogic.friendlyError("e_teapot")
                == "That didn't work. Check the connection and try again.")
            #expect(RoutineFormLogic.friendlyError(nil)
                == "That didn't work. Check the connection and try again.")
        }
    }
}
