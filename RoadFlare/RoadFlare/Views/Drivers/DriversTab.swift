import SwiftUI
import RidestrSDK

struct DriversTab: View {
    @Environment(AppState.self) private var appState
    @State private var showAddDriver = false
    @State private var selectedDriver: FollowedDriver?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                if let repo = appState.driversRepository, repo.hasDrivers {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Sorted: online first, then on_ride, then offline
                            ForEach(sortedDrivers(repo: repo)) { driver in
                                DriverCard(
                                    driver: driver,
                                    repo: repo,
                                    onRequest: {
                                        appState.requestRideDriverPubkey = driver.pubkey
                                        appState.selectedTab = 1
                                    },
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
            .navigationTitle("My Drivers")
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectivityIndicator() }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddDriver = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(Color.rfPrimary)
                    }
                }
            }
            .sheet(isPresented: $showAddDriver) { AddDriverSheet() }
            .sheet(item: $selectedDriver) { driver in DriverDetailSheet(driver: driver) }
        }
    }

    /// Sort drivers: online first, then on_ride, then pending, then offline.
    private func sortedDrivers(repo: FollowedDriversRepository) -> [FollowedDriver] {
        repo.drivers.sorted { a, b in
            driverSortOrder(a, repo: repo) < driverSortOrder(b, repo: repo)
        }
    }

    private func driverSortOrder(_ driver: FollowedDriver, repo: FollowedDriversRepository) -> Int {
        guard driver.hasKey else { return 3 }  // Pending approval
        guard let loc = repo.driverLocations[driver.pubkey] else { return 4 }  // Offline (no location)
        switch loc.status {
        case "online": return 0
        case "on_ride": return 1
        default: return 4
        }
    }
}

// MARK: - Driver Card

struct DriverCard: View {
    let driver: FollowedDriver
    let repo: FollowedDriversRepository
    let onRequest: () -> Void
    let onTap: () -> Void

    private var profile: UserProfileContent? { repo.driverProfiles[driver.pubkey] }
    private var location: CachedDriverLocation? { repo.driverLocations[driver.pubkey] }
    private var displayName: String {
        repo.driverNames[driver.pubkey] ?? driver.name ?? shortPubkey
    }

    var body: some View {
        HStack(spacing: 14) {
            // Profile photo / avatar
            driverAvatar

            // Info + action
            VStack(alignment: .leading, spacing: 6) {
                // Name
                Text(displayName)
                    .font(RFFont.title(17))
                    .foregroundColor(Color.rfOnSurface)
                    .lineLimit(1)

                // Vehicle + status line
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

                // Action button / status badge
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
        }
        .padding(14)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .leading) {
            // Left accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(statusAccentColor)
                .frame(width: 3)
                .padding(.vertical, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName), \(statusText)")
        .accessibilityHint("Tap for driver details")
    }

    // MARK: - Avatar

    private var driverAvatar: some View {
        Group {
            if let pictureURL = profile?.picture, let url = URL(string: pictureURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    avatarPlaceholder
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 12))
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

    private var isOnline: Bool {
        driver.hasKey && location?.status == "online"
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
