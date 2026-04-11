import SwiftUI
import RoadFlareCore

struct MainTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        TabView(selection: $state.selectedTab) {
            RideTab()
                .tabItem { Label("RoadFlare", systemImage: "car") }
                .tag(0)

            DriversTab()
                .tabItem { Label("Drivers", systemImage: "person.2") }
                .tag(1)

            HistoryTab()
                .tabItem { Label("History", systemImage: "clock") }
                .tag(2)

            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(3)
        }
        .tint(Color.rfPrimary)
        .preferredColorScheme(.dark)
    }
}
