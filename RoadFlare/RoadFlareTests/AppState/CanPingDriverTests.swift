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

@Suite("FollowedDriversRepository.canPingDriver")
struct CanPingDriverTests {

    @Test func noKey_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let repo = makeRepo(driver: driver)
        #expect(repo.canPingDriver(driver) == false)
    }

    @Test func staleKey_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        repo.markKeyStale(pubkey: testPubkey)
        #expect(repo.canPingDriver(driver) == false)
    }

    @Test func online_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        #expect(repo.canPingDriver(driver) == false)
    }

    @Test func onRide_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "on_ride", timestamp: 1_000_000, keyVersion: 1)
        #expect(repo.canPingDriver(driver) == false)
    }

    @Test func offlineWithCurrentKey_returnsTrue() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        // No location update → driver is offline (nil status)
        #expect(repo.canPingDriver(driver) == true)
    }

    @Test func staleCallerSnapshot_missingKeyButRepoHasCurrentKey_returnsTrue() {
        let repoDriver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let staleSnapshot = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let repo = makeRepo(driver: repoDriver)
        #expect(repo.canPingDriver(staleSnapshot) == true)
    }

    @Test func staleCallerSnapshot_hasKeyButRepoMissingKey_returnsFalse() {
        let repoDriver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let staleSnapshot = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: repoDriver)
        #expect(repo.canPingDriver(staleSnapshot) == false)
    }
}

@Suite("FollowedDriversRepository.driverPingPreflight")
struct DriverPingPreflightTests {

    @Test func unknownDriver_returnsIneligible() {
        let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        #expect(repo.driverPingPreflight(driverPubkey: testPubkey) == .ineligible)
    }

    @Test func missingKey_returnsMissingKey() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let repo = makeRepo(driver: driver)
        #expect(repo.driverPingPreflight(driverPubkey: testPubkey) == .missingKey)
    }

    @Test func staleKey_returnsIneligible() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        repo.markKeyStale(pubkey: testPubkey)
        #expect(repo.driverPingPreflight(driverPubkey: testPubkey) == .ineligible)
    }

    @Test func online_returnsIneligible() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        #expect(repo.driverPingPreflight(driverPubkey: testPubkey) == .ineligible)
    }

    @Test func offlineWithCurrentKey_returnsNil() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        #expect(repo.driverPingPreflight(driverPubkey: testPubkey) == nil)
    }
}
