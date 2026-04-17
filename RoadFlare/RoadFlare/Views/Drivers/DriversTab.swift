import SwiftUI
import RidestrSDK
import RoadFlareCore

struct DriversTab: View {
    @Environment(AppState.self) private var appState
    @State private var showAddDriver = false
    @State private var selectedDriver: FollowedDriver?
    @State private var showProfile = false
    @State private var showConnectivity = false
    @State private var isOffline = false
    @State private var sharingDriver: FollowedDriver?
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
                            // Sorted: online first, then on_ride, then offline
                            ForEach(sortedDrivers) { driver in
                                DriverCard(
                                    driver: driver,
                                    onRequest: {
                                        appState.requestRideDriverPubkey = driver.pubkey
                                        appState.selectedTab = 0  // RoadFlare tab
                                    },
                                    onShare: { shareDriver(driver) },
                                    onPing: { pingDriver(driver) },
                                    onDelete: { appState.removeDriver(pubkey: driver.pubkey) },
                                    onTap: { selectedDriver = driver }
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
            .sheet(isPresented: $showAddDriver) { AddDriverSheet() }
            .sheet(item: $selectedDriver) { driver in DriverDetailSheet(driver: driver) }
            .sheet(isPresented: $showProfile) { EditProfileSheet() }
            .sheet(item: $sharingDriver) { driver in
                DriverShareSheet(
                    driver: driver,
                    driverName: appState.driverDisplayName(pubkey: driver.pubkey) ?? driver.name,
                    driverProfile: appState.driverProfile(pubkey: driver.pubkey)
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
            .toast($pingToastMessage, isError: pingToastIsError)
        }
    }

    private func shareDriver(_ driver: FollowedDriver) {
        sharingDriver = driver
    }

    private func pingDriver(_ driver: FollowedDriver) {
        // Capture pubkey as a plain String (Sendable) before the task boundary so
        // `driver` (a struct that may not be Sendable) doesn't need to cross the
        // isolation boundary.
        let driverPubkey = driver.pubkey
        Task {
            let result = await appState.sendDriverPing(driverPubkey: driverPubkey)
            let name = appState.driverDisplayName(pubkey: driverPubkey)
                ?? String(driverPubkey.prefix(8)) + "..."
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

    /// Sort drivers: online first, then on_ride, then pending, then offline.
    private var sortedDrivers: [FollowedDriver] {
        appState.followedDrivers.sorted { a, b in
            driverSortOrder(a) < driverSortOrder(b)
        }
    }

    private func driverSortOrder(_ driver: FollowedDriver) -> Int {
        guard driver.hasKey else { return 3 }  // Pending approval
        guard let loc = appState.driverLocation(pubkey: driver.pubkey) else { return 4 }  // Offline (no location)
        switch loc.status {
        case "online": return 0
        case "on_ride": return 1
        default: return 4
        }
    }
}

// MARK: - Driver Card

struct DriverCard: View {
    @Environment(AppState.self) private var appState
    let driver: FollowedDriver
    let onRequest: () -> Void
    let onShare: () -> Void
    let onPing: () -> Void
    let onDelete: () -> Void
    let onTap: () -> Void

    private var profile: UserProfileContent? { appState.driverProfile(pubkey: driver.pubkey) }
    private var location: CachedDriverLocation? { appState.driverLocation(pubkey: driver.pubkey) }
    private var displayName: String {
        appState.driverDisplayName(pubkey: driver.pubkey) ?? driver.name ?? shortPubkey
    }

    @State private var showDeleteConfirm = false

    var body: some View {
        HStack(spacing: 0) {
            // Main card content (tappable)
            HStack(spacing: 14) {
                driverAvatar

                VStack(alignment: .leading, spacing: 6) {
                    Text(displayName)
                        .font(RFFont.title(17))
                        .foregroundColor(Color.rfOnSurface)
                        .lineLimit(1)

                    HStack(spacing: 0) {
                        if let vehicle = profile?.vehicleDescription {
                            Text(vehicle.uppercased())
                                .font(RFFont.caption(11))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                            Text(" · ")
                                .font(RFFont.caption(11))
                                .foregroundColor(Color.rfOffline)
                        }
                        Text(statusText)
                            .font(RFFont.caption(11))
                            .foregroundColor(statusAccentColor)
                    }
                    .lineLimit(1)

                    // Status badge / request button
                    if isOnline {
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
                    } else if hasStaleKey {
                        Text("Key Outdated")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfError)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(Color.rfError.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if !driver.hasKey {
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

                // Action buttons (right side) — bell (if pingable) then share
                HStack(spacing: 8) {
                    if appState.canPingDriver(driver) {
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
                .fill(statusAccentColor)
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
        .confirmationDialog("Remove \(displayName)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Remove Driver", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to remove this driver from your network?")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName), \(statusText)")
        .accessibilityHint("Tap for driver details, swipe to delete")
    }

    // MARK: - Avatar

    private var driverAvatar: some View {
        Group {
            if let pictureURL = profile?.picture, let url = URL(string: pictureURL) {
                CachedAsyncImage(url: url, size: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .background(
                        avatarPlaceholder
                    )
            } else {
                avatarPlaceholder
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Status dot
            Circle()
                .fill(statusDotColor)
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

    private var hasStaleKey: Bool {
        appState.isDriverKeyStale(pubkey: driver.pubkey)
    }

    private var isOnline: Bool {
        driver.hasKey
            && !appState.isDriverKeyStale(pubkey: driver.pubkey)
            && location?.status == "online"
    }

    private var statusText: String {
        guard driver.hasKey else { return "Waiting for key" }
        guard let loc = location else { return "Offline" }
        switch loc.status {
        case "online": return "Available"
        case "on_ride": return "On a ride"
        default: return "Offline"
        }
    }

    private var statusAccentColor: Color {
        guard driver.hasKey else { return .rfTertiary }
        guard let loc = location else { return .rfOffline }
        switch loc.status {
        case "online": return .rfOnline
        case "on_ride": return .rfOnRide
        default: return .rfOffline
        }
    }

    private var statusDotColor: Color {
        guard driver.hasKey else { return .rfTertiary }
        guard let loc = location else { return .rfOffline }
        switch loc.status {
        case "online": return .rfOnline
        case "on_ride": return .rfOnRide
        default: return .rfOffline
        }
    }

    private var shortPubkey: String {
        String(driver.pubkey.prefix(8)) + "..."
    }
}
