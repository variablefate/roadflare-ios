import Foundation

/// Result from a route calculation.
public struct RouteResult: Sendable {
    /// Distance in kilometers.
    public let distanceKm: Double
    /// Estimated travel time in minutes.
    public let durationMinutes: Double
    /// Human-readable route summary (e.g., "via I-95 N").
    public let summary: String?

    public init(distanceKm: Double, durationMinutes: Double, summary: String? = nil) {
        self.distanceKm = distanceKm
        self.durationMinutes = durationMinutes
        self.summary = summary
    }

    /// Distance in miles.
    public var distanceMiles: Double {
        distanceKm * 0.621371
    }
}

/// Protocol for route calculation. Abstracted for testability.
/// Real implementation uses MKDirections (in the app layer).
public protocol RoutingServiceProtocol: Sendable {
    /// Calculate a driving route between two locations.
    func calculateRoute(from: Location, to: Location) async throws -> RouteResult
}
