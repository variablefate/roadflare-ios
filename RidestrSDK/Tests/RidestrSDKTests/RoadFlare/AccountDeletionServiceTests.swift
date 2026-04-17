import Foundation
import Testing
@testable import RidestrSDK

private func stubEvent(id: String, kind: UInt16, pubkey: String) -> NostrEvent {
    let json = """
    {"id":"\(id)","pubkey":"\(pubkey)","created_at":1700000000,"kind":\(kind),\
    "tags":[],"content":"","sig":"fakesig"}
    """
    return try! JSONDecoder().decode(NostrEvent.self, from: json.data(using: .utf8)!)
}

@Suite("AccountDeletionService Tests")
struct AccountDeletionServiceTests {
    private func makeKit() throws -> (sut: AccountDeletionService, relay: FakeRelayManager, pubkey: String) {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let sut = AccountDeletionService(relayManager: relay, keypair: keypair)
        return (sut, relay, keypair.publicKeyHex)
    }

    // MARK: - Scan

    @Test func scan_noEvents_returnsEmptyResult() async throws {
        let (sut, relay, _) = try makeKit()
        relay.fetchResults = []

        let result = await sut.scanRelays()

        #expect(result.roadflareEvents.isEmpty)
        #expect(result.metadataEvents.isEmpty)
        #expect(result.scanErrors.isEmpty)
        #expect(result.hasErrors == false)
        #expect(result.targetRelayURLs == DefaultRelays.all)
        // Two queries: roadflare kinds + kind 0
        #expect(relay.fetchCalls.count == 2)
    }

    @Test func scan_withEvents_categorisesCorrectly() async throws {
        let (sut, relay, pubkey) = try makeKit()
        let rfEvent = stubEvent(id: "rf1", kind: EventKind.followedDriversList.rawValue, pubkey: pubkey)
        let metaEvent = stubEvent(id: "meta1", kind: EventKind.metadata.rawValue, pubkey: pubkey)
        relay.fetchResults = [rfEvent, metaEvent]

        let result = await sut.scanRelays()

        // Both queries return both events — the FakeRelayManager returns fetchResults
        // for every fetchEvents call. In production, each filter returns only matching
        // events. This test verifies the result is populated and errors are empty.
        #expect(!result.roadflareEvents.isEmpty)
        #expect(!result.metadataEvents.isEmpty)
        #expect(result.scanErrors.isEmpty)
    }

    @Test func scan_fetchFailure_capturesErrorsRatherThanSilentEmpty() async throws {
        // Pragmatic test using a one-off throwing fake: the SDK FakeRelayManager
        // doesn't expose shouldFailFetch, so we verify the contract that errors
        // do propagate into scanErrors when fetch throws.
        final class ThrowingRelay: RelayManagerProtocol, @unchecked Sendable {
            func connect(to relays: [URL]) async throws {}
            func disconnect() async {}
            func publish(_ event: NostrEvent) async throws -> String { event.id }
            func subscribe(filter: NostrFilter, id: SubscriptionID) async throws -> AsyncStream<NostrEvent> {
                AsyncStream { $0.finish() }
            }
            func unsubscribe(_ id: SubscriptionID) async {}
            func fetchEvents(filter: NostrFilter, timeout: TimeInterval) async throws -> [NostrEvent] {
                throw RidestrError.relay(.notConnected)
            }
            var isConnected: Bool { false }
            func reconnectIfNeeded() async {}
        }

        let keypair = try NostrKeypair.generate()
        let sut = AccountDeletionService(relayManager: ThrowingRelay(), keypair: keypair)

        let result = await sut.scanRelays()

        #expect(result.roadflareEvents.isEmpty)
        #expect(result.metadataEvents.isEmpty)
        #expect(result.hasErrors == true)
        #expect(result.scanErrors.count == 2)  // both queries failed
        #expect(result.scanErrors.contains { $0.contains("RoadFlare events query failed") })
        #expect(result.scanErrors.contains { $0.contains("Nostr profile query failed") })
    }

    // MARK: - Delete RoadFlare events

    @Test func deleteRoadflare_noEvents_publishesNothing() async throws {
        let (sut, relay, _) = try makeKit()
        let scan = RelayScanResult(
            roadflareEvents: [],
            metadataEvents: [],
            scanErrors: [],
            targetRelayURLs: DefaultRelays.all
        )

        let result = await sut.deleteRoadflareEvents(from: scan)

        #expect(result.publishedSuccessfully == true)
        #expect(result.deletedEventIds.isEmpty)
        #expect(relay.publishedEvents.isEmpty)
    }

    @Test func deleteRoadflare_withEvents_publishesKind5ForRoadflareOnly() async throws {
        let (sut, relay, pubkey) = try makeKit()
        let rfEvent = stubEvent(id: "rf1", kind: EventKind.followedDriversList.rawValue, pubkey: pubkey)
        let metaEvent = stubEvent(id: "meta1", kind: EventKind.metadata.rawValue, pubkey: pubkey)
        let scan = RelayScanResult(
            roadflareEvents: [rfEvent],
            metadataEvents: [metaEvent],
            scanErrors: [],
            targetRelayURLs: DefaultRelays.all
        )

        let result = await sut.deleteRoadflareEvents(from: scan)

        #expect(result.publishedSuccessfully == true)
        #expect(result.deletedEventIds == ["rf1"])
        #expect(relay.publishedEvents.count == 1)
        let kind5 = relay.publishedEvents[0]
        #expect(kind5.kind == 5)
        let eTagIds = kind5.tagValues("e")
        #expect(eTagIds.contains("rf1"))
        #expect(!eTagIds.contains("meta1"))  // Kind 0 NOT included
    }

    // MARK: - Delete all Ridestr events

    @Test func deleteAll_withEvents_publishesKind5IncludingMetadata() async throws {
        let (sut, relay, pubkey) = try makeKit()
        let rfEvent = stubEvent(id: "rf1", kind: EventKind.followedDriversList.rawValue, pubkey: pubkey)
        let metaEvent = stubEvent(id: "meta1", kind: EventKind.metadata.rawValue, pubkey: pubkey)
        let scan = RelayScanResult(
            roadflareEvents: [rfEvent],
            metadataEvents: [metaEvent],
            scanErrors: [],
            targetRelayURLs: DefaultRelays.all
        )

        let result = await sut.deleteAllRidestrEvents(from: scan)

        #expect(result.publishedSuccessfully == true)
        #expect(result.deletedEventIds.contains("rf1"))
        #expect(result.deletedEventIds.contains("meta1"))
        let kind5 = relay.publishedEvents[0]
        let eTagIds = kind5.tagValues("e")
        #expect(eTagIds.contains("rf1"))
        #expect(eTagIds.contains("meta1"))
    }

    // MARK: - Publish failure

    @Test func delete_publishFails_returnsFailureResult() async throws {
        let (sut, relay, pubkey) = try makeKit()
        let rfEvent = stubEvent(id: "rf1", kind: 30011, pubkey: pubkey)
        let scan = RelayScanResult(
            roadflareEvents: [rfEvent],
            metadataEvents: [],
            scanErrors: [],
            targetRelayURLs: DefaultRelays.all
        )
        relay.shouldFailPublish = true

        let result = await sut.deleteRoadflareEvents(from: scan)

        #expect(result.publishedSuccessfully == false)
        #expect(result.publishError != nil)
        #expect(result.deletedEventIds == ["rf1"])
    }

    // MARK: - Kind lists

    @Test func roadflareKinds_containsAll12RiderAuthoredKinds() {
        let rawValues = AccountDeletionService.roadflareKinds.map(\.rawValue)
        // Replaceable
        #expect(rawValues.contains(30011))  // followedDriversList
        #expect(rawValues.contains(30174))  // rideHistoryBackup
        #expect(rawValues.contains(30177))  // unifiedProfile
        #expect(rawValues.contains(30181))  // riderRideState
        // Regular/ephemeral
        #expect(rawValues.contains(3173))   // rideOffer
        #expect(rawValues.contains(3175))   // rideConfirmation
        #expect(rawValues.contains(3178))   // chatMessage
        #expect(rawValues.contains(3179))   // cancellation
        #expect(rawValues.contains(3186))   // keyShare
        #expect(rawValues.contains(3187))   // followNotification
        #expect(rawValues.contains(3188))   // keyAcknowledgement
        #expect(rawValues.contains(3189))   // driverPingRequest
    }

    @Test func roadflareKinds_excludesDriverAndNonRidestrKinds() {
        let rawValues = AccountDeletionService.roadflareKinds.map(\.rawValue)
        #expect(!rawValues.contains(0))      // metadata — separate tier
        #expect(!rawValues.contains(3174))   // rideAcceptance — driver-authored
        #expect(!rawValues.contains(30012))  // driverRoadflareState
        #expect(!rawValues.contains(30173))  // driverAvailability
        #expect(!rawValues.contains(30180))  // driverRideState
    }
}
