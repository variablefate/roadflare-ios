import Foundation

/// Fare estimate for a ride.
public struct FareEstimate: Sendable, Equatable, Hashable, Codable {
    /// Distance in miles.
    public let distanceMiles: Double
    /// Duration in minutes.
    public let durationMinutes: Double
    /// Estimated fare in USD.
    public let fareUSD: Decimal
    /// Route summary (e.g., "via I-95 N").
    public let routeSummary: String?

    public init(distanceMiles: Double, durationMinutes: Double, fareUSD: Decimal, routeSummary: String? = nil) {
        self.distanceMiles = distanceMiles
        self.durationMinutes = durationMinutes
        self.fareUSD = fareUSD
        self.routeSummary = routeSummary
    }
}

/// Fare configuration, typically loaded from RemoteConfig (Kind 30182).
public struct FareConfig: Sendable, Equatable {
    public let baseFareUsd: Decimal
    public let rateUsdPerMile: Decimal
    public let minimumFareUsd: Decimal

    public init(
        baseFareUsd: Decimal = AdminConstants.roadflareBaseFareUsd,
        rateUsdPerMile: Decimal = AdminConstants.roadflareUIRateUsdPerMile,
        minimumFareUsd: Decimal = AdminConstants.roadflareUIMinimumFareUsd
    ) {
        assert(baseFareUsd >= 0 && rateUsdPerMile >= 0 && minimumFareUsd >= 0,
               "Fare config values must be non-negative")
        self.baseFareUsd = baseFareUsd
        self.rateUsdPerMile = rateUsdPerMile
        self.minimumFareUsd = minimumFareUsd
    }
}

/// Calculates ride fare estimates based on route distance.
public struct FareCalculator: Sendable {
    public let config: FareConfig

    public init(config: FareConfig = FareConfig()) {
        self.config = config
    }

    /// Calculate fare from a route result.
    public func estimate(route: RouteResult) -> FareEstimate {
        let miles = route.distanceMiles
        let fare = calculateFare(distanceMiles: miles)
        return FareEstimate(
            distanceMiles: miles,
            durationMinutes: route.durationMinutes,
            fareUSD: fare,
            routeSummary: route.summary
        )
    }

    /// Calculate fare from pickup and destination using a routing service.
    public func estimate(
        from pickup: Location,
        to destination: Location,
        using router: RoutingServiceProtocol
    ) async throws -> FareEstimate {
        let route = try await router.calculateRoute(from: pickup, to: destination)
        return estimate(route: route)
    }

    /// Calculate fare from distance in miles.
    /// Negative or non-finite distances are clamped to zero (minimum fare applies).
    public func calculateFare(distanceMiles: Double) -> Decimal {
        let safeMiles = distanceMiles.isFinite && distanceMiles > 0 ? distanceMiles : 0
        let miles = Decimal(safeMiles)
        let rawFare = config.baseFareUsd + (miles * config.rateUsdPerMile)
        return max(rawFare, config.minimumFareUsd)
    }

    /// Calculate fare from distance in kilometers.
    public func calculateFareFromKm(distanceKm: Double) -> Decimal {
        calculateFare(distanceMiles: distanceKm * LocationConstants.kmToMiles)
    }
}
