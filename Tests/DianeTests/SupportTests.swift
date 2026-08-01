import DianeKit
import SwiftUI
import Testing

@testable import Diane

@Suite struct SupportTests {
    @MainActor
    @Suite struct SyncSignalsTests {
        @Test func eventBumpsItsTopicSetsAndLeavesDisjointSetsAlone() {
            let signals = SyncSignals()
            let chores = signals.version(of: [.chores])
            let choresAndStars = signals.version(of: [.chores, .stars])
            let disjoint = signals.version(of: [.rewards, .events])

            signals.apply(.event(SSEvent(name: "chores-changed", data: "{}")))

            #expect(signals.version(of: [.chores]) == chores + 1)
            #expect(signals.version(of: [.chores, .stars]) == choresAndStars + 1)
            #expect(signals.version(of: [.rewards, .events]) == disjoint)
        }

        @Test func unknownEventNameIsIgnored() {
            let signals = SyncSignals()
            let all = Set(DianeTopic.allCases)
            let before = signals.version(of: all)

            signals.apply(.event(SSEvent(name: "gremlins-changed", data: "{}")))

            #expect(signals.version(of: all) == before)
        }

        @Test func connectedChangesEveryVersion() {
            let signals = SyncSignals()
            // Uneven counters first, so the epoch bump must move every topic.
            signals.apply(.event(SSEvent(name: "stars-changed", data: "{}")))
            let before = DianeTopic.allCases.map { signals.version(of: [$0]) }

            signals.apply(.connected)

            for (topic, old) in zip(DianeTopic.allCases, before) {
                #expect(signals.version(of: [topic]) != old)
            }
        }

        @Test func versionIsMonotonicNonDecreasingOverAnySequence() {
            let signals = SyncSignals()
            let sets: [Set<DianeTopic>] = [
                [.chores], [.chores, .stars], [.events, .calendars], Set(DianeTopic.allCases),
            ]
            var last = sets.map { signals.version(of: $0) }

            let sequence: [SSESignal] = [
                .event(SSEvent(name: "chores-changed", data: "{}")),
                .event(SSEvent(name: "not-a-topic", data: "")),
                .connected,
                .event(SSEvent(name: "stars-changed", data: "{}")),
                .event(SSEvent(name: "events-changed", data: "{}")),
                .connected,
                .event(SSEvent(name: "settings-changed", data: "{}")),
            ]
            for signal in sequence {
                signals.apply(signal)
                let now = sets.map { signals.version(of: $0) }
                for (new, old) in zip(now, last) {
                    #expect(new >= old)
                }
                last = now
            }
        }
    }

    @Suite struct ColorHexTests {
        @Test func parsesRRGGBB() {
            #expect(Color(hex: "#4A90D9") == Color(red: 74 / 255, green: 144 / 255, blue: 217 / 255))
        }

        @Test func pureRedResolvesToRed() {
            let resolved = Color(hex: "#FF0000").resolve(in: EnvironmentValues())
            #expect(abs(resolved.red - 1) < 0.001)
            #expect(abs(resolved.green) < 0.001)
            #expect(abs(resolved.blue) < 0.001)
        }

        @Test func hashPrefixIsOptional() {
            #expect(Color(hex: "4A90D9") == Color(hex: "#4A90D9"))
        }

        @Test func wrongLengthFallsBackToGray() {
            #expect(Color(hex: "#FFF") == Color.gray)
            #expect(Color(hex: "") == Color.gray)
            #expect(Color(hex: "#4A90D9FF") == Color.gray)
        }

        @Test func nonHexFallsBackToGray() {
            #expect(Color(hex: "#GGGGGG") == Color.gray)
        }
    }

    @Suite struct LoadableTests {
        @Test func valueOnlyForLoaded() {
            #expect(Loadable.loaded(7).value == 7)
            #expect(Loadable<Int>.loading.value == nil)
            #expect(Loadable<Int>.failed("offline").value == nil)
        }
    }

    // The household frame for "today"/windows — D02/D03/D05 root fix.
    @MainActor
    @Suite struct HouseholdClockTests {
        // 2026-07-28T02:30Z = Jul 27 9:30 PM Chicago, Jul 28 04:30 in Warsaw.
        private let instant = Date(timeIntervalSince1970: 1_785_209_400 - 3_600)
        private let chicago = TimeZone(identifier: "America/Chicago")!
        private let warsaw = TimeZone(identifier: "Europe/Warsaw")!

        @Test func computesTodayAndMinuteInTheHouseholdZone() {
            let clock = HouseholdClock(timeZone: chicago, now: instant)
            #expect(clock.today == "2026-07-27")
            #expect(clock.minute == "21:30")
            let abroad = HouseholdClock(timeZone: warsaw, now: instant)
            #expect(abroad.today == "2026-07-28")
        }

        @Test func tomorrowSharesTheFrameOfToday() {
            let clock = HouseholdClock(timeZone: chicago, now: instant)
            #expect(clock.tomorrow == "2026-07-28")
            // Year rollover: 2026-12-31T18:00 Chicago.
            clock.tick(now: Date(timeIntervalSince1970: 1_798_761_600))
            #expect(clock.today == "2026-12-31")
            #expect(clock.tomorrow == "2027-01-01")
        }

        @Test func tickFlipsTheDayAtHouseholdMidnight() {
            let clock = HouseholdClock(timeZone: chicago, now: instant)
            clock.tick(now: instant.addingTimeInterval(3 * 3_600))
            #expect(clock.today == "2026-07-28")
            #expect(clock.minute == "00:30")
        }

        @Test func cancellationHelperMatchesOnlyCancellation() {
            #expect(isTaskCancellation(CancellationError()))
            #expect(isTaskCancellation(URLError(.cancelled)))
            #expect(!isTaskCancellation(URLError(.timedOut)))
        }
    }

    // My own default chore-reminder time — per MEMBER, "HH:mm" or off.
    @Suite struct ChoreReminderLogicTests {
        @Test func everyMinuteOfTheDayRoundTrips() {
            for hour in 0...23 {
                for minute in 0...59 {
                    guard let text = ChoreReminderLogic.format(hour: hour, minute: minute) else {
                        Issue.record("no wire form for \(hour):\(minute)")
                        continue
                    }
                    #expect(text.count == 5)
                    #expect(ChoreReminderLogic.isValid(text))
                    let parsed = ChoreReminderLogic.parse(text)
                    #expect(parsed?.hour == hour)
                    #expect(parsed?.minute == minute)
                }
            }
        }

        @Test func formatsZeroPadded() {
            #expect(ChoreReminderLogic.format(hour: 9, minute: 5) == "09:05")
            #expect(ChoreReminderLogic.format(hour: 0, minute: 0) == "00:00")
            #expect(ChoreReminderLogic.format(hour: 23, minute: 59) == "23:59")
        }

        @Test func formatRefusesTimesThatAreNotOnTheClock() {
            #expect(ChoreReminderLogic.format(hour: 24, minute: 0) == nil)
            #expect(ChoreReminderLogic.format(hour: -1, minute: 0) == nil)
            #expect(ChoreReminderLogic.format(hour: 12, minute: 60) == nil)
            #expect(ChoreReminderLogic.format(hour: 12, minute: -1) == nil)
        }

        @Test func rejectsWhatTheServerRejects() {
            for bad in ["9:00", "24:00", "ab:cd", "12:60", "1:2", "12:00:00", "", ":", "0800", "08:0", " 08:00", "08:00 ", "-1:00", "+8:00"] {
                #expect(!ChoreReminderLogic.isValid(bad), "\(bad) must not be valid")
                #expect(ChoreReminderLogic.parse(bad) == nil, "\(bad) must not parse")
            }
        }

        // Stricter than ICU on purpose: zod's \d on the server is ASCII-only,
        // so a full-width or Arabic-Indic "digit" would 422.
        @Test func rejectsNonASCIIDigits() {
            #expect(!ChoreReminderLogic.isValid("１８:００"))
            #expect(!ChoreReminderLogic.isValid("١٨:٠٠"))
            #expect(!ChoreReminderLogic.isValid("1８:00"))
        }

        // The wire contract, verbatim from MemberUpdate.choreReminderTime.
        @Test func agreesWithTheServerPatternOnAnASCIICorpus() throws {
            let regex = try NSRegularExpression(pattern: #"^([01]\d|2[0-3]):[0-5]\d$"#)
            var corpus = ["", ":", "9:00", "ab:cd", "0800", "08:0", "12:00:00", "08:00 ", "-1:00"]
            for hour in 0...25 {
                for minute in [0, 9, 30, 59, 60] {
                    corpus.append(String(format: "%02d:%02d", hour, minute))
                }
            }
            for candidate in corpus {
                let range = NSRange(candidate.startIndex..., in: candidate)
                let serverAccepts = regex.firstMatch(in: candidate, range: range) != nil
                #expect(ChoreReminderLogic.isValid(candidate) == serverAccepts, "\(candidate)")
            }
        }

        // The row is a bare picker now, so whatever it shows is a time the
        // server can ring at — a stored value it could never have written
        // (or none at all) falls back rather than being displayed.
        @Test func theDraftSeedsFromTheStoredTimeAndFallsBackOtherwise() {
            #expect(ChoreReminderLogic.draft(nil) == ChoreReminderLogic.fallback)
            #expect(ChoreReminderLogic.isValid(ChoreReminderLogic.fallback))
            #expect(ChoreReminderLogic.draft("07:30") == "07:30")
            #expect(ChoreReminderLogic.draft("nonsense") == ChoreReminderLogic.fallback)
            #expect(ChoreReminderLogic.draft("24:00") == ChoreReminderLogic.fallback)
            #expect(ChoreReminderLogic.draft("") == ChoreReminderLogic.fallback)
        }

        // Turning the reminder OFF is a literal null, not an omitted key: the
        // route reads an absent key as "keep existing".
        @Test func clearingEncodesAnExplicitNull() throws {
            let json = try String(
                decoding: JSONEncoder().encode(MemberReminderPatch(choreReminderTime: nil)),
                as: UTF8.self
            )
            #expect(json == #"{"choreReminderTime":null}"#)
            let set = try String(
                decoding: JSONEncoder().encode(MemberReminderPatch(choreReminderTime: "18:00")),
                as: UTF8.self
            )
            #expect(set == #"{"choreReminderTime":"18:00"}"#)
        }

        @Test func errorCopyNeverLeaksRawServerCodes() {
            #expect(
                ChoreReminderLogic.friendlyError("validation_failed (choreReminderTime)")
                    == "That time isn't one the server accepts. Pick another."
            )
            #expect(ChoreReminderLogic.friendlyError("forbidden").contains("your own"))
            #expect(!ChoreReminderLogic.friendlyError("some_new_code").contains("some_new_code"))
        }
    }
}
