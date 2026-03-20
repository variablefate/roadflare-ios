import Foundation
import Testing
@testable import RidestrSDK

@Suite("FareCalculator Tests")
struct FareCalculatorTests {
    let calculator = FareCalculator()  // Uses default config

    @Test func defaultConfigValues() {
        #expect(calculator.config.baseFareUsd == AdminConstants.roadflareBaseFareUsd)
        #expect(calculator.config.rateUsdPerMile == AdminConstants.roadflareUIRateUsdPerMile)
        #expect(calculator.config.minimumFareUsd == AdminConstants.roadflareUIMinimumFareUsd)
    }

    @Test func basicFareCalculation() {
        // 10 miles: $2.50 base + (10 × $1.50) = $17.50
        let fare = calculator.calculateFare(distanceMiles: 10.0)
        #expect(fare == 17.50)
    }

    @Test func minimumFareApplied() {
        // 0.5 miles: $2.50 + (0.5 × $1.50) = $3.25 → minimum $5.00 kicks in
        let fare = calculator.calculateFare(distanceMiles: 0.5)
        #expect(fare == AdminConstants.roadflareUIMinimumFareUsd)
    }

    @Test func zeroDistanceGetsMinimum() {
        let fare = calculator.calculateFare(distanceMiles: 0.0)
        #expect(fare == AdminConstants.roadflareUIMinimumFareUsd)
    }

    @Test func fareFromKm() {
        // 16.09 km ≈ 10 miles
        let fare = calculator.calculateFareFromKm(distanceKm: 16.09)
        // Should be close to 10-mile fare (~$17.50)
        #expect(fare > 17.0 && fare < 18.0)
    }

    @Test func fareFromRouteResult() {
        let route = RouteResult(distanceKm: 16.09, durationMinutes: 25.0, summary: "via I-95")
        let estimate = calculator.estimate(route: route)
        #expect(estimate.distanceMiles > 9.9 && estimate.distanceMiles < 10.1)
        #expect(estimate.durationMinutes == 25.0)
        #expect(estimate.fareUSD > 17.0 && estimate.fareUSD < 18.0)
        #expect(estimate.routeSummary == "via I-95")
    }

    @Test func customConfig() {
        let config = FareConfig(baseFareUsd: 5.00, rateUsdPerMile: 2.00, minimumFareUsd: 8.00)
        let calc = FareCalculator(config: config)
        // 5 miles: $5.00 + (5 × $2.00) = $15.00
        let fare = calc.calculateFare(distanceMiles: 5.0)
        #expect(fare == 15.00)
    }

    @Test func customConfigMinimum() {
        let config = FareConfig(baseFareUsd: 1.00, rateUsdPerMile: 0.50, minimumFareUsd: 10.00)
        let calc = FareCalculator(config: config)
        // 2 miles: $1.00 + (2 × $0.50) = $2.00 → minimum $10.00
        let fare = calc.calculateFare(distanceMiles: 2.0)
        #expect(fare == 10.00)
    }

    @Test func fareEstimateWithRouter() async throws {
        let router = FakeRoutingService()
        router.result = RouteResult(distanceKm: 8.05, durationMinutes: 18.0, summary: "via Broadway")

        let estimate = try await calculator.estimate(
            from: Location(latitude: 40.71, longitude: -74.01),
            to: Location(latitude: 40.76, longitude: -73.98),
            using: router
        )
        #expect(estimate.distanceMiles > 4.9 && estimate.distanceMiles < 5.1)
        #expect(estimate.routeSummary == "via Broadway")
    }

    @Test func routeResultDistanceMiles() {
        let route = RouteResult(distanceKm: 1.60934, durationMinutes: 3.0)
        // 1.60934 km ≈ 1 mile
        #expect(abs(route.distanceMiles - 1.0) < 0.01)
    }
}

// MARK: - Fake

final class FakeRoutingService: RoutingServiceProtocol, @unchecked Sendable {
    var result = RouteResult(distanceKm: 10.0, durationMinutes: 20.0)
    var shouldFail = false

    func calculateRoute(from: Location, to: Location) async throws -> RouteResult {
        if shouldFail { throw RidestrError.location(.routeCalculationFailed(underlying: FakeError.simulated)) }
        return result
    }

    enum FakeError: Error { case simulated }
}
