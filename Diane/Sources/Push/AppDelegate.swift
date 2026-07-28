import SwiftUI
import UserNotifications

/// UIKit shim: APNs registration callbacks and notification presentation
/// have no SwiftUI equivalent. All real logic lives in PushRegistrar.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var appState: AppState?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            appState?.pushRegistrar.handleDeviceToken(token)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            appState?.pushRegistrar.handleRegistrationFailure(error)
        }
    }

    /// A chore reminder arriving while the app is open should still show.
    /// nonisolated: UNUserNotificationCenterDelegate is not MainActor-bound,
    /// unlike UIApplicationDelegate (which isolates this whole class).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
