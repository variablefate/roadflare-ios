import Foundation
import Testing
@testable import RidestrSDK

@Suite("Location Tests")
struct LocationTests {
    @Test func approximate() {
        let loc = Location(latitude: 40.12345, longitude: -74.56789)
        let approx = loc.approximate()
        #expect(approx.latitude == 40.12)
        #expect(approx.longitude == -74.57)
        #expect(approx.address == nil)
    }

    @Test func approximateRounding() {
        let loc = Location(latitude: 40.125, longitude: -74.565)
        let approx = loc.approximate()
        #expect(approx.latitude == 40.13)  // .125 rounds to .13
        #expect(approx.longitude == -74.57)
    }

    @Test func distanceKnownPair() {
        // NYC to LA: approximately 3,944 km
        let nyc = Location(latitude: 40.7128, longitude: -74.0060)
        let la = Location(latitude: 34.0522, longitude: -118.2437)
        let dist = nyc.distance(to: la)
        // Should be within 2% of 3944 km
        #expect(dist > 3860 && dist < 4030)
    }

    @Test func distanceToSelf() {
        let loc = Location(latitude: 40.7128, longitude: -74.0060)
        #expect(loc.distance(to: loc) == 0)
    }

    @Test func isWithinMile() {
        let loc1 = Location(latitude: 40.7128, longitude: -74.0060)
        // ~1.5 km away (within 1 mile)
        let loc2 = Location(latitude: 40.7250, longitude: -74.0060)
        #expect(loc1.isWithinMile(of: loc2))

        // ~5 km away (outside 1 mile)
        let loc3 = Location(latitude: 40.7600, longitude: -74.0060)
        #expect(!loc1.isWithinMile(of: loc3))
    }

    @Test func geohash() {
        let loc = Location(latitude: 40.7128, longitude: -74.0060)
        let gh = loc.geohash()
        #expect(gh.hash.count == GeohashPrecision.ride)
    }

    @Test func geohashTags() {
        let loc = Location(latitude: 40.7128, longitude: -74.0060)
        let tags = loc.geohashTags()
        #expect(tags.count == 2)  // precision 4 and 5
        #expect(tags[0].count == 4)
        #expect(tags[1].count == 5)
    }

    @Test func codableJSON() throws {
        let loc = Location(latitude: 40.7128, longitude: -74.0060, address: "NYC")
        let data = try JSONEncoder().encode(loc)
        let decoded = try JSONDecoder().decode(Location.self, from: data)
        #expect(decoded.latitude == loc.latitude)
        #expect(decoded.longitude == loc.longitude)
        #expect(decoded.address == loc.address)
    }

    @Test func codingKeysMatchAndroid() throws {
        // Android uses "lat" and "lon" field names
        let json = """
        {"lat": 40.7128, "lon": -74.0060}
        """.data(using: .utf8)!
        let loc = try JSONDecoder().decode(Location.self, from: json)
        #expect(loc.latitude == 40.7128)
        #expect(loc.longitude == -74.0060)
    }

    @Test func toJSON() {
        let loc = Location(latitude: 40.7128, longitude: -74.0060)
        let json = loc.toJSON()
        #expect(json["lat"] as? Double == 40.7128)
        #expect(json["lon"] as? Double == -74.0060)
    }

    @Test func equatable() {
        let loc1 = Location(latitude: 40.7128, longitude: -74.0060)
        let loc2 = Location(latitude: 40.7128, longitude: -74.0060)
        let loc3 = Location(latitude: 40.7129, longitude: -74.0060)
        #expect(loc1 == loc2)
        #expect(loc1 != loc3)
    }
}
