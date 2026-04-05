import SwiftUI
import os
import RidestrSDK

@main
struct RoadFlareApp: App {
    @State private var appState = AppState()
    @State private var isHandlingForeground = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Route SDK log output through os.Logger via AppLogger.sdk so SDK
        // info/warning lines surface in Console.app. Without this, every
        // RidestrLogger call in the SDK is silently discarded.
        RidestrLogger.handler = { level, message, _, _ in
            switch level {
            case .debug: AppLogger.sdk.debug("\(message)")
            case .info: AppLogger.sdk.info("\(message)")
            case .warning: AppLogger.sdk.warning("\(message)")
            case .error: AppLogger.sdk.error("\(message)")
            }
        }
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
