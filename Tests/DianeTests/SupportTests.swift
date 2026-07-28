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
}
