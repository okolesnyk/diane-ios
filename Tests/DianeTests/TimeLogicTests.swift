import Foundation
import Testing

@testable import Diane

// The shared instant/clock helpers (the M9 Today screen's surviving logic).
@Suite struct TimeLogicTests {
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let chicago = TimeZone(identifier: "America/Chicago")!

    @Test func dateStringUsesTheLocalCalendarDayNotUTC() {
        // 2026-07-28T03:30Z is still July 27 in New York (UTC-4).
        let instant = Date(timeIntervalSince1970: 1_785_209_400)
        #expect(TimeLogic.dateString(for: instant, timeZone: newYork) == "2026-07-27")
        #expect(TimeLogic.dateString(for: instant, timeZone: TimeZone(identifier: "UTC")!) == "2026-07-28")
    }

    // D02: "today" is the HOUSEHOLD's day, not the device's — at midnight in
    // New York the Chicago household is still on yesterday.
    @Test func todayFollowsTheHouseholdFrameNotTheDevice() {
        // 2026-07-28T04:00Z = Jul 28 00:00 New York = Jul 27 23:00 Chicago.
        let instant = Date(timeIntervalSince1970: 1_785_211_200)
        #expect(TimeLogic.dateString(for: instant, timeZone: chicago) == "2026-07-27")
        #expect(TimeLogic.dateString(for: instant, timeZone: newYork) == "2026-07-28")
    }

    @Test func dateStringZeroPadsMonthAndDay() {
        // 2026-01-05T12:00Z.
        let instant = Date(timeIntervalSince1970: 1_767_614_400)
        #expect(TimeLogic.dateString(for: instant, timeZone: TimeZone(identifier: "UTC")!) == "2026-01-05")
    }

    @Test func timeLabelRendersTheInstantInLocalTime() {
        #expect(TimeLogic.timeLabel("2026-07-27T18:30:00Z", timeZone: newYork, use24: true) == "14:30")
        #expect(TimeLogic.timeLabel(nil, timeZone: newYork, use24: true) == nil)
        #expect(TimeLogic.timeLabel("not-a-date", timeZone: newYork, use24: true) == nil)
    }

    // The api emits fractional seconds; the default ISO8601 parser rejects
    // them, which rendered every event time as "—" (caught live in M9).
    @Test func timeLabelAcceptsFractionalSeconds() {
        #expect(TimeLogic.timeLabel("2026-07-27T22:00:00.000Z", timeZone: newYork, use24: true) == "18:00")
    }

    @Test func minutesParsesTheWallClockAndRejectsGarbage() {
        #expect(TimeLogic.minutes("00:00") == 0)
        #expect(TimeLogic.minutes("07:05") == 7 * 60 + 5)
        #expect(TimeLogic.minutes("23:59") == 23 * 60 + 59)
        #expect(TimeLogic.minutes("late") == nil)
    }

    @Test func clockMinutesUsesTheGivenTimeZone() {
        // 2026-07-27T18:30Z = 14:30 in New York.
        let instant = Date(timeIntervalSince1970: 1_785_177_000)
        #expect(TimeLogic.clockMinutes(of: instant, timeZone: newYork) == 14 * 60 + 30)
    }

    @Test func dismissPromptNamesTheChore() {
        #expect(TimeLogic.dismissPrompt("Dishes") == "Dismiss \u{201C}Dishes\u{201D}?")
    }

    @Test func conflictCodesMapToHumanCopy() {
        let generic = TimeLogic.conflictMessage(code: nil)
        #expect(!generic.isEmpty)
        for code in ["not_actionable", "already_claimed", "not_claimable", "already_completed", "insufficient_stars"] {
            #expect(TimeLogic.conflictMessage(code: code) != generic, "\(code) should have curated copy")
        }
        #expect(TimeLogic.conflictMessage(code: "already_claimed").contains("grabbed"))
        #expect(TimeLogic.conflictMessage(code: "insufficient_stars").contains("spent"))
        #expect(TimeLogic.conflictMessage(code: "chore_archived") == generic)
    }
}
