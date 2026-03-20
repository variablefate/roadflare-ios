import Foundation
import Testing
@testable import RidestrSDK

@Suite("Schema Version Backward Compatibility Tests")
struct SchemaVersionTests {

    @Test func decodeLegacyFollowedDriversWithoutSchemaVersion() throws {
        let legacyJSON = """
        {
            "drivers": [
                {"pubkey":"d1","addedAt":1700000000,"note":null,"roadflareKey":null}
            ],
            "updated_at": 1700000000
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(FollowedDriversContent.self, from: legacyJSON)
        #expect(decoded.schemaVersion == nil) // Missing from old data
        #expect(decoded.drivers.count == 1)
        #expect(decoded.drivers[0].pubkey == "d1")
    }

    @Test func encodeWithSchemaVersionIncludesField() throws {
        let content = FollowedDriversContent(
            drivers: [], updatedAt: 1700000000, schemaVersion: 1
        )
        let data = try JSONEncoder().encode(content)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["schemaVersion"] as? Int == 1)
    }

    @Test func decodeLegacyRideHistoryWithoutSchemaVersion() throws {
        let legacyJSON = """
        {
            "id": "ride1",
            "date": 0,
            "role": "rider",
            "status": "completed",
            "counterpartyPubkey": "d1",
            "pickupGeohash": "9q8yy",
            "dropoffGeohash": "9q8yz",
            "pickup": {"lat": 37.7, "lon": -122.4},
            "destination": {"lat": 37.8, "lon": -122.3},
            "fare": 15.50,
            "paymentMethod": "zelle",
            "appOrigin": "roadflare"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(RideHistoryEntry.self, from: legacyJSON)
        #expect(decoded.schemaVersion == nil) // Missing from old data
        #expect(decoded.id == "ride1")
        #expect(decoded.fare == 15.50)
    }

    @Test func decodeLegacySavedLocationWithoutSchemaVersion() throws {
        let legacyJSON = """
        {
            "id": "loc1",
            "latitude": 37.7749,
            "longitude": -122.4194,
            "displayName": "Home",
            "addressLine": "123 Main St",
            "isPinned": true,
            "timestampMs": 1700000000000
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SavedLocation.self, from: legacyJSON)
        #expect(decoded.schemaVersion == nil)
        #expect(decoded.displayName == "Home")
        #expect(decoded.isPinned)
    }

    @Test func newDataDefaultsToSchemaVersionOne() {
        let content = FollowedDriversContent(drivers: [], updatedAt: 0)
        #expect(content.schemaVersion == 1)

        let location = SavedLocation(latitude: 0, longitude: 0, displayName: "", addressLine: "")
        #expect(location.schemaVersion == 1)
    }

    @Test func roundtripPreservesSchemaVersion() throws {
        let original = FollowedDriversContent(drivers: [], updatedAt: 1700000000, schemaVersion: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FollowedDriversContent.self, from: data)
        #expect(decoded.schemaVersion == 1)
    }
}
