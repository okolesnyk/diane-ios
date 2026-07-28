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

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
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
