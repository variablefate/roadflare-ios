import SwiftUI
import RidestrSDK

/// Drivers tab: view and manage your trusted driver network.
struct DriversTab: View {
    @Environment(AppState.self) private var appState
    @State private var showAddDriver = false
    @State private var selectedDriver: FollowedDriver?

    var body: some View {
        NavigationStack {
            Group {
                if let repo = appState.driversRepository, repo.hasDrivers {
                    driverList(repo: repo)
                } else {
                    emptyState
                }
            }
            .navigationTitle("My Drivers")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectivityIndicator()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddDriver = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddDriver) {
                AddDriverSheet()
            }
            .sheet(item: $selectedDriver) { driver in
                DriverDetailSheet(driver: driver)
            }
        }
    }

    private func driverList(repo: FollowedDriversRepository) -> some View {
        List {
            ForEach(repo.drivers) { driver in
                Button {
                    selectedDriver = driver
                } label: {
                    DriverRow(
                        driver: driver,
                        displayName: repo.driverNames[driver.pubkey] ?? driver.name,
                        location: repo.driverLocations[driver.pubkey]
                    )
                }
                .buttonStyle(.plain)
            }
            .onDelete { indexSet in
                for index in indexSet {
                    let driver = repo.drivers[index]
                    repo.removeDriver(pubkey: driver.pubkey)
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Drivers Yet", systemImage: "person.2.slash")
        } description: {
            Text("Add drivers you know and trust to your personal network.")
        } actions: {
            Button("Add Your First Driver") {
                showAddDriver = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// A single driver row in the list.
struct DriverRow: View {
    let driver: FollowedDriver
    let displayName: String?
    let location: CachedDriverLocation?

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName ?? shortPubkey)
                    .font(.body.bold())

                HStack(spacing: 4) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !driver.hasKey {
                        Text("Pending approval")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if let note = driver.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        guard driver.hasKey else { return .gray }
        guard let loc = location else { return .gray }
        switch loc.status {
        case "online": return .green
        case "on_ride": return .orange
        default: return .gray
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
        let hex = driver.pubkey
        return String(hex.prefix(8)) + "..." + String(hex.suffix(4))
    }
}
