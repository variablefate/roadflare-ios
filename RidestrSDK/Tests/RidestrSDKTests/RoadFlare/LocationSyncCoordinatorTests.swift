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

    @Test func processKeySharePublishesAckAddressedToDriver() async throws {
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

        try await kit.coordinator.requestKeyRefresh(driverPubkey: kit.driverKeypair.publicKeyHex)

        #expect(kit.relay.publishedEvents.count == 1)
        let ack = kit.relay.publishedEvents[0]
        #expect(ack.kind == EventKind.keyAcknowledgement.rawValue)
        let driverPTag = ack.tags.first { $0.count >= 2 && $0[0] == "p" }
        #expect(driverPTag?[1] == kit.driverKeypair.publicKeyHex)
    }

    // Pins the contract that the SDK now surfaces publish failures to the
    // caller (issue #72 follow-up): the AppState rate-limit wrapper relies
    // on this so it can roll back the cooldown slot when nothing was
    // actually sent. A best-effort caller (e.g. `checkForStaleKeys`) wraps
    // with `try?` to preserve the previous best-effort behavior.
    @Test func requestKeyRefreshThrowsWhenRelayPublishFails() async throws {
        let kit = try await makeKit()
        kit.relay.shouldFailPublish = true

        await #expect(throws: (any Error).self) {
            try await kit.coordinator.requestKeyRefresh(driverPubkey: kit.driverKeypair.publicKeyHex)
        }
        #expect(kit.relay.publishedEvents.isEmpty)
    }

    // MARK: - publishFollowedDriversList

    @Test func publishFollowedDriversListPublishesAndMarksStore() async throws {
        let kit = try await makeKit()
        kit.driversRepo.addDriver(FollowedDriver(
            pubkey: kit.driverKeypair.publicKeyHex, addedAt: 1000
        ))

        try await kit.coordinator.publishFollowedDriversList()

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

        try await coordinator.publishFollowedDriversList()

        #expect(relay.publishedEvents.count == 1)
        #expect(relay.publishedEvents[0].kind == EventKind.followedDriversList.rawValue)
    }

    @Test func publishFollowedDriversListThrowsOnRelayFailure() async throws {
        let kit = try await makeKit()
        kit.relay.shouldFailPublish = true

        await #expect(throws: (any Error).self) {
            try await kit.coordinator.publishFollowedDriversList()
        }
    }
}
