import DianeKit
import Observation
import SwiftUI
import UserNotifications

/// Owns the APNs token lifecycle: permission → registration → POST /devices,
/// and DELETE /devices on sign-out. The server treats a re-registered token
/// as the same install moving accounts, so re-posting is always safe — that
/// move is also the self-heal for any registration a failed sign-out
/// cleanup leaves behind.
@MainActor
@Observable
final class PushRegistrar {
    enum Status: Equatable {
        case idle
        case denied
        case registered
        case waiting  // token known, registration not yet confirmed
        case failed(String)
    }

    private(set) var status: Status = .idle

    private var client: DianeClient?
    private var pendingToken: String?
    /// Invalidates in-flight work from a previous session: a POST landing
    /// after sign-out must not resurrect state (review M9).
    private var generation = 0

    /// Last registration CONFIRMED by the server; cleared only when the
    /// server confirms deletion.
    @ObservationIgnored
    @AppStorage("diane.apns.lastToken") private var lastPostedToken: String?

    func sessionDidStart(client: DianeClient) {
        self.client = client
        generation += 1
        let currentGeneration = generation
        Task {
            let center = UNUserNotificationCenter.current()
            let granted =
                (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            guard generation == currentGeneration else { return }
            guard granted else {
                status = .denied
                return
            }
            UIApplication.shared.registerForRemoteNotifications()
            if let token = pendingToken ?? lastPostedToken {
                await post(token: token, in: currentGeneration)
            }
        }
    }

    func handleDeviceToken(_ token: String) {
        pendingToken = token
        let currentGeneration = generation
        Task { await post(token: token, in: currentGeneration) }
    }

    func handleRegistrationFailure(_ error: Error) {
        // Expected on simulators without APNs support; the app works without.
        status = .failed(error.localizedDescription)
    }

    /// Foreground retry hook: a registration that failed while away from
    /// home must not stay dead for the whole app session (review M9).
    func retryIfNeeded() {
        guard status != .registered, status != .denied,
              let token = pendingToken, client != nil else { return }
        let currentGeneration = generation
        Task { await post(token: token, in: currentGeneration) }
    }

    /// Best-effort server cleanup on explicit sign-out. On failure the
    /// registration row survives server-side (documented; the next sign-in
    /// re-posts the same token and MOVES the install) — but local state is
    /// always invalidated so no stale POST can complete afterwards.
    func sessionWillEnd(client: DianeClient) async {
        generation += 1
        self.client = nil
        let tokens = [lastPostedToken, pendingToken].compactMap { $0 }
        pendingToken = nil
        status = .idle
        for token in Set(tokens) {
            let output = try? await client.api.deleteDevice(body: .json(.init(token: token)))
            if case .noContent = output, token == lastPostedToken {
                lastPostedToken = nil
            }
        }
    }

    /// Revoked-session teardown: the token is already dead, no network
    /// goodbyes possible. Keeps lastPostedToken so the next sign-in's
    /// re-post moves the registration.
    func sessionDidEnd() {
        generation += 1
        client = nil
        pendingToken = nil
        status = .idle
    }

    private func post(token: String, in expectedGeneration: Int) async {
        guard let client, generation == expectedGeneration else { return }
        status = .waiting
        do {
            let output = try await client.api.registerDevice(
                body: .json(.init(token: token, platform: .ios))
            )
            guard generation == expectedGeneration else { return }
            if case .ok = output {
                lastPostedToken = token
                status = .registered
            } else {
                status = .failed("The server didn't accept the registration.")
            }
        } catch {
            guard generation == expectedGeneration else { return }
            // Offline: keep the token, retryIfNeeded picks it up on the
            // next foreground.
            status = .failed("Couldn't reach home — will retry.")
        }
    }
}
