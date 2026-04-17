import SwiftUI
import RoadFlareCore

struct HistoryTab: View {
    @Environment(AppState.self) private var appState
    @State private var showProfile = false
    @State private var showConnectivity = false
    @State private var isOffline = false

    var body: some View {
        // Capture once per body — `rideHistoryRows` allocates a NumberFormatter
        // per row on every access, and body would otherwise read it twice
        // (empty check + ForEach).
        let rows = appState.rideHistoryRows
        return NavigationStack {
            VStack(spacing: 0) {
                AppHeader(title: "History", showProfile: $showProfile, showConnectivity: $showConnectivity, isOffline: isOffline)

                ZStack {
                    Color.rfSurface

                    if rows.isEmpty {
                    VStack(spacing: 24) {
                        Image(systemName: "clock")
                            .font(.system(size: 48))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                        Text("No Rides Yet")
                            .font(RFFont.headline(20))
                            .foregroundColor(Color.rfOnSurface)
                        Text("Your completed rides will appear here.")
                            .font(RFFont.body(15))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(rows) { row in
                                SwipeToDeleteRow {
                                    // History cards are currently read-only.
                                } onDelete: {
                                    withAnimation {
                                        appState.removeRideHistoryEntry(id: row.id)
                                    }
                                } content: {
                                    RideHistoryCard(row: row)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                }
            }
            }
            .background(Color.rfSurface)
            .navigationBarHidden(true)
            .sheet(isPresented: $showProfile) { EditProfileSheet() }
            .sheet(isPresented: $showConnectivity) { ConnectivitySheet() }
            .task {
                while !Task.isCancelled {
                    isOffline = !(await appState.isRelayConnected())
                    try? await Task.sleep(for: .seconds(10))
                }
            }
        }
    }
}

struct RideHistoryCard: View {
    let row: RideHistoryRow

    var body: some View {
        HStack(spacing: 12) {
            FlareIndicator(color: row.isCompleted ? .rfOnline : .rfError)
                .frame(height: 50)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(row.date, style: .date)
                        .font(RFFont.title(15))
                        .foregroundColor(Color.rfOnSurface)
                    Spacer()
                    Text(row.fareLabel)
                        .font(RFFont.headline(18))
                        .foregroundColor(Color.rfPrimary)
                }

                if let name = row.counterpartyName {
                    Text(name)
                        .font(RFFont.caption(13))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }

                if let pickup = row.pickupAddress, let dest = row.destinationAddress {
                    HStack(spacing: 4) {
                        Text(pickup)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                        Text(dest)
                    }
                    .font(RFFont.caption(11))
                    .foregroundColor(Color.rfOffline)
                    .lineLimit(1)
                }

                HStack(spacing: 12) {
                    if let dist = row.distanceLabel {
                        Text(dist)
                    }
                    if let dur = row.durationLabel {
                        Text(dur)
                    }
                    Text(row.paymentMethodLabel)
                }
                .font(RFFont.caption(11))
                .foregroundColor(Color.rfOffline)
            }
        }
        .rfCard()
    }
}
