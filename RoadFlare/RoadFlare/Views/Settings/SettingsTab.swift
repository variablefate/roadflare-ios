import SwiftUI
import RidestrSDK

/// Settings tab.
struct SettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var showKeyBackup = false
    @State private var showLogoutConfirm = false
    @State private var showShareSheet = false
    @State private var shareText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Profile") {
                    if !appState.settings.profileName.isEmpty {
                        LabeledContent("Name", value: appState.settings.profileName)
                    }

                    if let npub = appState.keypair?.npub {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your Public Key")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(npub)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                }

                Section("Payment Methods") {
                    PaymentMethodPicker(settings: appState.settings)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("Key Backup") {
                    Button {
                        showKeyBackup = true
                    } label: {
                        Label("View & Copy Private Key", systemImage: "key")
                    }

                    Button {
                        shareKey()
                    } label: {
                        Label("Share Key via...", systemImage: "square.and.arrow.up")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: RidestrSDKVersion.version)
                    LabeledContent("Drivers", value: "\(appState.driversRepository?.drivers.count ?? 0)")
                }

                Section {
                    Button("Log Out", role: .destructive) {
                        showLogoutConfirm = true
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectivityIndicator()
                }
            }
            .sheet(isPresented: $showKeyBackup) {
                NsecBackupSheet()
            }
            .sheet(isPresented: $showShareSheet) {
                if !shareText.isEmpty {
                    ShareSheet(items: [shareText])
                }
            }
            .alert("Log Out?", isPresented: $showLogoutConfirm) {
                Button("Log Out", role: .destructive) {
                    Task { await appState.logout() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all local data including your keys. Make sure you have backed up your private key.")
            }
        }
    }

    private func shareKey() {
        Task {
            guard let nsec = try? await appState.keyManager?.exportNsec() else { return }
            shareText = nsec
            showShareSheet = true
        }
    }
}
