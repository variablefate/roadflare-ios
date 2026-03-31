import Foundation
import Testing
@testable import RidestrSDK

@Suite("RelayManager Tests")
struct RelayManagerTests {
    @Test func initNotConnected() async {
        let keypair = try! NostrKeypair.generate()
        let manager = RelayManager(keypair: keypair)
        let connected = await manager.isConnected
        #expect(!connected)
    }

    @Test func publishBeforeConnectThrows() async throws {
        let keypair = try NostrKeypair.generate()
        let manager = RelayManager(keypair: keypair)

        // Create a signed event
        let event = try await EventSigner.sign(
            kind: .rideOffer,
            content: "test",
            tags: [],
            keypair: keypair
        )

        await #expect(throws: RidestrError.self) {
            try await manager.publish(event)
        }
    }

    @Test func subscribeBeforeConnectThrows() async throws {
        let keypair = try NostrKeypair.generate()
        let manager = RelayManager(keypair: keypair)

        await #expect(throws: RidestrError.self) {
            _ = try await manager.subscribe(
                filter: NostrFilter().kinds([.rideOffer]),
                id: SubscriptionID()
            )
        }
    }

    @Test func fetchBeforeConnectThrows() async throws {
        let keypair = try NostrKeypair.generate()
        let manager = RelayManager(keypair: keypair)

        await #expect(throws: RidestrError.self) {
            _ = try await manager.fetchEvents(
                filter: NostrFilter().kinds([.rideOffer])
            )
        }
    }

    @Test func disconnectWhenNotConnected() async {
        let keypair = try! NostrKeypair.generate()
        let manager = RelayManager(keypair: keypair)
        // Should not crash
        await manager.disconnect()
        let connected = await manager.isConnected
        #expect(!connected)
    }
}

// MARK: - FakeRelayManager Tests

@Suite("FakeRelayManager Tests")
struct FakeRelayManagerTests {
    @Test func recordsPublishedEvents() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        let event = NostrEvent(
            id: "abc", pubkey: "def", createdAt: 1700000000,
            kind: 3173, tags: [], content: "test", sig: "sig"
        )
        _ = try await fake.publish(event)
        #expect(fake.publishedEvents.count == 1)
        #expect(fake.publishedEvents.first?.id == "abc")
    }

    @Test func recordsConnectCalls() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)
        #expect(fake.connectCalls.count == 1)
        #expect(fake.connectCalls.first?.count == 3)
    }

    @Test func failConnect() async {
        let fake = FakeRelayManager()
        fake.shouldFailConnect = true
        await #expect(throws: RidestrError.self) {
            try await fake.connect(to: DefaultRelays.all)
        }
    }

    @Test func failPublish() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)
        fake.shouldFailPublish = true

        let event = NostrEvent(
            id: "abc", pubkey: "def", createdAt: 1700000000,
            kind: 3173, tags: [], content: "test", sig: "sig"
        )
        await #expect(throws: RidestrError.self) {
            try await fake.publish(event)
        }
    }

    @Test func subscribeReturnsCannedEvents() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        let subId = SubscriptionID("test-sub")
        let cannedEvent = NostrEvent(
            id: "event1", pubkey: "pub1", createdAt: 1700000000,
            kind: 3174, tags: [], content: "accepted", sig: "sig"
        )
        fake.subscriptionEvents["test-sub"] = [cannedEvent]

        let stream = try await fake.subscribe(
            filter: NostrFilter().kinds([.rideAcceptance]),
            id: subId
        )

        var received: [NostrEvent] = []
        for await event in stream {
            received.append(event)
        }
        #expect(received.count == 1)
        #expect(received.first?.id == "event1")
    }

    @Test func injectEventToNonexistentSubscriptionReturnsFalse() async throws {
        let fake = FakeRelayManager()
        let event = NostrEvent(id: "e1", pubkey: "p1", createdAt: 100, kind: 3174, tags: [], content: "a", sig: "s")
        let delivered = fake.injectEvent(event, subscriptionId: "nonexistent")
        #expect(!delivered)
    }

    @Test func resetRecordingClearsHistory() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)
        let event = NostrEvent(id: "e1", pubkey: "p1", createdAt: 100, kind: 1, tags: [], content: "", sig: "s")
        _ = try await fake.publish(event)
        #expect(fake.publishedEvents.count == 1)
        #expect(fake.connectCalls.count == 1)

        fake.resetRecording()
        #expect(fake.publishedEvents.isEmpty)
        #expect(fake.connectCalls.isEmpty)
    }

    @Test func fetchReturnsCannedEvents() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        let cannedEvent = NostrEvent(
            id: "event1", pubkey: "pub1", createdAt: 1700000000,
            kind: 30182, tags: [], content: "{}", sig: "sig"
        )
        fake.fetchResults = [cannedEvent]

        let results = try await fake.fetchEvents(
            filter: NostrFilter.remoteConfig(),
            timeout: 5
        )
        #expect(results.count == 1)
        #expect(fake.fetchCalls.count == 1)
    }

    @Test func disconnectTracked() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)
        #expect(fake.isConnected)
        await fake.disconnect()
        let connectedAfter = fake.isConnected
        #expect(!connectedAfter)
        #expect(fake.disconnectCount == 1)
    }

    @Test func unsubscribeTracked() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)
        let subId = SubscriptionID("unsub-test")
        await fake.unsubscribe(subId)
        #expect(fake.unsubscribeCalls.count == 1)
        #expect(fake.unsubscribeCalls.first?.rawValue == "unsub-test")
    }

    @Test func unsubscribeFinishesLiveSubscription() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)
        fake.keepSubscriptionsAlive = true

        let subId = SubscriptionID("live-unsub-test")
        let stream = try await fake.subscribe(filter: NostrFilter.remoteConfig(), id: subId)
        let consumer = Task {
            for await _ in stream {}
        }

        #expect(fake.activeSubscriptionCount == 1)

        await fake.unsubscribe(subId)
        try await Task.sleep(for: .milliseconds(50))

        #expect(fake.activeSubscriptionCount == 0)
        await consumer.value
    }

    @Test func finishSubscriptionClosesLiveStream() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)
        fake.keepSubscriptionsAlive = true

        let subId = SubscriptionID("finish-test")
        let stream = try await fake.subscribe(filter: NostrFilter.remoteConfig(), id: subId)
        let consumer = Task {
            for await _ in stream {}
        }

        #expect(fake.activeSubscriptionCount == 1)

        fake.finishSubscription(subId.rawValue)
        try await Task.sleep(for: .milliseconds(50))

        #expect(fake.activeSubscriptionCount == 0)
        await consumer.value
    }

    @Test func latestSubscribeGenerationWinsWhenSubscribeCompletionsRace() async throws {
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)
        fake.keepSubscriptionsAlive = true
        fake.subscribeDelay = .milliseconds(100)

        let subId = SubscriptionID("race-sub")
        let first = Task {
            try await fake.subscribe(filter: NostrFilter.remoteConfig(), id: subId)
        }
        try await Task.sleep(for: .milliseconds(10))
        let second = Task {
            try await fake.subscribe(filter: NostrFilter.remoteConfig(), id: subId)
        }

        _ = try await first.value
        _ = try await second.value
        try await Task.sleep(for: .milliseconds(150))

        #expect(fake.activeSubscriptionCount == 1)
        #expect(fake.isSubscriptionActive(subId.rawValue))

        await fake.unsubscribe(subId)
        #expect(fake.activeSubscriptionCount == 0)
    }
}
