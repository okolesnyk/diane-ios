import DianeKit
import Foundation
import Testing

@testable import Diane

@Suite struct TodayLogicTests {
    // MARK: Fixtures

    private func chore(
        id: String,
        status: Components.Schemas.ChoreOccurrence.StatusPayload = .open,
        late: Bool = false,
        assignee: String? = nil,
        claimedBy: String? = nil,
        completedBy: String? = nil
    ) -> Components.Schemas.ChoreOccurrence {
        .init(
            id: id, choreId: "chore", title: id, emoji: nil, notes: nil,
            starValue: 2, upForGrabs: assignee == nil && claimedBy == nil,
            dueDate: nil, dueMode: nil, dueTime: nil, status: status, late: late,
            assigneeMemberId: assignee, claimedByMemberId: claimedBy,
            completedByMemberId: completedBy, completedAt: nil
        )
    }

    private func event(
        id: String,
        allDay: Bool = false,
        startsAt: String? = nil,
        summary: String = "Event"
    ) -> Components.Schemas.EventOccurrence {
        .init(
            id: id, eventId: "ev", calendarId: "cal", summary: summary,
            location: nil, allDay: allDay, startsAt: startsAt, endsAt: nil,
            startDate: nil, endDate: nil, memberIds: nil, color: nil, recurrence: nil
        )
    }

    private func entry(
        member: String,
        start: String,
        end: String,
        statuses: [Components.Schemas.RoutineBoardEntry.TasksPayloadPayload.StatusPayload] = [],
        streak: Int = 0
    ) -> Components.Schemas.RoutineBoardEntry {
        .init(
            routineId: "r-\(member)-\(start)", title: "Routine", emoji: nil,
            windowStart: start, windowEnd: end, memberId: member,
            complete: false, streak: streak,
            tasks: statuses.enumerated().map {
                .init(
                    taskId: "t\($0.offset)", title: "Task", emoji: nil, starValue: 1,
                    status: $0.element, completedByMemberId: nil, completedAt: nil
                )
            }
        )
    }

    private let newYork = TimeZone(identifier: "America/New_York")!
    private let chicago = TimeZone(identifier: "America/Chicago")!

    // MARK: Today string

    @Test func dateStringUsesTheLocalCalendarDayNotUTC() {
        // 2026-07-28T03:30Z is still July 27 in New York (UTC-4).
        let instant = Date(timeIntervalSince1970: 1_785_209_400)
        #expect(TodayLogic.dateString(for: instant, timeZone: newYork) == "2026-07-27")
        #expect(TodayLogic.dateString(for: instant, timeZone: TimeZone(identifier: "UTC")!) == "2026-07-28")
    }

    // D02: "today" is the HOUSEHOLD's day, not the device's — at midnight in
    // New York the Chicago household is still on yesterday.
    @Test func todayFollowsTheHouseholdFrameNotTheDevice() {
        // 2026-07-28T04:00Z = Jul 28 00:00 New York = Jul 27 23:00 Chicago.
        let instant = Date(timeIntervalSince1970: 1_785_211_200)
        #expect(TodayLogic.dateString(for: instant, timeZone: chicago) == "2026-07-27")
        #expect(TodayLogic.dateString(for: instant, timeZone: newYork) == "2026-07-28")
        #expect(TodayLogic.nextDayString(for: instant, timeZone: chicago) == "2026-07-28")
    }

    @Test func dateStringZeroPadsMonthAndDay() {
        // 2026-01-05T12:00Z.
        let instant = Date(timeIntervalSince1970: 1_767_614_400)
        #expect(TodayLogic.dateString(for: instant, timeZone: TimeZone(identifier: "UTC")!) == "2026-01-05")
    }

    // /events is end-EXCLUSIVE [from, to) — "today" must query to=tomorrow,
    // including across month and year boundaries.
    @Test func nextDayStringRollsOverMonthAndYear() {
        let utc = TimeZone(identifier: "UTC")!
        // 2026-07-28T03:30Z: tomorrow differs by zone.
        let instant = Date(timeIntervalSince1970: 1_785_209_400)
        #expect(TodayLogic.nextDayString(for: instant, timeZone: newYork) == "2026-07-28")
        #expect(TodayLogic.nextDayString(for: instant, timeZone: utc) == "2026-07-29")
        // 2026-12-31T12:00Z → 2027-01-01.
        let yearEnd = Date(timeIntervalSince1970: 1_798_718_400)
        #expect(TodayLogic.nextDayString(for: yearEnd, timeZone: utc) == "2027-01-01")
    }

    // MARK: Event sorting + time label

    @Test func eventsSortAllDayFirstThenTimedByStart() {
        let sorted = TodayLogic.sortedEvents([
            event(id: "late", startsAt: "2026-07-27T18:00:00Z"),
            event(id: "fair", allDay: true),
            event(id: "early", startsAt: "2026-07-27T08:00:00Z"),
            event(id: "trip", allDay: true),
        ])
        #expect(sorted.map(\.id) == ["fair", "trip", "early", "late"])
    }

    @Test func timedTiesBreakBySummary() {
        let sorted = TodayLogic.sortedEvents([
            event(id: "b", startsAt: "2026-07-27T08:00:00Z", summary: "Swim"),
            event(id: "a", startsAt: "2026-07-27T08:00:00Z", summary: "Piano"),
        ])
        #expect(sorted.map(\.id) == ["a", "b"])
    }

    @Test func timeLabelRendersTheInstantInLocalTime() {
        #expect(TodayLogic.timeLabel("2026-07-27T18:30:00Z", timeZone: newYork) == "14:30")
        #expect(TodayLogic.timeLabel(nil, timeZone: newYork) == nil)
        #expect(TodayLogic.timeLabel("not-a-date", timeZone: newYork) == nil)
    }

    // The api emits fractional seconds; the default ISO8601 parser rejects
    // them, which rendered every event time as "—" (caught live in M9).
    @Test func timeLabelAcceptsFractionalSeconds() {
        #expect(TodayLogic.timeLabel("2026-07-27T22:00:00.000Z", timeZone: newYork) == "18:00")
    }

    // MARK: Chore partitioning

    @Test func choreSectionsSplitMinePoolAndCompleted() {
        let sections = TodayLogic.choreSections([
            chore(id: "assigned-me", assignee: "me"),
            chore(id: "claimed-me", assignee: "sis", claimedBy: "me"),
            chore(id: "sis-own", assignee: "sis"),
            chore(id: "claimed-away", assignee: "me", claimedBy: "sis"),
            chore(id: "pool"),
            chore(id: "done-me", status: .completed, assignee: "me", completedBy: "me"),
            chore(id: "done-pool-by-me", status: .completed, completedBy: "me"),
            chore(id: "done-sis", status: .completed, assignee: "sis", completedBy: "sis"),
        ], me: "me")

        #expect(sections.mine.map(\.id) == ["assigned-me", "claimed-me"])
        #expect(sections.pool.map(\.id) == ["pool"])
        #expect(sections.completed.map(\.id) == ["done-me", "done-pool-by-me"])
        #expect(!sections.isEmpty)
    }

    // D06: completed rows belong to their OWNER — Mom checking off my chore
    // keeps it on MY board; me completing sis's chore stays on HER board.
    // Pool rows (no owner) belong to their completer.
    @Test func completedRowsAttributeToOwnerNotCompleter() {
        let sections = TodayLogic.choreSections([
            chore(id: "mine-by-mom", status: .completed, assignee: "me", completedBy: "mom"),
            chore(id: "sis-by-me", status: .completed, assignee: "sis", completedBy: "me"),
            chore(id: "claimed-sis-by-me", status: .completed, claimedBy: "sis", completedBy: "me"),
            chore(id: "pool-by-me", status: .completed, completedBy: "me"),
            chore(id: "pool-by-sis", status: .completed, completedBy: "sis"),
        ], me: "me")
        #expect(sections.completed.map(\.id) == ["mine-by-mom", "pool-by-me"])
    }

    // D06: household-facing "by <name>" note only when a DIFFERENT member
    // completed an owner's row.
    @Test func completedByNoteNamesTheOtherCompleter() {
        let names = ["mom": "Mom", "me": "Ben"]
        let byMom = chore(id: "c", status: .completed, assignee: "me", completedBy: "mom")
        #expect(TodayLogic.completedByNote(byMom, names: names) == "by Mom")
        let byMe = chore(id: "c", status: .completed, assignee: "me", completedBy: "me")
        #expect(TodayLogic.completedByNote(byMe, names: names) == nil)
        // Pool row: completer IS the owner-of-record, no note.
        let pool = chore(id: "c", status: .completed, completedBy: "me")
        #expect(TodayLogic.completedByNote(pool, names: names) == nil)
        // Open rows and unknown names stay silent.
        let open = chore(id: "c", assignee: "me")
        #expect(TodayLogic.completedByNote(open, names: names) == nil)
        let unknown = chore(id: "c", status: .completed, assignee: "me", completedBy: "dad")
        #expect(TodayLogic.completedByNote(unknown, names: names) == nil)
    }

    @Test func lateFlagSurvivesPartitioningAndEmptyIsEmpty() {
        let sections = TodayLogic.choreSections([chore(id: "overdue", late: true, assignee: "me")], me: "me")
        #expect(sections.mine.first?.late == true)
        #expect(TodayLogic.choreSections([chore(id: "sis", assignee: "sis")], me: "me").isEmpty)
    }

    @Test func ownerPrefersClaimerOverAssignee() {
        #expect(TodayLogic.owner(of: chore(id: "c", assignee: "a", claimedBy: "b")) == "b")
        #expect(TodayLogic.owner(of: chore(id: "c", assignee: "a")) == "a")
        #expect(TodayLogic.owner(of: chore(id: "c")) == nil)
    }

    // MARK: Routine windows

    // D26: END-INCLUSIVE like the web kiosk — "until 7:30" counts AT 7:30.
    @Test func windowIsStartAndEndInclusive() {
        #expect(TodayLogic.windowContains(clock: 6 * 60, start: "06:00", end: "12:00"))
        #expect(TodayLogic.windowContains(clock: 11 * 60 + 59, start: "06:00", end: "12:00"))
        #expect(TodayLogic.windowContains(clock: 12 * 60, start: "06:00", end: "12:00"))
        #expect(!TodayLogic.windowContains(clock: 12 * 60 + 1, start: "06:00", end: "12:00"))
        #expect(!TodayLogic.windowContains(clock: 5 * 60 + 59, start: "06:00", end: "12:00"))
    }

    // D26: evening presets end 23:59 — the last minute of the day must count.
    @Test func eveningWindowCountsItsFinalMinute() {
        #expect(TodayLogic.windowContains(clock: 23 * 60 + 59, start: "18:00", end: "23:59"))
    }

    @Test func windowCrossingNoonUses24HourClock() {
        // "11:00"–"13:00": a 12-hour-clock comparison would get this wrong.
        #expect(TodayLogic.windowContains(clock: 12 * 60 + 30, start: "11:00", end: "13:00"))
        #expect(TodayLogic.windowContains(clock: 13 * 60, start: "11:00", end: "13:00")) // D26
        #expect(!TodayLogic.windowContains(clock: 13 * 60 + 1, start: "11:00", end: "13:00"))
    }

    @Test func windowEndingBeforeStartWrapsPastMidnight() {
        #expect(TodayLogic.windowContains(clock: 22 * 60, start: "21:00", end: "06:00"))
        #expect(TodayLogic.windowContains(clock: 5 * 60, start: "21:00", end: "06:00"))
        #expect(TodayLogic.windowContains(clock: 6 * 60, start: "21:00", end: "06:00")) // D26
        #expect(!TodayLogic.windowContains(clock: 6 * 60 + 1, start: "21:00", end: "06:00"))
        #expect(!TodayLogic.windowContains(clock: 12 * 60, start: "21:00", end: "06:00"))
    }

    @Test func activeRoutinesKeepOnlyMineInsideTheWindow() {
        let active = TodayLogic.activeRoutines([
            entry(member: "me", start: "06:00", end: "12:00"),
            entry(member: "me", start: "18:00", end: "20:00"),
            entry(member: "sis", start: "06:00", end: "12:00"),
        ], me: "me", clock: 7 * 60)
        #expect(active.map(\.windowStart) == ["06:00"])
        #expect(active.allSatisfy { $0.memberId == "me" })
    }

    @Test func clockMinutesUsesTheGivenTimeZone() {
        // 2026-07-27T18:30Z = 14:30 in New York.
        let instant = Date(timeIntervalSince1970: 1_785_177_000)
        #expect(TodayLogic.clockMinutes(of: instant, timeZone: newYork) == 14 * 60 + 30)
    }

    // D05: the screen feeds the ticking household clock ("HH:mm") into the
    // window filter — at 06:50 the 07:00 routine is absent, at 07:00 present.
    @Test func windowOpeningAppearsOnTheMinuteTick() {
        let board = [entry(member: "me", start: "07:00", end: "08:30")]
        let before = TodayLogic.activeRoutines(board, me: "me", clock: TodayLogic.minutes("06:50") ?? -1)
        let opening = TodayLogic.activeRoutines(board, me: "me", clock: TodayLogic.minutes("07:00") ?? -1)
        #expect(before.isEmpty)
        #expect(opening.count == 1)
    }

    // MARK: Progress, balance, misc

    @Test func progressCountsResolvedTasksLikeTheKiosk() {
        let progress = TodayLogic.progress(of: entry(
            member: "me", start: "06:00", end: "12:00",
            statuses: [.completed, .skipped, .open]
        ))
        #expect(progress.done == 2)
        #expect(progress.total == 3)
    }

    @Test func balanceLookupDefaultsToZero() {
        let balances: [Components.Schemas.StarBalance] = [
            .init(memberId: "me", balance: 7),
            .init(memberId: "sis", balance: 12),
        ]
        #expect(TodayLogic.balance(of: "me", in: balances) == 7)
        #expect(TodayLogic.balance(of: "nobody", in: balances) == 0)
    }

    // D21: the map covers exactly the codes the server emits in the Error
    // body's `error` field; chore_archived never existed server-side.
    @Test func conflictCodesMapToHumanCopy() {
        let generic = TodayLogic.conflictMessage(code: nil)
        #expect(!generic.isEmpty)
        for code in ["not_actionable", "already_claimed", "not_claimable", "already_completed", "insufficient_stars"] {
            #expect(TodayLogic.conflictMessage(code: code) != generic, "\(code) should have curated copy")
        }
        #expect(TodayLogic.conflictMessage(code: "already_claimed").contains("grabbed"))
        #expect(TodayLogic.conflictMessage(code: "insufficient_stars").contains("spent"))
        #expect(TodayLogic.conflictMessage(code: "chore_archived") == generic)
    }

    // D07: dueMode 'by' rows carry a deadline chip so they don't read as
    // due today; 'on' and undated rows show none.
    @Test func deadlineChipOnlyForByModeRows() {
        let posix = Locale(identifier: "en_US_POSIX")
        #expect(TodayLogic.deadlineLabel(dueDate: "2026-08-15", dueMode: .by, locale: posix) == "by Aug 15")
        #expect(TodayLogic.deadlineLabel(dueDate: "2026-01-03", dueMode: .by, locale: posix) == "by Jan 3")
        #expect(TodayLogic.deadlineLabel(dueDate: "2026-08-15", dueMode: .on, locale: posix) == nil)
        #expect(TodayLogic.deadlineLabel(dueDate: nil, dueMode: .by, locale: posix) == nil)
        #expect(TodayLogic.deadlineLabel(dueDate: "garbage", dueMode: .by, locale: posix) == nil)
    }

    // D08: cancellation is lifecycle, not an outage — screens must never
    // map it to a .failed state.
    @Test func taskCancellationIsNotAFailure() {
        #expect(isTaskCancellation(CancellationError()))
        #expect(isTaskCancellation(URLError(.cancelled)))
        #expect(!isTaskCancellation(URLError(.timedOut)))
        #expect(!isTaskCancellation(URLError(.cannotConnectToHost)))
    }

    @Test func actionResultPayloadRoundTripsIntoAnOccurrence() {
        let payload = Components.Schemas.ChoreActionResult.OccurrencePayload(
            id: "occ", choreId: "chore", title: "Dishes", emoji: "🍽️", notes: nil,
            starValue: 3, upForGrabs: false, dueDate: "2026-07-27", dueMode: .on,
            dueTime: nil, status: .completed, late: false,
            assigneeMemberId: "me", claimedByMemberId: nil,
            completedByMemberId: "me", completedAt: "2026-07-27T15:00:00Z"
        )
        let occurrence = TodayLogic.occurrence(from: payload)
        #expect(occurrence.id == "occ")
        #expect(occurrence.status == .completed)
        #expect(occurrence.dueMode == .on)
        #expect(occurrence.starValue == 3)
        #expect(occurrence.completedByMemberId == "me")
    }
}
