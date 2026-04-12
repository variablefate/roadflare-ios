# LocationSyncCoordinator SDK Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the Nostr key-sync protocol logic from the app-layer `LocationCoordinator` into a new SDK class `LocationSyncCoordinator`, leaving the app layer as a thin subscription-lifecycle manager.

**Architecture:** `LocationSyncCoordinator` lives in `RidestrSDK/Sources/RidestrSDK/RoadFlare/` alongside `ProfileBackupCoordinator`. It owns key share parsing/validation, Kind 3188 ack publishing, stale key detection, and the followed-drivers-list republish trigger. App-layer `LocationCoordinator` becomes an `@Observable @MainActor` subscription wrapper that creates a `LocationSyncCoordinator` in its `init` and delegates all protocol steps to it. `RideCoordinator` requires zero changes—it passes deps to `LocationCoordinator.init` exactly as today.

**Tech Stack:** Swift, RidestrSDK (SPM package), Swift Testing framework, `@unchecked Sendable` pattern for thread safety, `FakeRelayManager` + `InMemoryFollowedDriversPersistence` for SDK tests.

---

## ADR Note

No new ADR is required. This extraction applies the already-established SDK/app split principle from ADR-0001, ADR-0002, ADR-0003, and ADR-0004. The boundary rule is clear: Nostr protocol semantics belong in the SDK, iOS subscription lifecycle belongs in the app. Document the pattern being followed, not the pattern itself.

---

## File Structure

| File | Change | Responsibility |
|------|--------|---------------|
| `RidestrSDK/Sources/RidestrSDK/RoadFlare/LocationSyncCoordinator.swift` | CREATE | `LocationSyncCoordinator` class + `KeyShareOutcome` enum |
| `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/LocationSyncCoordinatorTests.swift` | CREATE | SDK tests for all four public entry points (14 tests) |
| `RoadFlare/RoadFlareCore/ViewModels/LocationCoordinator.swift` | MODIFY | Remove protocol logic; add `locationSync` delegate; simplify `handleKeyShareEvent` to a short delegate |
| `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift` | MODIFY | Add restart test using existing `makeCoordinator`, `eventually`, and `FakeRelayManager` |

**Not changed:** `RideCoordinator.swift`, `AppState.swift`, `RideCoordinator.init` signature, `Package.swift` (auto-discovers sources).

---

## Proposed SDK API

```swift
public final class LocationSyncCoordinator: @unchecked Sendable {
    public init(
        relayManager: any RelayManagerProtocol,
        keypair: NostrKeypair,
        driversRepository: FollowedDriversRepository,
        roadflareDomainService: RoadflareDomainService? = nil,
        roadflareSyncStore: RoadflareSyncStateStore? = nil
    )

    public func processKeyShare(_ event: NostrEvent) async throws -> KeyShareOutcome
    public func checkForStaleKeys() async
    public func requestKeyRefresh(driverPubkey: String) async
    public func publishFollowedDriversList() async
}

public enum KeyShareOutcome: Sendable, Equatable {
    case appliedNewer   // key stored, ack sent, followed list republished; caller restarts location subs
    case ignoredOlder   // older/duplicate key (ack may have been sent); no restart needed
    case unknownDriver  // driver not followed; discarded
}
```

---

## Task 1: Write failing SDK tests for `LocationSyncCoordinator`

**Files:**
- Create: `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/LocationSyncCoordinatorTests.swift`

- [ ] **Step 1: Create the test file**

```swift
// RidestrSDK/Tests/RidestrSDKTests/RoadFlare/LocationSyncCoordinatorTests.swift
import Foundation
import Testing
@testable import RidestrSDK

@Suite("LocationSyncCoordinator Tests")
struct LocationSyncCoordinatorTests {

    // MARK: - Test Kit

    private struct TestKit {
        let riderKeypair: NostrKeypair
        let driverKeypair: NostrKeypair
        let relay: FakeRelayManager
        let driversRepo: FollowedDriversRepository
        let syncStore: RoadflareSyncStateStore
        let coordinator: LocationSyncCoordinator
    }

    private func makeKit() async throws -> TestKit {
        let riderKeypair = try NostrKeypair.generate()
        let driverKeypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        try await relay.connect(to: [URL(string: "wss://fake")!])
        let driversRepo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        let syncStore = RoadflareSyncStateStore(
            defaults: UserDefaults(suiteName: "lsc_test_\(UUID().uuidString)")!,
            namespace: UUID().uuidString
        )
        let domainService = RoadflareDomainService(relayManager: relay, keypair: riderKeypair)
        let coordinator = LocationSyncCoordinator(
            relayManager: relay,
            keypair: riderKeypair,
            driversRepository: driversRepo,
            roadflareDomainService: domainService,
            roadflareSyncStore: syncStore
        )
        return TestKit(
            riderKeypair: riderKeypair,
            driverKeypair: driverKeypair,
            relay: relay,
            driversRepo: driversRepo,
            syncStore: syncStore,
            coordinator: coordinator
        )
    }

    /// Build a valid, encrypted Kind 3186 key share event.
    private func makeKeyShareEvent(
        driverKeypair: NostrKeypair,
        riderPubkey: String,
        roadflareKey: RoadflareKey
    ) throws -> NostrEvent {
        let content = KeyShareContent(
            roadflareKey: roadflareKey,
            keyUpdatedAt: roadflareKey.keyUpdatedAt ?? Int(Date.now.timeIntervalSince1970),
            driverPubKey: driverKeypair.publicKeyHex
        )
        let json = try JSONEncoder().encode(content)
        let plaintext = String(data: json, encoding: .utf8)!
        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: driverKeypair.privateKeyHex,
            recipientPublicKeyHex: riderPubkey
        )
        let futureExpiry = Int(Date.now.timeIntervalSince1970) + 43200
        return NostrEvent(
            id: UUID().uuidString,
            pubkey: driverKeypair.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.keyShare.rawValue,
            tags: [["p", riderPubkey], ["expiration", String(futureExpiry)]],
            content: encrypted, sig: "sig"
        )
    }

    private func makeRoadflareKey(version: Int = 1, keyUpdatedAt: Int = 1700000000) -> RoadflareKey {
        RoadflareKey(
            privateKeyHex: "aabbccdd\(version)",
            publicKeyHex: "eeff0011\(version)",
            version: version,
            keyUpdatedAt: keyUpdatedAt
        )
    }

    // MARK: - processKeyShare: Happy Path

    @Test func processKeyShareAcceptsNewKey() async throws {
        let kit = try await makeKit()
        let roadflareKey = makeRoadflareKey(version: 1)
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000
        ))
        let event = try makeKeyShareEvent(
            driverKeypair: kit.driverKeypair,
            riderPubkey: kit.riderKeypair.publicKeyHex,
            roadflareKey: roadflareKey
        )

        let outcome = try await kit.coordinator.processKeyShare(event)

        #expect(outcome == .appliedNewer)
        // Ack (Kind 3188) + followed-list (Kind 30011) = 2 published events
        #expect(kit.relay.publishedEvents.count == 2)
        let ackEvent = kit.relay.publishedEvents.first { $0.kind == EventKind.keyAcknowledgement.rawValue }
        #expect(ackEvent != nil)
        // Key stored in repository
        let storedKey = kit.driversRepo.getRoadflareKey(driverPubkey: kit.driverKeypair.publicKeyHex)
        #expect(storedKey?.version == 1)
    }

    @Test func processKeyShareSendsAckWithReceivedStatus() async throws {
        let kit = try await makeKit()
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000
        ))
        let event = try makeKeyShareEvent(
            driverKeypair: kit.driverKeypair,
            riderPubkey: kit.riderKeypair.publicKeyHex,
            roadflareKey: makeRoadflareKey()
        )

        _ = try await kit.coordinator.processKeyShare(event)

        // The ack event must be addressed to the driver
        let ackEvent = kit.relay.publishedEvents.first { $0.kind == EventKind.keyAcknowledgement.rawValue }
        #expect(ackEvent != nil)
        let driverPTag = ackEvent?.tags.first { $0.count >= 2 && $0[0] == "p" }
        #expect(driverPTag?[1] == kit.driverKeypair.publicKeyHex)
    }

    @Test func processKeyShareRepublishesFollowedList() async throws {
        let kit = try await makeKit()
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000
        ))
        let event = try makeKeyShareEvent(
            driverKeypair: kit.driverKeypair,
            riderPubkey: kit.riderKeypair.publicKeyHex,
            roadflareKey: makeRoadflareKey()
        )

        _ = try await kit.coordinator.processKeyShare(event)

        let followedListEvent = kit.relay.publishedEvents.first {
            $0.kind == EventKind.followedDriversList.rawValue
        }
        #expect(followedListEvent != nil)
        #expect(kit.syncStore.metadata(for: .followedDrivers).lastSuccessfulPublishAt > 0)
    }

    // MARK: - processKeyShare: Guard Conditions

    @Test func processKeyShareIgnoresUnknownDriver() async throws {
        let kit = try await makeKit()
        // Do NOT add driver to repo
        let event = try makeKeyShareEvent(
            driverKeypair: kit.driverKeypair,
            riderPubkey: kit.riderKeypair.publicKeyHex,
            roadflareKey: makeRoadflareKey()
        )

        let outcome = try await kit.coordinator.processKeyShare(event)

        #expect(outcome == .unknownDriver)
        #expect(kit.relay.publishedEvents.isEmpty)
    }

    @Test func processKeyShareIgnoresOlderKey() async throws {
        let kit = try await makeKit()
        let newerKey = makeRoadflareKey(version: 2, keyUpdatedAt: 1700001000)
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000,
            roadflareKey: newerKey
        ))
        // Build event with an older key
        let olderKey = makeRoadflareKey(version: 1, keyUpdatedAt: 1700000000)
        let event = try makeKeyShareEvent(
            driverKeypair: kit.driverKeypair,
            riderPubkey: kit.riderKeypair.publicKeyHex,
            roadflareKey: olderKey
        )

        let outcome = try await kit.coordinator.processKeyShare(event)

        #expect(outcome == .ignoredOlder)
        #expect(kit.relay.publishedEvents.isEmpty)
        // Key must not have been downgraded
        let storedKey = kit.driversRepo.getRoadflareKey(driverPubkey: kit.driverKeypair.publicKeyHex)
        #expect(storedKey?.version == 2)
    }

    @Test func processKeyShareClearsStaleFlagOnAccept() async throws {
        let kit = try await makeKit()
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000
        ))
        kit.driversRepo.markKeyStale(pubkey: kit.driverKeypair.publicKeyHex)
        let event = try makeKeyShareEvent(
            driverKeypair: kit.driverKeypair,
            riderPubkey: kit.riderKeypair.publicKeyHex,
            roadflareKey: makeRoadflareKey()
        )

        _ = try await kit.coordinator.processKeyShare(event)

        #expect(!kit.driversRepo.staleKeyPubkeys.contains(kit.driverKeypair.publicKeyHex))
    }

    @Test func processKeyShareDuplicateCurrentSendsAckAndClearsStaleFlag() async throws {
        let kit = try await makeKit()
        let existingKey = makeRoadflareKey(version: 1, keyUpdatedAt: 1700000000)
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000,
            roadflareKey: existingKey
        ))
        // Mark key stale BEFORE the event arrives (simulates Kind 30012 detecting a newer key)
        kit.driversRepo.markKeyStale(pubkey: kit.driverKeypair.publicKeyHex)
        // Build a key share with the exact same key — repo will return .duplicateCurrent
        let event = try makeKeyShareEvent(
            driverKeypair: kit.driverKeypair,
            riderPubkey: kit.riderKeypair.publicKeyHex,
            roadflareKey: existingKey
        )

        let outcome = try await kit.coordinator.processKeyShare(event)

        // Returns .ignoredOlder — caller must not restart location subscriptions
        #expect(outcome == .ignoredOlder)
        // Ack was sent (Kind 3188 only — no Kind 30011 republish)
        #expect(kit.relay.publishedEvents.count == 1)
        let ackEvent = kit.relay.publishedEvents.first { $0.kind == EventKind.keyAcknowledgement.rawValue }
        #expect(ackEvent != nil)
        let followedListEvent = kit.relay.publishedEvents.first { $0.kind == EventKind.followedDriversList.rawValue }
        #expect(followedListEvent == nil)
        // Stale flag IS cleared — preserves existing app behavior (LocationCoordinator.swift:176).
        // A duplicate key share means the driver confirmed their current key; the stale detection
        // was a false alarm. Clearing the badge here matches what the current code does.
        #expect(!kit.driversRepo.staleKeyPubkeys.contains(kit.driverKeypair.publicKeyHex))
    }

    // MARK: - checkForStaleKeys

    @Test func checkForStaleKeysDetectsStaleKey() async throws {
        let kit = try await makeKit()
        let localTimestamp = 1700000000
        let remoteTimestamp = 1700000100  // newer than local
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000,
            roadflareKey: makeRoadflareKey(version: 1, keyUpdatedAt: localTimestamp)
        ))
        kit.relay.fetchResults = [NostrEvent(
            id: "state1",
            pubkey: kit.driverKeypair.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.driverRoadflareState.rawValue,
            tags: [["key_updated_at", String(remoteTimestamp)]],
            content: "", sig: "sig"
        )]

        await kit.coordinator.checkForStaleKeys()

        #expect(kit.driversRepo.staleKeyPubkeys.contains(kit.driverKeypair.publicKeyHex))
        let staleAck = kit.relay.publishedEvents.first { $0.kind == EventKind.keyAcknowledgement.rawValue }
        #expect(staleAck != nil)
    }

    @Test func checkForStaleKeysClearsStaleFlagWhenFresh() async throws {
        let kit = try await makeKit()
        let localTimestamp = 1700000200  // newer than remote
        let remoteTimestamp = 1700000100
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000,
            roadflareKey: makeRoadflareKey(version: 1, keyUpdatedAt: localTimestamp)
        ))
        kit.driversRepo.markKeyStale(pubkey: kit.driverKeypair.publicKeyHex)
        kit.relay.fetchResults = [NostrEvent(
            id: "state2",
            pubkey: kit.driverKeypair.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.driverRoadflareState.rawValue,
            tags: [["key_updated_at", String(remoteTimestamp)]],
            content: "", sig: "sig"
        )]

        await kit.coordinator.checkForStaleKeys()

        #expect(!kit.driversRepo.staleKeyPubkeys.contains(kit.driverKeypair.publicKeyHex))
        #expect(kit.relay.publishedEvents.isEmpty)
    }

    @Test func checkForStaleKeysRequestsRefreshForKeylessDriver() async throws {
        let kit = try await makeKit()
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000
            // no roadflareKey
        ))

        await kit.coordinator.checkForStaleKeys()

        let staleAck = kit.relay.publishedEvents.first { $0.kind == EventKind.keyAcknowledgement.rawValue }
        #expect(staleAck != nil)
    }

    @Test func checkForStaleKeysNoOpWhenNoKind30012() async throws {
        let kit = try await makeKit()
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000,
            roadflareKey: makeRoadflareKey()
        ))
        kit.relay.fetchResults = []  // relay returns nothing

        await kit.coordinator.checkForStaleKeys()

        #expect(kit.relay.publishedEvents.isEmpty)
    }

    // MARK: - requestKeyRefresh

    @Test func requestKeyRefreshPublishesStaleAck() async throws {
        let kit = try await makeKit()
        // makeKit() does not pre-load a driver key, so this also covers the
        // keyless-driver (version 0) path.

        await kit.coordinator.requestKeyRefresh(driverPubkey: kit.driverKeypair.publicKeyHex)

        #expect(kit.relay.publishedEvents.count == 1)
        let ack = kit.relay.publishedEvents[0]
        #expect(ack.kind == EventKind.keyAcknowledgement.rawValue)
        let driverPTag = ack.tags.first { $0.count >= 2 && $0[0] == "p" }
        #expect(driverPTag?[1] == kit.driverKeypair.publicKeyHex)
    }

    // MARK: - publishFollowedDriversList

    @Test func publishFollowedDriversListPublishesAndMarksStore() async throws {
        let kit = try await makeKit()
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000
        ))

        await kit.coordinator.publishFollowedDriversList()

        #expect(kit.relay.publishedEvents.count == 1)
        #expect(kit.relay.publishedEvents[0].kind == EventKind.followedDriversList.rawValue)
        #expect(kit.syncStore.metadata(for: .followedDrivers).lastSuccessfulPublishAt > 0)
    }

    @Test func publishFollowedDriversListWithoutDomainServicePublishesDirect() async throws {
        let riderKeypair = try NostrKeypair.generate()
        let driverKeypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        try await relay.connect(to: [URL(string: "wss://fake")!])
        let driversRepo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        driversRepo.addDriver(FollowedDriver(pubkey: driverKeypair.publicKeyHex, addedAt: 1000))
        // No domainService, no syncStore
        let coordinator = LocationSyncCoordinator(
            relayManager: relay,
            keypair: riderKeypair,
            driversRepository: driversRepo
        )

        await coordinator.publishFollowedDriversList()

        #expect(relay.publishedEvents.count == 1)
        #expect(relay.publishedEvents[0].kind == EventKind.followedDriversList.rawValue)
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail (no `LocationSyncCoordinator` yet)**

```bash
swift test --package-path RidestrSDK --filter LocationSyncCoordinatorTests
```
Expected: compile error — `cannot find type 'LocationSyncCoordinator' in scope`

---

## Task 2: Create `LocationSyncCoordinator` in SDK

**Files:**
- Create: `RidestrSDK/Sources/RidestrSDK/RoadFlare/LocationSyncCoordinator.swift`

- [ ] **Step 1: Create the file with the full implementation**

```swift
// RidestrSDK/Sources/RidestrSDK/RoadFlare/LocationSyncCoordinator.swift
import Foundation

/// SDK-owned coordinator for RoadFlare key sync protocol.
///
/// Owns:
/// - Key share reception + acknowledgement (Kind 3186 → Kind 3188)
/// - Stale key detection via Kind 30012 `key_updated_at` comparison
/// - Key refresh requests (Kind 3188 "stale")
/// - Followed drivers list republish on key update (Kind 30011)
///
/// This is pure Nostr protocol logic with no iOS dependencies. The app-layer
/// `LocationCoordinator` is a thin subscription manager that creates this
/// coordinator in its `init` and delegates all protocol steps to it.
public final class LocationSyncCoordinator: @unchecked Sendable {
    private let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair
    private let driversRepository: FollowedDriversRepository
    private let roadflareDomainService: RoadflareDomainService?
    private let roadflareSyncStore: RoadflareSyncStateStore?

    public init(
        relayManager: any RelayManagerProtocol,
        keypair: NostrKeypair,
        driversRepository: FollowedDriversRepository,
        roadflareDomainService: RoadflareDomainService? = nil,
        roadflareSyncStore: RoadflareSyncStateStore? = nil
    ) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.driversRepository = driversRepository
        self.roadflareDomainService = roadflareDomainService
        self.roadflareSyncStore = roadflareSyncStore
    }

    // MARK: - Key Share Processing (Kind 3186)

    /// Process an incoming Kind 3186 key share event from a driver.
    ///
    /// - Parses and validates the event (throws on malformed/expired/misaddressed events)
    /// - Returns `.unknownDriver` if the sender is not in the followed list
    /// - Returns `.ignoredOlder` if the incoming key is older than the stored key
    /// - For `.duplicateCurrent`: clears stale flag, sends "received" ack, returns `.ignoredOlder`
    ///   (no Kind 30011 republish, no subscription restart needed)
    /// - For `.appliedNewer`: stores key, clears stale flag, sends "received" ack,
    ///   republishes Kind 30011, returns `.appliedNewer`
    ///
    /// The caller (app-layer `LocationCoordinator`) should restart location subscriptions
    /// when this returns `.appliedNewer`.
    public func processKeyShare(_ event: NostrEvent) async throws -> KeyShareOutcome {
        let keyShare = try RideshareEventParser.parseKeyShare(event: event, keypair: keypair)

        guard driversRepository.isFollowing(pubkey: keyShare.driverPubkey) else {
            RidestrLogger.info("[LocationSyncCoordinator] Ignoring key share from unknown driver \(keyShare.driverPubkey.prefix(8))")
            return .unknownDriver
        }
        RidestrLogger.info("[LocationSyncCoordinator] Key share received: driver=\(keyShare.driverPubkey.prefix(8)), version=\(keyShare.roadflareKey.version)")

        let updateOutcome = driversRepository.updateDriverKey(
            driverPubkey: keyShare.driverPubkey,
            roadflareKey: keyShare.roadflareKey
        )

        switch updateOutcome {
        case .unknownDriver:
            // Race: driver removed between isFollowing check and updateDriverKey.
            return .unknownDriver
        case .ignoredOlder:
            RidestrLogger.info("[LocationSyncCoordinator] Ignoring older key share for \(keyShare.driverPubkey.prefix(8))")
            return .ignoredOlder
        case .duplicateCurrent, .appliedNewer:
            break
        }

        // Clear stale flag for any accepted key (.appliedNewer or .duplicateCurrent).
        // Preserves existing app behavior (LocationCoordinator.swift:176): the current code clears
        // stale for every outcome that isn't .ignoredOlder, so a duplicate key share also clears
        // the "Key Outdated" badge. This is intentional — if the driver re-sent their current key,
        // the stale detection was a false alarm (their key hasn't actually changed).
        driversRepository.clearKeyStale(pubkey: keyShare.driverPubkey)

        // Send acknowledgement (Kind 3188) for both duplicate and newer keys
        let ackEvent = try await RideshareEventBuilder.keyAcknowledgement(
            driverPubkey: keyShare.driverPubkey,
            keyVersion: keyShare.roadflareKey.version,
            keyUpdatedAt: keyShare.keyUpdatedAt,
            status: "received",
            keypair: keypair
        )
        _ = try await relayManager.publish(ackEvent)

        if updateOutcome == .appliedNewer {
            await publishFollowedDriversList()
            return .appliedNewer
        }

        // .duplicateCurrent: stale cleared, ack sent; followed list unchanged, no restart needed
        return .ignoredOlder
    }

    // MARK: - Stale Key Detection (Kind 30012)

    /// Check all followed drivers for stale keys by comparing the local
    /// `roadflareKey.keyUpdatedAt` against the driver's Kind 30012 public
    /// `key_updated_at` tag. Sends Kind 3188 "stale" acks for outdated keys.
    public func checkForStaleKeys() async {
        for driver in driversRepository.drivers {
            guard driver.hasKey else {
                // No key at all — request one
                await requestKeyRefresh(driverPubkey: driver.pubkey)
                continue
            }
            let localKeyUpdatedAt = driver.roadflareKey?.keyUpdatedAt ?? 0
            do {
                let filter = NostrFilter.driverRoadflareState(driverPubkey: driver.pubkey)
                let events = try await relayManager.fetchEvents(filter: filter, timeout: 5)
                guard let event = events.max(by: { $0.createdAt < $1.createdAt }) else { continue }
                let keyUpdatedAtTag = event.tags.first { $0.count >= 2 && $0[0] == "key_updated_at" }
                guard let remoteTimestamp = keyUpdatedAtTag.flatMap({ Int($0[1]) }) else { continue }
                if remoteTimestamp > localKeyUpdatedAt {
                    RidestrLogger.info("[LocationSyncCoordinator] Stale key for \(driver.pubkey.prefix(8)): local=\(localKeyUpdatedAt), remote=\(remoteTimestamp)")
                    driversRepository.markKeyStale(pubkey: driver.pubkey)
                    await requestKeyRefresh(driverPubkey: driver.pubkey)
                } else {
                    driversRepository.clearKeyStale(pubkey: driver.pubkey)
                }
            } catch {
                // Non-fatal — will retry on next check
            }
        }
    }

    // MARK: - Request Key Refresh (Kind 3188 "stale")

    /// Send a "stale" key ack to a driver, requesting they re-send Kind 3186.
    /// Used when: rider has no key for this driver, or driver rotated keys.
    public func requestKeyRefresh(driverPubkey: String) async {
        let localKey = driversRepository.getRoadflareKey(driverPubkey: driverPubkey)
        do {
            let ackEvent = try await RideshareEventBuilder.keyAcknowledgement(
                driverPubkey: driverPubkey,
                keyVersion: localKey?.version ?? 0,
                keyUpdatedAt: localKey?.keyUpdatedAt ?? 0,
                status: "stale",
                keypair: keypair
            )
            _ = try await relayManager.publish(ackEvent)
            RidestrLogger.info("[LocationSyncCoordinator] Sent stale key ack to \(driverPubkey.prefix(8))")
        } catch {
            // Best effort
        }
    }

    // MARK: - Publish Followed Drivers (Kind 30011)

    /// Publish the followed drivers list to Nostr. Called internally after a
    /// key update; also available for external callers (e.g. app-layer delegate).
    public func publishFollowedDriversList() async {
        roadflareSyncStore?.markDirty(.followedDrivers)
        do {
            let event: NostrEvent
            if let roadflareDomainService {
                event = try await roadflareDomainService.publishFollowedDriversList(driversRepository.drivers)
            } else {
                event = try await RideshareEventBuilder.followedDriversList(
                    drivers: driversRepository.drivers,
                    keypair: keypair
                )
                _ = try await relayManager.publish(event)
            }
            roadflareSyncStore?.markPublished(.followedDrivers, at: event.createdAt)
        } catch {
            RidestrLogger.info("[LocationSyncCoordinator] Failed to publish followed drivers list: \(error)")
        }
    }
}

// MARK: - KeyShareOutcome

/// Result of processing a Kind 3186 key share event via `LocationSyncCoordinator.processKeyShare`.
public enum KeyShareOutcome: Sendable, Equatable {
    /// New key accepted, stored, ack sent, followed list republished.
    /// The app-layer caller should restart location subscriptions.
    case appliedNewer
    /// Incoming key is older, a duplicate, or a driver-not-found race.
    /// No subscription restart is needed.
    case ignoredOlder
    /// Driver is not in the followed list; event was discarded.
    case unknownDriver
}
```

- [ ] **Step 2: Run the tests to verify they pass**

```bash
swift test --package-path RidestrSDK --filter LocationSyncCoordinatorTests
```
Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git add RidestrSDK/Sources/RidestrSDK/RoadFlare/LocationSyncCoordinator.swift \
    RidestrSDK/Tests/RidestrSDKTests/RoadFlare/LocationSyncCoordinatorTests.swift
git commit -m "feat(sdk): add LocationSyncCoordinator for key sync protocol logic

Extracts Kind 3186 reception + ack, stale key detection, and Kind 30011
republish from the app layer into a testable SDK class. Closes #28 (SDK side).

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Task 3: Simplify app-layer `LocationCoordinator`

**Files:**
- Modify: `RoadFlare/RoadFlareCore/ViewModels/LocationCoordinator.swift`

The app-layer coordinator retains:
- `@Observable @MainActor` — required for SwiftUI observation of `lastError`
- `startLocationSubscriptions()` and `handleLocationEvent()` — these are already thin (delegate entirely to `RideshareEventParser` + `driversRepository.updateDriverLocation`)
- `startKeyShareSubscription()` — subscription lifecycle loop is app-specific async wiring
- `keypair` stored property — still needed for `NostrFilter.keyShares(myPubkey:)`
- `driversRepository` stored property — accessed by `RideCoordinator.driversRepository` getter
- `lastError` — still set for subscription-level failures; not piped up through `RideCoordinator`

Removed from the app layer:
- Stored `roadflareDomainService` and `roadflareSyncStore` properties — removed from `LocationCoordinator` only; they are passed through `LocationCoordinator.init` to `LocationSyncCoordinator.init`. **Note:** these properties remain in `RideCoordinator` (unchanged), where they are also used independently in `backupRideHistory()` — do not remove them from `RideCoordinator`.
- Full `handleKeyShareEvent` body (replaced with 6-line delegate)
- Full `publishFollowedDriversList` body (1-line delegate)
- Full `checkForStaleKeys` body (1-line delegate)
- Full `requestKeyRefresh` body (1-line delegate)

- [ ] **Step 1: Replace `LocationCoordinator.swift` with the simplified version**

The full file after modification:

```swift
// RoadFlare/RoadFlareCore/ViewModels/LocationCoordinator.swift
import Foundation
import os
import RidestrSDK

/// Thin subscription manager for RoadFlare location broadcasts (Kind 30014)
/// and key shares (Kind 3186).
///
/// All Nostr protocol logic (key share state machine, stale key detection,
/// ack publishing) is owned by `LocationSyncCoordinator` in the SDK.
/// This class manages subscription lifetimes and feeds events to the SDK coordinator.
@Observable
@MainActor
final class LocationCoordinator {
    let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair
    private let locationSync: LocationSyncCoordinator
    let driversRepository: FollowedDriversRepository

    private struct ManagedSubscription {
        let id: SubscriptionID
        let generation: UUID
        let task: Task<Void, Never>
    }

    private var activeLocationSubscription: ManagedSubscription?
    private var activeKeyShareSubscription: ManagedSubscription?

    var lastError: String?

    init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair,
         driversRepository: FollowedDriversRepository,
         roadflareDomainService: RoadflareDomainService? = nil,
         roadflareSyncStore: RoadflareSyncStateStore? = nil) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.driversRepository = driversRepository
        self.locationSync = LocationSyncCoordinator(
            relayManager: relayManager,
            keypair: keypair,
            driversRepository: driversRepository,
            roadflareDomainService: roadflareDomainService,
            roadflareSyncStore: roadflareSyncStore
        )
    }

    // MARK: - Location Subscription (Kind 30014)

    func startLocationSubscriptions() {
        let pubkeys = driversRepository.allPubkeys
        let previous = takeLocationSubscription()

        guard !pubkeys.isEmpty else {
            if let previous {
                Task {
                    previous.task.cancel()
                    await relayManager.unsubscribe(previous.id)
                }
            }
            return
        }

        let subId = SubscriptionID("roadflare-locations")
        let generation = UUID()

        let task = Task {
            previous?.task.cancel()
            if let oldId = previous?.id {
                await relayManager.unsubscribe(oldId)
            }
            guard !Task.isCancelled,
                  activeLocationSubscription?.generation == generation else { return }

            do {
                let filter = NostrFilter.roadflareLocations(driverPubkeys: pubkeys)
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                guard !Task.isCancelled,
                      activeLocationSubscription?.generation == generation else { return }

                for await event in stream {
                    guard !Task.isCancelled,
                          activeLocationSubscription?.generation == generation else { break }
                    await handleLocationEvent(event)
                }
            } catch {
                guard activeLocationSubscription?.generation == generation else { return }
                lastError = "Location subscription failed: \(error.localizedDescription)"
            }
        }
        activeLocationSubscription = ManagedSubscription(id: subId, generation: generation, task: task)
    }

    func handleLocationEvent(_ event: NostrEvent) async {
        let driverPubkey = event.pubkey
        guard let key = driversRepository.getRoadflareKey(driverPubkey: driverPubkey) else {
            AppLogger.location.debug("Location event ignored — no key for driver \(driverPubkey.prefix(8))")
            return
        }

        do {
            let parsed = try RideshareEventParser.parseRoadflareLocation(
                event: event,
                roadflarePrivateKeyHex: key.privateKeyHex
            )
            driversRepository.updateDriverLocation(
                pubkey: driverPubkey,
                latitude: parsed.location.latitude,
                longitude: parsed.location.longitude,
                status: parsed.location.status.rawValue,
                timestamp: parsed.location.timestamp,
                keyVersion: parsed.keyVersion
            )
        } catch {
            AppLogger.location.info("Location decryption failed for driver \(driverPubkey.prefix(8)) (key v\(key.version)): \(error)")
        }
    }

    // MARK: - Key Share Subscription (Kind 3186)

    func startKeyShareSubscription() {
        let previous = takeKeyShareSubscription()

        let subId = SubscriptionID("key-shares")
        let generation = UUID()

        let task = Task {
            previous?.task.cancel()
            if let oldId = previous?.id {
                await relayManager.unsubscribe(oldId)
            }
            guard !Task.isCancelled,
                  activeKeyShareSubscription?.generation == generation else { return }
            do {
                let filter = NostrFilter.keyShares(myPubkey: keypair.publicKeyHex)
                AppLogger.location.info("Subscribing to key shares for \(self.keypair.publicKeyHex.prefix(8))...")
                let stream = try await relayManager.subscribe(filter: filter, id: subId)
                guard !Task.isCancelled,
                      activeKeyShareSubscription?.generation == generation else { return }
                AppLogger.location.info("Key share subscription active")

                for await event in stream {
                    guard !Task.isCancelled,
                          activeKeyShareSubscription?.generation == generation else { break }
                    await handleKeyShareEvent(event)
                }
            } catch {
                guard activeKeyShareSubscription?.generation == generation else { return }
                lastError = "Key share subscription failed: \(error.localizedDescription)"
            }
        }
        activeKeyShareSubscription = ManagedSubscription(id: subId, generation: generation, task: task)
    }

    func handleKeyShareEvent(_ event: NostrEvent) async {
        do {
            let outcome = try await locationSync.processKeyShare(event)
            if outcome == .appliedNewer {
                startLocationSubscriptions()
            }
        } catch {
            AppLogger.location.info("Key share handling failed: \(error)")
        }
    }

    // MARK: - Delegates to SDK

    func publishFollowedDriversList() async {
        await locationSync.publishFollowedDriversList()
    }

    func checkForStaleKeys() async {
        await locationSync.checkForStaleKeys()
    }

    func requestKeyRefresh(driverPubkey: String) async {
        await locationSync.requestKeyRefresh(driverPubkey: driverPubkey)
    }

    // MARK: - Cleanup

    func stopAll() async {
        let location = takeLocationSubscription()
        let keyShare = takeKeyShareSubscription()
        location?.task.cancel()
        keyShare?.task.cancel()
        if let id = location?.id { await relayManager.unsubscribe(id) }
        if let id = keyShare?.id { await relayManager.unsubscribe(id) }
    }

    private func takeLocationSubscription() -> ManagedSubscription? {
        let previous = activeLocationSubscription
        activeLocationSubscription = nil
        return previous
    }

    private func takeKeyShareSubscription() -> ManagedSubscription? {
        let previous = activeKeyShareSubscription
        activeKeyShareSubscription = nil
        return previous
    }
}
```

- [ ] **Step 2: Add restart test to `RideCoordinatorTests.swift`**

**Files:**
- Modify: `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift`

Add the following test to the `RideCoordinatorTests` struct. It reuses the existing `makeCoordinator`, `eventually`, and `fake` (`FakeRelayManager`) — no new file, no duplicated helpers.

```swift
    @MainActor
    @Test func locationSubscriptionRestartsAfterAppliedNewerKeyShare() async throws {
        // keepSubscriptionsAlive: true — stream stays open until unsubscribe() fires it.
        // This means the old subscription Task is genuinely live when the restart tears it down,
        // matching real-world behavior (vs. the default where the stream closes immediately).
        let (coordinator, fake, riderKeypair, _, _) = try await makeCoordinator(keepSubscriptionsAlive: true)
        let driver = try NostrKeypair.generate()
        coordinator.driversRepository.addDriver(FollowedDriver(pubkey: driver.publicKeyHex))

        // Step 1: establish initial location subscription so there is something to tear down.
        coordinator.location.startLocationSubscriptions()
        let initialSubscribed = await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue == "roadflare-locations" }.count >= 1
        }
        #expect(initialSubscribed, "initial subscribe must be established before key share arrives")

        // Step 2: send a key share that returns .appliedNewer, triggering startLocationSubscriptions().
        let roadflareKey = RoadflareKey(
            privateKeyHex: "aabbccdd1", publicKeyHex: "eeff00111",
            version: 1, keyUpdatedAt: 1700000000
        )
        let content = KeyShareContent(
            roadflareKey: roadflareKey, keyUpdatedAt: 1700000000,
            driverPubKey: driver.publicKeyHex
        )
        let plaintext = String(data: try JSONEncoder().encode(content), encoding: .utf8)!
        let encrypted = try NIP44.encrypt(
            plaintext: plaintext,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )
        let event = NostrEvent(
            id: UUID().uuidString, pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.keyShare.rawValue,
            tags: [["p", riderKeypair.publicKeyHex],
                   ["expiration", "\(Int(Date.now.timeIntervalSince1970) + 43200)"]],
            content: encrypted, sig: "sig"
        )
        await coordinator.location.handleKeyShareEvent(event)

        // Step 3: assert RESTART — second subscribe AND at least one unsubscribe.
        // count >= 2 proves startLocationSubscriptions() fired twice.
        // unsubscribeCalls proves the old subscription was torn down first (LocationCoordinator.swift:71).
        let restarted = await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue == "roadflare-locations" }.count >= 2
        }
        #expect(restarted, "startLocationSubscriptions() must fire a second time after appliedNewer")
        let unsubscribed = fake.unsubscribeCalls.contains { $0.rawValue == "roadflare-locations" }
        #expect(unsubscribed, "old location subscription must be torn down before the new one starts")
    }
```

- [ ] **Step 3: Run the full SDK test suite**

```bash
swift test --package-path RidestrSDK
```
Expected: All tests PASS (no regressions)

- [ ] **Step 4: Build the full Xcode project to catch concurrency errors**

```bash
xcodebuild \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.4" \
  build
```
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run the RoadFlare app unit tests**

```bash
xcodebuild \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlareTests \
  -destination "platform=iOS Simulator,name=iPhone 17,OS=26.4" \
  -parallel-testing-enabled NO \
  test
```
Expected: All tests PASS (includes new restart test in `RideCoordinatorTests`; existing test at line 210 calls `handleKeyShareEvent` directly and still passes — it checks `contains { $0.kind == keyAcknowledgement }`, which is satisfied by the new delegate path through `processKeyShare`)

- [ ] **Step 6: Commit**

```bash
git add RoadFlare/RoadFlareCore/ViewModels/LocationCoordinator.swift \
    RoadFlare/RoadFlareTests/RideCoordinatorTests.swift
git commit -m "refactor(app): simplify LocationCoordinator to thin subscription manager

Delegates key share processing, stale detection, and ack publishing to the
new SDK-owned LocationSyncCoordinator. LocationCoordinator now owns only
subscription lifecycle (start/stop/restart) and calls processKeyShare()
for protocol decisions. init signature unchanged — no RideCoordinator changes.
Adds restart test to RideCoordinatorTests covering subscription teardown
and resubscribe after appliedNewer key share.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

## Migration Summary

| Responsibility | Before | After |
|---|---|---|
| Parse Kind 3186 + validate driver membership | `LocationCoordinator.handleKeyShareEvent` | `LocationSyncCoordinator.processKeyShare` |
| Send Kind 3188 "received" ack | `LocationCoordinator.handleKeyShareEvent` | `LocationSyncCoordinator.processKeyShare` |
| Republish Kind 30011 on key update | `LocationCoordinator.publishFollowedDriversList` | `LocationSyncCoordinator.publishFollowedDriversList` |
| Stale key detection (Kind 30012) | `LocationCoordinator.checkForStaleKeys` | `LocationSyncCoordinator.checkForStaleKeys` |
| Send Kind 3188 "stale" ack | `LocationCoordinator.requestKeyRefresh` | `LocationSyncCoordinator.requestKeyRefresh` |
| Restart location subscriptions after key accept | `LocationCoordinator.handleKeyShareEvent` | `LocationCoordinator.handleKeyShareEvent` (app, unchanged) |
| Kind 30014 subscription loop | `LocationCoordinator` | `LocationCoordinator` (unchanged) |
| Kind 3186 subscription loop | `LocationCoordinator` | `LocationCoordinator` (unchanged) |

---

## Test Strategy

**SDK tests** (new — `LocationSyncCoordinatorTests.swift`):
- 14 tests covering all four public entry points (`processKeyShare`, `checkForStaleKeys`, `requestKeyRefresh`, `publishFollowedDriversList`)
- Includes dedicated `.duplicateCurrent` test: verifies ack sent, no Kind 30011 republish, stale flag cleared, returns `.ignoredOlder`
- Use `FakeRelayManager` for relay interaction verification
- Use `InMemoryFollowedDriversPersistence` for repository state
- Build real encrypted Kind 3186 events using `NIP44.encrypt` + `KeyShareContent`
- Build real Kind 30012 events with `key_updated_at` tags
- No mocks — all SDK types used directly

**App tests** (added to `RideCoordinatorTests.swift`):
- 1 new test: `locationSubscriptionRestartsAfterAppliedNewerKeyShare`
- Uses existing `makeCoordinator`, `eventually`, and `fake` — no new file, no duplicated helpers
- Three phases: establish initial subscription via `coordinator.location.startLocationSubscriptions()`, send `.appliedNewer` key share via `coordinator.location.handleKeyShareEvent(_:)`, assert ≥2 subscribe calls AND ≥1 `unsubscribeCalls` hit for `"roadflare-locations"`
- Existing test at line 210 (`handleKeyShareUpdatesDriverAndPublishesAck`) unchanged and still passes

---

## Risk / Rollback

- **Behavioral parity:** `LocationSyncCoordinator` is a line-by-line extraction. Existing behavior is preserved exactly: `clearKeyStale` runs for both `.appliedNewer` and `.duplicateCurrent` (matching `LocationCoordinator.swift:176`), Kind 30011 republish runs only for `.appliedNewer`, and subscription restart is triggered only for `.appliedNewer`.
- **No interface changes:** `RideCoordinator`, `AppState`, all Views — zero changes. The `LocationCoordinator.init` signature is identical.
- **Rollback:** Delete `LocationSyncCoordinator.swift` and revert `LocationCoordinator.swift` to its pre-migration state. Both are isolated changes.
- **`publishFollowedDriversList()` is `public`:** The app layer calls it cross-module via `LocationCoordinator.publishFollowedDriversList()` → `locationSync.publishFollowedDriversList()`, and the SDK module boundary requires `public` for that delegation to compile. No ambiguity.
