import Foundation
import Testing
@testable import RidestrSDK

@Suite("FollowedDriversRepository Extended Tests")
struct FollowedDriversRepositoryExtendedTests {

    private func makeRepo() -> FollowedDriversRepository {
        FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
    }

    // MARK: - Driver Management

    @Test func addDriverInsertsNew() {
        let repo = makeRepo()
        let driver = FollowedDriver(pubkey: "d1", name: "Alice")
        repo.addDriver(driver)
        #expect(repo.drivers.count == 1)
        #expect(repo.getDriver(pubkey: "d1")?.name == "Alice")
    }

    @Test func addDriverUpdatesExisting() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1", name: "Alice"))
        repo.addDriver(FollowedDriver(pubkey: "d1", name: "Bob"))
        #expect(repo.drivers.count == 1)
        #expect(repo.getDriver(pubkey: "d1")?.name == "Bob")
    }

    @Test func removeDriverClearsAllRelatedData() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1", name: "Alice"))
        repo.cacheDriverName(pubkey: "d1", name: "Alice Display")
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.7, longitude: -74.0,
                                   status: "online", timestamp: 1000, keyVersion: 1)

        repo.removeDriver(pubkey: "d1")
        #expect(repo.drivers.isEmpty)
        #expect(repo.cachedDriverName(pubkey: "d1") == nil)
        #expect(repo.driverLocations["d1"] == nil)
    }

    @Test func updateDriverKeyOnExistingDriver() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        let key = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 1)
        repo.updateDriverKey(driverPubkey: "d1", roadflareKey: key)
        #expect(repo.getDriver(pubkey: "d1")?.roadflareKey?.publicKeyHex == "pub")
    }

    @Test func updateDriverKeyOnNonexistentDriverDoesNothing() {
        let repo = makeRepo()
        let key = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 1)
        repo.updateDriverKey(driverPubkey: "nonexistent", roadflareKey: key)
        #expect(repo.drivers.isEmpty)
    }

    @Test func updateDriverNote() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.updateDriverNote(driverPubkey: "d1", note: "Reliable driver")
        #expect(repo.getDriver(pubkey: "d1")?.note == "Reliable driver")
    }

    // MARK: - Queries

    @Test func allPubkeys() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.addDriver(FollowedDriver(pubkey: "d2"))
        #expect(Set(repo.allPubkeys) == ["d1", "d2"])
    }

    @Test func isFollowing() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        #expect(repo.isFollowing(pubkey: "d1"))
        #expect(!repo.isFollowing(pubkey: "d2"))
    }

    @Test func hasDrivers() {
        let repo = makeRepo()
        #expect(!repo.hasDrivers)
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        #expect(repo.hasDrivers)
    }

    // MARK: - Driver Names

    @Test func cacheDriverNameOnlyForFollowed() {
        let repo = makeRepo()
        // Can't cache name for unfollowed driver
        repo.cacheDriverName(pubkey: "d1", name: "Alice")
        #expect(repo.cachedDriverName(pubkey: "d1") == nil)

        // Follow, then cache
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.cacheDriverName(pubkey: "d1", name: "Alice")
        #expect(repo.cachedDriverName(pubkey: "d1") == "Alice")
    }

    // MARK: - Location Cache

    @Test func updateLocationRejectsStale() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))

        let first = repo.updateDriverLocation(pubkey: "d1", latitude: 40.7, longitude: -74.0,
                                               status: "online", timestamp: 1000, keyVersion: 1)
        #expect(first)

        // Older timestamp rejected
        let second = repo.updateDriverLocation(pubkey: "d1", latitude: 40.8, longitude: -73.9,
                                                status: "online", timestamp: 900, keyVersion: 1)
        #expect(!second)

        // Newer timestamp accepted
        let third = repo.updateDriverLocation(pubkey: "d1", latitude: 40.9, longitude: -73.8,
                                               status: "on_ride", timestamp: 1100, keyVersion: 1)
        #expect(third)
        #expect(repo.driverLocations["d1"]?.status == "on_ride")
    }

    @Test func clearDriverLocations() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.7, longitude: -74.0,
                                   status: "online", timestamp: 1000, keyVersion: 1)
        #expect(!repo.driverLocations.isEmpty)

        repo.clearDriverLocations()
        #expect(repo.driverLocations.isEmpty)
    }

    @Test func getRoadflareKey() {
        let repo = makeRepo()
        let key = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 1)
        repo.addDriver(FollowedDriver(pubkey: "d1", roadflareKey: key))
        #expect(repo.getRoadflareKey(driverPubkey: "d1")?.publicKeyHex == "pub")
        #expect(repo.getRoadflareKey(driverPubkey: "nonexistent") == nil)
    }

    // MARK: - Sync

    @Test func replaceAllOverwrites() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.addDriver(FollowedDriver(pubkey: "d2"))
        #expect(repo.drivers.count == 2)

        repo.replaceAll(drivers: [FollowedDriver(pubkey: "d3")])
        #expect(repo.drivers.count == 1)
        #expect(repo.drivers[0].pubkey == "d3")
    }

    @Test func restoreFromNostr() {
        let repo = makeRepo()
        let content = FollowedDriversContent(
            drivers: [
                FollowedDriverEntry(pubkey: "d1", addedAt: 1000, note: "Note 1", roadflareKey: nil),
                FollowedDriverEntry(pubkey: "d2", addedAt: 2000, note: nil, roadflareKey: nil),
            ],
            updatedAt: 3000
        )
        repo.restoreFromNostr(content: content)
        #expect(repo.drivers.count == 2)
        #expect(repo.getDriver(pubkey: "d1")?.note == "Note 1")
    }

    // MARK: - Cleanup

    @Test func clearAllRemovesEverything() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        repo.cacheDriverName(pubkey: "d1", name: "Alice")
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.7, longitude: -74.0,
                                   status: "online", timestamp: 1000, keyVersion: 1)

        repo.clearAll()
        #expect(repo.drivers.isEmpty)
        #expect(repo.driverNames.isEmpty)
        #expect(repo.driverLocations.isEmpty)
    }

    // MARK: - Persistence Roundtrip

    @Test func persistenceRoundtrip() {
        let persistence = InMemoryFollowedDriversPersistence()
        let repo1 = FollowedDriversRepository(persistence: persistence)
        repo1.addDriver(FollowedDriver(pubkey: "d1", name: "Alice"))
        repo1.cacheDriverName(pubkey: "d1", name: "Alice Display")

        // New repo from same persistence should load the data
        let repo2 = FollowedDriversRepository(persistence: persistence)
        #expect(repo2.drivers.count == 1)
        #expect(repo2.cachedDriverName(pubkey: "d1") == "Alice Display")
    }
}
