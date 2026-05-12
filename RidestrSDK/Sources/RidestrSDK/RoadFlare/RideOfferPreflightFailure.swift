import Foundation

/// Structural reason a driver is not a valid target for a Kind 3177 ride
/// offer at the moment the offer would publish.
///
/// Mirrors `DriverPingResult` but scoped to the eligibility-only subset:
/// the ride-offer path surfaces publish failures, fare-pricing errors,
/// and identity errors through other channels, so this enum only carries
/// the structural-preflight outcomes (driver-not-followed, no key, key
/// stale, driver offline).
///
/// Returned from `FollowedDriversRepository.rideOfferPreflight(driverPubkey:)`.
/// `nil` from that call means the driver is eligible.
public enum RideOfferPreflightFailure: Sendable, Equatable {
    /// The driver is not in the rider's followed list.
    case driverNotFollowed
    /// The driver is followed but has not yet shared a current RoadFlare key.
    case missingKey
    /// A stale-key signal has been observed for this driver since the last
    /// key share; the rider's view of the driver's key may not decrypt.
    case staleKey
    /// The driver is currently not broadcasting an `online` status.
    case offline
}
