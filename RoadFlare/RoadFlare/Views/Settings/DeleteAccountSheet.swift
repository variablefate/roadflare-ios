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
        case scanning
        case complete(RelayScanResult)
        case failed(String)
    }

    /// Initial state is .scanning so the spinner + relay list render
    /// immediately; the actual scan kicks off in the .task modifier below.
    /// There is no "idle" state — a user opening this sheet has already
    /// committed to the delete flow, so asking them to press "Scan Relays"
    /// before anything happens was a redundant tap.
    @State private var phase: ScanPhase = .scanning

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
        .task {
            // Auto-start the scan when the view appears. Re-runs if the user
            // navigates back from page 2, which is acceptable — a fresh scan
            // reflects current relay state before they commit to deletion.
            await startScan()
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
                scanCompleteCard(scan)
                // Surface scan errors honestly — silent "0 events" when relays
                // were unreachable would mislead the user into thinking nothing
                // exists when their data may still be on those relays.
                if scan.hasErrors {
                    scanErrorWarning(scan)
                }

                NavigationLink {
                    DeleteAccountResultsView(scan: scan)
                } label: {
                    Text("Continue")
                }
                .buttonStyle(RFDestructiveButtonStyle())
            }

        case .failed:
            Button {
                Task { await startScan() }
            } label: {
                Text("Try Again")
            }
            .buttonStyle(RFSecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private func scanCompleteCard(_ scan: RelayScanResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(Color.rfPrimary)
                Text("Scan Complete")
                    .font(RFFont.title(15))
                    .foregroundColor(Color.rfOnSurface)
            }
            // Same nested-Text interpolation pattern as page 2's scan summary —
            // bold counts anchor the numbers, surrounding text stays muted.
            Text("Found \(Text("\(scan.roadflareCount)").bold().foregroundColor(Color.rfOnSurface)) RoadFlare event\(scan.roadflareCount == 1 ? "" : "s") and \(Text("\(scan.metadataCount)").bold().foregroundColor(Color.rfOnSurface)) Nostr profile event\(scan.metadataCount == 1 ? "" : "s") across \(scan.targetRelayURLs.count) relays created by your account.")
                .font(RFFont.body(14))
                .foregroundColor(Color.rfOnSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            Text("Continue to review and confirm deletion.")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

    /// Phases of the delete flow on page 2. Starts at .ready (show scan +
    /// delete button). Progresses through .publishing → .verifying → .success
    /// after user confirms in the checkbox sheet. .failed surfaces publish
    /// errors so the user can retry with the session still alive.
    enum Phase {
        case ready
        case publishing
        case verifying(deletedEventIds: [String])
        case success(DeletionVerificationResult)
        case failed(String)
    }

    @State private var phase: Phase = .ready
    @State private var checkProfile = false
    @State private var checkOtherApps = false
    @State private var checkBackedUp = false

    private var allChecked: Bool {
        checkProfile && checkOtherApps && checkBackedUp
    }

    private var isBusy: Bool {
        switch phase {
        case .publishing, .verifying: true
        default: false
        }
    }

    private var isSuccess: Bool {
        if case .success = phase { return true }
        return false
    }

    private var navTitle: String {
        switch phase {
        case .ready, .failed: "Delete Account"
        case .publishing, .verifying: "Deleting…"
        case .success: ""
        }
    }

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
            switch phase {
            case .success(let verification):
                successContent(verification)
            default:
                scanAndConfirmContent
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.rfSurface, for: .navigationBar)
        .navigationBarBackButtonHidden(isBusy || isSuccess)
    }

    // MARK: Scan + confirm (pre-delete)

    @ViewBuilder
    private var scanAndConfirmContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                scanSummaryCard
                confirmCheckboxes
                if case .failed(let msg) = phase {
                    publishErrorBanner(msg)
                }
                deleteAccountOption
                if isBusy {
                    deletingIndicator
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    // MARK: Subviews

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundColor(Color.rfError)
            Text("Delete Your Account")
                .font(RFFont.headline(22))
                .foregroundColor(Color.rfOnSurface)
            Text("Step 2 of 2 — Review & Confirm")
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

    private var confirmCheckboxes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Please confirm you understand:")
                .font(RFFont.body(14))
                .foregroundColor(Color.rfOnSurfaceVariant)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 0) {
                confirmRow(
                    isOn: $checkProfile,
                    text: "I understand this deletes all my RoadFlare events, Ridestr protocol events, and my Nostr profile (Kind 0 / display name) from relays"
                )
                Divider().padding(.leading, 46)
                confirmRow(
                    isOn: $checkOtherApps,
                    text: "I understand this may affect other Nostr apps that use this identity"
                )
                Divider().padding(.leading, 46)
                confirmRow(
                    isOn: $checkBackedUp,
                    text: "I understand this action cannot be undone"
                )
            }
            .background(Color.rfSurfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
    }

    private var deleteAccountOption: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                // Gated on allChecked above — this can only fire when all three
                // acknowledgements are ticked. Phase flip handled inside
                // performDeletion so cancel vs. retry behave consistently.
                Task { await performDeletion() }
            } label: {
                Text("Delete My Account")
            }
            // Grey (disabled style) until all three boxes are checked; flips to
            // red (destructive) once the user has confirmed every warning. The
            // third checkbox already acknowledges irreversibility, so no
            // additional caption is needed beneath the button.
            .buttonStyle(RFDestructiveButtonStyle(isDisabled: !allChecked || isBusy))
            .disabled(!allChecked || isBusy)
        }
    }

    private var deletingIndicator: some View {
        HStack(spacing: 12) {
            ProgressView().tint(Color.rfOnSurface)
            Text(deletingStatus)
                .font(RFFont.body(15))
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var deletingStatus: String {
        switch phase {
        case .publishing: "Publishing deletion request to relays…"
        case .verifying: "Verifying with relays…"
        default: "Deleting…"
        }
    }

    // MARK: Success (post-delete, pre-logout)

    @ViewBuilder
    private func successContent(_ verification: DeletionVerificationResult) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 96, weight: .regular))
                .foregroundColor(Color.rfOnline)
            VStack(spacing: 12) {
                Text("Account Deletion Successful")
                    .font(RFFont.headline(22))
                    .foregroundColor(Color.rfOnSurface)
                    .multilineTextAlignment(.center)
                // Only surface a detail line when verification turned up
                // something worth telling the user (partial deletion or relay
                // errors). On a clean success the checkmark + title say enough
                // — keeps the happy path uncluttered for the App Review video.
                if let detail = successDetail(for: verification) {
                    Text(detail)
                        .font(RFFont.body(14))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
            }
            Spacer()
            Button {
                Task { await appState.logout() }
            } label: {
                Text("Done")
            }
            .buttonStyle(RFPrimaryButtonStyle())
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Returns a detail string only when verification surfaced a partial
    /// deletion or relay-side check error. Fully-honoured and zero-event
    /// cases return nil so the success screen stays minimal.
    private func successDetail(for v: DeletionVerificationResult) -> String? {
        if v.requestedCount == 0 || v.fullyHonoured { return nil }
        if !v.scanErrors.isEmpty && v.remainingCount == 0 {
            return "Some relays couldn't be re-checked, but none of the reachable relays still hold your events."
        }
        return "\(v.deletedCount) of \(v.requestedCount) event\(v.requestedCount == 1 ? " was" : "s were") confirmed removed; some relays may still be processing or may not honour NIP-09."
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

    private func performDeletion() async {
        phase = .publishing
        let result = await appState.publishAccountDeletion(from: scan)
        guard result.publishedSuccessfully else {
            phase = .failed(result.publishError ?? "Unknown publish error")
            return
        }
        // Publish succeeded; verify before logging out so the user can see
        // whether relays actually honoured the request. The keypair + relay
        // manager stay alive through this step because logout() is deferred
        // until the user taps Done on the success screen.
        phase = .verifying(deletedEventIds: result.deletedEventIds)
        let verification = await appState.verifyAccountDeletion(eventIds: result.deletedEventIds)
        phase = .success(verification)
    }
}

