import Foundation
import Testing
@testable import RidestrSDK

@Suite("ProgressiveReveal Tests")
struct ProgressiveRevealTests {
    @Test func approximateForOffer() {
        let precise = Location(latitude: 40.71234, longitude: -74.00567)
        let approx = ProgressiveReveal.approximateForOffer(precise)
        #expect(approx.latitude == 40.71)
        #expect(approx.longitude == -74.01)
    }

    @Test func roadflareAlwaysSharesPrecisePickup() {
        let result = ProgressiveReveal.shouldSharePrecisePickup(
            isRoadflare: true,
            driverLocation: nil,  // Even without driver location
            pickupLocation: Location(latitude: 40.71, longitude: -74.01)
        )
        #expect(result)
    }

    @Test func generalRideSharesWhenDriverClose() {
        let pickup = Location(latitude: 40.7128, longitude: -74.0060)
        let driverClose = Location(latitude: 40.7200, longitude: -74.0060)  // ~0.8 km away

        let result = ProgressiveReveal.shouldSharePrecisePickup(
            isRoadflare: false,
            driverLocation: driverClose,
            pickupLocation: pickup
        )
        #expect(result)
    }

    @Test func generalRideDoesNotShareWhenDriverFar() {
        let pickup = Location(latitude: 40.7128, longitude: -74.0060)
        let driverFar = Location(latitude: 40.7500, longitude: -74.0060)  // ~4 km away

        let result = ProgressiveReveal.shouldSharePrecisePickup(
            isRoadflare: false,
            driverLocation: driverFar,
            pickupLocation: pickup
        )
        #expect(!result)
    }

    @Test func generalRideDoesNotShareWithoutDriverLocation() {
        let result = ProgressiveReveal.shouldSharePrecisePickup(
            isRoadflare: false,
            driverLocation: nil,
            pickupLocation: Location(latitude: 40.71, longitude: -74.01)
        )
        #expect(!result)
    }

    @Test func destinationSharedOnlyAfterPinVerified() {
        #expect(!ProgressiveReveal.shouldSharePreciseDestination(pinVerified: false))
        #expect(ProgressiveReveal.shouldSharePreciseDestination(pinVerified: true))
    }

    @Test func settlementGeohashPrecision() {
        let loc = Location(latitude: 40.7128, longitude: -74.0060)
        let gh = ProgressiveReveal.settlementGeohash(for: loc)
        #expect(gh.count == GeohashPrecision.settlement)  // 7 chars
    }

    @Test func historyGeohashPrecision() {
        let loc = Location(latitude: 40.7128, longitude: -74.0060)
        let gh = ProgressiveReveal.historyGeohash(for: loc)
        #expect(gh.count == GeohashPrecision.history)  // 6 chars
    }

    @Test func historyGeohashIsPrefix() {
        let loc = Location(latitude: 40.7128, longitude: -74.0060)
        let history = ProgressiveReveal.historyGeohash(for: loc)
        let settlement = ProgressiveReveal.settlementGeohash(for: loc)
        // 6-char history hash should be a prefix of 7-char settlement hash
        #expect(settlement.hasPrefix(history))
    }
}
