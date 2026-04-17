import SwiftUI
import RidestrSDK
import RoadFlareCore

// MARK: - Container

struct DeleteAccountSheet: View {
    var body: some View {
        NavigationStack {
            DeleteAccountScanView()
        }
    }
}

// MARK: - Page 1: Relay Scan

struct DeleteAccountScanView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum ScanPhase {
        case idle
        case scanning
        case complete(RelayScanResult)
        case failed(String)
    }

    @State private var phase: ScanPhase = .idle

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    header
                    relayList
                    errorBanner
                    primaryAction
                    nostrExplainer
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.rfSurface, for: .navigationBar)
        .toolbar {
            // ToolbarContentBuilder requires every branch to produce ToolbarContent —
            // empty branches aren't allowed, so use a single conditional instead.
            // Hide Cancel during active scan to prevent accidental dismissal.
            if !isScanning {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }
            }
        }
    }

    // MARK: Subviews

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 52))
                .foregroundColor(Color.rfError)
            Text("Delete Account")
                .font(RFFont.headline(22))
                .foregroundColor(Color.rfOnSurface)
            Text("Step 1 of 2 — Relay Scan")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
        .padding(.top, 8)
    }

    private var relayList: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Relays")
            VStack(spacing: 8) {
                ForEach(DefaultRelays.all, id: \.absoluteString) { url in
                    HStack {
                        Circle()
                            .fill(relayDotColor)
                            .frame(width: 6, height: 6)
                        Text(url.absoluteString)
                            .font(RFFont.mono(12))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                        Spacer()
                        if case .scanning = phase {
                            ProgressView()
                                .scaleEffect(0.6)
                                .tint(Color.rfPrimary)
                        }
                    }
                    .rfCard(.low)
                }
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if case .failed(let msg) = phase {
            Text(msg)
                .font(RFFont.body(13))
                .foregroundColor(Color.rfError)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.rfSurfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch phase {
        case .idle:
            Button {
                Task { await startScan() }
            } label: {
                Text("Scan Relays")
            }
            .buttonStyle(RFDestructiveButtonStyle())

        case .scanning:
            HStack(spacing: 12) {
                ProgressView().tint(Color.rfOnSurface)
                Text("Scanning relays…")
                    .font(RFFont.body(15))
                    .foregroundColor(Color.rfOnSurfaceVariant)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.rfSurfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 24))

        case .complete(let scan):
            VStack(spacing: 12) {
                // Surface scan errors honestly — silent "0 events" when relays
                // were unreachable would mislead the user into thinking nothing
                // exists when their data may still be on those relays.
                if scan.hasErrors {
                    scanErrorWarning(scan)
                }

                NavigationLink {
                    DeleteAccountResultsView(scan: scan)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: scan.hasErrors ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        Text("Continue — \(scan.totalCount) event\(scan.totalCount == 1 ? "" : "s") found")
                    }
                }
                .buttonStyle(RFDestructiveButtonStyle())
            }

        case .failed:
            Button {
                phase = .idle
            } label: {
                Text("Try Again")
            }
            .buttonStyle(RFSecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private func scanErrorWarning(_ scan: RelayScanResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Color.rfError)
                Text("Scan incomplete")
                    .font(RFFont.title(14))
                    .foregroundColor(Color.rfOnSurface)
            }
            ForEach(scan.scanErrors, id: \.self) { err in
                Text(err)
                    .font(RFFont.caption(12))
                    .foregroundColor(Color.rfOnSurfaceVariant)
            }
            Text("You can still continue, but events on unreachable relays may not be deleted.")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var nostrExplainer: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("RoadFlare is built on Nostr, a decentralized protocol. Your data is stored on independent relays — not on RoadFlare's servers.")
                    .font(RFFont.body(14))
                    .foregroundColor(Color.rfOnSurfaceVariant)

                Text("When you delete your account, RoadFlare sends a deletion request (NIP-09) to each relay. Most relays honour these requests and remove your events, but because relays are independently operated, removal cannot be guaranteed.")
                    .font(RFFont.body(14))
                    .foregroundColor(Color.rfOnSurfaceVariant)

                Text("Your private key exists only on this device. Once deleted, the key — and your Nostr identity — cannot be recovered.")
                    .font(RFFont.body(14))
                    .foregroundColor(Color.rfOnSurfaceVariant)
            }
            .padding(.top, 8)
        } label: {
            Text("About Nostr & Account Deletion")
                .font(RFFont.body(15))
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
        .tint(Color.rfOnSurfaceVariant)
        .padding(16)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Helpers

    private var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    private var relayDotColor: Color {
        switch phase {
        case .idle: Color.rfOffline
        case .scanning: Color.rfPrimary
        case .complete: Color.rfOnline
        case .failed: Color.rfError
        }
    }

    private func startScan() async {
        phase = .scanning
        do {
            let scan = try await appState.scanRelaysForDeletion()
            phase = .complete(scan)
        } catch AccountDeletionError.activeRideInProgress {
            phase = .failed("You have an active ride. Complete or cancel it before deleting your account.")
        } catch AccountDeletionError.servicesNotReady {
            phase = .failed("Unable to connect — please try again.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Page 2: Scan Results + Delete Options

struct DeleteAccountResultsView: View {
    @Environment(AppState.self) private var appState
    let scan: RelayScanResult

    @State private var showRoadflareConfirm = false
    @State private var showFullDeleteSheet = false
    @State private var isDeleting = false
    /// When deletion publish fails, the user is still logged out. The root view
    /// tree swaps to the logged-out UI before this sheet can present an alert,
    /// so we show a persistent banner here as well as logging to Console.app.
    @State private var publishErrorMessage: String?

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    header
                    scanSummaryCard
                    if let publishErrorMessage {
                        publishErrorBanner(publishErrorMessage)
                    }
                    roadflareDeleteOption
                    fullDeleteOption
                    if isDeleting {
                        deletingIndicator
                    }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Delete Events")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.rfSurface, for: .navigationBar)
        .navigationBarBackButtonHidden(isDeleting)
        .alert("Delete RoadFlare Events?", isPresented: $showRoadflareConfirm) {
            Button("Delete", role: .destructive) {
                // Flip isDeleting synchronously so rapid taps on the alert button
                // don't spawn a second concurrent deletion Task (SwiftUI alert
                // buttons aren't debounced and the .disabled(isDeleting) gate on
                // the page button doesn't cover the alert's confirm).
                isDeleting = true
                publishErrorMessage = nil
                Task { await performRoadflareDeletion() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will request deletion of \(scan.roadflareCount) RoadFlare event\(scan.roadflareCount == 1 ? "" : "s") from all relays, then remove all local data and log you out.")
        }
        .sheet(isPresented: $showFullDeleteSheet) {
            FullDeletionConfirmSheet(scan: scan) {
                isDeleting = true
                publishErrorMessage = nil
                Task { await performFullDeletion() }
            }
        }
    }

    // MARK: Subviews

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundColor(Color.rfError)
            Text("Review & Delete")
                .font(RFFont.headline(22))
                .foregroundColor(Color.rfOnSurface)
            Text("Step 2 of 2 — Choose What to Delete")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
        .padding(.top, 8)
    }

    private var scanSummaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(Color.rfPrimary)
                Text("Scan Results")
                    .font(RFFont.title(15))
                    .foregroundColor(Color.rfOnSurface)
            }
            // Use nested-Text interpolation (iOS 15+, recommended in iOS 26 over
            // deprecated Text + Text concatenation). The bold counts visually
            // anchor the summary while keeping surrounding text muted.
            Text("Found \(Text("\(scan.roadflareCount)").bold().foregroundColor(Color.rfOnSurface)) RoadFlare event\(scan.roadflareCount == 1 ? "" : "s") and \(Text("\(scan.metadataCount)").bold().foregroundColor(Color.rfOnSurface)) Nostr profile event\(scan.metadataCount == 1 ? "" : "s") across \(scan.targetRelayURLs.count) relays.")
                .font(RFFont.body(14))
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var roadflareDeleteOption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommended")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
                .textCase(.uppercase)
                .tracking(1)

            Button {
                showRoadflareConfirm = true
            } label: {
                Text("Delete RoadFlare Events")
            }
            .buttonStyle(RFDestructiveButtonStyle(isDisabled: isDeleting))
            .disabled(isDeleting)

            Text("Removes ride history, driver list, saved locations, and all protocol events from relays. Keeps your Nostr profile (Kind 0) intact so other Nostr apps still work.")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
                .padding(.horizontal, 4)
        }
    }

    private var fullDeleteOption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Complete Deletion")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
                .textCase(.uppercase)
                .tracking(1)

            Button {
                showFullDeleteSheet = true
            } label: {
                Text("Completely Delete Account")
            }
            .buttonStyle(RFDestructiveSecondaryButtonStyle())
            .disabled(isDeleting)

            Text("Removes everything above plus your Nostr profile (Kind 0). This may affect other Nostr apps using this identity.")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
                .padding(.horizontal, 4)
        }
    }

    private var deletingIndicator: some View {
        HStack(spacing: 12) {
            ProgressView().tint(Color.rfOnSurface)
            Text("Deleting…")
                .font(RFFont.body(15))
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func publishErrorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Color.rfError)
                Text("Deletion request failed")
                    .font(RFFont.title(14))
                    .foregroundColor(Color.rfOnSurface)
            }
            Text(message)
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Actions

    private func performRoadflareDeletion() async {
        // isDeleting and publishErrorMessage are set synchronously by the
        // confirm-button action (closes the rapid-tap race); defer guarantees
        // the UI is unstuck if deletion stops short of logout (publish failure
        // or active-ride guard hit). On success, logout() replaces the view
        // tree before this defer fires, so the reset is purely defensive.
        defer { isDeleting = false }
        let result = await appState.deleteRoadflareEvents(from: scan)
        // On success: logout() sets authState = .loggedOut → RootView replaces MainTabView → sheet dismissed.
        // On failure: AppState preserves the session so this banner can render and the user can retry
        // (logging out on publish failure would destroy the keypair before the user sees the error,
        // stranding their events on relays with no retry path).
        if !result.publishedSuccessfully, let err = result.publishError {
            publishErrorMessage = err
        }
    }

    private func performFullDeletion() async {
        defer { isDeleting = false }
        let result = await appState.deleteAllRidestrEvents(from: scan)
        if !result.publishedSuccessfully, let err = result.publishError {
            publishErrorMessage = err
        }
    }
}

// MARK: - Full Deletion Confirmation (checkbox sheet)

struct FullDeletionConfirmSheet: View {
    let scan: RelayScanResult
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var checkProfile = false
    @State private var checkOtherApps = false
    @State private var checkBackedUp = false

    private var allChecked: Bool {
        checkProfile && checkOtherApps && checkBackedUp
    }

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.system(size: 40))
                            .foregroundColor(Color.rfError)
                        Text("Complete Account Deletion")
                            .font(RFFont.headline(20))
                            .foregroundColor(Color.rfOnSurface)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 16)

                    Text("This deletes all \(scan.totalCount) event\(scan.totalCount == 1 ? "" : "s") including your Nostr profile (Kind 0 metadata). Please confirm you understand:")
                        .font(RFFont.body(14))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)

                    VStack(spacing: 0) {
                        confirmRow(
                            isOn: $checkProfile,
                            text: "I understand this deletes my Nostr profile (display name) from relays"
                        )
                        Divider().padding(.leading, 46)
                        confirmRow(
                            isOn: $checkOtherApps,
                            text: "I understand this may affect other Nostr apps that use this identity"
                        )
                        Divider().padding(.leading, 46)
                        confirmRow(
                            isOn: $checkBackedUp,
                            text: "I have backed up my private key, or I no longer need it"
                        )
                    }
                    .background(Color.rfSurfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    Button {
                        dismiss()
                        onConfirm()
                    } label: {
                        Text("Completely Delete Account")
                    }
                    .buttonStyle(RFDestructiveButtonStyle(isDisabled: !allChecked))
                    .disabled(!allChecked)

                    Button("Cancel") { dismiss() }
                        .buttonStyle(RFGhostButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        // .large instead of .medium — wrapped checkbox rows + three buttons don't
        // fit in half-screen on compact phones, and dragging between detents was
        // cutting the confirm button off below the fold.
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func confirmRow(isOn: Binding<Bool>, text: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundColor(isOn.wrappedValue ? Color.rfError : Color.rfOffline)
                    .frame(width: 24)
                Text(text)
                    .font(RFFont.body(14))
                    .foregroundColor(Color.rfOnSurface)
                    .multilineTextAlignment(.leading)
                    // Force the Text to take the full remaining width and let it
                    // wrap vertically as needed — without fixedSize the row keeps
                    // the text on one line and truncates at the trailing edge.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
