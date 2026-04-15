import Testing
@testable import RoadFlareCore
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

@Suite("AppState.canPingDriver")
struct CanPingDriverTests {

    @Test func noKey_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let repo = makeRepo(driver: driver)
        #expect(AppState.canPingDriver(driver, using: repo) == false)
    }

    @Test func staleKey_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        repo.markKeyStale(pubkey: testPubkey)
        #expect(AppState.canPingDriver(driver, using: repo) == false)
    }

    @Test func online_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        #expect(AppState.canPingDriver(driver, using: repo) == false)
    }

    @Test func onRide_returnsFalse() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "on_ride", timestamp: 1_000_000, keyVersion: 1)
        #expect(AppState.canPingDriver(driver, using: repo) == false)
    }

    @Test func offlineWithCurrentKey_returnsTrue() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        // No location update → driver is offline (nil status)
        #expect(AppState.canPingDriver(driver, using: repo) == true)
    }
}
