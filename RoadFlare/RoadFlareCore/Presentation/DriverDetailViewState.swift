import Foundation
import RidestrSDK

/// Display-ready state for the driver detail sheet.
///
/// All strings are pre-resolved so the view doesn't need to touch any
/// SDK repository or derive logic.
public struct DriverDetailViewState: Equatable, Sendable {

    // MARK: - Identity

    /// Hex public key — used as a stable identifier for actions.
    public let pubkey: String

    /// Best available display name shown as the sheet title.
    public let displayName: String

    // MARK: - Status

    /// Human-readable status label: "Available", "On a ride", "Offline", "Pending approval".
    public let statusLabel: String

    /// Whether the "Request Ride" button should be shown (driver is online and has a key).
    public let canRequestRide: Bool

    // MARK: - Driver Info section

    /// Vehicle description (e.g. "Black Tesla Model S"), or nil if unknown.
    public let vehicleDescription: String?

    // MARK: - RoadFlare Key section

    /// Whether the driver has shared their RoadFlare key (follow approved).
    public let hasKey: Bool

    /// The key's version number, if a key is present.
    public let keyVersion: Int?

    // MARK: - Last Known Location section

    /// Raw status string from the last location broadcast (e.g. "online"), or nil if no location.
    public let lastLocationStatus: String?

    /// Human-readable relative time string for the last location update, or nil if no location.
    /// Example: "3 min ago"
    public let lastLocationTimestampLabel: String?

    // MARK: - Personal Note

    /// The rider's personal note for this driver (may be empty string).
    public let note: String

    // MARK: - Factory

    /// Project a `FollowedDriver` + repository context into a `DriverDetailViewState`.
    ///
    /// - Parameters:
    ///   - driver: The canonical driver model (should be the freshest copy from the repo).
    ///   - displayName: Best-available name already resolved by the repository.
    ///   - location: The driver's latest cached location broadcast, if any.
    ///   - profile: The driver's cached Kind 0 profile, if available.
    ///   - referenceDate: Used for relative timestamp formatting (injectable for testing).
    public static func from(
        _ driver: FollowedDriver,
        displayName: String?,
        location: CachedDriverLocation?,
        profile: UserProfileContent?,
        referenceDate: Date = .now
    ) -> DriverDetailViewState {
        let resolvedName = displayName
            ?? driver.name
            ?? (String(driver.pubkey.prefix(8)) + "...")

        let canRequestRide = driver.hasKey && location?.status == "online"

        let statusLabel: String
        if !driver.hasKey {
            statusLabel = "Pending approval"
        } else if let loc = location {
            switch loc.status {
            case "online":  statusLabel = "Available"
            case "on_ride": statusLabel = "On a ride"
            default:        statusLabel = "Offline"
            }
        } else {
            statusLabel = "Offline"
        }

        let lastLocationTimestampLabel: String?
        if let loc = location {
            let date = Date(timeIntervalSince1970: TimeInterval(loc.timestamp))
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            lastLocationTimestampLabel = formatter.localizedString(for: date, relativeTo: referenceDate)
        } else {
            lastLocationTimestampLabel = nil
        }

        return DriverDetailViewState(
            pubkey: driver.pubkey,
            displayName: resolvedName,
            statusLabel: statusLabel,
            canRequestRide: canRequestRide,
            vehicleDescription: profile?.vehicleDescription,
            hasKey: driver.hasKey,
            keyVersion: driver.roadflareKey?.version,
            lastLocationStatus: location?.status,
            lastLocationTimestampLabel: lastLocationTimestampLabel,
            note: driver.note ?? ""
        )
    }
}
