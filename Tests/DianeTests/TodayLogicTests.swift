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
        summary: String = "Event",
        memberIds: [String]? = nil
    ) -> Components.Schemas.EventOccurrence {
        .init(
            id: id, eventId: "ev", calendarId: "cal", summary: summary,
            location: nil, allDay: allDay, startsAt: startsAt, endsAt: nil,
            startDate: nil, endDate: nil, memberIds: memberIds, color: nil, recurrence: nil
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

    private func member(
        _ id: String,
        sortOrder: Int,
        name: String? = nil
    ) -> Components.Schemas.Member {
        .init(
            id: id, name: name ?? id, color: "#FF6B6B", avatar: nil, birthday: nil,
            role: .kid, sortOrder: sortOrder, hasPassword: false, hasPasskeys: false,
            passwordResetRequired: false, createdAt: "2026-01-01T00:00:00.000Z"
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

    // R8: my list is MY WHOLE DAY (like every other member's block) — the
    // in-window entries just come first and carry the "Now" flag.
    @Test func myRoutinesShowTheWholeDayWithInWindowFirst() {
        let mine = TodayLogic.myRoutines([
            entry(member: "me", start: "18:00", end: "20:00"),
            entry(member: "sis", start: "06:00", end: "12:00"),
            entry(member: "me", start: "06:00", end: "12:00"),
            entry(member: "me", start: "05:00", end: "06:30"),
        ], me: "me", clock: 6 * 60)
        // Never another member's board.
        #expect(mine.allSatisfy { $0.entry.memberId == "me" })
        // Nothing dropped: the 18:00 routine is still listed, just not "Now".
        #expect(mine.count == 3)
        // In-window first, board order kept inside each group.
        #expect(mine.map(\.entry.windowStart) == ["06:00", "05:00", "18:00"])
        #expect(mine.map(\.isNow) == [true, true, false])
    }

    @Test func clockMinutesUsesTheGivenTimeZone() {
        // 2026-07-27T18:30Z = 14:30 in New York.
        let instant = Date(timeIntervalSince1970: 1_785_177_000)
        #expect(TodayLogic.clockMinutes(of: instant, timeZone: newYork) == 14 * 60 + 30)
    }

    // D05: the screen feeds the ticking household clock ("HH:mm") into the
    // window test — at 06:50 the 07:00 routine is listed but not "Now", at
    // 07:00 it lights up (R8: the tick changes the pill, not the roster).
    @Test func windowOpeningAppearsOnTheMinuteTick() {
        let board = [entry(member: "me", start: "07:00", end: "08:30")]
        let before = TodayLogic.myRoutines(board, me: "me", clock: TodayLogic.minutes("06:50") ?? -1)
        let opening = TodayLogic.myRoutines(board, me: "me", clock: TodayLogic.minutes("07:00") ?? -1)
        #expect(before.map(\.isNow) == [false])
        #expect(opening.map(\.isNow) == [true])
    }

    // MARK: Family hub

    @Test func familyDaysListTheOthersBySortOrderNeverMe() {
        let days = TodayLogic.familyDays(
            members: [member("mom", sortOrder: 2), member("me", sortOrder: 0), member("dad", sortOrder: 1)],
            me: "me", occurrences: [], routines: [], events: []
        )
        #expect(days.map(\.member.id) == ["dad", "mom"])
    }

    @Test func familyDaysBreakSortOrderTiesByName() {
        let days = TodayLogic.familyDays(
            members: [
                member("zoe", sortOrder: 1, name: "Zoe"),
                member("amy", sortOrder: 1, name: "Amy"),
                member("me", sortOrder: 0),
            ],
            me: "me", occurrences: [], routines: [], events: []
        )
        #expect(days.map(\.member.id) == ["amy", "zoe"])
    }

    // D06 matrix reused on the hub: open rows go to their OWNER (claimer
    // beats assignee); done rows count for owner-else-completer; unowned
    // pool rows stay off family blocks — they live in "My day".
    @Test func familyDaysAttributeChoresLikeD06() {
        let days = TodayLogic.familyDays(
            members: [member("me", sortOrder: 0), member("sis", sortOrder: 1)],
            me: "me",
            occurrences: [
                chore(id: "sis-own", assignee: "sis"),
                chore(id: "claimed-by-sis", assignee: "me", claimedBy: "sis"),
                chore(id: "claimed-away", assignee: "sis", claimedBy: "me"),
                chore(id: "pool"),
                chore(id: "done-sis-by-me", status: .completed, assignee: "sis", completedBy: "me"),
                chore(id: "done-pool-by-sis", status: .completed, completedBy: "sis"),
                chore(id: "done-mine", status: .completed, assignee: "me", completedBy: "me"),
            ],
            routines: [],
            events: []
        )
        #expect(days.count == 1)
        #expect(days[0].openChores.map(\.id) == ["sis-own", "claimed-by-sis"])
        #expect(days[0].doneCount == 2)
    }

    // The hub shows the member's WHOLE day — no window cut (that filter is
    // only for MY actionable list); board order kept.
    @Test func familyRoutinesAreTheWholeDayNotWindowCut() {
        let days = TodayLogic.familyDays(
            members: [member("me", sortOrder: 0), member("sis", sortOrder: 1)],
            me: "me",
            occurrences: [],
            routines: [
                entry(member: "sis", start: "06:00", end: "09:00"),
                entry(member: "me", start: "06:00", end: "09:00"),
                entry(member: "sis", start: "18:00", end: "20:00"),
            ],
            events: []
        )
        #expect(days[0].routines.map(\.windowStart) == ["06:00", "18:00"])
        #expect(days[0].routines.allSatisfy { $0.memberId == "sis" })
    }

    @Test func freeDayOnlyWhenTrulyNothing() {
        let days = TodayLogic.familyDays(
            members: [member("me", sortOrder: 0), member("kid", sortOrder: 1), member("mom", sortOrder: 2)],
            me: "me",
            occurrences: [chore(id: "done", status: .completed, assignee: "mom", completedBy: "mom")],
            routines: [],
            events: []
        )
        #expect(days[0].member.id == "kid")
        #expect(days[0].isFree)
        // A "1 done ✓" line is still a day.
        #expect(!days[1].isFree)
        #expect(days[1].doneCount == 1)
    }

    // MARK: Family events (R6)

    // R6: the matrix. A member's events are the ones whose memberIds CONTAINS
    // their id; a multi-member event lands on every one of them; a
    // whole-family event (memberIds nil) belongs to the shared Today section
    // and must NOT be duplicated onto anyone's block; a member with none
    // gets none.
    @Test func familyEventsFollowMemberIdsAndNeverDuplicateWholeFamily() {
        let days = TodayLogic.familyDays(
            members: [
                member("me", sortOrder: 0),
                member("wife", sortOrder: 1),
                member("kid", sortOrder: 2),
                member("gran", sortOrder: 3),
            ],
            me: "me",
            occurrences: [],
            routines: [],
            events: [
                event(id: "dentist", startsAt: "2026-07-27T14:00:00Z", memberIds: ["wife"]),
                event(id: "carpool", startsAt: "2026-07-27T16:00:00Z", memberIds: ["wife", "kid"]),
                event(id: "cookout", allDay: true, memberIds: nil),
                event(id: "mine", startsAt: "2026-07-27T09:00:00Z", memberIds: ["me"]),
            ]
        )
        let byMember = Dictionary(uniqueKeysWithValues: days.map { ($0.member.id, $0.events.map(\.id)) })
        #expect(byMember["wife"] == ["dentist", "carpool"])
        #expect(byMember["kid"] == ["carpool"])
        #expect(byMember["gran"] == [])
        // The whole-family event never reaches a member block.
        #expect(days.allSatisfy { !$0.events.map(\.id).contains("cookout") })
        // And my own events don't leak onto anyone else's.
        #expect(days.allSatisfy { !$0.events.map(\.id).contains("mine") })
    }

    // R6: a member block sorts events like the shared list — all-day first,
    // then by start.
    @Test func familyEventsSortAllDayFirstThenByStart() {
        let days = TodayLogic.familyDays(
            members: [member("me", sortOrder: 0), member("wife", sortOrder: 1)],
            me: "me",
            occurrences: [],
            routines: [],
            events: [
                event(id: "late", startsAt: "2026-07-27T20:00:00Z", memberIds: ["wife"]),
                event(id: "trip", allDay: true, memberIds: ["wife"]),
                event(id: "early", startsAt: "2026-07-27T08:00:00Z", memberIds: ["wife"]),
            ]
        )
        #expect(days[0].events.map(\.id) == ["trip", "early", "late"])
    }

    // R6: the headline bug — "Free day ✨" printed under a member who has
    // appointments. Events are plans; an event alone ends the free day.
    @Test func aMemberWithOnlyAnEventIsNotFree() {
        let days = TodayLogic.familyDays(
            members: [member("me", sortOrder: 0), member("wife", sortOrder: 1), member("gran", sortOrder: 2)],
            me: "me",
            occurrences: [],
            routines: [],
            events: [
                event(id: "yoga", startsAt: "2026-07-27T15:00:00Z", memberIds: ["wife"]),
                event(id: "cookout", allDay: true, memberIds: nil),
            ]
        )
        #expect(days[0].member.id == "wife")
        #expect(!days[0].isFree)
        // Gran only has the whole-family event, which isn't hers to carry.
        #expect(days[1].member.id == "gran")
        #expect(days[1].isFree)
    }

    @Test func memberEventsIgnoreEmptyAndForeignTags() {
        let events = [
            event(id: "hers", memberIds: ["wife"]),
            event(id: "family", memberIds: nil),
            event(id: "nobody", memberIds: []),
        ]
        #expect(TodayLogic.memberEvents(events, member: "wife").map(\.id) == ["hers"])
        #expect(TodayLogic.memberEvents(events, member: "kid").isEmpty)
    }

    // MARK: Sheet payloads (R3)

    // R3: the routine sheet FREEZES the board date it was opened with. A live
    // `boardDate` reload at household midnight would flip RoutineDetailView's
    // `boardDate != today` guard to "fresh" and re-arm task actions against
    // yesterday's snapshot.
    @Test func routineSheetPayloadFreezesTheBoardDate() {
        let opened = "2026-07-26"
        let sheet = TodayView.ActiveSheet.routine(
            entry: entry(member: "me", start: "06:00", end: "09:00"),
            boardDate: opened
        )
        guard case .routine(let payloadEntry, let frozen) = sheet else {
            Issue.record("expected the routine case")
            return
        }
        #expect(frozen == opened)
        #expect(payloadEntry.memberId == "me")
        // Household midnight rolls "today" forward; the frozen date still
        // reads stale (the guard is boardDate != today).
        #expect(frozen != "2026-07-27")
        // The id ignores the date, so a refresh never re-presents the sheet.
        #expect(sheet.id == "routine-r-me-06:00-me")
    }

    // MARK: Row accessibility labels (R13)

    // R13: Today rows are real Buttons, each with one curated VoiceOver
    // label — the trait and the announcement arrive together.
    @Test func rowLabelsReadTheWholeRow() {
        #expect(TodayLogic.eventRowLabel(
            event(id: "e", startsAt: "2026-07-27T18:30:00Z", summary: "Dentist"),
            timeZone: newYork
        ) == "Dentist, at 14:30")
        #expect(TodayLogic.eventRowLabel(
            event(id: "e", allDay: true, summary: "Trip"), timeZone: newYork
        ) == "Trip, all day")
        // Unparseable start: the summary alone, never a dangling comma.
        #expect(TodayLogic.eventRowLabel(
            event(id: "e", startsAt: nil, summary: "Mystery"), timeZone: newYork
        ) == "Mystery")

        #expect(TodayLogic.choreRowLabel(chore(id: "Dishes", late: true, assignee: "me"))
            == "Dishes, 2 stars, late")
        #expect(TodayLogic.choreRowLabel(
            chore(id: "Dishes", status: .completed, assignee: "me", completedBy: "mom"),
            names: ["mom": "Mom"]
        ) == "Dishes, 2 stars, done, by Mom")

        let board = entry(member: "me", start: "06:00", end: "09:00", statuses: [.completed, .open, .open])
        #expect(TodayLogic.routineRowLabel(board, isNow: true) == "Routine, now, 1 of 3 done")
        #expect(TodayLogic.routineRowLabel(board, isNow: false) == "Routine, 1 of 3 done")
    }

    // MARK: Uncheck

    // Kiosk trust: the circle flips a done row back to open — no matter who
    // owns it or checked it — and completes an open one.
    @Test func circleActionFlipsOnCompletionState() {
        #expect(TodayLogic.circleAction(for: chore(id: "open", assignee: "me")) == .complete)
        #expect(TodayLogic.circleAction(for: chore(id: "pool")) == .complete)
        #expect(TodayLogic.circleAction(
            for: chore(id: "done", status: .completed, assignee: "me", completedBy: "me")
        ) == .uncomplete)
        #expect(TodayLogic.circleAction(
            for: chore(id: "done-other", status: .completed, assignee: "sis", completedBy: "mom")
        ) == .uncomplete)
    }

    // MARK: Swipe actions (M9c)

    // M9c: exactly two surfaces — the circle, and swipe. Swipe carries claim
    // (unowned open rows), put back (anything claimed, D27) and dismiss (any
    // open row, D23); a done row offers none of them, because the circle
    // un-checks it.
    @Test func swipeActionsMirrorTheChoresBoardRules() {
        let pool = TodayLogic.swipeActions(for: chore(id: "pool"))
        #expect(pool == .init(canClaim: true, canPutBack: false, canDismiss: true))

        let claimed = TodayLogic.swipeActions(for: chore(id: "claimed", claimedBy: "me"))
        #expect(claimed == .init(canClaim: false, canPutBack: true, canDismiss: true))

        // Assigned rows are neither claimable nor put-backable — still dismissable.
        let assigned = TodayLogic.swipeActions(for: chore(id: "assigned", assignee: "me"))
        #expect(assigned == .init(canClaim: false, canPutBack: false, canDismiss: true))

        // D27: anyone may put back a sibling's claim.
        let claimedBySis = TodayLogic.swipeActions(for: chore(id: "hers", claimedBy: "sis"))
        #expect(claimedBySis.canPutBack)

        // A completed row strands nothing: uncomplete lives on the circle.
        let done = TodayLogic.swipeActions(
            for: chore(id: "done", status: .completed, assignee: "me", completedBy: "me")
        )
        #expect(done == .init())
        #expect(TodayLogic.circleAction(for: chore(
            id: "done", status: .completed, assignee: "me", completedBy: "me"
        )) == .uncomplete)
    }

    // D24: dismiss is permanent, so the confirm names the chore.
    @Test func dismissPromptNamesTheChore() {
        #expect(TodayLogic.dismissPrompt("Dishes") == "Dismiss \u{201C}Dishes\u{201D}?")
    }

    // MARK: Routine progress lines

    @Test func routineProgressLabelCountsResolvedAndCelebratesAllDone() {
        let base = (start: "06:00", end: "07:00")
        #expect(TodayLogic.routineProgressLabel(of: entry(
            member: "m", start: base.start, end: base.end, statuses: [.completed, .skipped, .open]
        )) == "2 of 3")
        #expect(TodayLogic.routineProgressLabel(of: entry(
            member: "m", start: base.start, end: base.end, statuses: [.open, .open]
        )) == "0 of 2")
        // Skips resolve too — the line celebrates a finished board.
        #expect(TodayLogic.routineProgressLabel(of: entry(
            member: "m", start: base.start, end: base.end, statuses: [.completed, .skipped]
        )) == "All done ✓")
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
