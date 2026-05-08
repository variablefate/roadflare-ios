import Foundation
import Testing
@testable import RoadFlareCore
@testable import RidestrSDK

/// Tests for issue #96: subscription IDs in `LocationCoordinator` must be unique per
/// invocation so the empty-pubkeys → re-add path cannot let a stale CLOSE silently
/// tear down a freshly-issued REQ that happens to share the same stable ID.
///
/// The load-bearing invariant pinned here is: across any sequence of
/// `start*Subscription[s]()` calls, no two REQs are ever issued with the same
/// `SubscriptionID.rawValue`. Detached unsubscribe Tasks from a prior generation
/// then cannot collide with a later generation's subscription.
@Suite("LocationCoordinator subscription race (issue #96)")
@MainActor
struct LocationCoordinatorSubscriptionRaceTests {

    // Trailing dash anchors the match against the per-invocation UUID suffix,
    // so a hypothetical future stable ID like `"key-shares-v2"` cannot silently
    // satisfy these prefix checks.
    private static let locationPrefix = "roadflare-locations-"
    private static let availabilityPrefix = "driver-availability-"
    private static let keySharePrefix = "key-shares-"

    private func makeBundle() throws -> (
        coordinator: LocationCoordinator,
        fake: FakeRelayManager,
        repo: FollowedDriversRepository,
        keypair: NostrKeypair
    ) {
        let fake = FakeRelayManager()
        fake.keepSubscriptionsAlive = true
        let keypair = try NostrKeypair.generate()
        let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        let coordinator = LocationCoordinator(
            relayManager: fake,
            keypair: keypair,
            driversRepository: repo
        )
        return (coordinator, fake, repo, keypair)
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: pollInterval)
        }
        return true
    }

    private func makeDriver() throws -> FollowedDriver {
        let kp = try NostrKeypair.generate()
        return FollowedDriver(pubkey: kp.publicKeyHex)
    }

    // MARK: - Location subscription (Kind 30014)

    @Test func locationSubscriptionAssignsUniqueIDPerInvocation() async throws {
        let (coordinator, fake, repo, _) = try makeBundle()
        try await fake.connect(to: [URL(string: "wss://test")!])

        repo.addDriver(try makeDriver())
        coordinator.startLocationSubscriptions()
        #expect(await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue.hasPrefix(Self.locationPrefix) }.count >= 1
        })

        coordinator.startLocationSubscriptions()
        #expect(await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue.hasPrefix(Self.locationPrefix) }.count >= 2
        })

        let ids = fake.subscribeCalls
            .map(\.id.rawValue)
            .filter { $0.hasPrefix(Self.locationPrefix) }
        #expect(Set(ids).count == ids.count, "Subscription IDs must be unique across invocations")
    }

    @Test func locationSubscriptionEmptyThenReaddDoesNotReuseID() async throws {
        // Reproduces the issue #96 race shape: a transient empty-pubkeys frame
        // between two non-empty frames must not let the second frame reuse the
        // first frame's subscription ID. With unique IDs the detached
        // unsubscribe from the empty frame can never collide with the new REQ.
        let (coordinator, fake, repo, _) = try makeBundle()
        try await fake.connect(to: [URL(string: "wss://test")!])

        let driverA = try makeDriver()
        let driverB = try makeDriver()

        repo.addDriver(driverA)
        coordinator.startLocationSubscriptions()
        #expect(await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue.hasPrefix(Self.locationPrefix) }
        })
        let firstID = fake.subscribeCalls
            .last(where: { $0.id.rawValue.hasPrefix(Self.locationPrefix) })!.id

        repo.removeDriver(pubkey: driverA.pubkey)
        coordinator.startLocationSubscriptions()  // empty-pubkeys path

        repo.addDriver(driverB)
        coordinator.startLocationSubscriptions()

        #expect(await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue.hasPrefix(Self.locationPrefix) }.count >= 2
        })

        let secondID = fake.subscribeCalls
            .last(where: { $0.id.rawValue.hasPrefix(Self.locationPrefix) })!.id

        #expect(firstID != secondID,
                "Re-added subscription must use a fresh ID; otherwise the empty-frame's detached unsubscribe can tear it down")

        // The detached unsubscribe targets the FIRST id, never the SECOND id.
        #expect(await eventually { fake.unsubscribeCalls.contains(firstID) },
                "Empty-pubkeys path must unsubscribe the prior subscription so the negative assertion below is meaningful")
        #expect(!fake.unsubscribeCalls.contains(secondID),
                "A late unsubscribe targeting the new ID would prove the race is still possible")
    }

    @Test func locationSubscriptionEmptyTearsDownPriorSubscription() async throws {
        let (coordinator, fake, repo, _) = try makeBundle()
        try await fake.connect(to: [URL(string: "wss://test")!])

        let driver = try makeDriver()
        repo.addDriver(driver)
        coordinator.startLocationSubscriptions()
        #expect(await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue.hasPrefix(Self.locationPrefix) }
        })
        let priorID = fake.subscribeCalls
            .last(where: { $0.id.rawValue.hasPrefix(Self.locationPrefix) })!.id

        repo.removeDriver(pubkey: driver.pubkey)
        coordinator.startLocationSubscriptions()  // empty path

        #expect(await eventually {
            fake.unsubscribeCalls.contains(priorID)
        }, "Empty-pubkeys path must unsubscribe the prior subscription by its unique ID")
    }

    // MARK: - Driver availability subscription (Kind 30173)

    @Test func driverAvailabilitySubscriptionAssignsUniqueIDPerInvocation() async throws {
        let (coordinator, fake, repo, _) = try makeBundle()
        try await fake.connect(to: [URL(string: "wss://test")!])

        repo.addDriver(try makeDriver())
        coordinator.startDriverAvailabilitySubscription()
        #expect(await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue.hasPrefix(Self.availabilityPrefix) }.count >= 1
        })

        coordinator.startDriverAvailabilitySubscription()
        #expect(await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue.hasPrefix(Self.availabilityPrefix) }.count >= 2
        })

        let ids = fake.subscribeCalls
            .map(\.id.rawValue)
            .filter { $0.hasPrefix(Self.availabilityPrefix) }
        #expect(Set(ids).count == ids.count, "Subscription IDs must be unique across invocations")
    }

    @Test func driverAvailabilityEmptyThenReaddDoesNotReuseID() async throws {
        let (coordinator, fake, repo, _) = try makeBundle()
        try await fake.connect(to: [URL(string: "wss://test")!])

        let driverA = try makeDriver()
        let driverB = try makeDriver()

        repo.addDriver(driverA)
        coordinator.startDriverAvailabilitySubscription()
        #expect(await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue.hasPrefix(Self.availabilityPrefix) }
        })
        let firstID = fake.subscribeCalls
            .last(where: { $0.id.rawValue.hasPrefix(Self.availabilityPrefix) })!.id

        repo.removeDriver(pubkey: driverA.pubkey)
        coordinator.startDriverAvailabilitySubscription()  // empty path

        repo.addDriver(driverB)
        coordinator.startDriverAvailabilitySubscription()

        #expect(await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue.hasPrefix(Self.availabilityPrefix) }.count >= 2
        })

        let secondID = fake.subscribeCalls
            .last(where: { $0.id.rawValue.hasPrefix(Self.availabilityPrefix) })!.id
        #expect(firstID != secondID)

        _ = await eventually { fake.unsubscribeCalls.contains(firstID) }
        #expect(!fake.unsubscribeCalls.contains(secondID))
    }

    @Test func driverAvailabilityEmptyTearsDownPriorSubscription() async throws {
        let (coordinator, fake, repo, _) = try makeBundle()
        try await fake.connect(to: [URL(string: "wss://test")!])

        let driver = try makeDriver()
        repo.addDriver(driver)
        coordinator.startDriverAvailabilitySubscription()
        #expect(await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue.hasPrefix(Self.availabilityPrefix) }
        })
        let priorID = fake.subscribeCalls
            .last(where: { $0.id.rawValue.hasPrefix(Self.availabilityPrefix) })!.id

        repo.removeDriver(pubkey: driver.pubkey)
        coordinator.startDriverAvailabilitySubscription()

        #expect(await eventually {
            fake.unsubscribeCalls.contains(priorID)
        })
    }

    // MARK: - Key share subscription (Kind 3186)

    // Key-share has no empty-pubkeys branch (it filters on the rider's own pubkey),
    // but the same uniqueness pattern applies: rapid consecutive restarts must not
    // reuse the stable string ID. This pins the pattern uniformly across all three
    // managed subscriptions.
    @Test func keyShareSubscriptionAssignsUniqueIDPerInvocation() async throws {
        let (coordinator, fake, _, _) = try makeBundle()
        try await fake.connect(to: [URL(string: "wss://test")!])

        coordinator.startKeyShareSubscription()
        #expect(await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue.hasPrefix(Self.keySharePrefix) }.count >= 1
        })

        coordinator.startKeyShareSubscription()
        #expect(await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue.hasPrefix(Self.keySharePrefix) }.count >= 2
        })

        let ids = fake.subscribeCalls
            .map(\.id.rawValue)
            .filter { $0.hasPrefix(Self.keySharePrefix) }
        #expect(Set(ids).count == ids.count, "Subscription IDs must be unique across invocations")
    }

    @Test func keyShareSubscriptionTearsDownPriorOnRestart() async throws {
        let (coordinator, fake, _, _) = try makeBundle()
        try await fake.connect(to: [URL(string: "wss://test")!])

        coordinator.startKeyShareSubscription()
        #expect(await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue.hasPrefix(Self.keySharePrefix) }
        })
        let priorID = fake.subscribeCalls
            .last(where: { $0.id.rawValue.hasPrefix(Self.keySharePrefix) })!.id

        coordinator.startKeyShareSubscription()
        #expect(await eventually {
            fake.unsubscribeCalls.contains(priorID)
        })
        // Wait for the second subscribe to actually land before reading the latest id —
        // the unsubscribe of the prior id happens before the new subscribe inside the
        // restart Task, so the two events are not simultaneous.
        #expect(await eventually {
            fake.subscribeCalls.filter { $0.id.rawValue.hasPrefix(Self.keySharePrefix) }.count >= 2
        })

        let secondID = fake.subscribeCalls
            .last(where: { $0.id.rawValue.hasPrefix(Self.keySharePrefix) })!.id
        #expect(priorID != secondID)
    }
}
