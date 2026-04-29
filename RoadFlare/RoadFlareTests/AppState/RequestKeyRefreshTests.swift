import Testing
import Foundation
@testable import RoadFlareCore
@testable import RidestrSDK

// Pure AppState behavior tests for the user-initiated key-refresh path.
//
// `rideCoordinator` stays nil in tests because constructing a real one is
// heavy. The production path treats a nil coordinator as a publish failure
// (so a tap during the brief logout / identity-replacement window doesn't
// burn a 60s cooldown for a publish that never happened); for tests that
// need to drive `.sent` or simulate an SDK throw, install
// `setKeyRefreshSDKHookForTesting(_:)` with a stub closure.
//
// The underlying `LocationSyncCoordinator.requestKeyRefresh` `throws`
// contract is covered separately in the SDK suite.

private struct StubError: Error {}

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
        appState.setKeyRefreshSDKHookForTesting { _ in /* succeed */ }

        let outcome = await appState.requestKeyRefresh(pubkey: pubkeyA)
        #expect(outcome == .sent)
    }

    @Test func secondCallWithinCooldownReturnsRateLimited() async {
        let driver = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)
        appState.setKeyRefreshSDKHookForTesting { _ in /* succeed */ }

        _ = await appState.requestKeyRefresh(pubkey: pubkeyA)
        let outcome = await appState.requestKeyRefresh(pubkey: pubkeyA)

        guard case .rateLimited(let retryAt) = outcome else {
            Issue.record("Expected .rateLimited, got \(outcome)")
            return
        }
        #expect(retryAt > Date.now)
        #expect(retryAt.timeIntervalSinceNow <= 60)
    }

    @Test func cooldownIsPerPubkey() async {
        let driverA = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let driverB = FollowedDriver(pubkey: pubkeyB, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driverA, driverB])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)
        appState.setKeyRefreshSDKHookForTesting { _ in /* succeed */ }

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
        appState.setKeyRefreshSDKHookForTesting { _ in /* succeed */ }

        // Prime cooldown to a timestamp safely past the 60s window.
        let pastDate = Date.now.addingTimeInterval(-(AppState.keyRefreshCooldownSeconds + 5))
        appState.primeKeyRefreshCooldownForTesting(pubkey: pubkeyA, lastRequest: pastDate)

        let outcome = await appState.requestKeyRefresh(pubkey: pubkeyA)
        #expect(outcome == .sent)
    }

    // Pins the contract that an SDK throw rolls back the cooldown so the
    // rider can retry immediately. Without rollback, the user would see a
    // misleading "sent" toast and be locked out for 60s.
    @Test func publishFailureRollsBackCooldown() async {
        let driver = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)
        appState.setKeyRefreshSDKHookForTesting { _ in throw StubError() }

        let outcome = await appState.requestKeyRefresh(pubkey: pubkeyA)
        #expect(outcome == .publishFailed)

        // Slot was rolled back — a retry the very next instant must reach the
        // SDK call again rather than getting `.rateLimited`. We swap in a
        // succeeding hook to verify that the second call actually progresses
        // past the cooldown check.
        appState.setKeyRefreshSDKHookForTesting { _ in /* succeed */ }
        let retry = await appState.requestKeyRefresh(pubkey: pubkeyA)
        #expect(retry == .sent)
    }

    // Pins the no-coordinator + no-hook path: `.publishFailed` is returned
    // and the cooldown is NOT claimed. Reachable during the brief logout /
    // identity-replacement window.
    @Test func noDispatchAvailableReturnsPublishFailedWithoutClaimingSlot() async {
        let driver = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)
        // No hook installed → keyRefreshDispatch() returns nil.

        let outcome = await appState.requestKeyRefresh(pubkey: pubkeyA)
        #expect(outcome == .publishFailed)

        // Slot must not have been claimed; the next call must still reach the
        // dispatch resolution (returns `.publishFailed` again, not
        // `.rateLimited`).
        let retry = await appState.requestKeyRefresh(pubkey: pubkeyA)
        #expect(retry == .publishFailed)
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
        appState.setKeyRefreshSDKHookForTesting { _ in /* succeed */ }

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
        appState.setKeyRefreshSDKHookForTesting { _ in /* succeed */ }

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
        appState.setKeyRefreshSDKHookForTesting { _ in /* succeed */ }

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

    // Pins the deterministic ordering contract: the property converts
    // `Set<String>` to `[String]`, and `Set.Iterator` does not guarantee a
    // stable order across reads. Without the explicit sort, this test
    // would flake non-deterministically (and so would any future caller
    // that compares the array directly).
    @Test func sortedAcrossMultipleStaleDrivers() {
        let driverA = FollowedDriver(pubkey: pubkeyA, name: "Alice", roadflareKey: testKey)
        let driverB = FollowedDriver(pubkey: pubkeyB, name: "Bob", roadflareKey: testKey)
        let repo = makeRepo(drivers: [driverA, driverB])
        // Mark in reverse-lexicographic order to defeat any insertion-order
        // coincidence: ['b...' first, then 'a...'].
        repo.markKeyStale(pubkey: pubkeyB)
        repo.markKeyStale(pubkey: pubkeyA)
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)
        // pubkeyA = "a...", pubkeyB = "b...", so sorted order is [A, B].
        #expect(appState.staleKeyDriverPubkeys == [pubkeyA, pubkeyB])
    }
}
