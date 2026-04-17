import Foundation
import RidestrSDK

/// Display-ready state for the driver detail sheet.
///
/// All strings are pre-resolved so the view doesn't need to touch any
/// SDK repository or derive logic.
public struct DriverDetailViewState: Equatable, Sendable, Identifiable {

    // MARK: - Identity

    /// Hex public key — used as a stable identifier for actions.
    public let pubkey: String

    /// `Identifiable` conformance keyed on `pubkey`.
    public var id: String { pubkey }

    /// Best available display name shown as the sheet title.
    public let displayName: String

    // MARK: - Status

    /// Human-readable status label: "Available", "On a ride", "Offline", "Pending approval", "Key outdated".
    public let statusLabel: String

    /// Whether the "Request Ride" button should be shown (driver is online, has a key, and the key is not stale).
    public let canRequestRide: Bool

    // MARK: - Driver Info section

    /// Profile picture URL string, if available.
    public let pictureURL: String?

    /// Vehicle description (e.g. "Black Tesla Model S"), or nil if unknown.
    public let vehicleDescription: String?

    // MARK: - Action availability

    /// `true` when the ping bell should be shown for this driver.
    public let canPing: Bool

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
    ///   - displayName: Display name from the repository if known; the factory falls back to driver.name then a short pubkey prefix.
    ///   - location: The driver's latest cached location broadcast, if any.
    ///   - profile: The driver's cached Kind 0 profile, if available.
    ///   - isKeyStale: Whether this driver's key has been flagged as stale.
    ///   - canPing: Whether the ping action is currently available for this driver.
    ///   - referenceDate: Used for relative timestamp formatting (injectable for testing).
    ///   - locale: Locale used for the relative timestamp. Defaults to `.current` so
    ///     production output follows the device locale; tests may inject a fixed locale.
    public static func from(
        _ driver: FollowedDriver,
        displayName: String?,
        location: CachedDriverLocation?,
        profile: UserProfileContent?,
        isKeyStale: Bool,
        canPing: Bool,
        referenceDate: Date = .now,
        locale: Locale = .current
    ) -> DriverDetailViewState {
        let resolvedName = displayName
            ?? driver.name
            ?? (String(driver.pubkey.prefix(8)) + "...")

        let canRequestRide = driver.hasKey && !isKeyStale && location?.status == "online"
        let status = resolveDriverPresentationStatus(
            hasKey: driver.hasKey, isKeyStale: isKeyStale, location: location
        )
        let statusLabel = status.detailLabel

        // Suppress the raw location fields when the key is stale — showing "3 min ago"
        // next to "Key outdated" contradicts itself, since that broadcast was decrypted
        // with the pre-rotation key and no longer reflects the driver's current state.
        let lastLocationTimestampLabel: String?
        if let loc = location, !isKeyStale {
            let date = Date(timeIntervalSince1970: TimeInterval(loc.timestamp))
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            formatter.locale = locale
            lastLocationTimestampLabel = formatter.localizedString(for: date, relativeTo: referenceDate)
        } else {
            lastLocationTimestampLabel = nil
        }

        return DriverDetailViewState(
            pubkey: driver.pubkey,
            displayName: resolvedName,
            statusLabel: statusLabel,
            canRequestRide: canRequestRide,
            pictureURL: profile?.picture,
            vehicleDescription: profile?.vehicleDescription,
            canPing: canPing,
            hasKey: driver.hasKey,
            keyVersion: driver.roadflareKey?.version,
            lastLocationStatus: isKeyStale ? nil : location?.status,
            lastLocationTimestampLabel: lastLocationTimestampLabel,
            note: driver.note ?? ""
        )
    }
}
