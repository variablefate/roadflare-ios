import Foundation
import RidestrSDK

/// Display-ready representation of an online driver option in the ride request flow.
///
/// Only drivers that are requestable — as determined by
/// `FollowedDriversRepository.canRequestRide(_:)` — should be projected into
/// this type. The factory enforces that precondition and returns `nil` otherwise.
public struct RideRequestDriverOption: Equatable, Sendable, Identifiable {

    // MARK: - Identity

    /// Hex public key — used as the selection key and action identifier.
    public var id: String { pubkey }
    public let pubkey: String

    /// Display name for the driver option row.
    public let displayName: String

    // MARK: - Factory

    /// Project a `FollowedDriver` into a ride-request driver option.
    ///
    /// Returns `nil` when `canRequestRide` is `false`. The eligibility decision
    /// itself is the SDK's responsibility (`FollowedDriversRepository.canRequestRide(_:)`);
    /// this factory is a pure projection that trusts the resolved boolean. See issue #94.
    ///
    /// - Parameters:
    ///   - driver: The followed driver domain model.
    ///   - displayName: Display name from the repository if known; the factory falls back to driver.name then a short pubkey prefix.
    ///   - canRequestRide: Whether a ride can currently be requested from this driver.
    public static func from(
        _ driver: FollowedDriver,
        displayName: String?,
        canRequestRide: Bool
    ) -> RideRequestDriverOption? {
        guard canRequestRide else { return nil }

        let resolvedName = displayName
            ?? driver.name
            ?? (String(driver.pubkey.prefix(8)) + "...")

        return RideRequestDriverOption(
            pubkey: driver.pubkey,
            displayName: resolvedName
        )
    }
}
