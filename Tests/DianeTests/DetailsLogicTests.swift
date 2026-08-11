import DianeKit
import Foundation
import Testing

@testable import Diane

@Suite struct DetailsLogicTests {
    // Berlin is UTC+2 in July — offsets make zone bugs visible.
    private static let berlin = TimeZone(identifier: "Europe/Berlin")!
    private static let newYork = TimeZone(identifier: "America/New_York")!

    // MARK: Event when-line

    @Suite struct WhenLine {
        private func timed(_ startsAt: String?, _ endsAt: String?) -> Components.Schemas.EventOccurrence {
            .init(id: "o", eventId: "e", calendarId: "c", summary: "Event", allDay: false, startsAt: startsAt, endsAt: endsAt)
        }

        private func allDay(_ startDate: String, _ endDate: String?) -> Components.Schemas.EventOccurrence {
            .init(id: "o", eventId: "e", calendarId: "c", summary: "Event", allDay: true, startDate: startDate, endDate: endDate)
        }

        @Test func timedSameDay() {
            let line = EventDetailLogic.whenLine(
                for: timed("2026-07-27T15:00:00Z", "2026-07-27T16:00:00Z"),
                timeZone: DetailsLogicTests.berlin
            )
            #expect(line == "17:00–18:00 · Mon, Jul 27")
        }

        @Test func timedUsesHouseholdZoneNotUTC() {
            let line = EventDetailLogic.whenLine(
                for: timed("2026-07-27T15:00:00Z", "2026-07-27T16:00:00Z"),
                timeZone: DetailsLogicTests.newYork
            )
            #expect(line == "11:00–12:00 · Mon, Jul 27")
        }

        // The zone decides the DAY too: 23:30Z Monday is already Tuesday in Berlin.
        @Test func timedZoneShiftsTheDayLabel() {
            let line = EventDetailLogic.whenLine(
                for: timed("2026-07-27T22:30:00Z", "2026-07-27T23:00:00Z"),
                timeZone: DetailsLogicTests.berlin
            )
            #expect(line == "00:30–01:00 · Tue, Jul 28")
        }

        @Test func timedCrossDayShowsBothDays() {
            let line = EventDetailLogic.whenLine(
                for: timed("2026-07-27T21:30:00Z", "2026-07-28T07:00:00Z"),
                timeZone: DetailsLogicTests.berlin
            )
            #expect(line == "Mon, Jul 27 23:30 – Tue, Jul 28 09:00")
        }

        @Test func timedWithoutEnd() {
            let line = EventDetailLogic.whenLine(
                for: timed("2026-07-27T15:00:00Z", nil),
                timeZone: DetailsLogicTests.berlin
            )
            #expect(line == "17:00 · Mon, Jul 27")
        }

        @Test func timedFractionalSecondsParse() {
            let line = EventDetailLogic.whenLine(
                for: timed("2026-07-27T15:00:00.000Z", "2026-07-27T16:00:00.000Z"),
                timeZone: DetailsLogicTests.berlin
            )
            #expect(line == "17:00–18:00 · Mon, Jul 27")
        }

        @Test func timedWithoutStartIsEmpty() {
            #expect(EventDetailLogic.whenLine(for: timed(nil, nil), timeZone: DetailsLogicTests.berlin) == "")
        }

        // Wire endDate is END-EXCLUSIVE: [Jul 27, Jul 28) is a single day.
        @Test func allDaySingleFromExclusiveEnd() {
            let line = EventDetailLogic.whenLine(for: allDay("2026-07-27", "2026-07-28"), timeZone: DetailsLogicTests.berlin)
            #expect(line == "All day · Mon, Jul 27")
        }

        @Test func allDaySingleWithoutEnd() {
            let line = EventDetailLogic.whenLine(for: allDay("2026-07-27", nil), timeZone: DetailsLogicTests.berlin)
            #expect(line == "All day · Mon, Jul 27")
        }

        // [Jul 27, Jul 30) reads as the human range Jul 27 – Jul 29.
        @Test func allDayRangeShownInclusive() {
            let line = EventDetailLogic.whenLine(for: allDay("2026-07-27", "2026-07-30"), timeZone: DetailsLogicTests.berlin)
            #expect(line == "All day · Mon, Jul 27 – Wed, Jul 29")
        }

        @Test func allDayRangeCrossesMonths() {
            let line = EventDetailLogic.whenLine(for: allDay("2026-07-30", "2026-08-02"), timeZone: DetailsLogicTests.berlin)
            #expect(line == "All day · Thu, Jul 30 – Sat, Aug 1")
        }

        // Degenerate wire shape (end == start) must not render a backwards range.
        @Test func allDayDegenerateEndEqualsStart() {
            let line = EventDetailLogic.whenLine(for: allDay("2026-07-27", "2026-07-27"), timeZone: DetailsLogicTests.berlin)
            #expect(line == "All day · Mon, Jul 27")
        }
    }

    // MARK: Event recurrence humanizer

    @Suite struct RecurrenceLine {
        private typealias Recurrence = Components.Schemas.EventOccurrence.RecurrencePayload

        @Test func nilRecurrenceIsNil() {
            #expect(EventDetailLogic.recurrenceLine(nil) == nil)
        }

        @Test func daily() {
            #expect(EventDetailLogic.recurrenceLine(.init(freq: .daily)) == "Repeats daily")
        }

        @Test func explicitIntervalOneReadsLikeAbsent() {
            #expect(EventDetailLogic.recurrenceLine(.init(freq: .daily, interval: 1)) == "Repeats daily")
        }

        @Test func dailyWithInterval() {
            #expect(EventDetailLogic.recurrenceLine(.init(freq: .daily, interval: 3)) == "Repeats every 3 days")
        }

        @Test func weeklyBare() {
            #expect(EventDetailLogic.recurrenceLine(.init(freq: .weekly)) == "Repeats weekly")
        }

        @Test func weeklyDaysSortedIntoWeekOrder() {
            #expect(
                EventDetailLogic.recurrenceLine(.init(freq: .weekly, byWeekday: [.we, .mo]))
                    == "Repeats weekly on Mo, We"
            )
        }

        @Test func weeklyEmptyDaySetReadsBare() {
            #expect(EventDetailLogic.recurrenceLine(.init(freq: .weekly, byWeekday: [])) == "Repeats weekly")
        }

        @Test func weeklyIntervalDaysAndUntil() {
            #expect(
                EventDetailLogic.recurrenceLine(
                    .init(freq: .weekly, interval: 2, byWeekday: [.mo, .we], until: "2026-08-30")
                ) == "Repeats every 2 weeks on Mo, We · until Aug 30"
            )
        }

        @Test func weeklyAllSevenDays() {
            #expect(
                EventDetailLogic.recurrenceLine(
                    .init(freq: .weekly, byWeekday: [.su, .sa, .fr, .th, .we, .tu, .mo])
                ) == "Repeats weekly on Mo, Tu, We, Th, Fr, Sa, Su"
            )
        }

        @Test func monthlyBare() {
            #expect(EventDetailLogic.recurrenceLine(.init(freq: .monthly)) == "Repeats monthly")
        }

        @Test func monthlyOnDay() {
            #expect(
                EventDetailLogic.recurrenceLine(.init(freq: .monthly, byMonthDay: 15))
                    == "Repeats monthly on day 15"
            )
        }

        @Test func monthlyIntervalOnDay() {
            #expect(
                EventDetailLogic.recurrenceLine(.init(freq: .monthly, interval: 2, byMonthDay: 1))
                    == "Repeats every 2 months on day 1"
            )
        }

        @Test func yearly() {
            #expect(EventDetailLogic.recurrenceLine(.init(freq: .yearly)) == "Repeats yearly")
        }

        @Test func yearlyWithInterval() {
            #expect(EventDetailLogic.recurrenceLine(.init(freq: .yearly, interval: 2)) == "Repeats every 2 years")
        }

        @Test func untilOnDaily() {
            #expect(
                EventDetailLogic.recurrenceLine(.init(freq: .daily, until: "2026-12-24"))
                    == "Repeats daily · until Dec 24"
            )
        }
    }

    // MARK: Synced split + date helper

    @Test func calendarWithAccountIsSynced() {
        let synced = Components.Schemas.Calendar(
            id: "c1", accountId: "a1", displayName: "iCloud", enabled: true,
            writable: false, eventCount: 3, createdAt: "2026-01-01T00:00:00Z"
        )
        let local = Components.Schemas.Calendar(
            id: "c2", accountId: nil, displayName: "Family", enabled: true,
            writable: true, eventCount: 3, createdAt: "2026-01-01T00:00:00Z"
        )
        #expect(EventDetailLogic.isSynced(synced))
        #expect(!EventDetailLogic.isSynced(local))
    }

    @Test func mediumDateFallsBackToRawOnGarbage() {
        #expect(EventDetailLogic.mediumDate("2026-08-30") == "Aug 30")
        #expect(EventDetailLogic.mediumDate("soon") == "soon")
        #expect(EventDetailLogic.mediumDate("2026-13-05") == "2026-13-05")
    }

    // MARK: R2 — "whole family" on the wire

    @Suite struct WholeFamilyMembers {
        // R2: an empty selection is [], NOT nil — verified live, {} → 422.
        @Test func emptySelectionIsAnEmptyArray() {
            #expect(EventDetailLogic.memberIdsPayload(selected: [], order: ["a", "b"]) == [])
        }

        @Test func picksKeepDisplayOrderAndDropUnknownIds() {
            #expect(
                EventDetailLogic.memberIdsPayload(selected: ["b", "a", "ghost"], order: ["a", "b", "c"])
                    == ["a", "b"]
            )
        }

        // R2: the bug was the ENCODING — the synthesized Codable omits a nil,
        // so the required key never reached the server.
        @Test func wholeFamilyBodyCarriesTheRequiredKey() throws {
            let body = Components.Schemas.EventMembersUpdate(
                memberIds: EventDetailLogic.memberIdsPayload(selected: [], order: ["a"])
            )
            let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
            #expect(json == #"{"memberIds":[]}"#)
        }

        // R2: this exact body is the live 422 — the fix must never send it.
        @Test func nilMemberIdsEncodesToTheRejectedEmptyBody() throws {
            let json = String(
                decoding: try JSONEncoder().encode(Components.Schemas.EventMembersUpdate(memberIds: nil)),
                as: UTF8.self
            )
            #expect(json == "{}")
        }

        @Test func pickedMembersStillTravel() throws {
            let body = Components.Schemas.EventMembersUpdate(
                memberIds: EventDetailLogic.memberIdsPayload(selected: ["a"], order: ["a", "b"])
            )
            let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
            #expect(json == #"{"memberIds":["a"]}"#)
        }
    }

    // MARK: R9 — actions don't wait on the calendar fetch

    @Suite struct EventActions {
        private func calendar(accountId: String?) -> Components.Schemas.Calendar {
            .init(
                id: "c", accountId: accountId, displayName: "Family", enabled: true,
                writable: true, eventCount: 1, createdAt: "2026-01-01T00:00:00Z"
            )
        }

        // R9: still loading (or the list failed) — assume editable, the 409 rules.
        @Test func unknownCalendarStillOffersEditAndDelete() {
            #expect(EventDetailLogic.offersContentActions(for: nil))
        }

        @Test func localCalendarOffersEditAndDelete() {
            #expect(EventDetailLogic.offersContentActions(for: calendar(accountId: nil)))
        }

        @Test func syncedCalendarShowsTheReadOnlyNoteInstead() {
            #expect(!EventDetailLogic.offersContentActions(for: calendar(accountId: "a1")))
        }
    }

    // MARK: Chore status + schedule

    @Suite struct ChoreLines {
        private func occurrence(
            status: Components.Schemas.ChoreOccurrence.StatusPayload = .open,
            late: Bool = false
        ) -> Components.Schemas.ChoreOccurrence {
            .init(id: "o", choreId: "ch", title: "Dishes", starValue: 2, upForGrabs: false, status: status, late: late)
        }

        @Test func openStatus() {
            #expect(ChoreDetailLogic.status(of: occurrence()) == .open)
        }

        @Test func lateStatus() {
            #expect(ChoreDetailLogic.status(of: occurrence(late: true)) == .late)
        }

        @Test func completedWinsOverLate() {
            #expect(ChoreDetailLogic.status(of: occurrence(status: .completed, late: true)) == .done)
        }

        @Test func doneLineFull() {
            let line = ChoreDetailLogic.doneLine(
                byName: "Ann", completedAt: "2026-07-27T15:42:00Z", timeZone: DetailsLogicTests.berlin
            )
            #expect(line == "Done ✓ by Ann · 17:42")
        }

        @Test func doneLineTimeInHouseholdZone() {
            let line = ChoreDetailLogic.doneLine(
                byName: "Ann", completedAt: "2026-07-27T15:42:00Z", timeZone: DetailsLogicTests.newYork
            )
            #expect(line == "Done ✓ by Ann · 11:42")
        }

        @Test func doneLineWithoutName() {
            let line = ChoreDetailLogic.doneLine(
                byName: nil, completedAt: "2026-07-27T15:42:00.500Z", timeZone: DetailsLogicTests.berlin
            )
            #expect(line == "Done ✓ · 17:42")
        }

        @Test func doneLineUnparseableInstantDropsTime() {
            #expect(ChoreDetailLogic.doneLine(byName: "Ann", completedAt: "yesterday", timeZone: DetailsLogicTests.berlin) == "Done ✓ by Ann")
        }

        @Test func doneLineBare() {
            #expect(ChoreDetailLogic.doneLine(byName: nil, completedAt: nil, timeZone: DetailsLogicTests.berlin) == "Done ✓")
        }

        private let today = "2026-07-27"

        @Test func scheduleAnytime() {
            #expect(ChoreDetailLogic.scheduleLine(dueDate: nil, dueMode: nil, dueTime: nil, today: today) == "Anytime")
        }

        @Test func scheduleDueTodayWithTime() {
            #expect(
                ChoreDetailLogic.scheduleLine(dueDate: "2026-07-27", dueMode: .on, dueTime: "18:00", today: today)
                    == "Due today at 18:00"
            )
        }

        @Test func scheduleDueTodayBare() {
            #expect(
                ChoreDetailLogic.scheduleLine(dueDate: "2026-07-27", dueMode: nil, dueTime: nil, today: today)
                    == "Due today"
            )
        }

        @Test func scheduleFutureDate() {
            #expect(
                ChoreDetailLogic.scheduleLine(dueDate: "2026-08-15", dueMode: .on, dueTime: nil, today: today)
                    == "Due Aug 15, 2026"
            )
        }

        @Test func schedulePastDateKeepsTheDate() {
            #expect(
                ChoreDetailLogic.scheduleLine(dueDate: "2026-07-20", dueMode: nil, dueTime: "18:00", today: today)
                    == "Due Jul 20, 2026 at 18:00"
            )
        }

        // "By a date" reads as a deadline even when it lands today.
        @Test func scheduleByDeadline() {
            #expect(
                ChoreDetailLogic.scheduleLine(dueDate: "2026-08-15", dueMode: .by, dueTime: nil, today: today)
                    == "By Aug 15, 2026"
            )
            #expect(
                ChoreDetailLogic.scheduleLine(dueDate: "2026-07-27", dueMode: .by, dueTime: "18:00", today: today)
                    == "By Jul 27, 2026 at 18:00"
            )
        }
    }

    // MARK: R11 — the read-only chore sheet adopts the server's row

    @Suite struct ChoreResync {
        private func occurrence(
            id: String,
            status: Components.Schemas.ChoreOccurrence.StatusPayload = .open,
            claimedBy: String? = nil,
            completedBy: String? = nil,
            completedAt: String? = nil
        ) -> Components.Schemas.ChoreOccurrence {
            .init(
                id: id, choreId: "ch", title: "Dishes", starValue: 2, upForGrabs: true,
                status: status, late: false, claimedByMemberId: claimedBy,
                completedByMemberId: completedBy, completedAt: completedAt
            )
        }

        // R11: the sheet shows what the SERVER has, not the snapshot it opened
        // with — the synthetic id is the handle.
        @Test func takesTheServersRowWhenItIsStillOnTheBoard() {
            let fresh = occurrence(id: "ch:pool:2026-07-27", claimedBy: "ann")
            let outcome = ChoreDetailLogic.resync(
                id: "ch:pool:2026-07-27",
                from: [occurrence(id: "other:pool:2026-07-27"), fresh]
            )
            #expect(outcome == .replace(fresh))
            // Someone claimed it while the sheet was open; the People block says so.
            guard case .replace(let row) = outcome else { return }
            #expect(row.claimedByMemberId == "ann")
        }

        // R11: no row with our handle = there's nothing left to show.
        @Test func reportsGoneWhenTheRowLeftTheBoard() {
            #expect(
                ChoreDetailLogic.resync(id: "ch:pool:2026-07-27", from: [occurrence(id: "ch:pool:2026-07-28")])
                    == .gone
            )
        }

        @Test func emptyBoardIsGone() {
            #expect(ChoreDetailLogic.resync(id: "ch:pool:2026-07-27", from: []) == .gone)
        }

        // A row completed elsewhere comes back done — the status line follows.
        @Test func adoptsACompletedRow() {
            let done = occurrence(
                id: "ch:pool:2026-07-27", status: .completed,
                completedBy: "ann", completedAt: "2026-07-27T15:42:00Z"
            )
            guard case .replace(let row) = ChoreDetailLogic.resync(id: done.id, from: [done]) else {
                Issue.record("expected the refreshed row")
                return
            }
            #expect(ChoreDetailLogic.status(of: row) == .done)
            #expect(
                ChoreDetailLogic.doneLine(
                    byName: "Ann", completedAt: row.completedAt, timeZone: DetailsLogicTests.berlin
                ) == "Done ✓ by Ann · 17:42"
            )
        }
    }

    // MARK: Routine schedule + stale board

    @Suite struct RoutineLines {
        @Test func nilWeekdaysIsEveryDay() {
            #expect(RoutineDetailLogic.weekdaySummary(nil) == "Every day")
        }

        @Test func emptyWeekdaysIsEveryDay() {
            #expect(RoutineDetailLogic.weekdaySummary([]) == "Every day")
        }

        @Test func allSevenWeekdaysIsEveryDay() {
            #expect(RoutineDetailLogic.weekdaySummary([.mo, .tu, .we, .th, .fr, .sa, .su]) == "Every day")
        }

        @Test func weekdaysSortIntoWeekOrder() {
            #expect(RoutineDetailLogic.weekdaySummary([.fr, .mo, .we]) == "Mo, We, Fr")
        }

        @Test func singleWeekday() {
            #expect(RoutineDetailLogic.weekdaySummary([.su]) == "Su")
        }

        // D04: actions must never POST a board date that isn't household-today.
        @Test func boardFromAnotherDayIsStale() {
            #expect(RoutineDetailLogic.isStale(boardDate: "2026-07-26", today: "2026-07-27"))
        }

        @Test func todaysBoardIsNotStale() {
            #expect(!RoutineDetailLogic.isStale(boardDate: "2026-07-27", today: "2026-07-27"))
        }
    }

    // MARK: R12 — per-task attribution

    @Suite struct RoutineTaskAttribution {
        private func attribution(
            status: Components.Schemas.RoutineBoardEntry.TasksPayloadPayload.StatusPayload,
            byName: String? = nil,
            isMe: Bool = false,
            completedAt: String? = nil,
            timeZone: TimeZone = DetailsLogicTests.berlin
        ) -> String? {
            RoutineDetailLogic.taskAttribution(
                status: status, byName: byName, isMe: isMe, completedAt: completedAt, timeZone: timeZone
            )
        }

        // R12: an open task has nothing to attribute.
        @Test func openTaskHasNoLine() {
            #expect(attribution(status: .open, byName: "Ada", completedAt: "2026-07-27T05:12:00Z") == nil)
        }

        // R12: someone else did it — the whole point of the finding.
        @Test func someoneElseDidIt() {
            #expect(
                attribution(status: .completed, byName: "Ada", completedAt: "2026-07-27T05:12:00Z")
                    == "by Ada · 07:12"
            )
        }

        // R12: and it reads naturally when it was me.
        @Test func iDidIt() {
            #expect(
                attribution(status: .completed, byName: "Marta", isMe: true, completedAt: "2026-07-27T05:12:00Z")
                    == "by you · 07:12"
            )
        }

        @Test func timeIsHouseholdLocalNotUTC() {
            #expect(
                attribution(
                    status: .completed, byName: "Ada", completedAt: "2026-07-27T05:12:00Z",
                    timeZone: DetailsLogicTests.newYork
                ) == "by Ada · 01:12"
            )
        }

        @Test func fractionalSecondsParse() {
            #expect(
                attribution(status: .completed, byName: "Ada", completedAt: "2026-07-27T05:12:00.250Z")
                    == "by Ada · 07:12"
            )
        }

        // An unknown member id resolves to no name — the time still shows.
        @Test func unknownCompleterKeepsTheTime() {
            #expect(attribution(status: .completed, completedAt: "2026-07-27T05:12:00Z") == "at 07:12")
        }

        @Test func unparseableInstantDropsTheTime() {
            #expect(attribution(status: .completed, byName: "Ada", completedAt: "this morning") == "by Ada")
        }

        @Test func nothingToAttributeIsNil() {
            #expect(attribution(status: .completed) == nil)
        }

        // R12: skips carry the same fields — the caption says so.
        @Test func skippedNamesTheSkipper() {
            #expect(
                attribution(status: .skipped, byName: "Ada", completedAt: "2026-07-27T05:12:00Z")
                    == "Skipped by Ada · 07:12"
            )
            #expect(
                attribution(status: .skipped, byName: "Ada", isMe: true, completedAt: "2026-07-27T05:12:00Z")
                    == "Skipped by you · 07:12"
            )
        }

        @Test func bareSkipStillReadsAsSkipped() {
            #expect(attribution(status: .skipped) == "Skipped")
        }
    }
}
