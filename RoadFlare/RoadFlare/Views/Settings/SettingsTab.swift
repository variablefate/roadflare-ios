import SwiftUI
import Security
import RidestrSDK

struct SettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var showKeyBackup = false
    @State private var showLogoutConfirm = false
    @State private var showShareSheet = false
    @State private var shareText = ""
    @State private var savedToPasswords = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Profile
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Profile")
                            HStack(spacing: 12) {
                                Image(systemName: "person")
                                    .frame(width: 20)
                                    .foregroundColor(Color.rfPrimary)
                                TextField("Your name", text: Bindable(appState.settings).profileName)
                                    .font(RFFont.body(15))
                                    .foregroundColor(Color.rfOnSurface)
                                    // Empty name prevention handled by UserSettings.didSet guard
                            }
                            .padding(16)
                            .background(Color.rfSurfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                        // Payment Methods
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Payment Methods")
                            PaymentMethodPicker(settings: appState.settings)
                        }

                        // Saved Locations
                        VStack(alignment: .leading, spacing: 12) {
                            NavigationLink {
                                SavedLocationsView()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .frame(width: 20)
                                        .foregroundColor(Color.rfPrimary)
                                    Text("Saved Locations")
                                        .font(RFFont.body(15))
                                        .foregroundColor(Color.rfOnSurface)
                                    Spacer()
                                    Text("\(appState.savedLocations.favorites.count) favorites")
                                        .font(RFFont.caption(12))
                                        .foregroundColor(Color.rfOnSurfaceVariant)
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(Color.rfOffline)
                                }
                                .padding(16)
                                .background(Color.rfSurfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }

                        // Key Backup
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Account")
                            VStack(spacing: 0) {
                                SettingsButton(icon: "key", label: "View Backup Key") {
                                    showKeyBackup = true
                                }
                                SettingsButton(icon: "lock.shield", label: savedToPasswords ? "Saved to Passwords" : "Save to Apple Passwords") {
                                    saveToPasswords()
                                }
                                .disabled(savedToPasswords)
                                SettingsButton(icon: "square.and.arrow.up", label: "Share Backup Key") {
                                    shareKey()
                                }
                            }
                            .background(Color.rfSurfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                        // About
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("About")
                            VStack(spacing: 0) {
                                SettingsRow(icon: "info.circle", label: "Version", value: RidestrSDKVersion.version)
                                SettingsRow(icon: "person.2", label: "Drivers", value: "\(appState.driversRepository?.drivers.count ?? 0)")
                            }
                            .background(Color.rfSurfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                        // Logout
                        Button { showLogoutConfirm = true } label: {
                            Text("Log Out")
                                .font(RFFont.body(15))
                                .foregroundColor(Color.rfError)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.rfSurfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Settings")
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectivityIndicator() }
            }
            .sheet(isPresented: $showKeyBackup) { BackupKeySheet() }
            .sheet(isPresented: $showShareSheet) {
                if !shareText.isEmpty { ShareSheet(items: [shareText]) }
            }
            .alert("Log Out?", isPresented: $showLogoutConfirm) {
                Button("Log Out", role: .destructive) { Task { await appState.logout() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all local data including your keys. Make sure you have backed up your private key.")
            }
        }
    }

    private func saveToPasswords() {
        Task {
            guard let nsec = try? await appState.keyManager?.exportNsec(),
                  let npub = appState.keypair?.npub else { return }
            SecAddSharedWebCredential("roadflare.app" as CFString, npub as CFString, nsec as CFString) { error in
                Task { @MainActor in
                    if error == nil { savedToPasswords = true }
                }
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

// MARK: - Settings Components

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(RFFont.caption(12))
            .foregroundColor(Color.rfOnSurfaceVariant)
            .textCase(.uppercase)
            .tracking(1)
            .padding(.leading, 4)
    }
}

struct SettingsRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(Color.rfPrimary)
            Text(label)
                .font(RFFont.body(15))
                .foregroundColor(Color.rfOnSurface)
            Spacer()
            Text(value)
                .font(RFFont.body(14))
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
        .padding(16)
    }
}

struct SettingsButton: View {
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
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Color.rfOffline)
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
