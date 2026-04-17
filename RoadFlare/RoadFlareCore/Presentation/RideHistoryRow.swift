import Foundation
import RidestrSDK

/// Display-ready representation of a ride history entry for list rows.
///
/// All display strings are pre-derived so the view only needs to render
/// plain text and a `Date` (for SwiftUI's `Text(_:style:)` which formats
/// dates itself).
public struct RideHistoryRow: Equatable, Sendable, Identifiable {

    // MARK: - Identity

    public let id: String

    // MARK: - Date

    /// The ride's date, used with SwiftUI's `Text(ride.date, style: .date)`.
    public let date: Date

    // MARK: - Counterparty

    /// Driver name or nil if unknown.
    public let counterpartyName: String?

    // MARK: - Route

    /// Pickup address string, or nil if unavailable.
    public let pickupAddress: String?

    /// Destination address string, or nil if unavailable.
    public let destinationAddress: String?

    // MARK: - Fare & Stats

    /// Formatted fare string, e.g. "$12.50".
    public let fareLabel: String

    /// Distance label, e.g. "4.2 mi", or nil.
    public let distanceLabel: String?

    /// Duration label, e.g. "18 min", or nil.
    public let durationLabel: String?

    /// Human-readable payment method label, e.g. "Cash App".
    public let paymentMethodLabel: String

    // MARK: - Status

    /// Whether the ride completed successfully (vs. cancelled/failed).
    public let isCompleted: Bool

    // MARK: - Factory

    /// Project a `RideHistoryEntry` into a display-ready row.
    public static func from(_ entry: RideHistoryEntry) -> RideHistoryRow {
        let fareLabel: String
        if entry.fare == 0 {
            fareLabel = "–"
        } else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.locale = Locale(identifier: "en_US")
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
            fareLabel = formatter.string(from: entry.fare as NSDecimalNumber) ?? "$\(entry.fare)"
        }

        let distanceLabel = entry.distance.map { String(format: "%.1f mi", $0) }
        let durationLabel = entry.duration.map { "\($0) min" }

        return RideHistoryRow(
            id: entry.id,
            date: entry.date,
            counterpartyName: entry.counterpartyName,
            pickupAddress: entry.pickup.address,
            destinationAddress: entry.destination.address,
            fareLabel: fareLabel,
            distanceLabel: distanceLabel,
            durationLabel: durationLabel,
            paymentMethodLabel: PaymentMethod.displayName(for: entry.paymentMethod),
            isCompleted: entry.status == "completed"
        )
    }
}
