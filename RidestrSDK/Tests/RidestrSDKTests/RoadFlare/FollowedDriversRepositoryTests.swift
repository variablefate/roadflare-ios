import Foundation
import Testing
@testable import RidestrSDK

@Suite("FollowedDriversRepository Tests")
struct FollowedDriversRepositoryTests {
    func makeRepo() -> FollowedDriversRepository {
        FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
    }

    @Test func emptyOnInit() {
        let repo = makeRepo()
        #expect(repo.drivers.isEmpty)
        #expect(!repo.hasDrivers)
        #expect(repo.allPubkeys.isEmpty)
    }

    @Test func addDriver() {
        let repo = makeRepo()
        let driver = FollowedDriver(pubkey: "d1", name: "Alice")
        repo.addDriver(driver)
        #expect(repo.drivers.count == 1)
        #expect(repo.hasDrivers)
        #expect(repo.isFollowing(pubkey: "d1"))
        #expect(!repo.isFollowing(pubkey: "d2"))
    }

    @Test func addDriverUpdatesExisting() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1", name: "Alice"))
        repo.addDriver(FollowedDriver(pubkey: "d1", name: "Alice Updated"))
        #expect(repo.drivers.count == 1)
        #expect(repo.getDriver(pubkey: "d1")?.name == "Alice Updated")
    }

    @Test func removeDriver() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1", name: "Alice"))
        repo.addDriver(FollowedDriver(pubkey: "d2", name: "Bob"))
        repo.removeDriver(pubkey: "d1")
        #expect(repo.drivers.count == 1)
        #expect(!repo.isFollowing(pubkey: "d1"))
        #expect(repo.isFollowing(pubkey: "d2"))
    }

    @Test func removeDriverCleansUpNamesAndLocations() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1", name: "Alice"))
        repo.cacheDriverName(pubkey: "d1", name: "Alice Display")
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.0, longitude: -74.0, status: "online", timestamp: 100, keyVersion: 1)
        repo.removeDriver(pubkey: "d1")
        #expect(repo.cachedDriverName(pubkey: "d1") == nil)
        #expect(repo.driverLocations["d1"] == nil)
    }

    @Test func updateDriverKey() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        #expect(repo.getDriver(pubkey: "d1")?.hasKey == false)

        let key = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 1, keyUpdatedAt: 100)
        repo.updateDriverKey(driverPubkey: "d1", roadflareKey: key)
        #expect(repo.getDriver(pubkey: "d1")?.hasKey == true)
        #expect(repo.getDriver(pubkey: "d1")?.roadflareKey?.version == 1)
    }

    @Test func updateDriverKeyForUnknownDriverDoesNothing() {
        let repo = makeRepo()
        let key = RoadflareKey(privateKeyHex: "p", publicKeyHex: "q", version: 1, keyUpdatedAt: 0)
        repo.updateDriverKey(driverPubkey: "unknown", roadflareKey: key)
        #expect(repo.drivers.isEmpty)
    }

    @Test func updateDriverNote() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.updateDriverNote(driverPubkey: "d1", note: "Great driver, Toyota Camry")
        #expect(repo.getDriver(pubkey: "d1")?.note == "Great driver, Toyota Camry")
    }

    @Test func getRoadflareKey() {
        let repo = makeRepo()
        let key = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 2, keyUpdatedAt: 200)
        repo.addDriver(FollowedDriver(pubkey: "d1", roadflareKey: key))
        #expect(repo.getRoadflareKey(driverPubkey: "d1")?.version == 2)
        #expect(repo.getRoadflareKey(driverPubkey: "unknown") == nil)
    }

    @Test func allPubkeys() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.addDriver(FollowedDriver(pubkey: "d2"))
        repo.addDriver(FollowedDriver(pubkey: "d3"))
        #expect(Set(repo.allPubkeys) == Set(["d1", "d2", "d3"]))
    }

    // MARK: - Driver Names

    @Test func cacheDriverName() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.cacheDriverName(pubkey: "d1", name: "Alice")
        #expect(repo.cachedDriverName(pubkey: "d1") == "Alice")
    }

    @Test func cacheDriverNameOnlyForFollowed() {
        let repo = makeRepo()
        repo.cacheDriverName(pubkey: "unknown", name: "Stranger")
        #expect(repo.cachedDriverName(pubkey: "unknown") == nil)
    }

    // MARK: - Driver Locations

    @Test func updateDriverLocation() {
        let repo = makeRepo()
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.7, longitude: -74.0, status: "online", timestamp: 1000, keyVersion: 2)
        let loc = repo.driverLocations["d1"]
        #expect(loc?.latitude == 40.7)
        #expect(loc?.status == "online")
        #expect(loc?.keyVersion == 2)
    }

    @Test func staleLocationRejected() {
        let repo = makeRepo()
        // First update at timestamp 200
        let accepted = repo.updateDriverLocation(
            pubkey: "d1", latitude: 40.0, longitude: -74.0,
            status: "online", timestamp: 200, keyVersion: 1
        )
        #expect(accepted)

        // Newer update at timestamp 300 — accepted
        let newer = repo.updateDriverLocation(
            pubkey: "d1", latitude: 40.1, longitude: -73.9,
            status: "on_ride", timestamp: 300, keyVersion: 1
        )
        #expect(newer)
        #expect(repo.driverLocations["d1"]?.latitude == 40.1)

        // Stale update at timestamp 250 — rejected (older than 300)
        let stale = repo.updateDriverLocation(
            pubkey: "d1", latitude: 39.0, longitude: -75.0,
            status: "online", timestamp: 250, keyVersion: 1
        )
        #expect(!stale)
        #expect(repo.driverLocations["d1"]?.latitude == 40.1)  // Unchanged
    }

    @Test func sameTimestampLocationRejected() {
        let repo = makeRepo()
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.0, longitude: -74.0, status: "online", timestamp: 200, keyVersion: 1)
        let duplicate = repo.updateDriverLocation(pubkey: "d1", latitude: 41.0, longitude: -73.0, status: "online", timestamp: 200, keyVersion: 1)
        #expect(!duplicate)
        #expect(repo.driverLocations["d1"]?.latitude == 40.0)  // First one kept
    }

    @Test func removeDriverLocation() {
        let repo = makeRepo()
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.0, longitude: -74.0, status: "online", timestamp: 100, keyVersion: 1)
        repo.removeDriverLocation(pubkey: "d1")
        #expect(repo.driverLocations["d1"] == nil)
    }

    @Test func clearDriverLocations() {
        let repo = makeRepo()
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.0, longitude: -74.0, status: "online", timestamp: 100, keyVersion: 1)
        repo.updateDriverLocation(pubkey: "d2", latitude: 41.0, longitude: -73.0, status: "on_ride", timestamp: 100, keyVersion: 1)
        repo.clearDriverLocations()
        #expect(repo.driverLocations.isEmpty)
    }

    // MARK: - Sync

    @Test func replaceAll() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "old"))
        let newDrivers = [
            FollowedDriver(pubkey: "new1"),
            FollowedDriver(pubkey: "new2"),
        ]
        repo.replaceAll(drivers: newDrivers)
        #expect(repo.drivers.count == 2)
        #expect(!repo.isFollowing(pubkey: "old"))
        #expect(repo.isFollowing(pubkey: "new1"))
    }

    @Test func restoreFromNostr() {
        let repo = makeRepo()
        let content = FollowedDriversContent(
            drivers: [
                FollowedDriverEntry(pubkey: "d1", addedAt: 100, note: "test",
                    roadflareKey: RoadflareKey(privateKeyHex: "p", publicKeyHex: "q", version: 1, keyUpdatedAt: 200)),
                FollowedDriverEntry(pubkey: "d2", addedAt: 200, note: nil, roadflareKey: nil),
            ],
            updatedAt: 300
        )
        repo.restoreFromNostr(content: content)
        #expect(repo.drivers.count == 2)
        #expect(repo.getDriver(pubkey: "d1")?.roadflareKey?.version == 1)
        #expect(repo.getDriver(pubkey: "d2")?.hasKey == false)
    }

    // MARK: - Persistence

    @Test func persistsAcrossInit() {
        let persistence = InMemoryFollowedDriversPersistence()
        let repo1 = FollowedDriversRepository(persistence: persistence)
        repo1.addDriver(FollowedDriver(pubkey: "d1", name: "Alice"))
        repo1.cacheDriverName(pubkey: "d1", name: "Alice Display")

        let repo2 = FollowedDriversRepository(persistence: persistence)
        #expect(repo2.drivers.count == 1)
        #expect(repo2.getDriver(pubkey: "d1")?.name == "Alice")
        #expect(repo2.cachedDriverName(pubkey: "d1") == "Alice Display")
    }

    // MARK: - Cleanup

    @Test func clearAll() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.cacheDriverName(pubkey: "d1", name: "Alice")
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.0, longitude: -74.0, status: "online", timestamp: 100, keyVersion: 1)
        repo.clearAll()
        #expect(repo.drivers.isEmpty)
        #expect(repo.driverNames.isEmpty)
        #expect(repo.driverLocations.isEmpty)
    }
}
