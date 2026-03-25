import SwiftUI
import RidestrSDK

/// Connectivity settings sheet — shows relay status and Nostr protocol explainer.
/// Accessed from Settings → Advanced → Connectivity.
struct ConnectivitySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isConnected = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Connection status
                        HStack {
                            Circle()
                                .fill(isConnected ? Color.rfOnline : Color.rfError)
                                .frame(width: 10, height: 10)
                            Text(isConnected ? "Connected" : "Offline")
                                .font(RFFont.headline(20))
                                .foregroundColor(Color.rfOnSurface)
                        }

                        // Relay list
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Relays")
                            VStack(spacing: 8) {
                                ForEach(DefaultRelays.all, id: \.absoluteString) { url in
                                    HStack {
                                        Circle()
                                            .fill(isConnected ? Color.rfOnline : Color.rfOffline)
                                            .frame(width: 6, height: 6)
                                        Text(url.absoluteString)
                                            .font(RFFont.mono(12))
                                            .foregroundColor(Color.rfOnSurfaceVariant)
                                        Spacer()
                                    }
                                    .rfCard(.low)
                                }
                            }

                            Text("Relay connections are managed automatically.")
                                .font(RFFont.caption(12))
                                .foregroundColor(Color.rfOffline)
                        }

                        // About Nostr Protocol explainer
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("RoadFlare is built on Nostr, an open communication protocol — similar to how email is a protocol.")
                                    .font(RFFont.body(14))
                                    .foregroundColor(Color.rfOnSurfaceVariant)

                                Text("Just like many different companies run their own email servers but can all communicate with each other, Nostr works the same way. No single company owns the protocol — it's used by many people and apps.")
                                    .font(RFFont.body(14))
                                    .foregroundColor(Color.rfOnSurfaceVariant)

                                Text("Relays are the servers that pass messages between users, similar to how email servers relay email. Your account is a cryptographic key pair that works across any app that supports the Nostr protocol.")
                                    .font(RFFont.body(14))
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("About Nostr Protocol")
                                .font(RFFont.body(15))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                        }
                        .tint(Color.rfOnSurfaceVariant)
                        .padding(16)
                        .background(Color.rfSurfaceContainer)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Connectivity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundColor(Color.rfPrimary)
                }
            }
        }
        .task {
            if let rm = appState.relayManager { isConnected = await rm.isConnected }
        }
    }
}
