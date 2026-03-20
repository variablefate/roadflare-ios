import Foundation

/// Result from a route calculation.
public struct RouteResult: Sendable, Equatable, Codable {
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
        distanceKm * LocationConstants.kmToMiles
    }
}

/// Protocol for route calculation. Abstracted for testability.
/// Real implementation uses MKDirections (in the app layer).
public protocol RoutingServiceProtocol: Sendable {
    /// Calculate a driving route between two locations.
    func calculateRoute(from: Location, to: Location) async throws -> RouteResult
}

/// Haversine-based routing service for testing. Estimates routes using straight-line
/// distance with a 1.3x road-factor adjustment. No network calls.
public struct HaversineRoutingService: RoutingServiceProtocol {
    /// Road-factor multiplier applied to straight-line distance (default 1.3).
    public let roadFactor: Double

    public init(roadFactor: Double = 1.3) {
        self.roadFactor = roadFactor
    }

    public func calculateRoute(from: Location, to: Location) async throws -> RouteResult {
        let straightLineKm = from.distance(to: to)
        let estimatedKm = straightLineKm * roadFactor
        // Assume 30 km/h average speed in urban areas
        let estimatedMinutes = (estimatedKm / 30.0) * 60.0
        return RouteResult(
            distanceKm: estimatedKm,
            durationMinutes: estimatedMinutes,
            summary: "via straight line (estimate)"
        )
    }
}
