import SwiftUI
import RoadFlareCore

@main
struct RoadFlareApp: App {
    @State private var appState = AppState()
    @State private var isHandlingForeground = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLogger.bootstrapSDKLogging()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .task {
                    await appState.initialize()
                }
                .onChange(of: scenePhase) { oldPhase, newPhase in
                    // Only handle background → active transitions (not tab switches)
                    if newPhase == .active && oldPhase == .background && !isHandlingForeground {
                        isHandlingForeground = true
                        Task {
                            await appState.handleForeground()
                            isHandlingForeground = false
                        }
                    }
                }
                .onOpenURL { url in
                    // Custom URL scheme dispatch (e.g. `roadflared:npub1...?name=...`).
                    // Fires on both cold-start and warm-app paths. AppState routes
                    // the parsed driver intent into the drivers tab.
                    appState.handleIncomingURL(url)
                }
        }
    }
}
