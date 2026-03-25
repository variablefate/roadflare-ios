import SwiftUI

/// Custom header bar for the first 3 tabs. Not a toolbar — sits at the top of content.
/// Shows title on the left, profile icon + optional offline indicator on the right.
struct AppHeader: View {
    let title: String
    @Binding var showProfile: Bool
    @Binding var showConnectivity: Bool
    let isOffline: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(RFFont.headline(24))
                .foregroundColor(Color.rfOnSurface)

            Spacer()

            HStack(spacing: 14) {
                // Offline indicator (pulsing red)
                if isOffline {
                    Button { showConnectivity = true } label: {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 18))
                            .foregroundColor(Color.rfError)
                            .symbolEffect(.pulse)
                    }
                }

                // Profile icon
                Button { showProfile = true } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 22))
                        .foregroundColor(Color.rfPrimary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
