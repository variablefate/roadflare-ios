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
        repo.addDriver(FollowedDriver(pubkey: "d1", addedAt: 100, name: "Alice", note: "Local note"))
        let key = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 1, keyUpdatedAt: 100)
        repo.updateDriverKey(driverPubkey: "d1", roadflareKey: key)
        repo.cacheDriverName(pubkey: "d1", name: "Alice Display")
        repo.cacheDriverProfile(pubkey: "d1", profile: UserProfileContent(about: "Driver bio"))
        repo.updateDriverLocation(
            pubkey: "d1", latitude: 40.0, longitude: -74.0,
            status: "online", timestamp: 100, keyVersion: 1
        )
        repo.markKeyStale(pubkey: "d1")

        repo.addDriver(FollowedDriver(pubkey: "d1"))
        #expect(repo.drivers.count == 1)
        #expect(repo.getDriver(pubkey: "d1")?.addedAt == 100)
        #expect(repo.getDriver(pubkey: "d1")?.name == "Alice")
        #expect(repo.getDriver(pubkey: "d1")?.note == "Local note")
        #expect(repo.getDriver(pubkey: "d1")?.roadflareKey?.version == 1)
        #expect(repo.cachedDriverName(pubkey: "d1") == "Alice Display")
        #expect(repo.cachedDriverProfile(pubkey: "d1")?.about == "Driver bio")
        #expect(repo.driverLocations["d1"] != nil)
        #expect(repo.staleKeyPubkeys.contains("d1"))
    }

    @Test func addDriverUsesIncomingReplacementWhenNonEmptyAndNewer() {
        let repo = makeRepo()
        let olderKey = RoadflareKey(privateKeyHex: "oldPriv", publicKeyHex: "oldPub", version: 1, keyUpdatedAt: 100)
        let newerKey = RoadflareKey(privateKeyHex: "newPriv", publicKeyHex: "newPub", version: 2, keyUpdatedAt: 200)
        repo.addDriver(FollowedDriver(pubkey: "d1", addedAt: 100, name: "Alice", note: "Old note", roadflareKey: olderKey))
        repo.markKeyStale(pubkey: "d1")

        repo.addDriver(FollowedDriver(pubkey: "d1", addedAt: 999, name: "Alice Updated", note: "New note", roadflareKey: newerKey))

        let driver = repo.getDriver(pubkey: "d1")
        #expect(driver?.addedAt == 100)
        #expect(driver?.name == "Alice Updated")
        #expect(driver?.note == "New note")
        #expect(driver?.roadflareKey?.version == 2)
        #expect(!repo.staleKeyPubkeys.contains("d1"))
    }

    @Test func addDriverClearsStaleFlagWhenKeyUpdatedAtAdvances() {
        let repo = makeRepo()
        let current = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 1, keyUpdatedAt: 100)
        let refreshed = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 1, keyUpdatedAt: 200)
        repo.addDriver(FollowedDriver(pubkey: "d1", roadflareKey: current))
        repo.markKeyStale(pubkey: "d1")

        repo.addDriver(FollowedDriver(pubkey: "d1", roadflareKey: refreshed))

        #expect(repo.getDriver(pubkey: "d1")?.roadflareKey?.keyUpdatedAt == 200)
        #expect(!repo.staleKeyPubkeys.contains("d1"))
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
        repo.cacheDriverProfile(pubkey: "d1", profile: UserProfileContent(about: "Driver bio"))
        repo.updateDriverLocation(pubkey: "d1", latitude: 40.0, longitude: -74.0, status: "online", timestamp: 100, keyVersion: 1)
        repo.markKeyStale(pubkey: "d1")
        repo.removeDriver(pubkey: "d1")
        #expect(repo.cachedDriverName(pubkey: "d1") == nil)
        #expect(repo.cachedDriverProfile(pubkey: "d1") == nil)
        #expect(repo.driverLocations["d1"] == nil)
        #expect(!repo.staleKeyPubkeys.contains("d1"))
    }

    @Test func updateDriverKey() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1"))
        #expect(repo.getDriver(pubkey: "d1")?.hasKey == false)

        let key = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 1, keyUpdatedAt: 100)
        let outcome = repo.updateDriverKey(driverPubkey: "d1", roadflareKey: key)
        #expect(outcome == .appliedNewer)
        #expect(repo.getDriver(pubkey: "d1")?.hasKey == true)
        #expect(repo.getDriver(pubkey: "d1")?.roadflareKey?.version == 1)
    }

    @Test func updateDriverKeyForUnknownDriverDoesNothing() {
        let repo = makeRepo()
        let key = RoadflareKey(privateKeyHex: "p", publicKeyHex: "q", version: 1, keyUpdatedAt: 0)
        let outcome = repo.updateDriverKey(driverPubkey: "unknown", roadflareKey: key)
        #expect(outcome == .unknownDriver)
        #expect(repo.drivers.isEmpty)
    }

    @Test func updateDriverKeyRejectsOlderKey() {
        let repo = makeRepo()
        let current = RoadflareKey(privateKeyHex: "current", publicKeyHex: "current-pub", version: 2, keyUpdatedAt: 200)
        let older = RoadflareKey(privateKeyHex: "older", publicKeyHex: "older-pub", version: 1, keyUpdatedAt: 100)
        repo.addDriver(FollowedDriver(pubkey: "d1", roadflareKey: current))

        let outcome = repo.updateDriverKey(driverPubkey: "d1", roadflareKey: older)

        #expect(outcome == .ignoredOlder)
        #expect(repo.getDriver(pubkey: "d1")?.roadflareKey == current)
    }

    @Test func updateDriverKeyTreatsSameKeyAsDuplicate() {
        let repo = makeRepo()
        let current = RoadflareKey(privateKeyHex: "current", publicKeyHex: "current-pub", version: 2, keyUpdatedAt: 200)
        repo.addDriver(FollowedDriver(pubkey: "d1", roadflareKey: current))

        let outcome = repo.updateDriverKey(driverPubkey: "d1", roadflareKey: current)

        #expect(outcome == .duplicateCurrent)
        #expect(repo.getDriver(pubkey: "d1")?.roadflareKey == current)
    }

    // Regression for issue #72, Bug 3: writing one driver's key during a
    // backup-restore must not flip another driver's stale flag. The iOS-side
    // restore path (`AppState.restoreKeyFromBackup`) routes exclusively
    // through `updateDriverKey` for the target pubkey, so the only way the
    // user-reported "restoring one driver makes others outdated" symptom
    // could originate on the rider side is through a cross-driver write
    // here. This test pins that contract.
    @Test func updateDriverKeyDoesNotAffectOtherDriversStaleFlags() {
        let repo = makeRepo()
        let key1 = RoadflareKey(privateKeyHex: "p1", publicKeyHex: "q1", version: 1, keyUpdatedAt: 100)
        let key2 = RoadflareKey(privateKeyHex: "p2", publicKeyHex: "q2", version: 1, keyUpdatedAt: 100)
        repo.addDriver(FollowedDriver(pubkey: "d1", roadflareKey: key1))
        repo.addDriver(FollowedDriver(pubkey: "d2", roadflareKey: key2))
        repo.markKeyStale(pubkey: "d2")

        // Restore-style key write for d1.
        let restoredKey = RoadflareKey(privateKeyHex: "p1b", publicKeyHex: "q1b", version: 2, keyUpdatedAt: 200)
        let outcome = repo.updateDriverKey(driverPubkey: "d1", roadflareKey: restoredKey, source: .sync)
        #expect(outcome == .appliedNewer)

        // d2's stale state must be untouched.
        #expect(repo.staleKeyPubkeys == ["d2"])
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

    @Test func cachedDriverNameFallsBackToFollowedDriverName() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1", name: "Alice"))

        #expect(repo.cachedDriverName(pubkey: "d1") == "Alice")
    }

    @Test func cachedDriverNamePrefersCachedProfileName() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1", name: "Alice"))
        repo.cacheDriverName(pubkey: "d1", name: "Alice Display")

        #expect(repo.cachedDriverName(pubkey: "d1") == "Alice Display")
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
        let oldKey = RoadflareKey(privateKeyHex: "oldPriv", publicKeyHex: "oldPub", version: 1, keyUpdatedAt: 100)
        repo.addDriver(FollowedDriver(pubkey: "old", name: "Old", note: "Old note", roadflareKey: oldKey))
        repo.cacheDriverName(pubkey: "old", name: "Old Display")
        repo.cacheDriverProfile(pubkey: "old", profile: UserProfileContent(about: "Old bio"))
        repo.updateDriverLocation(pubkey: "old", latitude: 40.0, longitude: -74.0, status: "online", timestamp: 100, keyVersion: 1)
        repo.markKeyStale(pubkey: "old")
        let newDrivers = [
            FollowedDriver(pubkey: "old"),
            FollowedDriver(pubkey: "new2"),
        ]
        repo.replaceAll(drivers: newDrivers)
        #expect(repo.drivers.count == 2)
        #expect(repo.isFollowing(pubkey: "old"))
        #expect(repo.isFollowing(pubkey: "new2"))
        #expect(repo.getDriver(pubkey: "old")?.name == "Old")
        #expect(repo.getDriver(pubkey: "old")?.note == nil)
        #expect(repo.getDriver(pubkey: "old")?.roadflareKey?.version == 1)
        #expect(repo.cachedDriverName(pubkey: "old") == "Old Display")
        #expect(repo.cachedDriverProfile(pubkey: "old")?.about == "Old bio")
        #expect(repo.driverLocations["old"] != nil)
        #expect(repo.staleKeyPubkeys.contains("old"))
    }

    @Test func replaceAllTreatsRemoteNoteAsAuthoritative() {
        let repo = makeRepo()
        repo.addDriver(FollowedDriver(pubkey: "d1", addedAt: 100, note: "Old note"))

        repo.replaceAll(drivers: [FollowedDriver(pubkey: "d1", addedAt: 200, note: "")])

        #expect(repo.getDriver(pubkey: "d1")?.addedAt == 200)
        #expect(repo.getDriver(pubkey: "d1")?.note == nil)
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
