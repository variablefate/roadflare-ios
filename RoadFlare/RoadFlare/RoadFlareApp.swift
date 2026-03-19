import SwiftUI
import RidestrSDK

@main
struct RoadFlareApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .task {
                    await appState.initialize()
                }
        }
    }
}
