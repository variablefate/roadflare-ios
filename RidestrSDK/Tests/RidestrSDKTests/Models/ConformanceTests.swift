import Foundation
import Testing
@testable import RidestrSDK

@Suite("Protocol Conformance Tests")
struct ConformanceTests {

    // MARK: - FareEstimate

    @Test func fareEstimateEquatable() {
        let a = FareEstimate(distanceMiles: 5.0, durationMinutes: 15.0, fareUSD: 10.50, routeSummary: "via I-95")
        let b = FareEstimate(distanceMiles: 5.0, durationMinutes: 15.0, fareUSD: 10.50, routeSummary: "via I-95")
        let c = FareEstimate(distanceMiles: 6.0, durationMinutes: 15.0, fareUSD: 10.50, routeSummary: "via I-95")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func fareEstimateHashable() {
        let a = FareEstimate(distanceMiles: 5.0, durationMinutes: 15.0, fareUSD: 10.50, routeSummary: nil)
        let b = FareEstimate(distanceMiles: 5.0, durationMinutes: 15.0, fareUSD: 10.50, routeSummary: nil)
        let set: Set<FareEstimate> = [a, b]
        #expect(set.count == 1)
    }

    @Test func fareEstimateCodable() throws {
        let original = FareEstimate(distanceMiles: 8.2, durationMinutes: 22.0, fareUSD: 15.75, routeSummary: "via US-1")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FareEstimate.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - RouteResult

    @Test func routeResultEquatable() {
        let a = RouteResult(distanceKm: 10.0, durationMinutes: 20.0, summary: "via Main St")
        let b = RouteResult(distanceKm: 10.0, durationMinutes: 20.0, summary: "via Main St")
        #expect(a == b)
    }

    @Test func routeResultCodable() throws {
        let original = RouteResult(distanceKm: 15.5, durationMinutes: 30.0, summary: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RouteResult.self, from: data)
        #expect(decoded == original)
    }

    @Test func routeResultDistanceMilesConversion() {
        let route = RouteResult(distanceKm: 10.0, durationMinutes: 20.0)
        #expect(abs(route.distanceMiles - 6.21371) < 0.001)
    }

    // MARK: - GeocodingResult

    @Test func geocodingResultEquatable() {
        let a = GeocodingResult(latitude: 40.7, longitude: -74.0, displayName: "NYC", addressLine: "123 Main St")
        let b = GeocodingResult(latitude: 40.7, longitude: -74.0, displayName: "NYC", addressLine: "123 Main St")
        #expect(a == b)
    }

    @Test func geocodingResultCodable() throws {
        let original = GeocodingResult(latitude: 37.7, longitude: -122.4, displayName: "SF", addressLine: "456 Market St", locality: "San Francisco")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GeocodingResult.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - RoadflareKey (Security-Sensitive)

    @Test func roadflareKeyEquatableExcludesPrivateKey() {
        let a = RoadflareKey(privateKeyHex: "aaa", publicKeyHex: "pub1", version: 1)
        let b = RoadflareKey(privateKeyHex: "bbb", publicKeyHex: "pub1", version: 1)
        // Same public identity, different private keys → EQUAL
        #expect(a == b)
    }

    @Test func roadflareKeyNotEqualDifferentVersion() {
        let a = RoadflareKey(privateKeyHex: "aaa", publicKeyHex: "pub1", version: 1)
        let b = RoadflareKey(privateKeyHex: "aaa", publicKeyHex: "pub1", version: 2)
        #expect(a != b)
    }

    @Test func roadflareKeyHashableExcludesPrivateKey() {
        let a = RoadflareKey(privateKeyHex: "aaa", publicKeyHex: "pub1", version: 1)
        let b = RoadflareKey(privateKeyHex: "bbb", publicKeyHex: "pub1", version: 1)
        // Same public identity → same hash → set deduplicates
        let set: Set<RoadflareKey> = [a, b]
        #expect(set.count == 1)
    }

    // MARK: - FollowedDriver

    @Test func followedDriverHashableByPubkey() {
        let a = FollowedDriver(pubkey: "driver1", addedAt: 1000, name: "Alice")
        let b = FollowedDriver(pubkey: "driver1", addedAt: 2000, name: "Bob")
        // Same pubkey → same hash
        let set: Set<FollowedDriver> = [a, b]
        #expect(set.count == 1)
    }

    @Test func followedDriverDifferentPubkeys() {
        let a = FollowedDriver(pubkey: "driver1")
        let b = FollowedDriver(pubkey: "driver2")
        let set: Set<FollowedDriver> = [a, b]
        #expect(set.count == 2)
    }

    // MARK: - Vehicle

    @Test func vehicleEquatable() {
        let a = Vehicle(make: "Toyota", model: "Camry", year: 2022, color: "Silver")
        let b = Vehicle(id: a.id, make: "Toyota", model: "Camry", year: 2022, color: "Silver")
        #expect(a == b)
    }

    // MARK: - RideHistoryEntry

    @Test func rideHistoryEntryHashableById() {
        let pickup = Location(latitude: 40.7, longitude: -74.0)
        let dest = Location(latitude: 40.8, longitude: -73.9)
        let a = RideHistoryEntry(id: "ride1", date: .now, counterpartyPubkey: "d1",
                                  pickupGeohash: "dr5ru", dropoffGeohash: "dr5rv",
                                  pickup: pickup, destination: dest, fare: 15.0, paymentMethod: "zelle")
        let b = RideHistoryEntry(id: "ride1", date: .now, counterpartyPubkey: "d2",
                                  pickupGeohash: "dr5ru", dropoffGeohash: "dr5rv",
                                  pickup: pickup, destination: dest, fare: 20.0, paymentMethod: "venmo")
        // Same id → same hash
        let set: Set<RideHistoryEntry> = [a, b]
        #expect(set.count == 1)
    }

    // MARK: - SavedLocation

    @Test func savedLocationHashableById() {
        let a = SavedLocation(id: "loc1", latitude: 40.7, longitude: -74.0, displayName: "Home", addressLine: "123 Main")
        let b = SavedLocation(id: "loc1", latitude: 37.7, longitude: -122.4, displayName: "Work", addressLine: "456 Market")
        // Same id → same hash
        let set: Set<SavedLocation> = [a, b]
        #expect(set.count == 1)
    }

    // MARK: - LocationConstants

    @Test func locationConstantsValues() {
        #expect(LocationConstants.earthRadiusKm == 6371.0)
        #expect(abs(LocationConstants.kmToMiles - 0.621371) < 0.0001)
        #expect(abs(LocationConstants.milesToKm - 1.60934) < 0.0001)
    }

    @Test func kmToMilesRoundtrip() {
        let km = 10.0
        let miles = km * LocationConstants.kmToMiles
        let backToKm = miles * LocationConstants.milesToKm
        #expect(abs(backToKm - km) < 0.01)
    }
}
