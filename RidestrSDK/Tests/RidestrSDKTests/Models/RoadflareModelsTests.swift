import Foundation
import Testing
@testable import RidestrSDK

@Suite("RoadflareModels Tests")
struct RoadflareModelsTests {
    // MARK: - RoadflareKey

    @Test func roadflareKeyCodable() throws {
        let key = RoadflareKey(privateKeyHex: "aabb", publicKeyHex: "ccdd", version: 3, keyUpdatedAt: 1700000000)
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(RoadflareKey.self, from: data)
        #expect(decoded.privateKeyHex == "aabb")
        #expect(decoded.publicKeyHex == "ccdd")
        #expect(decoded.version == 3)
        #expect(decoded.keyUpdatedAt == 1700000000)
    }

    @Test func roadflareKeyCodingKeysMatchAndroid() throws {
        // Android uses "privateKey" and "publicKey" field names
        let json = """
        {"privateKey":"aabb","publicKey":"ccdd","version":2,"keyUpdatedAt":1700000000}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RoadflareKey.self, from: json)
        #expect(decoded.privateKeyHex == "aabb")
        #expect(decoded.version == 2)
    }

    // MARK: - RoadflareLocation

    @Test func roadflareLocationCodable() throws {
        let json = """
        {"lat":40.7128,"lon":-74.006,"timestamp":1700000000,"status":"online"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RoadflareLocation.self, from: json)
        #expect(decoded.latitude == 40.7128)
        #expect(decoded.longitude == -74.006)
        #expect(decoded.status == .online)
        #expect(decoded.timestamp == 1700000000)
    }

    @Test func roadflareLocationOnRide() throws {
        let json = """
        {"lat":40.0,"lon":-74.0,"timestamp":1700000000,"status":"on_ride","onRide":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RoadflareLocation.self, from: json)
        #expect(decoded.status == .onRide)
        #expect(decoded.onRide == true)
    }

    // MARK: - RoadflareStatus

    @Test func roadflareStatusRawValues() {
        #expect(RoadflareStatus.online.rawValue == "online")
        #expect(RoadflareStatus.onRide.rawValue == "on_ride")
        #expect(RoadflareStatus.offline.rawValue == "offline")
    }

    // MARK: - FollowedDriver

    @Test func followedDriverInit() {
        let driver = FollowedDriver(pubkey: "abc123", name: "Alice", note: "Great driver")
        #expect(driver.id == "abc123")
        #expect(driver.pubkey == "abc123")
        #expect(driver.name == "Alice")
        #expect(driver.note == "Great driver")
        #expect(!driver.hasKey)
    }

    @Test func followedDriverHasKey() {
        var driver = FollowedDriver(pubkey: "abc123")
        #expect(!driver.hasKey)
        driver.roadflareKey = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 1, keyUpdatedAt: 0)
        #expect(driver.hasKey)
    }

    @Test func followedDriverCodable() throws {
        let driver = FollowedDriver(
            pubkey: "abc123",
            name: "Bob",
            roadflareKey: RoadflareKey(privateKeyHex: "pp", publicKeyHex: "qq", version: 1, keyUpdatedAt: 100)
        )
        let data = try JSONEncoder().encode(driver)
        let decoded = try JSONDecoder().decode(FollowedDriver.self, from: data)
        #expect(decoded.pubkey == "abc123")
        #expect(decoded.name == "Bob")
        #expect(decoded.roadflareKey?.version == 1)
    }

    // MARK: - FollowedDriversContent (Kind 30011)

    @Test func followedDriversContentCodable() throws {
        let content = FollowedDriversContent(
            drivers: [
                FollowedDriverEntry(pubkey: "d1", addedAt: 100, note: "test", roadflareKey: nil),
                FollowedDriverEntry(pubkey: "d2", addedAt: 200, note: nil,
                    roadflareKey: RoadflareKey(privateKeyHex: "p", publicKeyHex: "q", version: 1, keyUpdatedAt: 300)),
            ],
            updatedAt: 500
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(FollowedDriversContent.self, from: data)
        #expect(decoded.drivers.count == 2)
        #expect(decoded.drivers[0].pubkey == "d1")
        #expect(decoded.drivers[1].roadflareKey?.version == 1)
        #expect(decoded.updatedAt == 500)
    }

    @Test func followedDriversContentCodingKeys() throws {
        let json = """
        {"drivers":[{"pubkey":"d1","addedAt":100,"note":null,"roadflareKey":null}],"updated_at":500}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FollowedDriversContent.self, from: json)
        #expect(decoded.updatedAt == 500)
    }

    // MARK: - KeyShareContent (Kind 3186)

    @Test func keyShareContentCodable() throws {
        let content = KeyShareContent(
            roadflareKey: RoadflareKey(privateKeyHex: "aa", publicKeyHex: "bb", version: 3, keyUpdatedAt: 1000),
            keyUpdatedAt: 1000,
            driverPubKey: "driver_hex"
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(KeyShareContent.self, from: data)
        #expect(decoded.roadflareKey.version == 3)
        #expect(decoded.driverPubKey == "driver_hex")
    }

    // MARK: - KeyAckContent (Kind 3188)

    @Test func keyAckContentCodable() throws {
        let content = KeyAckContent(keyVersion: 2, keyUpdatedAt: 1000, status: "received", riderPubKey: "rider_hex")
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(KeyAckContent.self, from: data)
        #expect(decoded.keyVersion == 2)
        #expect(decoded.status == "received")
    }

    @Test func keyAckStaleStatus() throws {
        let content = KeyAckContent(keyVersion: 1, keyUpdatedAt: 500, status: "stale", riderPubKey: "r1")
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(KeyAckContent.self, from: data)
        #expect(decoded.status == "stale")
    }

    // MARK: - RideHistoryEntry

    @Test func rideHistoryEntryCodable() throws {
        let entry = RideHistoryEntry(
            id: "ride1", date: Date(timeIntervalSince1970: 1700000000),
            counterpartyPubkey: "driver_pub", counterpartyName: "Alice",
            pickupGeohash: "dr5ru1", dropoffGeohash: "dr5rv2",
            pickup: Location(latitude: 40.71, longitude: -74.01),
            destination: Location(latitude: 40.76, longitude: -73.98),
            fare: 12.50, paymentMethod: "zelle",
            distance: 5.5, duration: 18,
            vehicleMake: "Toyota", vehicleModel: "Camry"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RideHistoryEntry.self, from: data)
        #expect(decoded.id == "ride1")
        #expect(decoded.counterpartyName == "Alice")
        #expect(decoded.fare == 12.50)
        #expect(decoded.appOrigin == "roadflare")
    }

    // MARK: - SavedLocation

    @Test func savedLocationInit() {
        let loc = SavedLocation(
            latitude: 40.7128, longitude: -74.006,
            displayName: "Home", addressLine: "123 Main St",
            isPinned: true, nickname: "Home"
        )
        #expect(loc.isPinned)
        #expect(loc.nickname == "Home")
    }

    @Test func savedLocationToLocation() {
        let saved = SavedLocation(
            latitude: 40.7128, longitude: -74.006,
            displayName: "Office", addressLine: "456 Work Ave"
        )
        let loc = saved.toLocation()
        #expect(loc.latitude == 40.7128)
        #expect(loc.address == "Office")
    }

    @Test func savedLocationCodable() throws {
        let saved = SavedLocation(latitude: 40.0, longitude: -74.0, displayName: "Test", addressLine: "Addr")
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SavedLocation.self, from: data)
        #expect(decoded.displayName == "Test")
    }
}
