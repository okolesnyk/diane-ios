import DianeKit
import Foundation
import Observation

/// Everything a signed-in screen needs, created once per sign-in.
struct SignedInContext {
    let client: DianeClient
    let session: StoredSession
}

/// Session lifecycle for the whole app. The iOS app is member-only: family
/// (kiosk) and service scopes stay on the web app.
@MainActor
@Observable
final class AppState {
    enum Phase {
        case launching
        case signedOut
        case signedIn(SignedInContext)
    }

    private(set) var phase: Phase = .launching

    private let sessionStore: SessionStore
    private let defaults: UserDefaults
    let pushRegistrar: PushRegistrar

    init(sessionStore: SessionStore = SessionStore(), defaults: UserDefaults = .standard) {
        self.sessionStore = sessionStore
        self.defaults = defaults
        self.pushRegistrar = PushRegistrar()
    }

    /// Restore the stored session and show the UI IMMEDIATELY — the app must
    /// never sit on a launch spinner waiting for a home-lab server that may
    /// be unroutable (review M9). Revocation is checked in the background:
    /// only a definitive 401 signs the user out; every screen already
    /// tolerates an unreachable server on its own.
    func bootstrap() async {
        // Keychain items outlive app deletion: without this purge a
        // hand-me-down phone boots into the previous owner's session on
        // reinstall (review M9 HIGH).
        if !defaults.bool(forKey: "diane.hasLaunched") {
            sessionStore.clear()
            defaults.set(true, forKey: "diane.hasLaunched")
        }
        guard let stored = sessionStore.load() else {
            phase = .signedOut
            return
        }
        let context = makeContext(for: stored)
        phase = .signedIn(context)
        pushRegistrar.sessionDidStart(client: context.client)
        await validateSession(context: context)
    }

    /// Background probe: 401 → signed out; 200 → refresh the stored member
    /// snapshot (role/name/color drift after kiosk edits — a demoted parent
    /// must lose the admin UI; review M9).
    private func validateSession(context: SignedInContext) async {
        guard let output = try? await context.client.api.getSession() else { return }
        switch output {
        case .unauthorized:
            handleUnauthorized()
        case .ok(let ok):
            guard let info = try? ok.body.json, let member = info.member else { return }
            var refreshed = context.session
            refreshed.memberID = member.id
            refreshed.memberName = member.name
            refreshed.memberColor = member.color
            refreshed.memberRole = member.role.rawValue
            guard refreshed != context.session else { return }
            sessionStore.save(refreshed)
            phase = .signedIn(SignedInContext(client: context.client, session: refreshed))
        default:
            break
        }
    }

    func didSignIn(origin: URL, token: String, member: Components.Schemas.SessionMember) {
        let stored = StoredSession(
            serverURL: origin,
            token: token,
            memberID: member.id,
            memberName: member.name,
            memberColor: member.color,
            memberRole: member.role.rawValue
        )
        sessionStore.save(stored)
        let context = makeContext(for: stored)
        phase = .signedIn(context)
        pushRegistrar.sessionDidStart(client: context.client)
    }

    /// Local teardown is immediate; the network goodbyes (device
    /// de-registration, session delete) run best-effort in the background —
    /// signing out away from home must not hang the UI for the transport
    /// timeout (review M9).
    func signOut() {
        guard case .signedIn(let context) = phase else {
            phase = .signedOut
            return
        }
        sessionStore.clear()
        phase = .signedOut
        let registrar = pushRegistrar
        Task {
            // Device delete needs the live session, so it goes first.
            await registrar.sessionWillEnd(client: context.client)
            _ = try? await context.client.api.logout()
        }
    }

    /// Screens call this on a 401 from any API call: the session was revoked
    /// server-side (member deleted, session pruned, password reset). No
    /// network goodbyes — the token is already dead, and the orphaned device
    /// registration self-heals on the next sign-in (token upsert moves it).
    func handleUnauthorized() {
        pushRegistrar.sessionDidEnd()
        sessionStore.clear()
        phase = .signedOut
    }

    private func makeContext(for stored: StoredSession) -> SignedInContext {
        let token = stored.token
        let client = DianeClient(origin: stored.serverURL, token: { token })
        return SignedInContext(client: client, session: stored)
    }
}
