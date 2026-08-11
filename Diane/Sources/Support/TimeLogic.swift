import Foundation

/// Instant/clock math plus a little shared copy, used by every page —
/// the survivors of the M9 Today screen's logic (that screen and the rest
/// of its logic retired 2026-08-10; the M9e pages replaced it).
enum TimeLogic {
    /// Local "YYYY-MM-DD" — the device's own calendar day, never via UTC.
    static func dateString(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// ISO-8601 UTC instant → local "HH:mm". The api emits fractional
    /// seconds ("...T22:00:00.000Z") which the default parser REJECTS —
    /// try fractional first, then plain (caught live in M9).
    static func parseInstant(_ isoInstant: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: isoInstant) ?? ISO8601DateFormatter().date(from: isoInstant)
    }

    static func timeLabel(_ isoInstant: String?, timeZone: TimeZone) -> String? {
        guard let isoInstant, let date = parseInstant(isoInstant) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// "HH:mm" → minutes since midnight.
    static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    static func clockMinutes(of date: Date, timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// D24: dismiss is permanent, so it names the chore and confirms first.
    static func dismissPrompt(_ title: String) -> String {
        "Dismiss \u{201C}\(title)\u{201D}?"
    }

    /// D21: the real emitted set (verified in diane-server apps/api/src);
    /// chore_archived was never a server code.
    static func conflictMessage(code: String?) -> String {
        switch code {
        case "already_claimed": "Someone already grabbed this one."
        case "not_claimable": "That one can't be claimed."
        case "not_actionable": "That chore can't be checked off right now."
        case "already_completed": "That one is already done."
        case "insufficient_stars": "Those stars are already spent."
        default: "Couldn't complete that chore."
        }
    }
}
