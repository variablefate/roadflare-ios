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

@Suite("FollowedDriversRepository.rideOfferPreflight")
struct RideOfferPreflightTests {

    @Test func unknownDriver_returnsDriverNotFollowed() {
        let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        #expect(repo.rideOfferPreflight(driverPubkey: testPubkey) == .driverNotFollowed)
    }

    @Test func missingKey_returnsMissingKey() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        #expect(repo.rideOfferPreflight(driverPubkey: testPubkey) == .missingKey)
    }

    @Test func staleKey_returnsStaleKey() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        repo.markKeyStale(pubkey: testPubkey)
        #expect(repo.rideOfferPreflight(driverPubkey: testPubkey) == .staleKey)
    }

    @Test func offline_returnsOffline() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        // No location update → status nil → not online
        #expect(repo.rideOfferPreflight(driverPubkey: testPubkey) == .offline)
    }

    @Test func onRide_returnsOnRide() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "on_ride", timestamp: 1_000_000, keyVersion: 1)
        // "on_ride" is distinct from "offline" — the driver is present and
        // reachable but servicing another ride. The preflight surfaces this
        // as `.onRide` so callers can show a more accurate message than
        // "Driver just went offline."
        #expect(repo.rideOfferPreflight(driverPubkey: testPubkey) == .onRide)
    }

    @Test func onlineWithCurrentKey_returnsNil() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        _ = repo.updateDriverLocation(pubkey: testPubkey, latitude: 0, longitude: 0,
                                      status: "online", timestamp: 1_000_000, keyVersion: 1)
        #expect(repo.rideOfferPreflight(driverPubkey: testPubkey) == nil)
    }

    // MARK: - Stale-key surfaces over offline / missing-key priority

    @Test func staleKeyTakesPrecedenceOverOffline() {
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(driver: driver)
        // No location → would be .offline. But stale key takes precedence.
        repo.markKeyStale(pubkey: testPubkey)
        #expect(repo.rideOfferPreflight(driverPubkey: testPubkey) == .staleKey)
    }

    @Test func missingKeyTakesPrecedenceOverStaleKey() {
        // Stale-key tracking is keyed by pubkey, so a driver without any key
        // who somehow ended up in staleKeyPubkeys should still surface
        // .missingKey — the key gate runs before the stale gate.
        let driver = FollowedDriver(pubkey: testPubkey, name: "Bob", roadflareKey: nil)
        let repo = makeRepo(driver: driver)
        repo.markKeyStale(pubkey: testPubkey)
        #expect(repo.rideOfferPreflight(driverPubkey: testPubkey) == .missingKey)
    }
}
