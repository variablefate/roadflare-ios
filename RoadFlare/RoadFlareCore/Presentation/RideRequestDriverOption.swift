import Foundation
import RidestrSDK

/// Display-ready representation of an online driver option in the ride request flow.
///
/// Only drivers that are online (have a key and are broadcasting "online") should
/// be projected into this type — the factory enforces that precondition.
public struct RideRequestDriverOption: Equatable, Sendable, Identifiable {

    // MARK: - Identity

    /// Hex public key — used as the selection key and action identifier.
    public var id: String { pubkey }
    public let pubkey: String

    /// Display name for the driver option row.
    public let displayName: String

    // MARK: - Factory

    /// Project an online `FollowedDriver` into a ride-request driver option.
    ///
    /// Returns `nil` if the driver is not eligible (no key or not online).
    ///
    /// - Parameters:
    ///   - driver: The followed driver domain model.
    ///   - displayName: Best-available name already resolved by the repository.
    ///   - location: The driver's latest cached location broadcast.
    public static func from(
        _ driver: FollowedDriver,
        displayName: String?,
        location: CachedDriverLocation?
    ) -> RideRequestDriverOption? {
        guard driver.hasKey, location?.status == "online" else { return nil }

        let resolvedName = displayName
            ?? driver.name
            ?? (String(driver.pubkey.prefix(8)) + "...")

        return RideRequestDriverOption(
            pubkey: driver.pubkey,
            displayName: resolvedName
        )
    }

    // MARK: - Convenience

    /// Build the full list of available driver options from a repository snapshot.
    ///
    /// Drivers are included only when they have a key and are broadcasting "online".
    ///
    /// - Parameters:
    ///   - drivers: All followed drivers.
    ///   - driverNames: Cached display name map from the repository.
    ///   - driverLocations: Cached location map from the repository.
    public static func onlineOptions(
        from drivers: [FollowedDriver],
        driverNames: [String: String],
        driverLocations: [String: CachedDriverLocation]
    ) -> [RideRequestDriverOption] {
        drivers.compactMap { driver in
            from(
                driver,
                displayName: driverNames[driver.pubkey],
                location: driverLocations[driver.pubkey]
            )
        }
    }
}
