import SwiftUI
import RidestrSDK

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
                        .animation(.easeInOut, value: appState.syncStatus)
                }

                Spacer()

                // Restored data summary (shows as items are found)
                VStack(spacing: 12) {
                    if appState.syncRestoredName {
                        restoredRow(icon: "person.fill", text: "Profile: \(appState.settings.profileName)")
                    }
                    if appState.syncRestoredDrivers > 0 {
                        restoredRow(icon: "person.2.fill", text: "\(appState.syncRestoredDrivers) driver\(appState.syncRestoredDrivers == 1 ? "" : "s") restored")
                    }
                    if appState.syncRestoredLocations > 0 {
                        restoredRow(icon: "mappin", text: "\(appState.syncRestoredLocations) saved location\(appState.syncRestoredLocations == 1 ? "" : "s")")
                    }
                    if appState.settings.paymentMethods.count > 1 || appState.settings.paymentMethods != [.cash] {
                        restoredRow(icon: "creditcard", text: "Payment methods restored")
                    }
                }
                .padding(.horizontal, 32)

                Spacer().frame(height: 40)
            }
        }
    }

    private func restoredRow(icon: String, text: String) -> some View {
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
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
