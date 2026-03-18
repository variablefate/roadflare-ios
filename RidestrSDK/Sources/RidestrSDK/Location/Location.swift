import Foundation

/// A geographic location used throughout the Ridestr protocol.
public struct Location: Codable, Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double
    public var address: String?

    enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lon"
        case address
    }

    public init(latitude: Double, longitude: Double, address: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
    }

    /// Round to 2 decimal places (~1km precision) for approximate sharing.
    public func approximate() -> Location {
        let decimals = pow(10.0, Double(RideConstants.locationApproxDecimals))
        return Location(
            latitude: (latitude * decimals).rounded() / decimals,
            longitude: (longitude * decimals).rounded() / decimals,
            address: nil  // Approximate locations don't carry address
        )
    }

    /// Haversine distance to another location in kilometers.
    public func distance(to other: Location) -> Double {
        let earthRadiusKm = 6371.0

        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180

        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180

        let a = sin(dLat / 2) * sin(dLat / 2) +
                sin(dLon / 2) * sin(dLon / 2) * cos(lat1) * cos(lat2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))

        return earthRadiusKm * c
    }

    /// Whether this location is within ~1 mile (1.6km) of another.
    public func isWithinMile(of other: Location) -> Bool {
        distance(to: other) < RideConstants.progressiveRevealThresholdKm
    }

    /// Geohash at the given precision.
    public func geohash(precision: Int = GeohashPrecision.ride) -> Geohash {
        Geohash(latitude: latitude, longitude: longitude, precision: precision)
    }

    /// Generate geohash tags at multiple precisions for Nostr events.
    public func geohashTags(
        minPrecision: Int = GeohashPrecision.normalSearch,
        maxPrecision: Int = GeohashPrecision.ride
    ) -> [String] {
        Geohash.tags(latitude: latitude, longitude: longitude,
                     minPrecision: minPrecision, maxPrecision: maxPrecision)
    }

    /// JSON representation matching Android's Location.toJson() format.
    public func toJSON() -> [String: Any] {
        ["lat": latitude, "lon": longitude]
    }
}
