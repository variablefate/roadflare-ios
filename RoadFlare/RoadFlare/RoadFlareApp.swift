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
        }
    }
}
