import SwiftUI
import RidestrSDK

/// Small connectivity indicator for the top-left navigation area.
/// Shows relay connection status with a colored dot.
struct ConnectivityIndicator: View {
    @Environment(AppState.self) private var appState
    @State private var showRelaySheet = false

    var body: some View {
        Button {
            showRelaySheet = true
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showRelaySheet) {
            RelayManagementSheet()
        }
    }

    private var statusColor: Color {
        // TODO: Check actual relay connection state
        appState.relayManager != nil ? .green : .red
    }

    private var statusText: String {
        appState.relayManager != nil ? "Connected" : "Offline"
    }
}

/// Relay management sheet — hidden from main settings, accessible via connectivity indicator.
struct RelayManagementSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Connected Relays") {
                    ForEach(DefaultRelays.all, id: \.absoluteString) { url in
                        HStack {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                            Text(url.absoluteString)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }
                }

                Section {
                    Text("Relay management is handled automatically. These are the Nostr relays your app communicates through.")
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
        }
    }
}
