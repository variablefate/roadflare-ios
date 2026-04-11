import SwiftUI
import RidestrSDK
import RoadFlareCore

/// Shown during key import while data is being restored from Nostr.
struct SyncScreen: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Icon
                ZStack {
                    Circle()
                        .fill(Color.rfPrimary.opacity(0.1))
                        .frame(width: 100, height: 100)
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 44))
                        .foregroundColor(Color.rfPrimary)
                        .symbolEffect(.pulse)
                }

                VStack(spacing: 8) {
                    Text("Restoring Your Data")
                        .font(RFFont.headline(24))
                        .foregroundColor(Color.rfOnSurface)

                    Text(appState.syncStatus)
                        .font(RFFont.body(15))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                        .contentTransition(.numericText())
                }

                Spacer()

                // Restored data summary — fixed layout, rows fade in via opacity
                VStack(spacing: 10) {
                    restoredRow(icon: "person.fill",
                                text: "Profile: \(appState.settings.profileName)",
                                visible: appState.syncRestoredName)

                    restoredRow(icon: "person.2.fill",
                                text: "\(appState.syncRestoredDrivers) driver\(appState.syncRestoredDrivers == 1 ? "" : "s") restored",
                                visible: appState.syncRestoredDrivers > 0)

                    restoredRow(icon: "mappin",
                                text: "\(appState.syncRestoredLocations) saved location\(appState.syncRestoredLocations == 1 ? "" : "s")",
                                visible: appState.syncRestoredLocations > 0)

                    restoredRow(icon: "creditcard",
                                text: "Payment methods restored",
                                visible: !appState.settings.roadflarePaymentMethods.isEmpty)
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 40)
            }
        }
    }

    private func restoredRow(icon: String, text: String, visible: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(Color.rfOnline)
                .frame(width: 24)
            Text(text)
                .font(RFFont.body(14))
                .foregroundColor(Color.rfOnSurface)
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(Color.rfOnline)
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeIn(duration: 0.3), value: visible)
    }
}
