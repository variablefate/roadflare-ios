import SwiftUI
import Security
import RidestrSDK

struct SettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var showKeyBackup = false
    @State private var showLogoutConfirm = false
    @State private var showEditProfile = false
    @State private var showConnectivity = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Profile Card (tappable → edit sheet)
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Profile")
                            Button { showEditProfile = true } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.rfPrimary.opacity(0.1))
                                            .frame(width: 48, height: 48)
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(Color.rfPrimary)
                                    }
                                    Text(appState.settings.profileName.isEmpty ? "Set your name" : appState.settings.profileName)
                                        .font(RFFont.title(16))
                                        .foregroundColor(appState.settings.profileName.isEmpty ? Color.rfOnSurfaceVariant : Color.rfOnSurface)
                                    Spacer()
                                    Image(systemName: "pencil")
                                        .foregroundColor(Color.rfOnSurfaceVariant)
                                }
                                .padding(16)
                                .background(Color.rfSurfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }

                        // Payment Methods
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Payment Methods")
                            PaymentMethodPicker(settings: appState.settings)
                                .onChange(of: appState.settings.paymentMethods) { oldValue, newValue in
                                    // Only publish if this was a user-initiated change, not a restore
                                    guard oldValue != newValue, appState.authState == .ready else { return }
                                    Task { await appState.publishProfileBackup() }
                                }
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

                        // Account
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Account")
                            VStack(spacing: 0) {
                                SettingsButton(icon: "key", label: "Backup & Recovery") {
                                    showKeyBackup = true
                                }
                            }
                            .background(Color.rfSurfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                        // Advanced
                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("Advanced")
                            VStack(spacing: 0) {
                                SettingsButton(icon: "antenna.radiowaves.left.and.right", label: "Connectivity") {
                                    showConnectivity = true
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
            .sheet(isPresented: $showKeyBackup) { BackupKeySheet() }
            .sheet(isPresented: $showConnectivity) { ConnectivitySheet() }
            .sheet(isPresented: $showEditProfile) {
                EditProfileSheet()
            }
            .alert("Log Out?", isPresented: $showLogoutConfirm) {
                Button("Log Out", role: .destructive) { Task { await appState.logout() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all local data including your keys. Make sure you have backed up your private key.")
            }
        }
    }

}

// MARK: - Edit Profile Sheet

struct EditProfileSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var editedName = ""
    @State private var saveState: SaveState = .idle
    @State private var copiedAccountId = false
    @State private var showBackupKey = false

    enum SaveState {
        case idle, saving, saved
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                VStack(spacing: 32) {
                    Spacer().frame(height: 16)

                    // Avatar
                    ZStack {
                        Circle()
                            .fill(Color.rfPrimary.opacity(0.1))
                            .frame(width: 80, height: 80)
                        Image(systemName: "person.fill")
                            .font(.system(size: 36))
                            .foregroundColor(Color.rfPrimary)
                    }

                    // Name field
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Display Name")
                            .font(RFFont.caption())
                            .foregroundColor(Color.rfOnSurfaceVariant)
                        TextField("Your name", text: $editedName)
                            .font(RFFont.body(16))
                            .padding(14)
                            .background(Color.rfSurfaceContainerLow)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .foregroundColor(Color.rfOnSurface)
                            .onChange(of: editedName) {
                                if editedName.count > 50 { editedName = String(editedName.prefix(50)) }
                            }
                    }
                    .padding(.horizontal, 24)

                    // Account ID (tap to copy)
                    if let npub = appState.keypair?.npub {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Account ID")
                                .font(RFFont.caption())
                                .foregroundColor(Color.rfOnSurfaceVariant)
                            Button {
                                UIPasteboard.general.string = npub
                                copiedAccountId = true
                                Task {
                                    try? await Task.sleep(for: .seconds(2))
                                    copiedAccountId = false
                                }
                            } label: {
                                HStack {
                                    Text(npub)
                                        .font(RFFont.mono(11))
                                        .foregroundColor(Color.rfOffline)
                                        .lineLimit(2)
                                    Spacer()
                                    Image(systemName: copiedAccountId ? "checkmark" : "doc.on.doc")
                                        .font(.caption)
                                        .foregroundColor(copiedAccountId ? Color.rfOnline : Color.rfOffline)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.rfSurfaceContainerLow)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 24)
                    }

                    // View Recovery Key button
                    Button { showBackupKey = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "key")
                                .foregroundColor(Color.rfPrimary)
                            Text("View Recovery Key")
                                .font(RFFont.body(15))
                                .foregroundColor(Color.rfPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(Color.rfOffline)
                        }
                        .padding(14)
                        .background(Color.rfSurfaceContainerLow)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)

                    Spacer()
                }
            }
            .navigationTitle("Edit Profile")
            .sheet(isPresented: $showBackupKey) { BackupKeySheet() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.rfOnSurfaceVariant)
                        .disabled(saveState != .idle)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        switch saveState {
                        case .saving:
                            ProgressView().tint(Color.rfPrimary)
                        case .saved:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(Color.rfOnline)
                        case .idle:
                            Text("Save")
                                .bold()
                                .foregroundColor(hasChanges ? Color.rfPrimary : Color.rfOffline)
                        }
                    }
                    .disabled(!hasChanges || saveState != .idle)
                }
            }
            .onAppear {
                editedName = appState.settings.profileName
            }
        }
    }

    private var hasChanges: Bool {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != appState.settings.profileName
    }

    private func save() {
        let trimmed = editedName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        saveState = .saving
        appState.settings.profileName = trimmed
        Task {
            await appState.saveAndPublishSettings()
            saveState = .saved
            try? await Task.sleep(for: .milliseconds(600))
            dismiss()
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
