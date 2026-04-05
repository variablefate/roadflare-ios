import Foundation
import Testing
@testable import RidestrSDK

@Suite("RoadflareDomainService Tests")
struct RoadflareDomainServiceTests {

    @Test func resolvePrefersRemoteWhenRemoteIsNewerAndLocalIsClean() {
        let metadata = RoadflareSyncMetadata(lastSuccessfulPublishAt: 100, isDirty: false)
        let resolution = RoadflareDomainService.resolve(
            domain: .profile,
            metadata: metadata,
            remoteCreatedAt: 200
        )

        #expect(resolution.source == .remote)
        #expect(!resolution.shouldPublishLocal)
    }

    @Test func resolvePrefersLocalWhenDirtyEvenIfRemoteIsNewer() {
        let metadata = RoadflareSyncMetadata(lastSuccessfulPublishAt: 100, isDirty: true)
        let resolution = RoadflareDomainService.resolve(
            domain: .profileBackup,
            metadata: metadata,
            remoteCreatedAt: 200
        )

        #expect(resolution.source == .local)
        #expect(resolution.shouldPublishLocal)
    }

    @Test func resolveKeepsLocalWhenLocalPublishIsNewer() {
        let metadata = RoadflareSyncMetadata(lastSuccessfulPublishAt: 300, isDirty: false)
        let resolution = RoadflareDomainService.resolve(
            domain: .followedDrivers,
            metadata: metadata,
            remoteCreatedAt: 200
        )

        #expect(resolution.source == .local)
        #expect(!resolution.shouldPublishLocal)
    }

    @Test func resolvePublishesDirtyLocalWithoutRemote() {
        let metadata = RoadflareSyncMetadata(lastSuccessfulPublishAt: 0, isDirty: true)
        let resolution = RoadflareDomainService.resolve(
            domain: .followedDrivers,
            metadata: metadata,
            remoteCreatedAt: nil
        )

        #expect(resolution.source == .local)
        #expect(resolution.shouldPublishLocal)
    }

    @Test func seedLegacyLocalStateWhenRemoteMissingAndMetadataIsPristine() {
        let metadata = RoadflareSyncMetadata(lastSuccessfulPublishAt: 0, isDirty: false)

        let shouldSeed = RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: metadata,
            remoteCreatedAt: nil,
            hasLocalState: true
        )

        #expect(shouldSeed)
    }

    @Test func doesNotSeedLegacyLocalStateWhenRemoteExistsOrNothingLocal() {
        let pristine = RoadflareSyncMetadata(lastSuccessfulPublishAt: 0, isDirty: false)

        #expect(!RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: pristine,
            remoteCreatedAt: 123,
            hasLocalState: true
        ))
        #expect(!RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: pristine,
            remoteCreatedAt: nil,
            hasLocalState: false
        ))
    }

    @Test func syncStateStoreTracksDirtyAndPublishedTimestamps() {
        let defaults = UserDefaults(suiteName: "RoadflareSyncStateStoreTests.\(UUID().uuidString)")!
        let store = RoadflareSyncStateStore(defaults: defaults)

        store.markDirty(.profile)
        #expect(store.metadata(for: .profile).isDirty)
        #expect(store.metadata(for: .profile).lastSuccessfulPublishAt == 0)

        store.markPublished(.profile, at: 1234)
        let profile = store.metadata(for: .profile)
        #expect(!profile.isDirty)
        #expect(profile.lastSuccessfulPublishAt == 1234)
    }

    @Test func fetchLatestFollowedDriversUsesNewestEvent() async throws {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RoadflareDomainService(relayManager: relay, keypair: keypair)

        let older = try await RideshareEventBuilder.followedDriversList(
            drivers: [FollowedDriver(pubkey: "old-driver", addedAt: 100)],
            keypair: keypair
        )
        let newer = try await RideshareEventBuilder.followedDriversList(
            drivers: [FollowedDriver(pubkey: "new-driver", addedAt: 200)],
            keypair: keypair
        )
        relay.fetchResults = [
            NostrEvent(
                id: older.id,
                pubkey: older.pubkey,
                createdAt: 100,
                kind: older.kind,
                tags: older.tags,
                content: older.content,
                sig: older.sig
            ),
            NostrEvent(
                id: newer.id,
                pubkey: newer.pubkey,
                createdAt: 200,
                kind: newer.kind,
                tags: newer.tags,
                content: newer.content,
                sig: newer.sig
            ),
        ]

        let snapshot = await service.fetchLatestFollowedDriversState().snapshot
        #expect(snapshot?.createdAt == 200)
        #expect(snapshot?.value.drivers.first?.pubkey == "new-driver")
    }

    @Test func fetchLatestFollowedDriversFallsBackToNewestDecodableEvent() async throws {
        let keypair = try NostrKeypair.generate()
        let otherKeypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RoadflareDomainService(relayManager: relay, keypair: keypair)

        let older = try await RideshareEventBuilder.followedDriversList(
            drivers: [FollowedDriver(pubkey: "valid-driver", addedAt: 100)],
            keypair: keypair
        )
        let newerUndecodable = try await RideshareEventBuilder.followedDriversList(
            drivers: [FollowedDriver(pubkey: "invalid-driver", addedAt: 200)],
            keypair: otherKeypair
        )
        relay.fetchResults = [
            NostrEvent(
                id: older.id,
                pubkey: older.pubkey,
                createdAt: 100,
                kind: older.kind,
                tags: older.tags,
                content: older.content,
                sig: older.sig
            ),
            NostrEvent(
                id: newerUndecodable.id,
                pubkey: newerUndecodable.pubkey,
                createdAt: 200,
                kind: newerUndecodable.kind,
                tags: newerUndecodable.tags,
                content: newerUndecodable.content,
                sig: newerUndecodable.sig
            ),
        ]

        let snapshot = await service.fetchLatestFollowedDriversState().snapshot
        #expect(snapshot?.createdAt == 100)
        #expect(snapshot?.value.drivers.first?.pubkey == "valid-driver")
    }

    @Test func startupRemoteStatePreservesRemotePresenceWhenNewestEventIsUndecodable() async throws {
        let keypair = try NostrKeypair.generate()
        let otherKeypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RoadflareDomainService(relayManager: relay, keypair: keypair)

        let older = try await RideshareEventBuilder.followedDriversList(
            drivers: [FollowedDriver(pubkey: "valid-driver", addedAt: 100)],
            keypair: keypair
        )
        let newerUndecodable = try await RideshareEventBuilder.followedDriversList(
            drivers: [FollowedDriver(pubkey: "invalid-driver", addedAt: 200)],
            keypair: otherKeypair
        )
        relay.fetchResults = [
            NostrEvent(
                id: older.id,
                pubkey: older.pubkey,
                createdAt: 100,
                kind: older.kind,
                tags: older.tags,
                content: older.content,
                sig: older.sig
            ),
            NostrEvent(
                id: newerUndecodable.id,
                pubkey: newerUndecodable.pubkey,
                createdAt: 200,
                kind: newerUndecodable.kind,
                tags: newerUndecodable.tags,
                content: newerUndecodable.content,
                sig: newerUndecodable.sig
            ),
        ]

        let remote = await service.fetchStartupRemoteState()
        #expect(remote.followedDrivers.latestSeenCreatedAt == 200)
        #expect(remote.followedDrivers.snapshot?.createdAt == 100)
        #expect(remote.followedDrivers.snapshot?.value.drivers.first?.pubkey == "valid-driver")
    }

    @Test func fetchLatestFollowedDriversStatePreservesRemotePresenceWhenNewestEventIsUndecodable() async throws {
        let keypair = try NostrKeypair.generate()
        let otherKeypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RoadflareDomainService(relayManager: relay, keypair: keypair)

        let older = try await RideshareEventBuilder.followedDriversList(
            drivers: [FollowedDriver(pubkey: "valid-driver", addedAt: 100)],
            keypair: keypair
        )
        let newerUndecodable = try await RideshareEventBuilder.followedDriversList(
            drivers: [FollowedDriver(pubkey: "invalid-driver", addedAt: 200)],
            keypair: otherKeypair
        )
        relay.fetchResults = [
            NostrEvent(
                id: older.id,
                pubkey: older.pubkey,
                createdAt: 100,
                kind: older.kind,
                tags: older.tags,
                content: older.content,
                sig: older.sig
            ),
            NostrEvent(
                id: newerUndecodable.id,
                pubkey: newerUndecodable.pubkey,
                createdAt: 200,
                kind: newerUndecodable.kind,
                tags: newerUndecodable.tags,
                content: newerUndecodable.content,
                sig: newerUndecodable.sig
            ),
        ]

        let remote = await service.fetchLatestFollowedDriversState()
        #expect(remote.latestSeenCreatedAt == 200)
        #expect(remote.snapshot?.createdAt == 100)
    }

    @Test func fetchDriverProfilesReturnsLatestPerPubkey() async throws {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RoadflareDomainService(relayManager: relay, keypair: keypair)

        relay.fetchResults = [
            NostrEvent(
                id: "older-a",
                pubkey: "driver-a",
                createdAt: 100,
                kind: EventKind.metadata.rawValue,
                tags: [],
                content: #"{"name":"Older A"}"#,
                sig: "sig"
            ),
            NostrEvent(
                id: "newer-a",
                pubkey: "driver-a",
                createdAt: 200,
                kind: EventKind.metadata.rawValue,
                tags: [],
                content: #"{"name":"Newer A"}"#,
                sig: "sig"
            ),
            NostrEvent(
                id: "only-b",
                pubkey: "driver-b",
                createdAt: 150,
                kind: EventKind.metadata.rawValue,
                tags: [],
                content: #"{"display_name":"Driver B"}"#,
                sig: "sig"
            ),
        ]

        let profiles = await service.fetchDriverProfiles(pubkeys: ["driver-a", "driver-b"])
        #expect(profiles["driver-a"]?.value.name == "Newer A")
        #expect(profiles["driver-a"]?.createdAt == 200)
        #expect(profiles["driver-b"]?.value.displayName == "Driver B")
    }

    @Test func fetchDriverProfilesFallsBackToNewestDecodableEventPerPubkey() async throws {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let service = RoadflareDomainService(relayManager: relay, keypair: keypair)

        relay.fetchResults = [
            NostrEvent(
                id: "older-a",
                pubkey: "driver-a",
                createdAt: 100,
                kind: EventKind.metadata.rawValue,
                tags: [],
                content: #"{"name":"Older A"}"#,
                sig: "sig"
            ),
            NostrEvent(
                id: "newer-invalid-a",
                pubkey: "driver-a",
                createdAt: 200,
                kind: EventKind.metadata.rawValue,
                tags: [],
                content: #"{invalid"#,
                sig: "sig"
            ),
        ]

        let profiles = await service.fetchDriverProfiles(pubkeys: ["driver-a"])
        #expect(profiles["driver-a"]?.value.name == "Older A")
        #expect(profiles["driver-a"]?.createdAt == 100)
    }

    // MARK: - publishAndMark Convenience Helpers

    @Test func publishProfileAndMarkMarksSyncStore() async throws {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        try await relay.connect(to: [URL(string: "wss://fake")!])
        let service = RoadflareDomainService(relayManager: relay, keypair: keypair)
        let syncStore = RoadflareSyncStateStore(
            defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!,
            namespace: UUID().uuidString
        )
        let settings = UserSettingsRepository(persistence: InMemoryUserSettingsPersistence())
        _ = settings.setProfileName("Alice")

        await service.publishProfileAndMark(from: settings, syncStore: syncStore)

        #expect(syncStore.metadata(for: .profile).lastSuccessfulPublishAt > 0)
        #expect(relay.publishedEvents.count == 1)
    }

    @Test func publishFollowedDriversListAndMarkMarksSyncStore() async throws {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        try await relay.connect(to: [URL(string: "wss://fake")!])
        let service = RoadflareDomainService(relayManager: relay, keypair: keypair)
        let syncStore = RoadflareSyncStateStore(
            defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!,
            namespace: UUID().uuidString
        )
        let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        repo.addDriver(FollowedDriver(pubkey: "d1", addedAt: 100, name: "Alice"))

        await service.publishFollowedDriversListAndMark(from: repo, syncStore: syncStore)

        #expect(syncStore.metadata(for: .followedDrivers).lastSuccessfulPublishAt > 0)
        #expect(relay.publishedEvents.count == 1)
    }

    @Test func publishRideHistoryAndMarkMarksSyncStore() async throws {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        try await relay.connect(to: [URL(string: "wss://fake")!])
        let service = RoadflareDomainService(relayManager: relay, keypair: keypair)
        let syncStore = RoadflareSyncStateStore(
            defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!,
            namespace: UUID().uuidString
        )
        let history = RideHistoryRepository(persistence: InMemoryRideHistoryPersistence())
        history.addRide(RideHistoryEntry(
            id: "r1", date: .now, counterpartyPubkey: "driver",
            pickupGeohash: "abc", dropoffGeohash: "def",
            pickup: Location(latitude: 40, longitude: -74),
            destination: Location(latitude: 41, longitude: -73),
            fare: 10.0, paymentMethod: "zelle"
        ))

        await service.publishRideHistoryAndMark(from: history, syncStore: syncStore)

        #expect(syncStore.metadata(for: .rideHistory).lastSuccessfulPublishAt > 0)
        #expect(relay.publishedEvents.count == 1)
    }
}
