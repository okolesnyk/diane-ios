import DianeKit
import Foundation
import Observation

/// The household's wall clock and calendar day, ticking once a minute.
///
/// Every server-side "today" (chore actionability, routine boards, event day
/// windows) is computed in the HOUSEHOLD timezone, not the device's — a
/// traveling phone must still see the family's day (review M9, same rule the
/// web kiosk applies via useLocalToday). Screens read `today`/`minute` in
/// their bodies (re-rendering each tick) and key refetches on `today`.
///
/// Verified cross-frame 2026-08-10 (device CDT, household Warsaw): the day,
/// minute, now-line, and late math all render household wall time. If a
/// SIMULATOR shows a skewed clock, suspect CoreSimulator's clock drift
/// after host sleep (reboot the sim), not this class — and don't test with
/// a UTC household: a zero offset can't reveal double application.
@MainActor
@Observable
final class HouseholdClock {
    private(set) var timeZone: TimeZone
    /// Household-local "YYYY-MM-DD".
    private(set) var today: String
    /// Household-local "HH:mm" — comparable to routine windowStart/End.
    private(set) var minute: String
    /// The module switchboard (M9e) — rides the same getHousehold fetch and
    /// the same settings-changed refresh the timezone does.
    private(set) var modules = ModuleSwitchboard()

    /// The instant the current today/minute were computed from — `tomorrow`
    /// must share the same frame as `today`, never re-read the real clock.
    private var lastNow: Date

    init(timeZone: TimeZone = .current, now: Date = .now) {
        self.timeZone = timeZone
        self.lastNow = now
        (today, minute) = Self.compute(now: now, timeZone: timeZone)
    }

    /// Household-local "YYYY-MM-DD" for the day after `today`.
    var tomorrow: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let day = calendar.date(byAdding: .day, value: 1, to: lastNow) else { return today }
        return Self.compute(now: day, timeZone: timeZone).0
    }

    /// Long-running: resolve the household tz, then tick every minute.
    func run(client: DianeClient) async {
        await refreshTimeZone(client: client)
        while !Task.isCancelled {
            let now = Date()
            let toNextMinute = 60.5 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
            try? await Task.sleep(nanoseconds: UInt64(toNextMinute * 1_000_000_000))
            guard !Task.isCancelled else { break }
            tick()
        }
    }

    /// Re-fetch the household tz + module switchboard (called on settings
    /// changes; a tz edit or a module flip on any client must reframe here).
    func refreshTimeZone(client: DianeClient) async {
        guard let output = try? await client.api.getHousehold(),
              case .ok(let ok) = output,
              let household = try? ok.body.json
        else { return }
        let switchboard = ModuleSwitchboard(
            chores: household.modules.chores,
            routines: household.modules.routines,
            rewards: household.modules.rewards
        )
        if switchboard != modules { modules = switchboard }
        guard let tz = TimeZone(identifier: household.tz) else { return }
        timeZone = tz
        tick()
    }

    func tick(now: Date = .now) {
        lastNow = now
        let (day, clock) = Self.compute(now: now, timeZone: timeZone)
        // Only assign on change: screens observe these, and @Observable
        // fires on every set.
        if day != today { today = day }
        if clock != minute { minute = clock }
    }

    private static func compute(now: Date, timeZone: TimeZone) -> (String, String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        return (
            String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0),
            String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        )
    }
}
