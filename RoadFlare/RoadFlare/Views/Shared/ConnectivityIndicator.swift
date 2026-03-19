import SwiftUI
import RidestrSDK

struct ConnectivityIndicator: View {
    @Environment(AppState.self) private var appState
    @State private var showRelaySheet = false
    @State private var connected = false

    var body: some View {
        Button { showRelaySheet = true } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(connected ? Color.rfOnline : Color.rfError)
                    .frame(width: 6, height: 6)
                Text(connected ? "Live" : "Offline")
                    .font(RFFont.caption(10))
                    .foregroundColor(Color.rfOnSurfaceVariant)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.rfSurfaceContainerHigh)
            .clipShape(Capsule())
        }
        .sheet(isPresented: $showRelaySheet) { RelayManagementSheet() }
        .task { await checkConnection() }
    }

    private func checkConnection() async {
        if let rm = appState.relayManager { connected = await rm.isConnected }
    }
}

struct RelayManagementSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isConnected = false

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
            NavigationStack {
                VStack(spacing: 24) {
                    HStack {
                        StatusDot(status: isConnected ? "online" : "offline")
                        Text(isConnected ? "Connected" : "Offline")
                            .font(RFFont.headline(20))
                            .foregroundColor(Color.rfOnSurface)
                    }

                    VStack(spacing: 8) {
                        ForEach(DefaultRelays.all, id: \.absoluteString) { url in
                            HStack {
                                StatusDot(status: isConnected ? "online" : "offline")
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
                        .multilineTextAlignment(.center)

                    Spacer()
                }
                .padding(24)
                .navigationTitle("Connectivity")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.rfSurface, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.foregroundColor(Color.rfPrimary)
                    }
                }
            }
        }
        .task {
            if let rm = appState.relayManager { isConnected = await rm.isConnected }
        }
    }
}
