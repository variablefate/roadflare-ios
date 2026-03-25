import SwiftUI
import RidestrSDK

struct HistoryTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            ZStack {
                Color.rfSurface.ignoresSafeArea()

                if appState.rideHistory.rides.isEmpty {
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
                            ForEach(appState.rideHistory.rides) { ride in
                                RideHistoryCard(ride: ride)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                }
            }
            .navigationTitle("History")
            .toolbarBackground(Color.rfSurface, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }
}

struct RideHistoryCard: View {
    let ride: RideHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            FlareIndicator(color: ride.status == "completed" ? .rfOnline : .rfError)
                .frame(height: 50)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(ride.date, style: .date)
                        .font(RFFont.title(15))
                        .foregroundColor(Color.rfOnSurface)
                    Spacer()
                    Text(formatFare(ride.fare))
                        .font(RFFont.headline(18))
                        .foregroundColor(Color.rfPrimary)
                }

                if let name = ride.counterpartyName {
                    Text(name)
                        .font(RFFont.caption(13))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }

                if let pickup = ride.pickup.address, let dest = ride.destination.address {
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
                    if let dist = ride.distance {
                        Text(String(format: "%.1f mi", dist))
                    }
                    if let dur = ride.duration {
                        Text("\(dur) min")
                    }
                    Text(ride.paymentMethod.capitalized)
                }
                .font(RFFont.caption(11))
                .foregroundColor(Color.rfOffline)
            }
        }
        .rfCard()
    }
}
