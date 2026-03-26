import Foundation
import Testing
@testable import RidestrSDK

@Suite("RoadflareSyncStateStore Tests")
struct RoadflareSyncStateStoreTests {
    @Test func markDirtyAndPublishedRoundTrip() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = RoadflareSyncStateStore(defaults: defaults)

        store.markDirty(.profile)
        #expect(store.metadata(for: .profile).isDirty)

        store.markPublished(.profile, at: 1234)
        #expect(store.metadata(for: .profile).lastSuccessfulPublishAt == 1234)
        #expect(!store.metadata(for: .profile).isDirty)
    }

    @Test func persistenceRoundTrip() {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!

        do {
            let store = RoadflareSyncStateStore(defaults: defaults)
            store.setMetadata(RoadflareSyncMetadata(lastSuccessfulPublishAt: 42, isDirty: true), for: .followedDrivers)
        }

        let reloaded = RoadflareSyncStateStore(defaults: defaults)
        #expect(reloaded.metadata(for: .followedDrivers) == RoadflareSyncMetadata(lastSuccessfulPublishAt: 42, isDirty: true))
    }

    @Test func namespaceIsolationPreventsCrossAccountBleed() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!

        let alice = RoadflareSyncStateStore(defaults: defaults, namespace: "alice")
        alice.markPublished(.profile, at: 100)

        let bob = RoadflareSyncStateStore(defaults: defaults, namespace: "bob")

        #expect(alice.metadata(for: .profile).lastSuccessfulPublishAt == 100)
        #expect(bob.metadata(for: .profile).lastSuccessfulPublishAt == 0)
        #expect(!bob.metadata(for: .profile).isDirty)
    }
}
