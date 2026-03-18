import Foundation

/// Manages progressive location reveal logic for the Ridestr protocol.
///
/// Privacy model:
/// - Offer: ~1km approximate location (2-decimal rounding)
/// - Confirmation (RoadFlare): precise pickup immediately
/// - Confirmation (general): precise pickup only when driver < 1 mile
/// - PIN verified: precise destination revealed
public enum ProgressiveReveal {
    /// Generate the approximate location for an offer (2-decimal precision, ~1km).
    public static func approximateForOffer(_ location: Location) -> Location {
        location.approximate()
    }

    /// Determine whether precise pickup should be shared at confirmation time.
    /// For RoadFlare rides, always share immediately (trusted driver).
    /// For general rides, only if driver is within ~1 mile.
    public static func shouldSharePrecisePickup(
        isRoadflare: Bool,
        driverLocation: Location?,
        pickupLocation: Location
    ) -> Bool {
        if isRoadflare { return true }
        guard let driverLoc = driverLocation else { return false }
        return pickupLocation.isWithinMile(of: driverLoc)
    }

    /// Determine whether precise destination should be shared.
    /// Only after PIN is verified.
    public static func shouldSharePreciseDestination(pinVerified: Bool) -> Bool {
        pinVerified
    }

    /// Generate a geohash for settlement verification (7-char precision, ~153m).
    public static func settlementGeohash(for location: Location) -> String {
        location.geohash(precision: GeohashPrecision.settlement).hash
    }

    /// Generate a geohash for ride history storage (6-char precision, ~1.2km).
    public static func historyGeohash(for location: Location) -> String {
        location.geohash(precision: GeohashPrecision.history).hash
    }
}
