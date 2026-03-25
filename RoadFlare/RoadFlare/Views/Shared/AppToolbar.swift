import SwiftUI

/// Custom header bar for the first 3 tabs. Not a toolbar — sits at the top of content.
/// Shows title on the left, profile icon + optional offline indicator on the right.
/// All titles use 38pt bold for consistent icon positioning across tabs.
struct AppHeader: View {
    let title: String
    var subtitle: String? = nil
    var subtitleColor: Color = Color.rfPrimary
    @Binding var showProfile: Bool
    @Binding var showConnectivity: Bool
    let isOffline: Bool

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: -10) {
                titleView

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(subtitleColor)
                }
            }

            Spacer()

            HStack(spacing: 14) {
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
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var titleView: some View {
        if title == "RoadFlare" {
            HStack(spacing: 0) {
                Text("Road")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundColor(Color.rfOnSurface)
                Text("Flare")
                    .font(.system(size: 38, weight: .bold))
                    .foregroundColor(Color.rfPrimary)
            }
        } else {
            Text(title)
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(Color.rfOnSurface)
        }
    }
}
