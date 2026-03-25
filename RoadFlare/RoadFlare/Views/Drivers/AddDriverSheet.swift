import SwiftUI
import RidestrSDK

/// Sheet for adding a new driver by QR scan, npub, or hex pubkey.
/// After scanning or pasting a valid key, fetches the driver's profile from Nostr
/// and shows a driver info card for confirmation before adding.
struct AddDriverSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var pubkeyInput = ""
    @State private var errorMessage: String?
    @State private var showScanner = false

    // Resolved driver state
    @State private var resolvedHexPubkey: String?
    @State private var resolvedProfile: UserProfileContent?
    @State private var scannedName: String?  // From QR ?name= parameter
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

                TextField("Paste npub or Account ID", text: $pubkeyInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(RFFont.mono(14))
                    .padding(12)
                    .background(Color.rfSurfaceContainerLow)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .foregroundColor(Color.rfOnSurface)
                    .onChange(of: pubkeyInput) {
                        errorMessage = nil
                    }
                    .onSubmit { resolveInput() }

                Button { resolveInput() } label: {
                    Text("Look Up Driver")
                }
                .buttonStyle(RFPrimaryButtonStyle(isDisabled: pubkeyInput.trimmingCharacters(in: .whitespaces).isEmpty))
                .disabled(pubkeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isFetchingProfile)
            }

            if let error = errorMessage {
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
                    Label("Add to My Drivers", systemImage: "person.badge.plus")
                }
                .buttonStyle(RFPrimaryButtonStyle())
            }

            // Back button
            Button {
                resolvedHexPubkey = nil
                resolvedProfile = nil
                scannedName = nil
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

    private var driverDisplayName: String {
        resolvedProfile?.displayName
            ?? resolvedProfile?.name
            ?? scannedName
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse nostr: URI with optional ?name= parameter
        // Format: nostr:npub1...?name=URL%20Encoded%20Name
        var npubPart: String
        var nameParam: String?

        if trimmed.hasPrefix("nostr:") {
            let withoutScheme = String(trimmed.dropFirst(6))
            // Split on ? to extract query parameters
            let parts = withoutScheme.split(separator: "?", maxSplits: 1)
            npubPart = String(parts[0])
            if parts.count > 1 {
                nameParam = parseNameParam(String(parts[1]))
            }
        } else if trimmed.hasPrefix("npub1") {
            let parts = trimmed.split(separator: "?", maxSplits: 1)
            npubPart = String(parts[0])
            if parts.count > 1 {
                nameParam = parseNameParam(String(parts[1]))
            }
        } else if trimmed.count == 64 && trimmed.allSatisfy(\.isHexDigit) {
            npubPart = trimmed
        } else {
            errorMessage = "QR code doesn't contain a valid Nostr public key"
            return
        }

        scannedName = nameParam
        pubkeyInput = npubPart
        resolveInput()
    }

    /// Extract name= parameter from URL query string.
    private func parseNameParam(_ query: String) -> String? {
        let pairs = query.split(separator: "&")
        for pair in pairs {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == "name" {
                return String(kv[1]).removingPercentEncoding
            }
        }
        return nil
    }

    // MARK: - Resolve Input

    private func resolveInput() {
        let trimmed = pubkeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let hexPubkey: String
        if trimmed.hasPrefix("npub1") {
            guard let decoded = try? NIP19.npubDecode(trimmed) else {
                errorMessage = "Invalid npub format"
                return
            }
            hexPubkey = decoded
        } else if trimmed.count == 64 && trimmed.allSatisfy(\.isHexDigit) {
            hexPubkey = trimmed
        } else {
            errorMessage = "Enter a valid npub or 64-character hex key"
            return
        }

        errorMessage = nil

        // Fetch driver's Kind 0 profile from Nostr, then show the card
        isFetchingProfile = true
        Task {
            await fetchDriverProfile(hexPubkey)
            resolvedHexPubkey = hexPubkey
            isFetchingProfile = false
        }
    }

    private func fetchDriverProfile(_ hexPubkey: String) async {
        guard let rm = appState.relayManager else { return }
        do {
            let filter = NostrFilter.metadata(pubkeys: [hexPubkey])
            let events = try await rm.fetchEvents(filter: filter, timeout: 5)
            if let event = events.sorted(by: { $0.createdAt > $1.createdAt }).first,
               let profile = RideshareEventParser.parseMetadata(event: event) {
                resolvedProfile = profile
            }
        } catch {
            // Non-fatal — show card without profile info
        }
    }

    // MARK: - Add Driver

    private func addDriver(hexPubkey: String) {
        let name = resolvedProfile?.displayName ?? resolvedProfile?.name ?? scannedName
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

        // Publish Kind 30011 so driver can discover this follower.
        // If we don't have a key yet, send a stale ack to request one.
        // (The key may already exist from Kind 30011 restore — check first.)
        Task {
            await appState.rideCoordinator?.publishFollowedDriversList()
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
