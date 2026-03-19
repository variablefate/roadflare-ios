import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DriversTab()
                .tabItem { Label("Drivers", systemImage: "person.2") }
                .tag(0)

            RideTab()
                .tabItem { Label("Ride", systemImage: "car") }
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
