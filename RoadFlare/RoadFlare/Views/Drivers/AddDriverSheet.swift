import SwiftUI
import RidestrSDK
import RoadFlareCore

/// Sheet for adding a new driver by QR scan, npub, or hex pubkey.
/// After scanning or pasting a valid key, fetches the driver's profile from Nostr
/// and shows a driver info card for confirmation before adding.
struct AddDriverSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var lookupDraft = DriverLookupDraft()
    @State private var showScanner = false

    // Resolved driver state
    @State private var resolvedHexPubkey: String?
    @State private var resolvedProfile: UserProfileContent?
    @State private var isFetchingProfile = false
    @State private var noteInput = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        if isFetchingProfile {
                            // Loading state while looking up driver
                            VStack(spacing: 20) {
                                Spacer().frame(height: 40)
                                ProgressView()
                                    .scaleEffect(1.3)
                                    .tint(Color.rfPrimary)
                                Text("Looking up driver...")
                                    .font(RFFont.body(15))
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                                Spacer()
                            }
                        } else if let hexPubkey = resolvedHexPubkey {
                            // Driver info card — ready to confirm
                            driverInfoCard(hexPubkey: hexPubkey)
                        } else {
                            // Input mode — scan or paste
                            inputSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
            }
            .navigationTitle(resolvedHexPubkey != nil ? "Add Driver" : "Find Driver")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                QRScannerSheet { scannedValue in
                    handleScan(scannedValue)
                }
            }
        }
    }

    // MARK: - Input Section

    private var inputSection: some View {
        VStack(spacing: 24) {
            // QR scan button
            Button { showScanner = true } label: {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(Color.rfPrimary.opacity(0.1))
                            .frame(width: 56, height: 56)
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 24))
                            .foregroundColor(Color.rfPrimary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Scan Driver's QR Code")
                            .font(RFFont.title(16))
                            .foregroundColor(Color.rfOnSurface)
                        Text("Point your camera at the driver's QR code")
                            .font(RFFont.caption(13))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundColor(Color.rfOffline)
                }
                .padding(16)
                .background(Color.rfSurfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            // Divider
            HStack {
                Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1)
                Text("or").font(RFFont.caption()).foregroundColor(Color.rfOffline)
                Rectangle().fill(Color.rfSurfaceContainerHigh).frame(height: 1)
            }

            // Manual entry
            VStack(alignment: .leading, spacing: 8) {
                Text("Driver's Account ID")
                    .font(RFFont.caption())
                    .foregroundColor(Color.rfOnSurfaceVariant)

                TextField("Paste npub or Account ID", text: pubkeyInputBinding)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(RFFont.mono(14))
                    .padding(12)
                    .background(Color.rfSurfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundColor(Color.rfOnSurface)
                    .onSubmit { resolveInput() }

                Button { resolveInput() } label: {
                    Text("Look Up Driver")
                }
                .buttonStyle(RFPrimaryButtonStyle(isDisabled: lookupDraft.pubkeyInput.trimmingCharacters(in: .whitespaces).isEmpty))
                .disabled(lookupDraft.pubkeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isFetchingProfile)
            }

            if let error = lookupDraft.errorMessage {
                Text(error)
                    .font(RFFont.caption())
                    .foregroundColor(Color.rfError)
            }
        }
    }

    // MARK: - Driver Info Card

    private func driverInfoCard(hexPubkey: String) -> some View {
        VStack(spacing: 24) {
            // Driver avatar + name
            VStack(spacing: 16) {
                // Profile photo or placeholder
                if let pictureURL = resolvedProfile?.picture, let url = URL(string: pictureURL) {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        driverAvatarPlaceholder
                    }
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    driverAvatarPlaceholder
                }

                VStack(spacing: 6) {
                    Text(driverDisplayName)
                        .font(RFFont.headline(22))
                        .foregroundColor(Color.rfOnSurface)

                    // Vehicle info (public from Kind 0)
                    if let vehicle = resolvedProfile?.vehicleDescription {
                        Text(vehicle.uppercased())
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }

                    Text(formatPubkey(hexPubkey))
                        .font(RFFont.mono(11))
                        .foregroundColor(Color.rfOffline)
                        .lineLimit(1)
                }
            }
            .padding(.top, 16)

            // Bio (if available)
            if let about = resolvedProfile?.about, !about.isEmpty {
                Text(about)
                    .font(RFFont.body(14))
                    .foregroundColor(Color.rfOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            // Already following check
            if appState.driversRepository?.isFollowing(pubkey: hexPubkey) == true {
                Label("You're already following this driver", systemImage: "checkmark.circle.fill")
                    .font(RFFont.body(15))
                    .foregroundColor(Color.rfOnline)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(Color.rfOnline.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                // Note field
                VStack(alignment: .leading, spacing: 8) {
                    Text("Note (optional)")
                        .font(RFFont.caption())
                        .foregroundColor(Color.rfOnSurfaceVariant)
                    TextField("e.g., Toyota Camry, airport runs", text: $noteInput)
                        .font(RFFont.body(14))
                        .padding(12)
                        .background(Color.rfSurfaceContainerLow)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(Color.rfOnSurface)
                }

                // Add button
                Button { addDriver(hexPubkey: hexPubkey) } label: {
                    Label("Add to Favorite Drivers", systemImage: "person.badge.plus")
                }
                .buttonStyle(RFPrimaryButtonStyle())
            }

            // Back button
            Button {
                resolvedHexPubkey = nil
                resolvedProfile = nil
                lookupDraft.errorMessage = nil
                lookupDraft.scannedName = nil
                noteInput = ""
            } label: {
                Text("Look Up Different Driver")
            }
            .buttonStyle(RFGhostButtonStyle())
        }
    }

    private var driverAvatarPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.rfPrimary.opacity(0.1))
                .frame(width: 88, height: 88)
            Image(systemName: "person.fill")
                .font(.system(size: 36))
                .foregroundColor(Color.rfPrimary)
        }
    }

    private var pubkeyInputBinding: Binding<String> {
        Binding(
            get: { lookupDraft.pubkeyInput },
            set: { newValue in
                var updatedDraft = lookupDraft
                updatedDraft.updatePubkeyInput(newValue)
                lookupDraft = updatedDraft
            }
        )
    }

    private var driverDisplayName: String {
        resolvedProfile?.displayName
            ?? resolvedProfile?.name
            ?? lookupDraft.scannedName
            ?? "Unknown Driver"
    }

    private func formatPubkey(_ hex: String) -> String {
        if let npub = try? NIP19.npubEncode(publicKeyHex: hex) {
            return String(npub.prefix(16)) + "..." + String(npub.suffix(8))
        }
        return String(hex.prefix(12)) + "..." + String(hex.suffix(8))
    }

    // MARK: - QR Parsing

    private func handleScan(_ value: String) {
        showScanner = false
        guard lookupDraft.applyScannedCode(value) != nil else { return }
        resolveInput()
    }

    // MARK: - Resolve Input

    private func resolveInput() {
        guard let lookup = lookupDraft.resolveLookup() else { return }
        let hexPubkey = lookup.hexPubkey

        // Fetch driver's Kind 0 profile from Nostr, then show the card
        isFetchingProfile = true
        Task {
            await fetchDriverProfile(hexPubkey)
            resolvedHexPubkey = hexPubkey
            isFetchingProfile = false
        }
    }

    private func fetchDriverProfile(_ hexPubkey: String) async {
        guard let service = appState.roadflareDomainService else { return }
        let profiles = await service.fetchDriverProfiles(pubkeys: [hexPubkey])
        resolvedProfile = profiles[hexPubkey]?.value
    }

    // MARK: - Add Driver

    private func addDriver(hexPubkey: String) {
        let name = resolvedProfile?.displayName ?? resolvedProfile?.name ?? lookupDraft.scannedName
        let driver = FollowedDriver(
            pubkey: hexPubkey,
            name: name,
            note: noteInput.isEmpty ? nil : noteInput
        )
        appState.driversRepository?.addDriver(driver)

        // Cache the driver's full profile if we fetched it
        if let profile = resolvedProfile {
            appState.driversRepository?.cacheDriverProfile(pubkey: hexPubkey, profile: profile)
        } else if let name, !name.isEmpty {
            appState.driversRepository?.cacheDriverName(pubkey: hexPubkey, name: name)
        }

        // Publish Kind 30011 (source of truth) + Kind 3187 (real-time nudge to driver).
        // On re-add, try to restore the key from Kind 30011 on the relay first.
        // If still no key, send a stale ack to request one from the driver.
        Task {
            await appState.rideCoordinator?.publishFollowedDriversList()
            await appState.sendFollowNotification(driverPubkey: hexPubkey)

            // If no key locally, try restoring from our Kind 30011 backup on the relay
            if appState.driversRepository?.getRoadflareKey(driverPubkey: hexPubkey) == nil {
                await appState.restoreKeyFromBackup(driverPubkey: hexPubkey)
            }
            // If still no key after restore attempt, request from driver
            if appState.driversRepository?.getRoadflareKey(driverPubkey: hexPubkey) == nil {
                await appState.rideCoordinator?.requestKeyRefresh(driverPubkey: hexPubkey)
            }
        }

        dismiss()
    }
}

/// Full-screen QR scanner with close button overlay.
struct QRScannerSheet: View {
    let onScan: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            QRScannerView { code in
                onScan(code)
            }
            .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .padding()
        }
    }
}
