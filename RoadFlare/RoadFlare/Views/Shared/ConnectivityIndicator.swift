import SwiftUI
import RidestrSDK

struct ConnectivitySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isConnected = false
    @State private var isReconnecting = false

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isConnected ? Color.rfOnline : Color.rfError)
                            .frame(width: 10, height: 10)
                        Text("Connectivity")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Color.rfOnSurface)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .font(RFFont.title(16))
                        .foregroundColor(Color.rfPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 24) {
                        // Relay list
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Relays")
                            VStack(spacing: 8) {
                                ForEach(DefaultRelays.all, id: \.absoluteString) { url in
                                    HStack {
                                        Circle()
                                            .fill(isConnected ? Color.rfOnline : Color.rfError)
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

                        // Reconnect button
                        Button {
                            isReconnecting = true
                            Task {
                                await appState.relayManager?.reconnectIfNeeded()
                                appState.rideCoordinator?.startLocationSubscriptions()
                                appState.rideCoordinator?.startKeyShareSubscription()
                                try? await Task.sleep(for: .seconds(2))
                                await checkConnection()
                                isReconnecting = false
                            }
                        } label: {
                            if isReconnecting {
                                ProgressView()
                                    .tint(Color.rfPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                Label("Reconnect", systemImage: "arrow.clockwise")
                                    .font(RFFont.title(16))
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.rfPrimary)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .disabled(isReconnecting)

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
                }
            }
        }
        .task {
            await checkConnection()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await checkConnection()
            }
        }
    }

    private func checkConnection() async {
        if let rm = appState.relayManager { isConnected = await rm.isConnected }
    }
}
