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
                        LazyVStack(spacing: 12) {
                            ForEach(repo.drivers) { driver in
                                Button { selectedDriver = driver } label: {
                                    DriverCard(
                                        driver: driver,
                                        displayName: repo.driverNames[driver.pubkey] ?? driver.name,
                                        location: repo.driverLocations[driver.pubkey]
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                } else {
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
}

/// Driver card with flare indicator for online status.
struct DriverCard: View {
    let driver: FollowedDriver
    let displayName: String?
    let location: CachedDriverLocation?

    var body: some View {
        HStack(spacing: 12) {
            // Flare indicator
            FlareIndicator(color: statusColor)
                .frame(height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName ?? shortPubkey)
                    .font(RFFont.title(16))
                    .foregroundColor(Color.rfOnSurface)

                HStack(spacing: 6) {
                    StatusDot(status: statusString)
                    Text(statusText)
                        .font(RFFont.caption(12))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }

                if let note = driver.note, !note.isEmpty {
                    Text(note)
                        .font(RFFont.caption(12))
                        .foregroundColor(Color.rfOffline)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(Color.rfOffline)
        }
        .rfCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName ?? "Driver"), \(statusText)")
    }

    private var statusString: String {
        guard driver.hasKey else { return "offline" }
        return location?.status ?? "offline"
    }

    private var statusColor: Color {
        guard driver.hasKey else { return .rfOffline }
        guard let loc = location else { return .rfOffline }
        switch loc.status {
        case "online": return .rfOnline
        case "on_ride": return .rfOnRide
        default: return .rfOffline
        }
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

    private var shortPubkey: String {
        String(driver.pubkey.prefix(8)) + "..." + String(driver.pubkey.suffix(4))
    }
}
