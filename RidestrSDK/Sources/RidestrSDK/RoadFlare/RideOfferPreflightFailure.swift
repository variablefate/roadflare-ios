import Foundation

/// Structural reason a driver is not a valid target for a Kind 3177 ride
/// offer at the moment the offer would publish.
///
/// The ride-offer path surfaces publish failures, fare-pricing errors,
/// and identity errors through other channels; this enum carries only the
/// structural-preflight outcomes (driver-not-followed, no key, key stale,
/// driver offline, driver on another ride). Analogous in role to the
/// eligibility subset of `DriverPingResult` but distinct in surface — the
/// ride-offer path has no rate-limit or publish-failure variants here, and
/// `.staleKey` and `.onRide` are explicit cases rather than being folded
/// into a generic `.ineligible`.
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
    /// The driver is not currently broadcasting any status, or is broadcasting
    /// an unrecognised non-`online` status (i.e., effectively offline).
    case offline
    /// The driver is broadcasting `on_ride` — present and reachable, but
    /// currently servicing a different ride and not available to accept a
    /// new offer.
    case onRide
}
