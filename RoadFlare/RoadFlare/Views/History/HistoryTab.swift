import SwiftUI
import RidestrSDK

/// History tab: past rides.
struct HistoryTab: View {
    // TODO: Wire up to RideHistoryRepository
    @State private var rides: [RideHistoryEntry] = []

    var body: some View {
        NavigationStack {
            Group {
                if rides.isEmpty {
                    ContentUnavailableView {
                        Label("No Rides Yet", systemImage: "clock")
                    } description: {
                        Text("Your completed rides will appear here.")
                    }
                } else {
                    List(rides) { ride in
                        RideHistoryRow(ride: ride)
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectivityIndicator()
                }
            }
        }
    }
}

struct RideHistoryRow: View {
    let ride: RideHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: ride.status == "completed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ride.status == "completed" ? .green : .red)
                    .font(.caption)
                Text(ride.date, style: .date)
                    .font(.subheadline.bold())
                Spacer()
                Text("$\(ride.fare as NSDecimalNumber)")
                    .font(.subheadline.bold())
            }

            if let pickup = ride.pickup.address {
                Text(pickup)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let dest = ride.destination.address {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                    Text(dest)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if let dist = ride.distance {
                    Text(String(format: "%.1f mi", dist))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let dur = ride.duration {
                    Text("\(dur) min")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(ride.paymentMethod.capitalized)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
