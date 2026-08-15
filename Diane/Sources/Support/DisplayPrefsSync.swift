import DianeKit
import Foundation

/// Mirrors the signed-in member's ACCOUNT display prefs (owner 2026-08-15:
/// week start + time format live on the member row, shared across their
/// clients) into the UserDefaults keys every view reads via @AppStorage.
/// Pulled on appear and on members-changed, so a pick on any other client
/// lands here live; the server is the source of truth.
@MainActor
enum DisplayPrefsSync {
    static func pull(context: SignedInContext) async {
        guard case .ok(let ok)? = try? await context.client.api.getMember(
            .init(path: .init(id: context.session.memberID))
        ), let member = try? ok.body.json else { return }
        let defaults = UserDefaults.standard
        apply(member.weekStart.rawValue, to: "weekStart", in: defaults)
        apply(member.timeFormat.rawValue, to: "timeFormat", in: defaults)
    }

    /// Only write on change — @AppStorage observers fire on every set.
    private static func apply(_ value: String, to key: String, in defaults: UserDefaults) {
        if defaults.string(forKey: key) != value {
            defaults.set(value, forKey: key)
        }
    }
}
