import Foundation
import Testing
@testable import RidestrSDK

/// Tests for persistence, storage, and data integrity across the SDK.
@Suite("Persistence & Storage Tests")
struct PersistenceTests {

    // MARK: - FollowedDriversRepository Persistence Roundtrip

    @Test func driversPersistAcrossInit() {
        let persistence = InMemoryFollowedDriversPersistence()
        let repo1 = FollowedDriversRepository(persistence: persistence)

        let key = RoadflareKey(privateKeyHex: "aa", publicKeyHex: "bb", version: 2, keyUpdatedAt: 1700000000)
        repo1.addDriver(FollowedDriver(pubkey: "d1", name: "Alice", note: "Great driver", roadflareKey: key))
        repo1.addDriver(FollowedDriver(pubkey: "d2", name: "Bob"))
        repo1.cacheDriverName(pubkey: "d1", name: "Alice Display")

        let repo2 = FollowedDriversRepository(persistence: persistence)
        #expect(repo2.drivers.count == 2)
        #expect(repo2.getDriver(pubkey: "d1")?.name == "Alice")
        #expect(repo2.getDriver(pubkey: "d1")?.roadflareKey?.version == 2)
        #expect(repo2.getDriver(pubkey: "d1")?.note == "Great driver")
        #expect(repo2.cachedDriverName(pubkey: "d1") == "Alice Display")
        #expect(repo2.getDriver(pubkey: "d2")?.name == "Bob")
    }

    @Test func driversPersistedAfterRemoval() {
        let persistence = InMemoryFollowedDriversPersistence()
        let repo = FollowedDriversRepository(persistence: persistence)
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.addDriver(FollowedDriver(pubkey: "d2"))
        repo.removeDriver(pubkey: "d1")

        let repo2 = FollowedDriversRepository(persistence: persistence)
        #expect(repo2.drivers.count == 1)
        #expect(repo2.isFollowing(pubkey: "d2"))
        #expect(!repo2.isFollowing(pubkey: "d1"))
    }

    @Test func driversPersistedAfterKeyUpdate() {
        let persistence = InMemoryFollowedDriversPersistence()
        let repo = FollowedDriversRepository(persistence: persistence)
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        #expect(!repo.getDriver(pubkey: "d1")!.hasKey)

        let key = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 3, keyUpdatedAt: 100)
        repo.updateDriverKey(driverPubkey: "d1", roadflareKey: key)

        let repo2 = FollowedDriversRepository(persistence: persistence)
        #expect(repo2.getDriver(pubkey: "d1")!.hasKey)
        #expect(repo2.getDriver(pubkey: "d1")!.roadflareKey?.version == 3)
    }

    @Test func clearAllWipesEverything() {
        let persistence = InMemoryFollowedDriversPersistence()
        let repo = FollowedDriversRepository(persistence: persistence)
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.cacheDriverName(pubkey: "d1", name: "Alice")
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.0, longitude: -74.0, status: "online", timestamp: 100, keyVersion: 1)
        repo.clearAll()

        let repo2 = FollowedDriversRepository(persistence: persistence)
        #expect(repo2.drivers.isEmpty)
        #expect(repo2.driverNames.isEmpty)
        #expect(repo2.driverLocations.isEmpty)
    }

    // MARK: - Location Cache Independence

    @Test func locationsDoNotPersist() {
        let persistence = InMemoryFollowedDriversPersistence()
        let repo1 = FollowedDriversRepository(persistence: persistence)
        repo1.addDriver(FollowedDriver(pubkey: "d1"))
        repo1.updateDriverLocation(pubkey: "d1", latitude: 40.0, longitude: -74.0, status: "online", timestamp: 100, keyVersion: 1)
        #expect(repo1.driverLocations["d1"] != nil)

        // Locations are ephemeral — new repo init should NOT have them
        let repo2 = FollowedDriversRepository(persistence: persistence)
        #expect(repo2.driverLocations["d1"] == nil)
    }

    // MARK: - Restore From Nostr

    @Test func restoreFromNostrReplacesAll() {
        let persistence = InMemoryFollowedDriversPersistence()
        let repo = FollowedDriversRepository(persistence: persistence)
        repo.addDriver(FollowedDriver(pubkey: "old_driver"))

        let content = FollowedDriversContent(
            drivers: [
                FollowedDriverEntry(pubkey: "new1", addedAt: 100, note: "test",
                    roadflareKey: RoadflareKey(privateKeyHex: "p", publicKeyHex: "q", version: 1, keyUpdatedAt: 100)),
                FollowedDriverEntry(pubkey: "new2", addedAt: 200, note: nil, roadflareKey: nil),
            ],
            updatedAt: 300
        )
        repo.restoreFromNostr(content: content)

        #expect(repo.drivers.count == 2)
        #expect(!repo.isFollowing(pubkey: "old_driver"))
        #expect(repo.isFollowing(pubkey: "new1"))
        #expect(repo.getDriver(pubkey: "new1")?.roadflareKey?.version == 1)

        // Verify persisted
        let repo2 = FollowedDriversRepository(persistence: persistence)
        #expect(repo2.drivers.count == 2)
    }

    // MARK: - RideHistoryEntry Codable

    @Test func rideHistoryEntryCodableRoundtrip() throws {
        let entry = RideHistoryEntry(
            id: "ride1",
            date: Date(timeIntervalSince1970: 1700000000),
            counterpartyPubkey: "driver_pub",
            counterpartyName: "Alice",
            pickupGeohash: "dr5ru1",
            dropoffGeohash: "dr5rv2",
            pickup: Location(latitude: 40.71, longitude: -74.01, address: "Penn Station"),
            destination: Location(latitude: 40.76, longitude: -73.98, address: "Central Park"),
            fare: 12.50,
            paymentMethod: "zelle",
            distance: 5.5,
            duration: 18,
            vehicleMake: "Toyota",
            vehicleModel: "Camry"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RideHistoryEntry.self, from: data)

        #expect(decoded.id == "ride1")
        #expect(decoded.counterpartyName == "Alice")
        #expect(decoded.fare == 12.50)
        #expect(decoded.pickup.address == "Penn Station")
        #expect(decoded.destination.address == "Central Park")
        #expect(decoded.distance == 5.5)
        #expect(decoded.duration == 18)
        #expect(decoded.vehicleMake == "Toyota")
        #expect(decoded.appOrigin == "roadflare")
    }

    @Test func rideHistoryEntryMinimalFields() throws {
        let entry = RideHistoryEntry(
            id: "ride2",
            date: Date(),
            counterpartyPubkey: "pub",
            pickupGeohash: "abc",
            dropoffGeohash: "def",
            pickup: Location(latitude: 0, longitude: 0),
            destination: Location(latitude: 0, longitude: 0),
            fare: 5.00,
            paymentMethod: "cash"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RideHistoryEntry.self, from: data)
        #expect(decoded.counterpartyName == nil)
        #expect(decoded.distance == nil)
        #expect(decoded.vehicleMake == nil)
    }

    // MARK: - SavedLocation

    @Test func savedLocationRoundtrip() throws {
        let loc = SavedLocation(
            latitude: 40.7128, longitude: -74.006,
            displayName: "Home", addressLine: "123 Main St",
            locality: "New York", isPinned: true, nickname: "Home"
        )
        let data = try JSONEncoder().encode(loc)
        let decoded = try JSONDecoder().decode(SavedLocation.self, from: data)
        #expect(decoded.displayName == "Home")
        #expect(decoded.isPinned)
        #expect(decoded.nickname == "Home")
        #expect(decoded.toLocation().latitude == 40.7128)
    }

    // MARK: - Payment Method Persistence

    @Test func paymentMethodCodableArray() throws {
        let methods: [PaymentMethod] = [.zelle, .venmo, .cash]
        let rawValues = methods.map(\.rawValue)
        let data = try JSONEncoder().encode(rawValues)
        let decoded = try JSONDecoder().decode([String].self, from: data)
        let restored = decoded.compactMap { PaymentMethod(rawValue: $0) }
        #expect(restored == methods)
    }

    // Note: RideStatePersistence, RideHistoryStore, and UserDefaultsDriversPersistence
    // are app-level services. Their tests belong in the RoadFlareTests target.
    // SDK tests cover the underlying data models (RideHistoryEntry, SavedLocation, etc.)
}
