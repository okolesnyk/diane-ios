import Foundation

/// Renders wall-clock times per the device's "Time format" preference
/// (Settings → My preferences, owner 2026-08-15 — the app mixed AM/PM and
/// 24h screen to screen). Wire times stay 24h "HH:mm"; every LABEL a clock
/// time reaches goes through here.
enum ClockDisplay {
    /// "16:05" → "16:05" | "4:05 PM". Malformed input passes through.
    static func label(_ hhmm: String, use24: Bool) -> String {
        guard let minutes = TimeLogic.minutes(hhmm) else { return hhmm }
        return label(hour: minutes / 60, minute: minutes % 60, use24: use24)
    }

    static func label(hour: Int, minute: Int, use24: Bool) -> String {
        if use24 { return String(format: "%02d:%02d", hour, minute) }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, minute, hour < 12 ? "AM" : "PM")
    }

    /// "17:00","18:00" → "17:00–18:00" | "5:00–6:00 PM" — one meridiem when
    /// the range stays inside it, both when it crosses noon or midnight.
    static func range(_ start: String, _ end: String, use24: Bool, separator: String = "–") -> String {
        guard !use24,
              let s = TimeLogic.minutes(start), let e = TimeLogic.minutes(end),
              (s < 720) == (e < 720)
        else {
            return "\(label(start, use24: use24))\(separator)\(label(end, use24: use24))"
        }
        let twelve = (s / 60) % 12 == 0 ? 12 : (s / 60) % 12
        return String(format: "%d:%02d%@%@", twelve, s % 60, separator, label(end, use24: false))
    }

    /// Day-grid axis: "07:00" | "7 AM" (noon "12 PM", midnight "12 AM").
    static func hourLabel(_ hour: Int, use24: Bool) -> String {
        if use24 { return String(format: "%02d:00", hour) }
        let h = hour % 24
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve) \(h < 12 ? "AM" : "PM")"
    }

    /// An instant's wall clock in `timeZone`.
    static func time(_ date: Date, timeZone: TimeZone, use24: Bool) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return label(hour: c.hour ?? 0, minute: c.minute ?? 0, use24: use24)
    }
}
