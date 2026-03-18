import SwiftUI
import RidestrSDK

/// Small connectivity indicator for the top-left navigation area.
struct ConnectivityIndicator: View {
    @Environment(AppState.self) private var appState
    @State private var showRelaySheet = false
    @State private var connected = false

    var body: some View {
        Button {
            showRelaySheet = true
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(connected ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(connected ? "Connected" : "Offline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showRelaySheet) {
            RelayManagementSheet()
        }
        .task {
            await checkConnection()
        }
    }

    private func checkConnection() async {
        if let rm = appState.relayManager {
            connected = await rm.isConnected
        }
    }
}

/// Relay management sheet — accessible via connectivity indicator.
struct RelayManagementSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var isConnected = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Circle()
                            .fill(isConnected ? .green : .red)
                            .frame(width: 10, height: 10)
                        Text(isConnected ? "Connected" : "Offline")
                            .font(.headline)
                    }
                }

                Section("Relays") {
                    ForEach(DefaultRelays.all, id: \.absoluteString) { url in
                        HStack {
                            Text(url.absoluteString)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(isConnected ? .green : .gray)
                        }
                    }
                }

                Section {
                    Text("Relay connections are managed automatically. These are the Nostr relays your app communicates through.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connectivity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                if let rm = appState.relayManager {
                    isConnected = await rm.isConnected
                }
            }
        }
    }
}
