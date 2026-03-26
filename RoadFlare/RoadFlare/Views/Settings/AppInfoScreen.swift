import SwiftUI
import RidestrSDK

struct AppInfoScreen: View {
    @Environment(\.openURL) private var openURL

    private let repoURL = "https://github.com/variablefate/roadflare-ios"
    private let licenseURL = "https://github.com/variablefate/roadflare-ios/blob/main/LICENSE"

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // App icon + version header
                    VStack(spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color.rfPrimary.opacity(0.1))
                                .frame(width: 80, height: 80)
                            Image(systemName: "car.fill")
                                .font(.system(size: 36))
                                .foregroundColor(Color.rfPrimary)
                        }
                        .padding(.top, 24)

                        HStack(spacing: 0) {
                            Text("Road")
                                .font(RFFont.title(22))
                                .foregroundColor(Color.rfOnSurface)
                            Text("Flare")
                                .font(RFFont.title(22))
                                .foregroundColor(Color.rfPrimary)
                        }

                        Text("Version \(RidestrSDKVersion.version)")
                            .font(RFFont.caption(13))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }

                    // Links
                    VStack(spacing: 0) {
                        InfoButton(icon: "doc.text", label: "Terms of Service") {
                            openURL(URL(string: "https://roadflare.app/terms")!)
                        }
                        InfoButton(icon: "lock.shield", label: "Privacy Policy") {
                            openURL(URL(string: "https://roadflare.app/privacy")!)
                        }
                        InfoButton(icon: "chevron.left.forwardslash.chevron.right", label: "Source Code") {
                            openURL(URL(string: repoURL)!)
                        }
                        InfoButton(icon: "doc.text.magnifyingglass", label: "License") {
                            openURL(URL(string: licenseURL)!)
                        }
                        InfoButton(icon: "exclamationmark.bubble", label: "Submit Issue") {
                            openURL(URL(string: "\(repoURL)/issues/new")!)
                        }
                    }
                    .background(Color.rfSurfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Open source note
                    Text("RoadFlare is free, open-source software built on the Nostr protocol. No accounts, no middlemen, no platform fees.")
                        .font(RFFont.caption(12))
                        .foregroundColor(Color.rfOffline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("App Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.rfSurface, for: .navigationBar)
    }
}

// MARK: - Info Button

private struct InfoButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .frame(width: 20)
                    .foregroundColor(Color.rfPrimary)
                Text(label)
                    .font(RFFont.body(15))
                    .foregroundColor(Color.rfOnSurface)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundColor(Color.rfOffline)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
