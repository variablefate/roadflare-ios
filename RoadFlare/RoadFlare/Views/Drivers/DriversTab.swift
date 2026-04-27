import SwiftUI
import RidestrSDK
import RoadFlareCore

struct DriversTab: View {
    @Environment(AppState.self) private var appState
    @State private var showAddDriver = false
    /// Captured from `appState.pendingDriverDeepLink` when a `roadflared:` URL
    /// arrives, then handed to `AddDriverSheet` as initial input. Cleared when
    /// the sheet dismisses.
    @State private var addDriverPrefill: ParsedDriverQRCode?
    @State private var selectedDriver: DriverListItem?
    @State private var showProfile = false
    @State private var showConnectivity = false
    @State private var isOffline = false
    @State private var sharingDriver: DriverListItem?
    @State private var pingToastMessage: String?
    @State private var pingToastIsError = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppHeader(title: "Favorite", subtitle: "Drivers", showProfile: $showProfile, showConnectivity: $showConnectivity, isOffline: isOffline)

                ZStack {
                    Color.rfSurface

                    if appState.hasFollowedDrivers {
                    ScrollView {
                        VStack(spacing: 16) {
                            ForEach(appState.driverListItems()) { item in
                                DriverCard(
                                    item: item,
                                    onRequest: {
                                        appState.requestRideDriverPubkey = item.pubkey
                                        appState.selectedTab = 0
                                    },
                                    onShare: { sharingDriver = item },
                                    onPing: { pingDriver(item) },
                                    onDelete: { appState.removeDriver(pubkey: item.pubkey) },
                                    onTap: { selectedDriver = item }
                                )
                            }

                            // Add driver card
                            Button { showAddDriver = true } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(Color.rfPrimary.opacity(0.1))
                                            .frame(width: 64, height: 64)
                                        Image(systemName: "person.badge.plus")
                                            .font(.system(size: 24))
                                            .foregroundColor(Color.rfPrimary)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Add New Driver")
                                            .font(RFFont.title(16))
                                            .foregroundColor(Color.rfOnSurface)
                                        Text("Scan QR code or enter Account ID")
                                            .font(RFFont.caption(13))
                                            .foregroundColor(Color.rfOnSurfaceVariant)
                                    }
                                    Spacer()
                                }
                                .padding(16)
                                .background(Color.rfSurfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .strokeBorder(Color.rfPrimary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [6]))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                } else {
                    // Empty state
                    VStack(spacing: 24) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 48))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                        Text("No Drivers Yet")
                            .font(RFFont.headline(20))
                            .foregroundColor(Color.rfOnSurface)
                        Text("Add drivers you know and trust\nto your personal network.")
                            .font(RFFont.body(15))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                            .multilineTextAlignment(.center)
                        Button("Add Your First Driver") { showAddDriver = true }
                            .buttonStyle(RFPrimaryButtonStyle())
                            .padding(.horizontal, 48)
                    }
                }
                }
            }
            .background(Color.rfSurface)
            .navigationBarHidden(true)
            .sheet(isPresented: $showConnectivity) { ConnectivitySheet() }
            .sheet(isPresented: $showAddDriver, onDismiss: {
                // Clear deep-link state once the sheet is dismissed (whether it
                // completed the add or the user cancelled). Do NOT clear before
                // dismiss — the sheet reads `addDriverPrefill` after its first
                // render to seed input.
                addDriverPrefill = nil
                appState.pendingDriverDeepLink = nil
            }) {
                AddDriverSheet(prefill: addDriverPrefill)
            }
            .sheet(item: $selectedDriver) { item in DriverDetailSheet(pubkey: item.pubkey) }
            .sheet(isPresented: $showProfile) { EditProfileSheet() }
            .sheet(item: $sharingDriver) { item in
                // Pass the raw cached name (nil when unresolved) rather than
                // item.displayName. DriverListItem.displayName falls back to a
                // "<pubkey-prefix>..." string, which the share sheet would URL-
                // encode into the `?name=` deeplink param — surfacing the pubkey
                // prefix as a "name" on the scanning rider's side.
                DriverShareSheet(
                    pubkey: item.pubkey,
                    driverName: appState.driverDisplayName(pubkey: item.pubkey),
                    pictureURL: item.pictureURL
                )
            }
            .refreshable {
                await refreshDrivers()
            }
            .task {
                while !Task.isCancelled {
                    isOffline = !(await appState.isRelayConnected())
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .onChange(of: appState.pendingDriverDeepLink) { _, newValue in
                // A `roadflared:` URL arrived. Capture the parsed payload into
                // local state and present the Add Driver sheet pre-filled.
                guard let parsed = newValue else { return }
                addDriverPrefill = parsed
                showAddDriver = true
            }
            .task {
                // On first appearance, also consume any pending deep link that
                // was set before the view rendered (cold-start path: `.onOpenURL`
                // fires very early; the drivers tab may not have mounted yet).
                if let parsed = appState.pendingDriverDeepLink {
                    addDriverPrefill = parsed
                    showAddDriver = true
                }
            }
            .toast($pingToastMessage, isError: pingToastIsError)
        }
    }

    private func pingDriver(_ item: DriverListItem) {
        let driverPubkey = item.pubkey
        let name = item.displayName
        Task {
            let result = await appState.sendDriverPing(driverPubkey: driverPubkey)
            switch result {
            case .sent:
                pingToastMessage = "Ping sent to \(name)"
                pingToastIsError = false
            case .rateLimited(let retryAt):
                let remaining = Int(retryAt.timeIntervalSinceNow / 60) + 1
                pingToastMessage = "Wait \(remaining) min before pinging \(name) again"
                pingToastIsError = true
            case .missingKey:
                pingToastMessage = "Can't ping \(name) right now"
                pingToastIsError = true
            case .ineligible:
                pingToastMessage = "Can't ping \(name) right now"
                pingToastIsError = true
            case .publishFailed:
                pingToastMessage = "Couldn't send ping — check your connection"
                pingToastIsError = true
            }
        }
    }

    private func refreshDrivers() async {
        appState.refreshDriverLocations()
        await appState.checkForStaleDriverKeys()
    }
}

// MARK: - Driver Card

struct DriverCard: View {
    let item: DriverListItem
    let onRequest: () -> Void
    let onShare: () -> Void
    let onPing: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                driverAvatar

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.displayName)
                        .font(RFFont.title(17))
                        .foregroundColor(Color.rfOnSurface)
                        .lineLimit(1)

                    HStack(spacing: 0) {
                        if let vehicle = item.vehicleDescription {
                            Text(vehicle.uppercased())
                                .font(RFFont.caption(11))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                            Text(" · ")
                                .font(RFFont.caption(11))
                                .foregroundColor(Color.rfOffline)
                        }
                        Text(statusText)
                            .font(RFFont.caption(11))
                            .foregroundColor(statusColor)
                    }
                    .lineLimit(1)

                    // Status badge / request button
                    if item.canRequestRide {
                        Button(action: onRequest) {
                            Text("Request Now")
                                .font(RFFont.title(13))
                                .foregroundColor(.black)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.rfPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    } else if item.status == .keyStale {
                        Text("Key Outdated")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfError)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.rfError.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if item.status == .pendingApproval {
                        Text("Pending Approval")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfTertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.rfTertiary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Text("Unavailable")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOffline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.rfSurfaceContainerHigh)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if item.canPing {
                        Button(action: onPing) {
                            Image(systemName: "bell")
                                .font(.system(size: 16))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                                .frame(width: 44, height: 44)
                                .background(Color.rfSurfaceContainerHigh)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ping driver")
                        .accessibilityHint("Sends a notification asking the driver to come online")
                    }

                    Button(action: onShare) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                            .frame(width: 44, height: 44)
                            .background(Color.rfSurfaceContainerHigh)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 3)
                .padding(.vertical, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Remove Driver", systemImage: "trash")
            }
        }
        .confirmationDialog("Remove \(item.displayName)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Remove Driver", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to remove this driver from your network?")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.displayName), \(statusText)")
        .accessibilityHint("Tap for driver details, swipe to delete")
    }

    // MARK: - Avatar

    private var driverAvatar: some View {
        Group {
            if let pictureURL = item.pictureURL, let url = URL(string: pictureURL) {
                CachedAsyncImage(url: url, size: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .background(avatarPlaceholder)
            } else {
                avatarPlaceholder
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.rfSurfaceContainer, lineWidth: 2))
                .offset(x: 2, y: 2)
        }
    }

    private var avatarPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.rfSurfaceContainerHigh)
                .frame(width: 64, height: 64)
            Image(systemName: "person.fill")
                .font(.system(size: 28))
                .foregroundColor(Color.rfOffline)
        }
    }

    // MARK: - Status

    private var statusText: String {
        switch item.status {
        case .online:          return "Available"
        case .onRide:          return "On a ride"
        case .keyStale:        return "Key outdated"
        case .pendingApproval: return "Waiting for key"
        case .offline:         return "Offline"
        }
    }

    /// The driver's status accent color — used for the left rail, the status-
    /// text color, and the avatar dot overlay. All three share the same mapping
    /// so a stale-key row stays red across every surface without drift.
    private var statusColor: Color {
        switch item.status {
        case .online:          return .rfOnline
        case .onRide:          return .rfOnRide
        case .keyStale:        return .rfError
        case .pendingApproval: return .rfTertiary
        case .offline:         return .rfOffline
        }
    }
}
