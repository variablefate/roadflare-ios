import Foundation
import Testing
@testable import RidestrSDK

@Suite("Geohash Tests")
struct GeohashTests {
    // Known reference: Las Vegas Strip ~36.1147, -115.1728
    // Expected geohash at precision 5: "9qqj1" (approximately)

    @Test func encodeKnownLocation() {
        let gh = Geohash(latitude: 36.1147, longitude: -115.1728, precision: 5)
        #expect(gh.hash.count == 5)
        // Should start with "9q" (southwest US region)
        #expect(gh.hash.hasPrefix("9q"))
    }

    @Test func decodeContainsOriginal() {
        let lat = 36.1147
        let lon = -115.1728
        let gh = Geohash(latitude: lat, longitude: lon, precision: 7)
        #expect(gh.contains(latitude: lat, longitude: lon))
    }

    @Test func roundtripPrecision5() {
        let gh1 = Geohash(latitude: 40.7128, longitude: -74.0060, precision: 5)
        // Decode center and re-encode
        let gh2 = Geohash(latitude: gh1.latitude, longitude: gh1.longitude, precision: 5)
        #expect(gh1.hash == gh2.hash)
    }

    @Test func precisionAffectsLength() {
        let lat = 40.7128
        let lon = -74.0060
        let gh3 = Geohash(latitude: lat, longitude: lon, precision: 3)
        let gh5 = Geohash(latitude: lat, longitude: lon, precision: 5)
        let gh7 = Geohash(latitude: lat, longitude: lon, precision: 7)
        #expect(gh3.hash.count == 3)
        #expect(gh5.hash.count == 5)
        #expect(gh7.hash.count == 7)
        // Shorter hash should be a prefix of longer
        #expect(gh5.hash.hasPrefix(gh3.hash))
        #expect(gh7.hash.hasPrefix(gh5.hash))
    }

    @Test func neighbors() {
        let gh = Geohash(latitude: 40.7128, longitude: -74.0060, precision: 5)
        let nbrs = gh.neighbors()
        // Should have 8 neighbors (or fewer at poles/edges)
        #expect(nbrs.count >= 7)
        #expect(nbrs.count <= 8)
        // All neighbors should be same precision
        for n in nbrs {
            #expect(n.hash.count == gh.hash.count)
        }
        // None should be the same as center
        for n in nbrs {
            #expect(n.hash != gh.hash)
        }
    }

    @Test func neighborsAtEquator() {
        let gh = Geohash(latitude: 0.0, longitude: 0.0, precision: 4)
        let nbrs = gh.neighbors()
        #expect(nbrs.count == 8)
    }

    @Test func invalidCharactersThrow() {
        #expect(throws: RidestrError.self) {
            try Geohash(hash: "abc!@#")
        }
    }

    @Test func emptyHashThrows() {
        #expect(throws: RidestrError.self) {
            try Geohash(hash: "")
        }
    }

    @Test func validHashParsing() throws {
        let gh = try Geohash(hash: "9q8yy")
        #expect(gh.hash == "9q8yy")
        #expect(gh.latitude > 30 && gh.latitude < 40)  // Southwest US range
    }

    @Test func boundingBox() {
        let gh = Geohash(latitude: 40.7128, longitude: -74.0060, precision: 5)
        let bb = gh.boundingBox
        #expect(bb.minLat < gh.latitude)
        #expect(bb.maxLat > gh.latitude)
        #expect(bb.minLon < gh.longitude)
        #expect(bb.maxLon > gh.longitude)
    }

    @Test func multiPrecisionTags() {
        let tags = Geohash.tags(latitude: 40.7128, longitude: -74.0060,
                                minPrecision: 3, maxPrecision: 5)
        #expect(tags.count == 3)
        #expect(tags[0].count == 3)
        #expect(tags[1].count == 4)
        #expect(tags[2].count == 5)
        // Each should be a prefix of the next
        #expect(tags[1].hasPrefix(tags[0]))
        #expect(tags[2].hasPrefix(tags[1]))
    }

    @Test func crossPlatformCompatibility() {
        // Test vector: NYC coordinates should produce same geohash on both platforms
        let gh = Geohash(latitude: 40.7128, longitude: -74.0060, precision: 5)
        #expect(gh.hash.hasPrefix("dr5r"))
    }

    @Test func knownVectors() {
        // Well-known geohash test vectors (from geohash.org)
        // (0, 0) at precision 5 = "s0000"
        let origin = Geohash(latitude: 0.0, longitude: 0.0, precision: 5)
        #expect(origin.hash == "s0000")

        // (57.64911, 10.40744) = "u4pru" (Aalborg, Denmark — standard test vector)
        let aalborg = Geohash(latitude: 57.64911, longitude: 10.40744, precision: 5)
        #expect(aalborg.hash == "u4pru")
    }

    @Test func dateLine() {
        // Near international date line: longitude close to 180
        let east = Geohash(latitude: 0.0, longitude: 179.9, precision: 5)
        let west = Geohash(latitude: 0.0, longitude: -179.9, precision: 5)
        // Should produce valid but different hashes
        #expect(east.hash.count == 5)
        #expect(west.hash.count == 5)
        #expect(east.hash != west.hash)
    }

    @Test func poles() {
        // North pole
        let north = Geohash(latitude: 89.99, longitude: 0.0, precision: 5)
        #expect(north.hash.count == 5)
        // South pole
        let south = Geohash(latitude: -89.99, longitude: 0.0, precision: 5)
        #expect(south.hash.count == 5)
        #expect(north.hash != south.hash)
    }
}
