import Foundation
import Testing

@testable import Diane

/// The one gate every rendered clock time passes (owner 2026-08-15): 24h
/// keeps the zero-padded wire look, 12h converts with AM/PM, and ranges say
/// a shared meridiem once.
struct ClockDisplayTests {
    @Test func labelKeeps24hPadded() {
        #expect(ClockDisplay.label("16:05", use24: true) == "16:05")
        #expect(ClockDisplay.label("09:00", use24: true) == "09:00")
    }

    @Test func labelConverts12hWithNoonAndMidnightAsTwelve() {
        #expect(ClockDisplay.label("16:05", use24: false) == "4:05 PM")
        #expect(ClockDisplay.label("09:00", use24: false) == "9:00 AM")
        #expect(ClockDisplay.label("00:30", use24: false) == "12:30 AM")
        #expect(ClockDisplay.label("12:00", use24: false) == "12:00 PM")
    }

    @Test func malformedInputPassesThrough() {
        #expect(ClockDisplay.label("late", use24: false) == "late")
        #expect(ClockDisplay.label("25:00", use24: false) == "25:00")
    }

    @Test func rangeElidesASharedMeridiem() {
        #expect(ClockDisplay.range("17:00", "18:00", use24: false) == "5:00–6:00 PM")
        #expect(ClockDisplay.range("06:00", "11:59", use24: false) == "6:00–11:59 AM")
    }

    @Test func rangeSaysBothAcrossNoonOrMidnight() {
        #expect(ClockDisplay.range("11:30", "13:00", use24: false) == "11:30 AM–1:00 PM")
        #expect(ClockDisplay.range("23:00", "01:00", use24: false) == "11:00 PM–1:00 AM")
    }

    @Test func rangeStaysPlainIn24h() {
        #expect(ClockDisplay.range("17:00", "18:00", use24: true) == "17:00–18:00")
    }

    @Test func hourLabelsForTheDayGridAxis() {
        #expect(ClockDisplay.hourLabel(7, use24: true) == "07:00")
        #expect(ClockDisplay.hourLabel(7, use24: false) == "7 AM")
        #expect(ClockDisplay.hourLabel(0, use24: false) == "12 AM")
        #expect(ClockDisplay.hourLabel(12, use24: false) == "12 PM")
        #expect(ClockDisplay.hourLabel(23, use24: false) == "11 PM")
    }

    @Test func instantTimeInZone() {
        let date = TimeLogic.parseInstant("2026-07-27T15:42:00Z")!
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        #expect(ClockDisplay.time(date, timeZone: berlin, use24: true) == "17:42")
        #expect(ClockDisplay.time(date, timeZone: berlin, use24: false) == "5:42 PM")
    }

    @Test func prefResolutionHonorsExplicitChoices() {
        #expect(DisplayPrefs.uses24Hour("24h"))
        #expect(!DisplayPrefs.uses24Hour("12h"))
    }
}
