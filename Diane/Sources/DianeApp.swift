import DianeKit
import SwiftUI

@main
struct DianeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    appDelegate.appState = appState
                    await appState.bootstrap()
                }
        }
    }
}

/// Device-local display prefs (owner ruling 2026-08-05: personal display
/// lives on the device; the API stays client-agnostic).
enum DisplayPrefs {
    /// "system" | "dark" | "light" — applied as preferredColorScheme.
    static func scheme(_ raw: String) -> ColorScheme? {
        switch raw {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// "system" | "sunday" | "monday" — resolved to Calendar's 1…7.
    static func firstWeekday(_ raw: String) -> Int {
        switch raw {
        case "sunday": 1
        case "monday": 2
        default: Foundation.Calendar.current.firstWeekday
        }
    }

    /// "system" | "12h" | "24h" — does this device show 24-hour clocks?
    static func uses24Hour(_ raw: String) -> Bool {
        switch raw {
        case "12h": false
        case "24h": true
        default: Locale.current.hourCycle == .zeroToTwentyThree
            || Locale.current.hourCycle == .oneToTwentyFour
        }
    }

    /// A locale whose hour cycle matches the pref, otherwise the device's own
    /// — hands the system time pickers the same convention the labels use.
    static func clockLocale(_ raw: String) -> Locale {
        var components = Locale.Components(locale: .current)
        switch raw {
        case "12h": components.hourCycle = .oneToTwelve
        case "24h": components.hourCycle = .zeroToTwentyThree
        default: return .autoupdatingCurrent
        }
        return Locale(components: components)
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    /// Appearance is per member per device (owner 2026-08-05).
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        phased.preferredColorScheme(DisplayPrefs.scheme(appearance))
    }

    @ViewBuilder private var phased: some View {
        switch appState.phase {
        case .launching:
            ProgressView()
        case .signedOut:
            SignInFlowView()
        case .signedIn(let context):
            RootTabView(context: context)
                // Rebuild the whole signed-in tree when the account changes.
                .id(context.session.memberID)
        }
    }
}
