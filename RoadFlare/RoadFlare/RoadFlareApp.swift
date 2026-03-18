import SwiftUI
import RidestrSDK

@main
struct RoadFlareApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    await appState.initialize()
                }
        }
    }
}
