import Foundation
import Testing
@testable import RidestrSDK

@Suite("RideHistorySyncCoordinator Tests")
struct RideHistorySyncCoordinatorTests {

    private struct TestKit {
        let rideHistory: RideHistoryRepository
        let syncStore: RoadflareSyncStateStore
        let relay: FakeRelayManager
        let coordinator: RideHistorySyncCoordinator
    }

    private func makeKit() async throws -> TestKit {
        let kp = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        try await relay.connect(to: [URL(string: "wss://fake")!])
        let syncStore = RoadflareSyncStateStore(
            defaults: UserDefaults(suiteName: "rhsc_test_\(UUID().uuidString)")!,
            namespace: UUID().uuidString
        )
        let domainService = RoadflareDomainService(relayManager: relay, keypair: kp)
        let rideHistory = RideHistoryRepository(persistence: InMemoryRideHistoryPersistence())
        let coordinator = RideHistorySyncCoordinator(domainService: domainService, syncStore: syncStore)
        return TestKit(rideHistory: rideHistory, syncStore: syncStore, relay: relay, coordinator: coordinator)
    }

    private func makeEntry(id: String = UUID().uuidString) -> RideHistoryEntry {
        RideHistoryEntry(
            id: id, date: .now, counterpartyPubkey: "driver",
            pickupGeohash: "abc", dropoffGeohash: "def",
            pickup: Location(latitude: 40, longitude: -74),
            destination: Location(latitude: 41, longitude: -73),
            fare: 12.50, paymentMethod: "zelle"
        )
    }

    // MARK: - Happy path

    @Test func publishAndMark_onSuccess_marksPublished() async throws {
        let kit = try await makeKit()
        kit.rideHistory.addRide(makeEntry())

        kit.coordinator.publishAndMark(from: kit.rideHistory)
        try await Task.sleep(for: .milliseconds(300))

        #expect(kit.syncStore.metadata(for: .rideHistory).isDirty == false)
        #expect(kit.syncStore.metadata(for: .rideHistory).lastSuccessfulPublishAt > 0)
    }

    // MARK: - Failure path

    @Test func publishAndMark_onFailure_marksDirty() async throws {
        let kit = try await makeKit()
        kit.relay.shouldFailPublish = true

        kit.coordinator.publishAndMark(from: kit.rideHistory)
        try await Task.sleep(for: .milliseconds(200))

        #expect(kit.syncStore.metadata(for: .rideHistory).isDirty == true)
    }

    // MARK: - Empty history

    @Test func publishAndMark_emptyHistory_succeeds() async throws {
        let kit = try await makeKit()
        // No rides added — empty history is valid after deletion

        kit.coordinator.publishAndMark(from: kit.rideHistory)
        try await Task.sleep(for: .milliseconds(300))

        #expect(!kit.relay.publishedEvents.isEmpty)
        #expect(kit.syncStore.metadata(for: .rideHistory).lastSuccessfulPublishAt > 0)
    }

    // MARK: - Generation / clearAll

    @Test func clearAll_invalidatesInFlightPublish_noMarkPublished() async throws {
        let kit = try await makeKit()
        kit.relay.publishDelay = .milliseconds(150)
        kit.rideHistory.addRide(makeEntry())

        kit.coordinator.publishAndMark(from: kit.rideHistory)
        try await Task.sleep(for: .milliseconds(30))   // let Task start and suspend inside relay publishDelay
        kit.coordinator.clearAll()                     // bumps generation while Task is mid-await
        try await Task.sleep(for: .milliseconds(400))  // let Task try to complete after relay returns

        // Generation mismatch — Task exits without touching store
        #expect(kit.syncStore.metadata(for: .rideHistory).lastSuccessfulPublishAt == 0)
        #expect(kit.syncStore.metadata(for: .rideHistory).isDirty == false)
    }

    @Test func clearAll_doesNotAffectCompletedPublish() async throws {
        let kit = try await makeKit()
        kit.rideHistory.addRide(makeEntry())

        kit.coordinator.publishAndMark(from: kit.rideHistory)
        try await Task.sleep(for: .milliseconds(300))  // let publish complete

        let publishedAt = kit.syncStore.metadata(for: .rideHistory).lastSuccessfulPublishAt
        #expect(publishedAt > 0)  // confirm publish succeeded

        kit.coordinator.clearAll()  // bumps generation — must not undo store state

        #expect(kit.syncStore.metadata(for: .rideHistory).lastSuccessfulPublishAt == publishedAt)
    }

    // MARK: - Content snapshot

    @Test func publishAndMark_snapshotsRidesAtCallTime() async throws {
        let kit = try await makeKit()
        kit.relay.publishDelay = .milliseconds(150)
        kit.rideHistory.addRide(makeEntry(id: "ride1"))

        kit.coordinator.publishAndMark(from: kit.rideHistory)  // captures [ride1] at call time
        kit.rideHistory.addRide(makeEntry(id: "ride2"))         // added AFTER Task fires
        try await Task.sleep(for: .milliseconds(400))

        // Only one publish was fired (not a second one triggered by addRide)
        #expect(kit.relay.publishedEvents.count == 1)
    }
}
