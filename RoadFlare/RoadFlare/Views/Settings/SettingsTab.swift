import SwiftUI
import RidestrSDK

/// Settings tab.
struct SettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var showKeyBackup = false
    @State private var showLogoutConfirm = false
    @State private var savedToPasswords = false
    @State private var saveError: String?

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

                Section("Security") {
                    Button {
                        showKeyBackup = true
                    } label: {
                        Label("Back Up Private Key", systemImage: "key")
                    }

                    Button {
                        saveToApplePasswords()
                    } label: {
                        Label(
                            savedToPasswords ? "Saved to Passwords" : "Save to Apple Passwords",
                            systemImage: savedToPasswords ? "checkmark.shield" : "lock.shield"
                        )
                    }
                    .disabled(savedToPasswords)

                    if let error = saveError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
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

    private func saveToApplePasswords() {
        guard let nsec = try? appState.keyManager?.exportNsec(),
              let npub = appState.keypair?.npub else {
            saveError = "No key to save"
            return
        }

        guard let data = nsec.data(using: .utf8) else {
            saveError = "Failed to encode key"
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: "ridestr.app",
            kSecAttrAccount as String: npub,
            kSecValueData as String: data,
            kSecAttrLabel as String: "RoadFlare Nostr Key",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        // Delete existing
        SecItemDelete([
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: "ridestr.app",
        ] as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            savedToPasswords = true
            saveError = nil
        } else {
            saveError = "Could not save (error \(status)). Try the manual backup instead."
        }
    }
}
