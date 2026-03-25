import SwiftUI

/// Shared toolbar modifier for the first 3 tabs (RoadFlare, Drivers, History).
/// Shows title inline in the toolbar, profile icon, and offline indicator when disconnected.
struct AppToolbar: ViewModifier {
    let title: String
    @Binding var showProfile: Bool
    @Binding var showConnectivity: Bool
    let isOffline: Bool

    func body(content: Content) -> some View {
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(title)
                        .font(RFFont.headline(20))
                        .foregroundColor(Color.rfOnSurface)
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 12) {
                        // Offline indicator (pulsing red)
                        if isOffline {
                            Button { showConnectivity = true } label: {
                                Image(systemName: "wifi.exclamationmark")
                                    .font(.system(size: 16))
                                    .foregroundColor(Color.rfError)
                                    .symbolEffect(.pulse)
                            }
                        }

                        // Profile icon
                        Button { showProfile = true } label: {
                            Image(systemName: "person.crop.circle")
                                .foregroundColor(Color.rfPrimary)
                        }
                    }
                }
            }
    }
}

extension View {
    func appToolbar(title: String, showProfile: Binding<Bool>, showConnectivity: Binding<Bool>, isOffline: Bool) -> some View {
        modifier(AppToolbar(title: title, showProfile: showProfile, showConnectivity: showConnectivity, isOffline: isOffline))
    }
}
