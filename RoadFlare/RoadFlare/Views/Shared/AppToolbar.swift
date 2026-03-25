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
            if title == "RoadFlare" {
                HStack(spacing: 0) {
                    Text("Road")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(Color.rfOnSurface)
                    Text("Flare")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundColor(Color.rfPrimary)
                }
            } else if title == "Favorite Drivers" {
                VStack(alignment: .leading, spacing: -2) {
                    Text("Favorite")
                        .font(.largeTitle.bold())
                        .foregroundColor(Color.rfOnSurface)
                    Text("Drivers")
                        .font(.largeTitle.bold())
                        .foregroundColor(Color.rfPrimary)
                }
            } else {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundColor(Color.rfOnSurface)
            }

            Spacer()

            HStack(spacing: 14) {
                // Offline indicator (pulsing red)
                if isOffline {
                    Button { showConnectivity = true } label: {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 20))
                            .foregroundColor(Color.rfError)
                            .symbolEffect(.pulse)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }

                // Profile icon
                Button { showProfile = true } label: {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 26))
                        .foregroundColor(Color.rfPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}
