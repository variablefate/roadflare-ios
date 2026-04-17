import Testing
import RidestrSDK

// Use the SDK's own InMemoryFollowedDriversPersistence (FollowedDriversRepository.swift:459)
// rather than a hand-rolled fake — it satisfies the same protocol with the same semantics.
private let testPubkey = String(repeating: "a", count: 64)
private let testKey = RoadflareKey(
    privateKeyHex: String(repeating: "b", count: 64),
    publicKeyHex:  String(repeating: "c", count: 64),
    version: 1, keyUpdatedAt: nil
)

private func makeRepo(driver: FollowedDriver) -> FollowedDriversRepository {
    let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
    repo.addDriver(driver)
    return repo
}

@Suite("FollowedDriversRepository.canRequestRide")
struct CanRequestRideTests {

    @Test func unknownDriver_returnsFalse() {
        let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        let stranger = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        #expect(repo.canRequestRide(stranger) == false)
    }

    @Test func noKey_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        #expect(repo.canRequestRide(driver) == false)
    }

    @Test func staleKey_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        repo.markKeyStale(pubkey: testPubkey)
        #expect(repo.canRequestRide(driver) == false)
    }

    @Test func offline_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        // No location update → status nil → not online
        #expect(repo.canRequestRide(driver) == false)
    }

    @Test func onRide_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "on_ride", timestamp: 1_000_000, keyVersion: 1)
        #expect(repo.canRequestRide(driver) == false)
    }

    @Test func onlineWithCurrentKey_returnsTrue() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        #expect(repo.canRequestRide(driver) == true)
    }

    @Test func staleCallerSnapshot_missingKeyButRepoHasCurrentKey_returnsTrue() {
        let repoDriver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let staleSnapshot = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let repo = makeRepo(driver: repoDriver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        #expect(repo.canRequestRide(staleSnapshot) == true)
    }

    @Test func staleCallerSnapshot_hasKeyButRepoMissingKey_returnsFalse() {
        let repoDriver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let staleSnapshot = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: repoDriver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        #expect(repo.canRequestRide(staleSnapshot) == false)
    }
}
