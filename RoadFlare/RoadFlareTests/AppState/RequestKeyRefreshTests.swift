import Testing
import Foundation
@testable import RoadFlareCore
@testable import RidestrSDK

// Pure AppState behavior tests for the user-initiated key-refresh path. The SDK
// network call is bypassed because `rideCoordinator` stays nil — the test seam
// `installDriverPingTestContext` only wires the repository. That's deliberate:
// these tests pin the rate-limit + outcome contract without depending on relay
// machinery. The underlying `LocationSyncCoordinator.requestKeyRefresh` is
// covered separately in the SDK suite.

private let pubkeyA = String(repeating: "a", count: 64)
private let pubkeyB = String(repeating: "b", count: 64)
private let testKey = RoadflareKey(
    privateKeyHex: String(repeating: "c", count: 64),
    publicKeyHex:  String(repeating: "d", count: 64),
    version: 1, keyUpdatedAt: nil
)

private func makeRepo(drivers: [FollowedDriver] = []) -> FollowedDriversRepository {
    let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
    drivers.forEach { repo.addDriver($0) }
    return repo
}

@Suite("AppState.requestKeyRefresh")
@MainActor
struct AppStateRequestKeyRefreshTests {

    @Test func firstCallReturnsSent() async {
        let driver = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        let outcome = await appState.requestKeyRefresh(pubkey: pubkeyA)
        #expect(outcome == .sent)
    }

    @Test func secondCallWithinCooldownReturnsRateLimited() async {
        let driver = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        _ = await appState.requestKeyRefresh(pubkey: pubkeyA)
        let outcome = await appState.requestKeyRefresh(pubkey: pubkeyA)

        guard case .rateLimited(let retryAt) = outcome else {
            Issue.record("Expected .rateLimited, got \(outcome)")
            return
        }
        #expect(retryAt > Date.now)
        // Retry should land within ~60s of now (allowing a generous margin for slow CI).
        #expect(retryAt.timeIntervalSinceNow <= 60)
    }

    @Test func cooldownIsPerPubkey() async {
        let driverA = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let driverB = FollowedDriver(pubkey: pubkeyB, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driverA, driverB])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        _ = await appState.requestKeyRefresh(pubkey: pubkeyA)
        // Driver B has its own cooldown slot — same-instant request must succeed.
        let outcomeB = await appState.requestKeyRefresh(pubkey: pubkeyB)
        #expect(outcomeB == .sent)
    }

    @Test func expiredCooldownAllowsResend() async {
        let driver = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        // Prime cooldown to a timestamp safely past the 60s window.
        let pastDate = Date.now.addingTimeInterval(-(AppState.keyRefreshCooldownSeconds + 5))
        appState.primeKeyRefreshCooldownForTesting(pubkey: pubkeyA, lastRequest: pastDate)

        let outcome = await appState.requestKeyRefresh(pubkey: pubkeyA)
        #expect(outcome == .sent)
    }
}

@Suite("AppState.refreshAllStaleDriverKeys")
@MainActor
struct AppStateRefreshAllStaleDriverKeysTests {

    @Test func returnsZeroWhenNoStaleDrivers() async {
        let driver = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        let sent = await appState.refreshAllStaleDriverKeys()
        #expect(sent == 0)
    }

    @Test func sendsForEachStaleDriver() async {
        let driverA = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let driverB = FollowedDriver(pubkey: pubkeyB, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driverA, driverB])
        repo.markKeyStale(pubkey: pubkeyA)
        repo.markKeyStale(pubkey: pubkeyB)
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        let sent = await appState.refreshAllStaleDriverKeys()
        #expect(sent == 2)
    }

    @Test func skipsNonStaleDrivers() async {
        let staleDriver = FollowedDriver(pubkey: pubkeyA, name: "Stale", roadflareKey: testKey)
        let freshDriver = FollowedDriver(pubkey: pubkeyB, name: "Fresh", roadflareKey: testKey)
        let repo = makeRepo(drivers: [staleDriver, freshDriver])
        repo.markKeyStale(pubkey: pubkeyA)
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        let sent = await appState.refreshAllStaleDriverKeys()
        #expect(sent == 1)
        // The non-stale driver's cooldown slot must remain free so a real
        // user-initiated tap on its row works immediately afterward.
        #expect(appState.staleKeyDriverPubkeys == [pubkeyA])
    }

    @Test func subsequentCallReturnsZeroDueToRateLimit() async {
        let driver = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driver])
        repo.markKeyStale(pubkey: pubkeyA)
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        _ = await appState.refreshAllStaleDriverKeys()
        let secondSent = await appState.refreshAllStaleDriverKeys()
        #expect(secondSent == 0)
    }
}

@Suite("AppState.staleKeyDriverPubkeys")
@MainActor
struct AppStateStaleKeyDriverPubkeysTests {

    @Test func emptyWhenNoRepository() {
        let appState = AppState()
        #expect(appState.staleKeyDriverPubkeys.isEmpty)
    }

    @Test func emptyWhenNoStaleDrivers() {
        let driver = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)
        #expect(appState.staleKeyDriverPubkeys.isEmpty)
    }

    @Test func reflectsStaleSet() {
        let driver = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driver])
        repo.markKeyStale(pubkey: pubkeyA)
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)
        #expect(appState.staleKeyDriverPubkeys == [pubkeyA])
    }
}
