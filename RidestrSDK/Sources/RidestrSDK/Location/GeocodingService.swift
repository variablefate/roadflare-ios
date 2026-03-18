import Foundation

/// Result from a geocoding operation.
public struct GeocodingResult: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let displayName: String
    public let addressLine: String
    public let locality: String?

    public init(latitude: Double, longitude: Double, displayName: String,
                addressLine: String, locality: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.displayName = displayName
        self.addressLine = addressLine
        self.locality = locality
    }

    public func toLocation() -> Location {
        Location(latitude: latitude, longitude: longitude, address: displayName)
    }
}

/// Protocol for geocoding operations. Abstracted for testability.
/// Real implementation uses CLGeocoder + MKLocalSearchCompleter (in the app layer).
public protocol GeocodingServiceProtocol: Sendable {
    /// Forward geocode: address string → coordinate.
    func geocode(address: String) async throws -> GeocodingResult?

    /// Reverse geocode: coordinate → address.
    func reverseGeocode(latitude: Double, longitude: Double) async throws -> GeocodingResult?

    /// Autocomplete: partial input → suggestions.
    func autocomplete(query: String) async throws -> [GeocodingResult]
}
