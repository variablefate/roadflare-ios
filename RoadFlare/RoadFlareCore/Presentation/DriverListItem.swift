import Foundation
import RidestrSDK

/// Display-ready representation of a followed driver for list/card views.
///
/// Projected from `FollowedDriver` + live `FollowedDriversRepository` state.
/// Does not expose raw Nostr keypair material or the `RoadflareKey` struct.
public struct DriverListItem: Equatable, Sendable, Identifiable {

    // MARK: - Identity

    /// Hex public key — used as a stable identifier for navigation and actions.
    public let pubkey: String

    /// `Identifiable` conformance keyed on `pubkey`.
    public var id: String { pubkey }

    /// Best available display name: caller-resolved `displayName` if set,
    /// otherwise `FollowedDriver.name`, otherwise a short pubkey prefix.
    public let displayName: String

    // MARK: - Status

    public enum Status: Equatable, Sendable {
        /// Driver has shared their key and is broadcasting "online".
        case online
        /// Driver is currently on a ride.
        case onRide
        /// Driver has a key but is not broadcasting (or broadcasting another status).
        case offline
        /// Driver has not yet approved the follow request (no key received).
        case pendingApproval
        /// Driver's key has been flagged as stale and needs refresh.
        case keyStale
    }

    public let status: Status

    /// `true` when the rider can tap "Request Now" for this driver.
    public var canRequestRide: Bool { status == .online }

    // MARK: - Profile extras (from cached Kind 0)

    /// Profile picture URL string, if available.
    public let pictureURL: String?

    /// Vehicle description string (e.g. "Black Tesla Model S"), if available.
    public let vehicleDescription: String?

    // MARK: - Action availability

    /// `true` when the ping bell should be shown for this driver.
    public let canPing: Bool

    // MARK: - Factory

    /// Project a `FollowedDriver` + its repository context into a `DriverListItem`.
    ///
    /// - Parameters:
    ///   - driver: The followed driver domain model.
    ///   - displayName: Display name from the repository if known; the factory falls back to driver.name then a short pubkey prefix.
    ///   - location: The driver's latest cached location broadcast, if any.
    ///   - profile: The driver's cached Kind 0 profile, if available.
    ///   - isKeyStale: Whether this driver's key has been flagged as stale.
    ///   - canPing: Whether the ping action is currently available.
    public static func from(
        _ driver: FollowedDriver,
        displayName: String?,
        location: CachedDriverLocation?,
        profile: UserProfileContent?,
        isKeyStale: Bool,
        canPing: Bool
    ) -> DriverListItem {
        let resolvedName = displayName
            ?? driver.name
            ?? (String(driver.pubkey.prefix(8)) + "...")

        let status = resolveDriverPresentationStatus(
            hasKey: driver.hasKey, isKeyStale: isKeyStale, location: location
        )

        return DriverListItem(
            pubkey: driver.pubkey,
            displayName: resolvedName,
            status: status,
            pictureURL: profile?.picture,
            vehicleDescription: profile?.vehicleDescription,
            canPing: canPing
        )
    }

    // MARK: - Convenience: sort order for the drivers list
    // Lower value = higher in list (online, onRide, keyStale, pendingApproval, offline).

    public var sortOrder: Int {
        switch status {
        case .online:          return 0
        case .onRide:          return 1
        case .keyStale:        return 2
        case .pendingApproval: return 3
        case .offline:         return 4
        }
    }
}
