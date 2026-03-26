import Testing
import Foundation
@testable import RoadFlare
@testable import RidestrSDK

private let rideCoordinatorAcceptanceEventId = String(repeating: "a", count: 64)
private let rideCoordinatorConfirmationEventId = String(repeating: "b", count: 64)
private let rideCoordinatorWrongConfirmationEventId = String(repeating: "c", count: 64)

@Suite("RideCoordinator Tests")
struct RideCoordinatorTests {

    // MARK: - Test Helpers

    @MainActor
    private func makeCoordinator(
        keypair existingKeypair: NostrKeypair? = nil,
        keepSubscriptionsAlive: Bool = false,
        clearRidePersistence: Bool = true,
        roadflarePaymentMethods: [String] = ["zelle"],
        stageTimeouts: RideCoordinator.StageTimeouts = .interopDefault
    ) async throws -> (RideCoordinator, FakeRelayManager, NostrKeypair) {
        if clearRidePersistence {
            RideStatePersistence.clear()
        }
        let keypair = try existingKeypair ?? NostrKeypair.generate()
        let fake = FakeRelayManager()
        fake.keepSubscriptionsAlive = keepSubscriptionsAlive
        try await fake.connect(to: DefaultRelays.all)

        let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        let settings = UserSettings(defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!)
        settings.setRoadflarePaymentMethods(roadflarePaymentMethods)
        let history = RideHistoryStore(defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!)
        let bitcoinPrice = BitcoinPriceService()
        bitcoinPrice.btcPriceUsdForTesting = 100_000

        let coordinator = RideCoordinator(
            relayManager: fake, keypair: keypair,
            driversRepository: repo, settings: settings,
            rideHistory: history, bitcoinPrice: bitcoinPrice,
            stageTimeouts: stageTimeouts
        )
        return (coordinator, fake, keypair)
    }

    @MainActor
    private func eventually(
        timeout: Duration = .seconds(1),
        pollInterval: Duration = .milliseconds(10),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout

        while !condition() {
            if clock.now >= deadline {
                return false
            }
            try? await Task.sleep(for: pollInterval)
        }

        return true
    }

    // MARK: - Key Share Handling

    @MainActor
    @Test func handleKeyShareUpdatesDriverAndPublishesAck() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()
        let roadflareKey = try NostrKeypair.generate()

        // Add driver to repository first
        coordinator.driversRepository.addDriver(FollowedDriver(pubkey: driver.publicKeyHex))

        // Build a key share event
        let content = KeyShareContent(
            roadflareKey: RoadflareKey(
                privateKeyHex: roadflareKey.privateKeyHex,
                publicKeyHex: roadflareKey.publicKeyHex,
                version: 1, keyUpdatedAt: 1700000000
            ),
            keyUpdatedAt: 1700000000,
            driverPubKey: driver.publicKeyHex
        )
        let json = try JSONEncoder().encode(content)
        let encrypted = try NIP44.encrypt(
            plaintext: String(data: json, encoding: .utf8)!,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )
        let event = NostrEvent(
            id: "ks1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.keyShare.rawValue,
            tags: [["p", riderKeypair.publicKeyHex], ["expiration", "\(Int(Date.now.timeIntervalSince1970) + 300)"]],
            content: encrypted, sig: "sig"
        )

        await coordinator.location.handleKeyShareEvent(event)

        // Driver should have key now
        let updatedDriver = coordinator.driversRepository.getDriver(pubkey: driver.publicKeyHex)
        #expect(updatedDriver?.hasKey == true)
        #expect(updatedDriver?.roadflareKey?.version == 1)

        // Should have published an ack (Kind 3188)
        let acks = fake.publishedEvents.filter { $0.kind == EventKind.keyAcknowledgement.rawValue }
        #expect(acks.count == 1)
    }

    @MainActor
    @Test func handleKeyShareIgnoresUnknownDriver() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        // DON'T add driver to repository
        let content = KeyShareContent(
            roadflareKey: RoadflareKey(privateKeyHex: "aa", publicKeyHex: "bb", version: 1),
            keyUpdatedAt: 100, driverPubKey: driver.publicKeyHex
        )
        let json = try JSONEncoder().encode(content)
        let encrypted = try NIP44.encrypt(
            plaintext: String(data: json, encoding: .utf8)!,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )
        let event = NostrEvent(
            id: "ks1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.keyShare.rawValue,
            tags: [["p", riderKeypair.publicKeyHex], ["expiration", "\(Int(Date.now.timeIntervalSince1970) + 300)"]],
            content: encrypted, sig: "sig"
        )

        await coordinator.location.handleKeyShareEvent(event)

        #expect(coordinator.driversRepository.drivers.isEmpty)
        let acks = fake.publishedEvents.filter { $0.kind == EventKind.keyAcknowledgement.rawValue }
        #expect(acks.isEmpty)
    }

    @MainActor
    @Test func handleKeyShareDoesNotOverwriteNewerLocalKey() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()
        let currentKey = RoadflareKey(privateKeyHex: "current-priv", publicKeyHex: "current-pub", version: 2, keyUpdatedAt: 200)
        coordinator.driversRepository.addDriver(
            FollowedDriver(pubkey: driver.publicKeyHex, roadflareKey: currentKey)
        )

        let content = KeyShareContent(
            roadflareKey: RoadflareKey(privateKeyHex: "old-priv", publicKeyHex: "old-pub", version: 1, keyUpdatedAt: 100),
            keyUpdatedAt: 100,
            driverPubKey: driver.publicKeyHex
        )
        let json = try JSONEncoder().encode(content)
        let encrypted = try NIP44.encrypt(
            plaintext: String(data: json, encoding: .utf8)!,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )
        let event = NostrEvent(
            id: "ks-old",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.keyShare.rawValue,
            tags: [["p", riderKeypair.publicKeyHex], ["expiration", "\(Int(Date.now.timeIntervalSince1970) + 300)"]],
            content: encrypted,
            sig: "sig"
        )

        await coordinator.location.handleKeyShareEvent(event)

        #expect(coordinator.driversRepository.getDriver(pubkey: driver.publicKeyHex)?.roadflareKey == currentKey)
        let acks = fake.publishedEvents.filter { $0.kind == EventKind.keyAcknowledgement.rawValue }
        #expect(acks.isEmpty)
    }

    // MARK: - Chat Handling

    @MainActor
    @Test func handleChatEventDeduplicates() async throws {
        let (coordinator, _, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        let chatJSON = "{\"message\":\"Hello!\"}"
        let encrypted = try NIP44.encrypt(
            plaintext: chatJSON,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )
        let event = NostrEvent(
            id: "chat1", pubkey: driver.publicKeyHex,
            createdAt: 1700000000,
            kind: EventKind.chatMessage.rawValue,
            tags: [["p", riderKeypair.publicKeyHex], ["e", "conf1"]],
            content: encrypted, sig: "sig"
        )

        await coordinator.chat.handleChatEvent(event)
        await coordinator.chat.handleChatEvent(event)  // Duplicate

        #expect(coordinator.chat.chatMessages.count == 1)
        #expect(coordinator.chat.chatMessages.first?.text == "Hello!")
    }

    @MainActor
    @Test func handleChatEventSortsByTimestamp() async throws {
        let (coordinator, _, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        for (id, ts) in [("c3", 300), ("c1", 100), ("c2", 200)] {
            let encrypted = try NIP44.encrypt(
                plaintext: "{\"message\":\"msg-\(id)\"}",
                senderPrivateKeyHex: driver.privateKeyHex,
                recipientPublicKeyHex: riderKeypair.publicKeyHex
            )
            let event = NostrEvent(
                id: id, pubkey: driver.publicKeyHex,
                createdAt: ts,
                kind: EventKind.chatMessage.rawValue,
                tags: [["p", riderKeypair.publicKeyHex], ["e", "conf1"]],
                content: encrypted, sig: "sig"
            )
            await coordinator.chat.handleChatEvent(event)
        }

        #expect(coordinator.chat.chatMessages.count == 3)
        #expect(coordinator.chat.chatMessages[0].timestamp == 100)
        #expect(coordinator.chat.chatMessages[1].timestamp == 200)
        #expect(coordinator.chat.chatMessages[2].timestamp == 300)
    }

    // MARK: - Send Offer

    @MainActor
    @Test func sendRideOfferPublishesEventAndTransitionsState() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        let pickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let destination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")

        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: pickup, destination: destination,
            fareEstimate: fare
        )

        // Should have published a Kind 3173 offer
        let offers = fake.publishedEvents.filter { $0.kind == EventKind.rideOffer.rawValue }
        #expect(offers.count == 1)
        #expect(offers.first?.isRoadflare == true)

        // State should transition
        #expect(coordinator.stateMachine.stage == .waitingForAcceptance)
        #expect(coordinator.stateMachine.driverPubkey == driver.publicKeyHex)
        #expect(coordinator.pickupLocation?.latitude == 40.71)
        #expect(coordinator.destinationLocation?.latitude == 40.76)
    }

    @MainActor
    @Test func sendRideOfferPublishesUnifiedOrderedRoadflarePaymentMethods() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator(
            roadflarePaymentMethods: ["venmo-business", "zelle", "cash"]
        )
        let driver = try NostrKeypair.generate()

        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        let pickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let destination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")

        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: pickup,
            destination: destination,
            fareEstimate: fare
        )

        let offer = try #require(fake.publishedEvents.first { $0.kind == EventKind.rideOffer.rawValue })
        let decrypted = try NIP44.decrypt(
            ciphertext: offer.content,
            receiverKeypair: driver,
            senderPublicKeyHex: riderKeypair.publicKeyHex
        )
        let parsed = try JSONDecoder().decode(RideOfferContent.self, from: Data(decrypted.utf8))

        #expect(parsed.paymentMethod == "venmo-business")
        #expect(parsed.fiatPaymentMethods == ["venmo-business", "zelle", "cash"])
        #expect(coordinator.selectedPaymentMethod == "venmo-business")
    }

    @MainActor
    @Test func sendRideOfferPersistsWaitingForAcceptanceState() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        let pickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let destination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")

        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: pickup, destination: destination,
            fareEstimate: fare
        )

        let loaded = RideStatePersistence.load()
        #expect(loaded?.stage == "waitingForAcceptance")
        #expect(loaded?.confirmationEventId == nil)
        #expect(loaded?.driverPubkey == driver.publicKeyHex)
    }

    @MainActor
    @Test func waitingForAcceptanceTimeoutMatchesOfferLifetimeRatherThanTwoMinuteFallback() async throws {
        let (coordinator, _, _) = try await makeCoordinator(
            stageTimeouts: .init(waitingForAcceptance: 0.2, driverAccepted: 30)
        )
        let driver = try NostrKeypair.generate()

        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: Location(latitude: 40.71, longitude: -74.01),
            destination: Location(latitude: 40.76, longitude: -73.98),
            fareEstimate: FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        )

        let expired = await eventually(timeout: .seconds(1)) {
            coordinator.stateMachine.stage == .idle
        }
        #expect(expired)
        #expect(RideStatePersistence.load() == nil)
    }

    @MainActor
    @Test func waitingForAcceptanceTimesOutUsingDriverVisibilityWindow() async throws {
        let (coordinator, fake, _) = try await makeCoordinator(
            stageTimeouts: .init(waitingForAcceptance: 0.05, driverAccepted: 5)
        )
        let driver = try NostrKeypair.generate()

        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        let pickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let destination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")

        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: pickup,
            destination: destination,
            fareEstimate: fare
        )

        let expired = await eventually(timeout: .seconds(1)) {
            coordinator.stateMachine.stage == .idle
        }
        #expect(expired)
        #expect(RideStatePersistence.load() == nil)
        #expect(coordinator.lastError == "Ride request expired before a driver responded.")
        #expect(fake.publishedEvents.contains { $0.kind == EventKind.deletion.rawValue })
    }

    // MARK: - Cancel Ride

    @MainActor
    @Test func cancelRidePublishesEventAndResetsState() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        // Set up a ride in progress
        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )
        _ = try coordinator.stateMachine.handleAcceptance(acceptanceEventId: "acc1")
        try coordinator.stateMachine.recordConfirmation(confirmationEventId: "conf1")

        await coordinator.cancelRide(reason: "Changed plans")

        // Should have published Kind 3179
        let cancels = fake.publishedEvents.filter { $0.kind == EventKind.cancellation.rawValue }
        #expect(cancels.count == 1)

        // State should be reset
        #expect(coordinator.stateMachine.stage == .idle)
        #expect(coordinator.chat.chatMessages.isEmpty)
    }

    @MainActor
    @Test func cancelRideWithoutConfirmationStillResets() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()

        // Start ride but don't get to confirmation
        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: "d1",
            paymentMethod: nil, fiatPaymentMethods: []
        )

        await coordinator.cancelRide(reason: "No response")

        // No cancellation published (no confirmationEventId)
        let cancels = fake.publishedEvents.filter { $0.kind == EventKind.cancellation.rawValue }
        #expect(cancels.isEmpty)

        // But state should still reset
        #expect(coordinator.stateMachine.stage == .idle)
    }

    @MainActor
    @Test func restoreDriverAcceptedWithoutConfirmationId() async throws {
        let keypair = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let sm = RideStateMachine()
        sm.restore(
            stage: .driverAccepted,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: nil,
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinAttempts: 2,
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        RideStatePersistence.save(
            stateMachine: sm,
            pickupLocation: Location(latitude: 40.71, longitude: -74.01),
            destinationLocation: Location(latitude: 40.76, longitude: -73.98),
            fareEstimate: FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50),
            paymentMethod: "zelle"
        )

        let (coordinator, _, _) = try await makeCoordinator(
            keypair: keypair,
            clearRidePersistence: false
        )
        #expect(coordinator.stateMachine.stage == .driverAccepted)
        #expect(coordinator.stateMachine.confirmationEventId == nil)
        #expect(coordinator.stateMachine.pinAttempts == 2)
        RideStatePersistence.clear()
    }

    @MainActor
    @Test func restoreLiveSubscriptionsRetriesConfirmationForDriverAcceptedRide() async throws {
        let keypair = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let sm = RideStateMachine()
        sm.restore(
            stage: .driverAccepted,
            offerEventId: "o1",
            acceptanceEventId: "acc1",
            confirmationEventId: nil,
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinAttempts: 1,
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        RideStatePersistence.save(
            stateMachine: sm,
            pickupLocation: Location(latitude: 40.71, longitude: -74.01),
            destinationLocation: Location(latitude: 40.76, longitude: -73.98),
            fareEstimate: FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50),
            paymentMethod: "zelle"
        )

        let (coordinator, fake, _) = try await makeCoordinator(
            keypair: keypair,
            keepSubscriptionsAlive: true,
            clearRidePersistence: false
        )
        fake.resetRecording()

        await coordinator.restoreLiveSubscriptions()

        let confirmations = fake.publishedEvents.filter { $0.kind == EventKind.rideConfirmation.rawValue }
        #expect(confirmations.count == 1)
        #expect(coordinator.stateMachine.stage == .rideConfirmed)
        #expect(coordinator.stateMachine.confirmationEventId != nil)
        await coordinator.stopAll()
        RideStatePersistence.clear()
    }

    @MainActor
    @Test func restoreLiveSubscriptionsReusesExistingConfirmationBeforeRepublishing() async throws {
        let keypair = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let sm = RideStateMachine()
        sm.restore(
            stage: .driverAccepted,
            offerEventId: "o1",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: nil,
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinAttempts: 1,
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        RideStatePersistence.save(
            stateMachine: sm,
            pickupLocation: Location(latitude: 40.71, longitude: -74.01),
            destinationLocation: Location(latitude: 40.76, longitude: -73.98),
            fareEstimate: FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50),
            paymentMethod: "zelle"
        )

        let confirmationEvent = try await RideshareEventBuilder.rideConfirmation(
            driverPubkey: driver.publicKeyHex,
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            keypair: keypair
        )

        let (coordinator, fake, _) = try await makeCoordinator(
            keypair: keypair,
            keepSubscriptionsAlive: true,
            clearRidePersistence: false
        )
        fake.fetchResults = [confirmationEvent]
        fake.resetRecording()

        await coordinator.restoreLiveSubscriptions()

        let confirmations = fake.publishedEvents.filter { $0.kind == EventKind.rideConfirmation.rawValue }
        #expect(confirmations.isEmpty)
        #expect(coordinator.stateMachine.stage == .rideConfirmed)
        #expect(coordinator.stateMachine.confirmationEventId == confirmationEvent.id)
        #expect(coordinator.stateMachine.precisePickupShared)
        await coordinator.stopAll()
        RideStatePersistence.clear()
    }

    @MainActor
    @Test func restoreLiveSubscriptionsRestoresWaitingAcceptanceRide() async throws {
        let keypair = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let sm = RideStateMachine()
        sm.restore(
            stage: .waitingForAcceptance,
            offerEventId: "o1",
            acceptanceEventId: nil,
            confirmationEventId: nil,
            driverPubkey: driver.publicKeyHex,
            pin: nil,
            pinAttempts: 0,
            pinVerified: false,
            paymentMethod: nil,
            fiatPaymentMethods: []
        )
        RideStatePersistence.save(
            stateMachine: sm,
            pickupLocation: nil,
            destinationLocation: nil,
            fareEstimate: nil,
            paymentMethod: nil
        )

        let (coordinator, fake, _) = try await makeCoordinator(
            keypair: keypair,
            keepSubscriptionsAlive: true,
            clearRidePersistence: false
        )
        await coordinator.restoreLiveSubscriptions()

        let didSubscribe = await eventually {
            fake.subscribeCalls.contains {
                $0.filter.kinds?.contains(EventKind.rideAcceptance.rawValue) == true
            }
        }
        #expect(didSubscribe)
        let acceptanceSubs = fake.subscribeCalls.filter { $0.filter.kinds?.contains(EventKind.rideAcceptance.rawValue) == true }
        #expect(acceptanceSubs.count == 1)
        #expect(acceptanceSubs.first?.filter.tagFilters["e"]?.contains("o1") == true)
        await coordinator.stopAll()
        RideStatePersistence.clear()
    }

    @MainActor
    @Test func restoreLiveSubscriptionsChecksForStaleKeys() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()
        let roadflareKey = try NostrKeypair.generate()

        coordinator.driversRepository.addDriver(
            FollowedDriver(
                pubkey: driver.publicKeyHex,
                roadflareKey: RoadflareKey(
                    privateKeyHex: roadflareKey.privateKeyHex,
                    publicKeyHex: roadflareKey.publicKeyHex,
                    version: 1,
                    keyUpdatedAt: 100
                )
            )
        )

        await coordinator.restoreLiveSubscriptions()

        let didFetchDriverState = await eventually {
            fake.fetchCalls.contains {
                $0.filter.kinds?.contains(EventKind.driverRoadflareState.rawValue) == true
            }
        }
        #expect(didFetchDriverState)
    }

    @MainActor
    @Test func acceptanceSubscriptionIgnoresMalformedEventAndProcessesLaterValidAcceptance() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator(keepSubscriptionsAlive: true)
        let driver = try NostrKeypair.generate()

        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        let pickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let destination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: pickup,
            destination: destination,
            fareEstimate: fare
        )

        let offerEventId = try #require(coordinator.stateMachine.offerEventId)
        let acceptanceSubId = "acceptance-\(offerEventId)"
        let didSubscribe = await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue == acceptanceSubId }
        }
        #expect(didSubscribe)

        let malformed = NostrEvent(
            id: "acc-bad",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.rideAcceptance.rawValue,
            tags: [["e", offerEventId], ["p", riderKeypair.publicKeyHex]],
            content: "not-json",
            sig: "sig"
        )
        #expect(fake.injectEvent(malformed, subscriptionId: acceptanceSubId))

        let valid = NostrEvent(
            id: "acc-good",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.rideAcceptance.rawValue,
            tags: [["e", offerEventId], ["p", riderKeypair.publicKeyHex]],
            content: #"{"status":"accepted"}"#,
            sig: "sig"
        )
        #expect(fake.injectEvent(valid, subscriptionId: acceptanceSubId))

        let confirmed = await eventually {
            coordinator.stateMachine.stage == .rideConfirmed
        }
        #expect(confirmed)
        await coordinator.stopAll()
    }

    @MainActor
    @Test func acceptanceSubscriptionIgnoresWrongRecipientAndProcessesLaterValidAcceptance() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator(keepSubscriptionsAlive: true)
        let wrongRider = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()

        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        let pickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let destination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: pickup,
            destination: destination,
            fareEstimate: fare
        )

        let offerEventId = try #require(coordinator.stateMachine.offerEventId)
        let acceptanceSubId = "acceptance-\(offerEventId)"
        let didSubscribe = await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue == acceptanceSubId }
        }
        #expect(didSubscribe)

        let wrongRecipient = NostrEvent(
            id: "acc-wrong-rider",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.rideAcceptance.rawValue,
            tags: [["e", offerEventId], ["p", wrongRider.publicKeyHex]],
            content: #"{"status":"accepted"}"#,
            sig: "sig"
        )
        #expect(fake.injectEvent(wrongRecipient, subscriptionId: acceptanceSubId))

        try? await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.stateMachine.stage == .waitingForAcceptance)

        let valid = NostrEvent(
            id: "acc-right-rider",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.rideAcceptance.rawValue,
            tags: [["e", offerEventId], ["p", riderKeypair.publicKeyHex]],
            content: #"{"status":"accepted"}"#,
            sig: "sig"
        )
        #expect(fake.injectEvent(valid, subscriptionId: acceptanceSubId))

        let confirmed = await eventually {
            coordinator.stateMachine.stage == .rideConfirmed
        }
        #expect(confirmed)
        await coordinator.stopAll()
    }

    @MainActor
    @Test func acceptanceHandlingRetriesConfirmationAfterTransientPublishFailure() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator(keepSubscriptionsAlive: true)
        let driver = try NostrKeypair.generate()

        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        let pickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let destination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: pickup,
            destination: destination,
            fareEstimate: fare
        )

        let offerEventId = try #require(coordinator.stateMachine.offerEventId)
        let acceptanceSubId = "acceptance-\(offerEventId)"
        let didSubscribe = await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue == acceptanceSubId }
        }
        #expect(didSubscribe)

        fake.shouldFailPublish = true
        let acceptance = NostrEvent(
            id: "acc-retry",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.rideAcceptance.rawValue,
            tags: [["e", offerEventId], ["p", riderKeypair.publicKeyHex]],
            content: #"{"status":"accepted"}"#,
            sig: "sig"
        )
        #expect(fake.injectEvent(acceptance, subscriptionId: acceptanceSubId))

        try? await Task.sleep(for: .milliseconds(200))
        fake.shouldFailPublish = false

        let confirmed = await eventually(timeout: .seconds(5), pollInterval: .milliseconds(50)) {
            coordinator.stateMachine.stage == .rideConfirmed
        }
        #expect(confirmed)
        let confirmations = fake.publishedEvents.filter { $0.kind == EventKind.rideConfirmation.rawValue }
        #expect(confirmations.count == 1)
        await coordinator.stopAll()
    }

    @MainActor
    @Test func confirmationRetryStopsAfterDriverAcceptedTimeoutClearsRide() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator(
            keepSubscriptionsAlive: true,
            stageTimeouts: .init(waitingForAcceptance: 900, driverAccepted: 0.2)
        )
        let driver = try NostrKeypair.generate()

        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        let pickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let destination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: pickup,
            destination: destination,
            fareEstimate: fare
        )

        let offerEventId = try #require(coordinator.stateMachine.offerEventId)
        let acceptanceSubId = "acceptance-\(offerEventId)"
        let didSubscribe = await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue == acceptanceSubId }
        }
        #expect(didSubscribe)

        fake.shouldFailPublish = true
        let acceptance = NostrEvent(
            id: "acc-timeout",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.rideAcceptance.rawValue,
            tags: [["e", offerEventId], ["p", riderKeypair.publicKeyHex]],
            content: #"{"status":"accepted"}"#,
            sig: "sig"
        )
        #expect(fake.injectEvent(acceptance, subscriptionId: acceptanceSubId))

        try? await Task.sleep(for: .milliseconds(100))
        fake.shouldFailPublish = false

        let expired = await eventually(timeout: .seconds(1)) {
            coordinator.stateMachine.stage == .idle
        }
        #expect(expired)
        let confirmations = fake.publishedEvents.filter { $0.kind == EventKind.rideConfirmation.rawValue }
        #expect(confirmations.isEmpty)
        #expect(RideStatePersistence.load() == nil)
        await coordinator.stopAll()
    }

    @MainActor
    @Test func driverAcceptedTimesOutUsingDriverConfirmationWindow() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator(
            keepSubscriptionsAlive: true,
            stageTimeouts: .init(waitingForAcceptance: 5, driverAccepted: 0.05)
        )
        let driver = try NostrKeypair.generate()

        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        let pickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let destination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: pickup,
            destination: destination,
            fareEstimate: fare
        )

        let offerEventId = try #require(coordinator.stateMachine.offerEventId)
        let acceptanceSubId = "acceptance-\(offerEventId)"
        let didSubscribe = await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue == acceptanceSubId }
        }
        #expect(didSubscribe)

        fake.shouldFailPublish = true
        let acceptance = NostrEvent(
            id: "acc-timeout",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.rideAcceptance.rawValue,
            tags: [["e", offerEventId], ["p", riderKeypair.publicKeyHex]],
            content: #"{"status":"accepted"}"#,
            sig: "sig"
        )
        #expect(fake.injectEvent(acceptance, subscriptionId: acceptanceSubId))

        let expired = await eventually(timeout: .seconds(1)) {
            coordinator.stateMachine.stage == .idle
        }
        #expect(expired)
        #expect(RideStatePersistence.load() == nil)
        #expect(coordinator.lastError == "Ride request expired before confirmation completed.")
        let confirmations = fake.publishedEvents.filter { $0.kind == EventKind.rideConfirmation.rawValue }
        #expect(confirmations.isEmpty)
        await coordinator.stopAll()
    }

    @MainActor
    @Test func cancellationRequiresExpectedDriverAndConfirmation() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator(keepSubscriptionsAlive: true)
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        await coordinator.handleAcceptance(acceptanceEventId: "acc1", driverPubkey: driver.publicKeyHex)
        let confirmationEventId = try #require(coordinator.stateMachine.confirmationEventId)
        fake.resetRecording()

        let otherDriver = try NostrKeypair.generate()
        let wrongSender = try await RideshareEventBuilder.cancellation(
            counterpartyPubkey: riderKeypair.publicKeyHex,
            confirmationEventId: confirmationEventId,
            reason: "spoof",
            keypair: otherDriver
        )
        _ = fake.injectEvent(wrongSender, subscriptionId: "cancel-\(confirmationEventId)")
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.stateMachine.stage == .rideConfirmed)

        let wrongConfirmation = try await RideshareEventBuilder.cancellation(
            counterpartyPubkey: riderKeypair.publicKeyHex,
            confirmationEventId: rideCoordinatorWrongConfirmationEventId,
            reason: "spoof",
            keypair: driver
        )
        _ = fake.injectEvent(wrongConfirmation, subscriptionId: "cancel-\(confirmationEventId)")
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.stateMachine.stage == .rideConfirmed)

        let valid = try await RideshareEventBuilder.cancellation(
            counterpartyPubkey: riderKeypair.publicKeyHex,
            confirmationEventId: confirmationEventId,
            reason: "changed plans",
            keypair: driver
        )
        _ = fake.injectEvent(valid, subscriptionId: "cancel-\(confirmationEventId)")
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.stateMachine.stage == .idle)
        #expect(coordinator.currentFareEstimate == nil)
        #expect(coordinator.pickupLocation == nil)
        #expect(coordinator.destinationLocation == nil)
        await coordinator.stopAll()
    }

    // MARK: - Send Chat

    @MainActor
    @Test func sendChatMessagePublishesAndAddsToLocal() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        // Setup active ride
        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: nil, fiatPaymentMethods: []
        )
        _ = try coordinator.stateMachine.handleAcceptance(acceptanceEventId: "acc1")
        try coordinator.stateMachine.recordConfirmation(confirmationEventId: "conf1")

        await coordinator.sendChatMessage("On my way out!")

        let chats = fake.publishedEvents.filter { $0.kind == EventKind.chatMessage.rawValue }
        #expect(chats.count == 1)
        #expect(coordinator.chat.chatMessages.count == 1)
        #expect(coordinator.chat.chatMessages.first?.text == "On my way out!")
        #expect(coordinator.chat.chatMessages.first?.isMine == true)
    }

    // MARK: - Publish Followed Drivers List

    @MainActor
    @Test func publishFollowedDriversListIncludesPTags() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()

        coordinator.driversRepository.addDriver(FollowedDriver(pubkey: "d1", name: "Alice"))
        coordinator.driversRepository.addDriver(FollowedDriver(pubkey: "d2", name: "Bob"))

        await coordinator.publishFollowedDriversList()

        let lists = fake.publishedEvents.filter { $0.kind == EventKind.followedDriversList.rawValue }
        #expect(lists.count == 1)
        #expect(lists.first?.referencedPubkeys.contains("d1") == true)
        #expect(lists.first?.referencedPubkeys.contains("d2") == true)
    }

    // MARK: - Ride Completion Saves History

    @MainActor
    @Test func rideCompletionSavesToHistory() async throws {
        let (coordinator, _, _) = try await makeCoordinator()

        coordinator.stateMachine.restore(
            stage: .inProgress, offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: "d1",
            pin: "1234", pinVerified: true,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01, address: "Penn")
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)

        await coordinator.handleRideCompletion()

        // History should have the ride
        // (rideHistory is private, but we can check indirectly via the store)
        // For now, just verify the method doesn't crash
        #expect(coordinator.stateMachine.stage == .inProgress)  // Not reset by handleRideCompletion
    }

    @MainActor
    @Test func activeRidePaymentMethodsPreferRideSnapshotOverCurrentSettings() async throws {
        let (coordinator, _, _) = try await makeCoordinator(
            roadflarePaymentMethods: ["cash"]
        )

        coordinator.stateMachine.restore(
            stage: .inProgress, offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: "d1",
            pin: "1234", pinVerified: true,
            paymentMethod: "venmo-business",
            fiatPaymentMethods: ["venmo-business", "zelle"]
        )

        #expect(coordinator.activeRidePaymentMethods == ["venmo-business", "zelle"])
    }

    @MainActor
    @Test func completedDriverStateClearsPersistenceAfterSavingHistory() async throws {
        RideStatePersistence.clear()
        let keypair = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let fake = FakeRelayManager()
        try await fake.connect(to: DefaultRelays.all)

        let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        let settings = UserSettings(defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!)
        settings.togglePaymentMethod(.zelle)
        let history = RideHistoryStore(defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!)
        let bitcoinPrice = BitcoinPriceService()
        bitcoinPrice.btcPriceUsdForTesting = 100_000

        let coordinator = RideCoordinator(
            relayManager: fake,
            keypair: keypair,
            driversRepository: repo,
            settings: settings,
            rideHistory: history,
            bitcoinPrice: bitcoinPrice
        )
        coordinator.stateMachine.restore(
            stage: .inProgress,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "conf1",
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinAttempts: 1,
            pinVerified: true,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        coordinator.selectedPaymentMethod = "zelle"
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01, address: "Penn")
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 12.50)
        coordinator.persistRideState()

        let completedEvent = NostrEvent(
            id: "ds-completed",
            pubkey: driver.publicKeyHex,
            createdAt: 300,
            kind: EventKind.driverRideState.rawValue,
            tags: [["d", "conf1"], ["e", "conf1"], ["p", keypair.publicKeyHex]],
            content: """
            {"current_status":"completed","history":[{"action":"status","at":300,"status":"completed","approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null}]}
            """,
            sig: "sig"
        )

        await coordinator.handleDriverStateEvent(completedEvent, confirmationEventId: "conf1")

        #expect(RideStatePersistence.load() == nil)
        #expect(history.rides.count == 1)
        #expect(history.rides.first?.id == "conf1")
        #expect(coordinator.stateMachine.stage == .completed)
        RideStatePersistence.clear()
    }

    @MainActor
    @Test func cancelRideAfterCompletionDoesNotPublishCancellation() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()

        coordinator.stateMachine.restore(
            stage: .completed, offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: "d1",
            pin: "1234", pinVerified: true,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )

        await coordinator.cancelRide()

        let cancellations = fake.publishedEvents.filter { $0.kind == EventKind.cancellation.rawValue }
        #expect(cancellations.isEmpty)
        #expect(coordinator.stateMachine.stage == .idle)
    }

    // MARK: - Location Event Handling

    @MainActor
    @Test func handleLocationEventUpdatesRepository() async throws {
        let (coordinator, _, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()
        let roadflareKey = try NostrKeypair.generate()

        // Add driver with key
        coordinator.driversRepository.addDriver(FollowedDriver(
            pubkey: driver.publicKeyHex,
            roadflareKey: RoadflareKey(
                privateKeyHex: roadflareKey.privateKeyHex,
                publicKeyHex: roadflareKey.publicKeyHex,
                version: 1
            )
        ))

        // Build location broadcast (encrypted to roadflare pubkey)
        let locJSON = "{\"lat\":36.17,\"lon\":-115.14,\"timestamp\":1700000100,\"status\":\"online\"}"
        let encrypted = try NIP44.encrypt(
            plaintext: locJSON,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: roadflareKey.publicKeyHex
        )
        let event = NostrEvent(
            id: "loc1", pubkey: driver.publicKeyHex,
            createdAt: 1700000100,
            kind: EventKind.roadflareLocation.rawValue,
            tags: [["d", "roadflare-location"], ["status", "online"], ["key_version", "1"]],
            content: encrypted, sig: "sig"
        )

        await coordinator.location.handleLocationEvent(event)

        let cached = coordinator.driversRepository.driverLocations[driver.publicKeyHex]
        #expect(cached?.latitude == 36.17)
        #expect(cached?.status == "online")
    }

    @MainActor
    @Test func handleLocationEventIgnoresDriverWithoutKey() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        // Add driver WITHOUT key
        coordinator.driversRepository.addDriver(FollowedDriver(pubkey: driver.publicKeyHex))

        let event = NostrEvent(
            id: "loc1", pubkey: driver.publicKeyHex,
            createdAt: 1700000100,
            kind: EventKind.roadflareLocation.rawValue,
            tags: [], content: "encrypted", sig: "sig"
        )

        await coordinator.location.handleLocationEvent(event)

        // No location update (no key to decrypt)
        #expect(coordinator.driversRepository.driverLocations[driver.publicKeyHex] == nil)
    }

    // MARK: - Subscription Wiring Verification
    // These tests verify that the coordinator subscribes to the RIGHT events
    // with the RIGHT filters — catching wiring bugs where the wrong kind/tag is used.

    @MainActor
    @Test func sendOfferSubscribesToAcceptanceWithCorrectFilter() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        let fare = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 10.0)
        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: Location(latitude: 40.71, longitude: -74.01),
            destination: Location(latitude: 40.76, longitude: -73.98),
            fareEstimate: fare
        )

        let didSubscribe = await eventually {
            fake.subscribeCalls.contains {
                $0.filter.kinds?.contains(EventKind.rideAcceptance.rawValue) == true
            }
        }
        #expect(didSubscribe)
        // Find the acceptance subscription
        let acceptanceSubs = fake.subscribeCalls.filter { sub in
            sub.filter.kinds?.contains(EventKind.rideAcceptance.rawValue) == true
        }
        #expect(acceptanceSubs.count == 1)

        // Verify the filter uses e-tag with the offer event ID
        let offerEventId = coordinator.stateMachine.offerEventId!
        #expect(acceptanceSubs.first?.filter.tagFilters["e"]?.contains(offerEventId) == true)
        #expect(acceptanceSubs.first?.filter.tagFilters["p"] == [riderKeypair.publicKeyHex])
        #expect(acceptanceSubs.first?.filter.authors == [driver.publicKeyHex])
    }

    @MainActor
    @Test func acceptanceTriggersDriverStateChatCancellationSubscriptions() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        // Setup: start ride and simulate acceptance handling
        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)

        fake.resetRecording()  // Clear offer publish calls
        await coordinator.handleAcceptance(acceptanceEventId: "acc1", driverPubkey: driver.publicKeyHex)

        // Should have published Kind 3175 confirmation
        let confirmations = fake.publishedEvents.filter { $0.kind == EventKind.rideConfirmation.rawValue }
        #expect(confirmations.count == 1)

        let didSubscribeAll = await eventually {
            let subscribeCalls = fake.subscribeCalls
            let hasDriverState = subscribeCalls.contains {
                $0.filter.kinds?.contains(EventKind.driverRideState.rawValue) == true
            }
            let hasChat = subscribeCalls.contains {
                $0.filter.kinds?.contains(EventKind.chatMessage.rawValue) == true
            }
            let hasCancel = subscribeCalls.contains {
                $0.filter.kinds?.contains(EventKind.cancellation.rawValue) == true
            }
            return hasDriverState && hasChat && hasCancel
        }
        #expect(didSubscribeAll)

        // Should have subscribed to 3 event types
        // Driver state (Kind 30180)
        let driverStateSubs = fake.subscribeCalls.filter { $0.filter.kinds?.contains(EventKind.driverRideState.rawValue) == true }
        #expect(driverStateSubs.count == 1)
        // Verify d-tag matches confirmation event ID
        let confEventId = coordinator.stateMachine.confirmationEventId!
        #expect(driverStateSubs.first?.filter.tagFilters["d"]?.contains(confEventId) == true)
        // Verify author filter is the driver
        #expect(driverStateSubs.first?.filter.authors?.contains(driver.publicKeyHex) == true)

        // Chat (Kind 3178)
        let chatSubs = fake.subscribeCalls.filter { $0.filter.kinds?.contains(EventKind.chatMessage.rawValue) == true }
        #expect(chatSubs.count == 1)
        // Verify author filter is the driver (counterparty)
        #expect(chatSubs.first?.filter.authors?.contains(driver.publicKeyHex) == true)
        // Verify e-tag scopes chat to the current ride
        #expect(chatSubs.first?.filter.tagFilters["e"]?.contains(confEventId) == true)

        // Cancellation (Kind 3179)
        let cancelSubs = fake.subscribeCalls.filter { $0.filter.kinds?.contains(EventKind.cancellation.rawValue) == true }
        #expect(cancelSubs.count == 1)
        // Verify p-tag is the rider's pubkey (cancellation addressed to us)
        #expect(cancelSubs.first?.filter.tagFilters["p"]?.contains(riderKeypair.publicKeyHex) == true)
    }

    @MainActor
    @Test func startKeyShareSubscriptionUsesCorrectFilter() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()

        coordinator.startKeyShareSubscription()
        let didSubscribe = await eventually {
            fake.subscribeCalls.contains {
                $0.filter.kinds?.contains(EventKind.keyShare.rawValue) == true
            }
        }
        #expect(didSubscribe)

        let keyShareSubs = fake.subscribeCalls.filter { $0.filter.kinds?.contains(EventKind.keyShare.rawValue) == true }
        #expect(keyShareSubs.count == 1)
        // Must filter by our pubkey in p-tag
        #expect(keyShareSubs.first?.filter.tagFilters["p"]?.contains(riderKeypair.publicKeyHex) == true)
    }

    @MainActor
    @Test func startLocationSubscriptionsUsesCorrectFilter() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()

        coordinator.driversRepository.addDriver(FollowedDriver(pubkey: "d1"))
        coordinator.driversRepository.addDriver(FollowedDriver(pubkey: "d2"))

        coordinator.startLocationSubscriptions()
        let didSubscribe = await eventually {
            fake.subscribeCalls.contains {
                $0.filter.kinds?.contains(EventKind.roadflareLocation.rawValue) == true
            }
        }
        #expect(didSubscribe)

        let locSubs = fake.subscribeCalls.filter { $0.filter.kinds?.contains(EventKind.roadflareLocation.rawValue) == true }
        #expect(locSubs.count == 1)
        // Must filter by all followed driver pubkeys
        #expect(locSubs.first?.filter.authors?.contains("d1") == true)
        #expect(locSubs.first?.filter.authors?.contains("d2") == true)
        // Must include d-tag for replaceable event
        #expect(locSubs.first?.filter.tagFilters["d"]?.contains("roadflare-location") == true)
    }

    @MainActor
    @Test func startLocationSubscriptionsSkipsWhenNoDrivers() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()

        // No drivers added
        coordinator.startLocationSubscriptions()
        try await Task.sleep(for: .milliseconds(100))

        let locSubs = fake.subscribeCalls.filter { $0.filter.kinds?.contains(EventKind.roadflareLocation.rawValue) == true }
        #expect(locSubs.isEmpty)  // No subscription when no drivers
    }

    @MainActor
    @Test func startLocationSubscriptionsUnsubscribesWhenDriverListBecomesEmpty() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()

        coordinator.driversRepository.addDriver(FollowedDriver(pubkey: "d1"))
        coordinator.startLocationSubscriptions()

        let didSubscribe = await eventually {
            fake.subscribeCalls.contains {
                $0.filter.kinds?.contains(EventKind.roadflareLocation.rawValue) == true
            }
        }
        #expect(didSubscribe)

        coordinator.driversRepository.removeDriver(pubkey: "d1")
        coordinator.startLocationSubscriptions()

        let didUnsubscribe = await eventually {
            fake.unsubscribeCalls.contains { $0.rawValue == "roadflare-locations" }
        }
        #expect(didUnsubscribe)

        let locSubs = fake.subscribeCalls.filter {
            $0.filter.kinds?.contains(EventKind.roadflareLocation.rawValue) == true
        }
        #expect(locSubs.count == 1)
    }

    // MARK: - handleAcceptance Full Side Effects

    @MainActor
    @Test func handleAcceptancePublishesConfirmationWithPrecisePickup() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )
        coordinator.pickupLocation = Location(latitude: 40.71234, longitude: -74.00567, address: "Penn Station")

        await coordinator.handleAcceptance(acceptanceEventId: "acc1", driverPubkey: driver.publicKeyHex)

        let confs = fake.publishedEvents.filter { $0.kind == EventKind.rideConfirmation.rawValue }
        #expect(confs.count == 1)
        #expect(coordinator.stateMachine.precisePickupShared)
        #expect(coordinator.stateMachine.stage == .rideConfirmed)
        #expect(coordinator.stateMachine.pin != nil)
        #expect(coordinator.stateMachine.pin?.count == 4)
    }

    @MainActor
    @Test func handleAcceptancePersistsState() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: nil, fiatPaymentMethods: []
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        await coordinator.handleAcceptance(acceptanceEventId: "acc1", driverPubkey: driver.publicKeyHex)

        let loaded = RideStatePersistence.load()
        #expect(loaded?.stage == "rideConfirmed")
        #expect(loaded?.pin != nil)
        #expect(loaded?.driverPubkey == driver.publicKeyHex)
        RideStatePersistence.clear()
    }

    @MainActor
    @Test func handleAcceptancePersistsDriverAcceptedBeforeConfirmationPublish() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: Location(latitude: 40.71, longitude: -74.01),
            destination: Location(latitude: 40.76, longitude: -73.98),
            fareEstimate: FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 10.0)
        )
        fake.shouldFailPublish = true

        await coordinator.handleAcceptance(acceptanceEventId: "acc1", driverPubkey: driver.publicKeyHex)

        let loaded = RideStatePersistence.load()
        #expect(loaded?.stage == "driverAccepted")
        #expect(loaded?.confirmationEventId == nil)
        #expect(coordinator.stateMachine.stage == .driverAccepted)
        RideStatePersistence.clear()
    }

    @MainActor
    @Test func handleAcceptanceWithoutPickupDoesNotPublishMalformedConfirmation() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1",
            driverPubkey: driver.publicKeyHex,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )

        await coordinator.handleAcceptance(acceptanceEventId: "acc1", driverPubkey: driver.publicKeyHex)

        let confirmations = fake.publishedEvents.filter { $0.kind == EventKind.rideConfirmation.rawValue }
        #expect(confirmations.isEmpty)
        #expect(coordinator.stateMachine.stage == .driverAccepted)
        #expect(coordinator.stateMachine.confirmationEventId == nil)
        #expect(coordinator.lastError?.contains("precise pickup") == true)
        RideStatePersistence.clear()
    }

    @MainActor
    @Test func acceptanceReplayDuringInFlightConfirmationOnlyPublishesOneConfirmation() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1",
            driverPubkey: driver.publicKeyHex,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)
        fake.publishDelay = .milliseconds(150)

        let firstAcceptance = Task { @MainActor in
            await coordinator.handleAcceptance(
                acceptanceEventId: "acc1",
                driverPubkey: driver.publicKeyHex
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        await coordinator.handleAcceptance(
            acceptanceEventId: "acc1",
            driverPubkey: driver.publicKeyHex
        )
        await firstAcceptance.value

        let confirmations = fake.publishedEvents.filter { $0.kind == EventKind.rideConfirmation.rawValue }
        #expect(confirmations.count == 1)
        #expect(coordinator.stateMachine.stage == .rideConfirmed)
        #expect(coordinator.stateMachine.confirmationEventId != nil)
        RideStatePersistence.clear()
    }

    // MARK: - handleDriverStateEvent Full Side Effects

    @MainActor
    @Test func handleDriverStateArrivedTransitionsStage() async throws {
        let (coordinator, _, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: nil, fiatPaymentMethods: []
        )
        _ = try coordinator.stateMachine.handleAcceptance(acceptanceEventId: "acc1")
        try coordinator.stateMachine.recordConfirmation(confirmationEventId: "conf1")

        let stateJSON = """
        {"current_status":"arrived","history":[{"action":"status","at":100,"status":"arrived","approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null}]}
        """
        let event = NostrEvent(
            id: "ds1", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.driverRideState.rawValue,
            tags: [["d", "conf1"], ["e", "conf1"], ["p", riderKeypair.publicKeyHex]],
            content: stateJSON,
            sig: "sig"
        )

        await coordinator.handleDriverStateEvent(event, confirmationEventId: "conf1")
        #expect(coordinator.stateMachine.stage == .driverArrived)
    }

    @MainActor
    @Test func handleDriverStateDeduplicate() async throws {
        let (coordinator, _, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: nil, fiatPaymentMethods: []
        )
        _ = try coordinator.stateMachine.handleAcceptance(acceptanceEventId: "acc1")
        try coordinator.stateMachine.recordConfirmation(confirmationEventId: "conf1")

        let event = NostrEvent(
            id: "ds_same", pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.driverRideState.rawValue,
            tags: [["d", "conf1"], ["e", "conf1"], ["p", riderKeypair.publicKeyHex]],
            content: "{\"current_status\":\"arrived\",\"history\":[]}",
            sig: "sig"
        )

        await coordinator.handleDriverStateEvent(event, confirmationEventId: "conf1")
        await coordinator.handleDriverStateEvent(event, confirmationEventId: "conf1")
        #expect(coordinator.stateMachine.stage == .driverArrived)
    }

    @MainActor
    @Test func handleDriverStateIgnoresOlderTimestamps() async throws {
        let (coordinator, _, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: nil, fiatPaymentMethods: []
        )
        _ = try coordinator.stateMachine.handleAcceptance(acceptanceEventId: "acc1")
        try coordinator.stateMachine.recordConfirmation(confirmationEventId: "conf1")

        let inProgress = NostrEvent(
            id: "ds-newer",
            pubkey: driver.publicKeyHex,
            createdAt: 200,
            kind: EventKind.driverRideState.rawValue,
            tags: [["d", "conf1"], ["e", "conf1"], ["p", riderKeypair.publicKeyHex]],
            content: "{\"current_status\":\"in_progress\",\"history\":[]}",
            sig: "sig"
        )
        let arrived = NostrEvent(
            id: "ds-older",
            pubkey: driver.publicKeyHex,
            createdAt: 100,
            kind: EventKind.driverRideState.rawValue,
            tags: [["d", "conf1"], ["e", "conf1"], ["p", riderKeypair.publicKeyHex]],
            content: "{\"current_status\":\"arrived\",\"history\":[]}",
            sig: "sig"
        )

        await coordinator.handleDriverStateEvent(inProgress, confirmationEventId: "conf1")
        await coordinator.handleDriverStateEvent(arrived, confirmationEventId: "conf1")

        #expect(coordinator.stateMachine.stage == .inProgress)
    }

    @MainActor
    @Test func handleDriverStateProcessesSameSecondHistoryExtensionAndDistinctPinActions() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        coordinator.stateMachine.restore(
            stage: .driverArrived,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "conf1",
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinAttempts: 0,
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")

        let wrongPin = try NIP44.encrypt(
            plaintext: "0000",
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )
        let correctPin = try NIP44.encrypt(
            plaintext: "1234",
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )

        let firstEvent = NostrEvent(
            id: "ds-same-second-1",
            pubkey: driver.publicKeyHex,
            createdAt: 2000,
            kind: EventKind.driverRideState.rawValue,
            tags: [["d", "conf1"], ["e", "conf1"], ["p", riderKeypair.publicKeyHex]],
            content: """
            {"current_status":"arrived","history":[{"action":"status","at":100,"status":"arrived","approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null},{"action":"pin_submit","at":500,"status":null,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":"\(wrongPin)"}]}
            """,
            sig: "sig"
        )
        let secondEvent = NostrEvent(
            id: "ds-same-second-2",
            pubkey: driver.publicKeyHex,
            createdAt: 2000,
            kind: EventKind.driverRideState.rawValue,
            tags: [["d", "conf1"], ["e", "conf1"], ["p", riderKeypair.publicKeyHex]],
            content: """
            {"current_status":"arrived","history":[{"action":"status","at":100,"status":"arrived","approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null},{"action":"pin_submit","at":500,"status":null,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":"\(wrongPin)"},{"action":"pin_submit","at":500,"status":null,"approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":"\(correctPin)"}]}
            """,
            sig: "sig"
        )

        await coordinator.handleDriverStateEvent(firstEvent, confirmationEventId: "conf1")
        await coordinator.handleDriverStateEvent(secondEvent, confirmationEventId: "conf1")

        let riderStates = fake.publishedEvents.filter { $0.kind == EventKind.riderRideState.rawValue }
        #expect(riderStates.count == 2)
        #expect(coordinator.stateMachine.pinAttempts == 2)
        #expect(coordinator.stateMachine.pin == nil)
        #expect(coordinator.stateMachine.pinVerified)
        #expect(coordinator.stateMachine.stage == .driverArrived)
        RideStatePersistence.clear()
    }

    @MainActor
    @Test func cancelledDriverStateClearsRideWhenCancellationEventIsMissed() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator(keepSubscriptionsAlive: true)
        let driver = try NostrKeypair.generate()

        coordinator.stateMachine.restore(
            stage: .inProgress,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "conf1",
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinAttempts: 1,
            pinVerified: true,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 3.5, durationMinutes: 14, fareUSD: 11.25)
        coordinator.persistRideState()
        await coordinator.restoreLiveSubscriptions()

        let cancelledEvent = NostrEvent(
            id: "ds-cancelled",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.driverRideState.rawValue,
            tags: [["d", "conf1"], ["e", "conf1"], ["p", riderKeypair.publicKeyHex]],
            content: """
            {"current_status":"cancelled","history":[{"action":"status","at":300,"status":"cancelled","approx_location":null,"final_fare":null,"invoice":null,"pin_encrypted":null}]}
            """,
            sig: "sig"
        )

        await coordinator.handleDriverStateEvent(cancelledEvent, confirmationEventId: "conf1")

        #expect(coordinator.stateMachine.stage == .idle)
        #expect(RideStatePersistence.load() == nil)
        #expect(fake.unsubscribeCalls.contains(SubscriptionID("driver-state-conf1")))
        #expect(fake.unsubscribeCalls.contains(SubscriptionID("cancel-conf1")))
    }

    @MainActor
    @Test func liveChatSubscriptionIgnoresDifferentConfirmationId() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator(keepSubscriptionsAlive: true)
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: nil, fiatPaymentMethods: []
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        await coordinator.handleAcceptance(acceptanceEventId: "acc1", driverPubkey: driver.publicKeyHex)
        let confirmationEventId = try #require(coordinator.stateMachine.confirmationEventId)

        let wrongRideEncrypted = try NIP44.encrypt(
            plaintext: #"{"message":"old ride"}"#,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )
        let wrongRideEvent = NostrEvent(
            id: "chat-old",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.chatMessage.rawValue,
            tags: [["p", riderKeypair.publicKeyHex], ["e", "other-conf"]],
            content: wrongRideEncrypted,
            sig: "sig"
        )
        #expect(fake.injectEvent(wrongRideEvent, subscriptionId: "chat-\(confirmationEventId)"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.chat.chatMessages.isEmpty)

        let validEncrypted = try NIP44.encrypt(
            plaintext: #"{"message":"current ride"}"#,
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )
        let validEvent = NostrEvent(
            id: "chat-current",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.chatMessage.rawValue,
            tags: [["p", riderKeypair.publicKeyHex], ["e", confirmationEventId]],
            content: validEncrypted,
            sig: "sig"
        )
        #expect(fake.injectEvent(validEvent, subscriptionId: "chat-\(confirmationEventId)"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(coordinator.chat.chatMessages.count == 1)
        #expect(coordinator.chat.chatMessages.first?.text == "current ride")
        await coordinator.stopAll()
    }

    // MARK: - handlePinSubmission Full Side Effects

    @MainActor
    @Test func handlePinCorrectPublishesVerifiedAndRevealsDestination() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        coordinator.stateMachine.restore(
            stage: .driverArrived, offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: driver.publicKeyHex,
            pin: "1234", pinVerified: false,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)

        let encryptedPin = try NIP44.encrypt(
            plaintext: "1234",
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )

        await coordinator.handlePinSubmission(
            pinEncrypted: encryptedPin,
            driverPubkey: driver.publicKeyHex,
            confirmationEventId: "conf1"
        )

        #expect(coordinator.stateMachine.pin == nil)
        #expect(coordinator.stateMachine.pinVerified)
        #expect(coordinator.stateMachine.preciseDestinationShared)
        #expect(coordinator.stateMachine.stage == .driverArrived)
        let riderStates = fake.publishedEvents.filter { $0.kind == EventKind.riderRideState.rawValue }
        #expect(riderStates.count == 1)
        #expect(coordinator.stateMachine.riderStateHistory.count == 2)
    }

    @MainActor
    @Test func handlePinWrongDoesNotRevealDestination() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        coordinator.stateMachine.restore(
            stage: .driverArrived, offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: driver.publicKeyHex,
            pin: "1234", pinVerified: false,
            paymentMethod: nil, fiatPaymentMethods: []
        )

        let encryptedPin = try NIP44.encrypt(
            plaintext: "9999",
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )

        await coordinator.handlePinSubmission(
            pinEncrypted: encryptedPin,
            driverPubkey: driver.publicKeyHex,
            confirmationEventId: "conf1"
        )

        #expect(!coordinator.stateMachine.pinVerified)
        #expect(!coordinator.stateMachine.preciseDestinationShared)
        #expect(coordinator.stateMachine.riderStateHistory.count == 1)
        #expect(coordinator.stateMachine.riderStateHistory[0].status == "rejected")
    }

    @MainActor
    @Test func handlePinIgnoresDuplicateSubmissionAfterVerification() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        coordinator.stateMachine.restore(
            stage: .driverArrived, offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: driver.publicKeyHex,
            pin: "1234", pinVerified: false,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)

        let encryptedPin = try NIP44.encrypt(
            plaintext: "1234",
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )

        await coordinator.handlePinSubmission(
            pinEncrypted: encryptedPin,
            driverPubkey: driver.publicKeyHex,
            confirmationEventId: "conf1"
        )
        await coordinator.handlePinSubmission(
            pinEncrypted: encryptedPin,
            driverPubkey: driver.publicKeyHex,
            confirmationEventId: "conf1"
        )

        let riderStates = fake.publishedEvents.filter { $0.kind == EventKind.riderRideState.rawValue }
        #expect(riderStates.count == 1)
        #expect(coordinator.stateMachine.riderStateHistory.count == 2)
        #expect(coordinator.stateMachine.preciseDestinationShared)
    }

    @MainActor
    @Test func handlePinDoesNotPublishAfterRideIsCancelledDuringVerificationDelay() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        coordinator.stateMachine.restore(
            stage: .driverArrived, offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: driver.publicKeyHex,
            pin: "1234", pinVerified: false,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)

        let encryptedPin = try NIP44.encrypt(
            plaintext: "1234",
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )

        let verificationTask = Task {
            await coordinator.handlePinSubmission(
                pinEncrypted: encryptedPin,
                driverPubkey: driver.publicKeyHex,
                confirmationEventId: "conf1"
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        await coordinator.cancelRide(reason: "Cancelled during PIN verification")
        await verificationTask.value

        let riderStates = fake.publishedEvents.filter { $0.kind == EventKind.riderRideState.rawValue }
        #expect(riderStates.isEmpty)
        #expect(coordinator.stateMachine.stage == .idle)
        #expect(coordinator.destinationLocation == nil)
    }

    @MainActor
    @Test func handlePinPublishFailureDoesNotMarkDestinationShared() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()
        fake.shouldFailPublish = true

        coordinator.stateMachine.restore(
            stage: .driverArrived, offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: driver.publicKeyHex,
            pin: "1234", pinVerified: false,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)

        let encryptedPin = try NIP44.encrypt(
            plaintext: "1234",
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )

        await coordinator.handlePinSubmission(
            pinEncrypted: encryptedPin,
            driverPubkey: driver.publicKeyHex,
            confirmationEventId: "conf1"
        )

        #expect(!coordinator.stateMachine.pinVerified)
        #expect(coordinator.stateMachine.stage == .driverArrived)
        #expect(!coordinator.stateMachine.preciseDestinationShared)
        #expect(coordinator.stateMachine.riderStateHistory.isEmpty)
        #expect(fake.publishedEvents.isEmpty)
        #expect(coordinator.lastError?.contains("PIN verification error:") == true)

        fake.shouldFailPublish = false
        await coordinator.handlePinSubmission(
            pinEncrypted: encryptedPin,
            driverPubkey: driver.publicKeyHex,
            confirmationEventId: "conf1"
        )

        #expect(coordinator.stateMachine.pinVerified)
        #expect(coordinator.stateMachine.preciseDestinationShared)
        #expect(coordinator.stateMachine.stage == .driverArrived)
        let riderStates = fake.publishedEvents.filter { $0.kind == EventKind.riderRideState.rawValue }
        #expect(riderStates.count == 1)
    }

    @MainActor
    @Test func failedPinResponseDoesNotPersistDriverStateCursorAndCanReplayAfterRestore() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()
        fake.shouldFailPublish = true

        coordinator.stateMachine.restore(
            stage: .rideConfirmed,
            offerEventId: "o1",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)

        let encryptedPin = try NIP44.encrypt(
            plaintext: "1234",
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )
        let driverState = DriverRideStateContent(
            currentStatus: "arrived",
            history: [
                DriverRideAction(
                    type: "pin_submit",
                    at: 1_700_000_000,
                    status: nil,
                    approxLocation: nil,
                    finalFare: nil,
                    invoice: nil,
                    pinEncrypted: encryptedPin
                )
            ]
        )
        let driverStateJSON = try JSONEncoder().encode(driverState)
        let event = NostrEvent(
            id: "driver-state-replay",
            pubkey: driver.publicKeyHex,
            createdAt: 1_700_000_100,
            kind: EventKind.driverRideState.rawValue,
            tags: [
                ["d", rideCoordinatorConfirmationEventId],
                ["e", rideCoordinatorConfirmationEventId],
                ["p", riderKeypair.publicKeyHex],
            ],
            content: String(data: driverStateJSON, encoding: .utf8)!,
            sig: "sig"
        )

        await coordinator.handleDriverStateEvent(event, confirmationEventId: rideCoordinatorConfirmationEventId)

        let saved = RideStatePersistence.load()
        #expect(saved?.stage == RiderStage.driverArrived.rawValue)
        #expect(saved?.lastDriverStateTimestamp == nil)
        #expect(saved?.lastDriverActionCount == nil)
        #expect(!coordinator.stateMachine.pinVerified)

        let (restoredCoordinator, restoredFake, _) = try await makeCoordinator(
            keypair: riderKeypair,
            clearRidePersistence: false
        )
        restoredCoordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)

        await restoredCoordinator.handleDriverStateEvent(
            event,
            confirmationEventId: rideCoordinatorConfirmationEventId
        )

        #expect(restoredCoordinator.stateMachine.pin == nil)
        #expect(restoredCoordinator.stateMachine.pinVerified)
        #expect(restoredCoordinator.stateMachine.preciseDestinationShared)
        let riderStates = restoredFake.publishedEvents.filter { $0.kind == EventKind.riderRideState.rawValue }
        #expect(riderStates.count == 1)
    }

    @MainActor
    @Test func handlePinMaxAttemptsAutoCancels() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        coordinator.stateMachine.restore(
            stage: .driverArrived, offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "conf1", driverPubkey: driver.publicKeyHex,
            pin: "1234", pinVerified: false,
            paymentMethod: nil, fiatPaymentMethods: []
        )

        for i in 0..<RideConstants.maxPinAttempts {
            let encryptedPin = try NIP44.encrypt(
                plaintext: "000\(i)",
                senderPrivateKeyHex: driver.privateKeyHex,
                recipientPublicKeyHex: riderKeypair.publicKeyHex
            )
            await coordinator.handlePinSubmission(
                pinEncrypted: encryptedPin,
                driverPubkey: driver.publicKeyHex,
                confirmationEventId: "conf1"
            )
        }

        #expect(coordinator.stateMachine.stage == .idle)
        let cancels = fake.publishedEvents.filter { $0.kind == EventKind.cancellation.rawValue }
        #expect(cancels.count == 1)
    }

    @MainActor
    @Test func handlePinMaxAttemptsAutoCancelsEvenWhenPublishFails() async throws {
        let (coordinator, fake, riderKeypair) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()
        fake.shouldFailPublish = true

        coordinator.stateMachine.restore(
            stage: .driverArrived,
            offerEventId: "o1",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinAttempts: RideConstants.maxPinAttempts - 1,
            pinVerified: false,
            paymentMethod: nil,
            fiatPaymentMethods: []
        )

        let encryptedPin = try NIP44.encrypt(
            plaintext: "9999",
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )

        await coordinator.handlePinSubmission(
            pinEncrypted: encryptedPin,
            driverPubkey: driver.publicKeyHex,
            confirmationEventId: rideCoordinatorConfirmationEventId
        )

        #expect(coordinator.stateMachine.stage == .idle)
        #expect(RideStatePersistence.load() == nil)
        #expect(fake.publishedEvents.isEmpty)
    }

    // MARK: - sendRideOffer Guards

    @MainActor
    @Test func sendRideOfferRejectsWhenNotIdle() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: "d1",
            paymentMethod: nil, fiatPaymentMethods: []
        )
        fake.resetRecording()
        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: Location(latitude: 40.71, longitude: -74.01),
            destination: Location(latitude: 40.76, longitude: -73.98),
            fareEstimate: FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 10.0)
        )
        let offers = fake.publishedEvents.filter { $0.kind == EventKind.rideOffer.rawValue }
        #expect(offers.isEmpty)
    }

    // MARK: - cancelRide Edge Cases

    @MainActor
    @Test func cancelRideWithoutDriverJustResets() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        await coordinator.cancelRide(reason: "test")
        #expect(fake.publishedEvents.isEmpty)
        #expect(coordinator.stateMachine.stage == .idle)
    }

    @MainActor
    @Test func cancelRideClearsAllRideData() async throws {
        let (coordinator, _, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle"]
        )
        _ = try coordinator.stateMachine.handleAcceptance(acceptanceEventId: "acc1")
        try coordinator.stateMachine.recordConfirmation(confirmationEventId: "conf1")
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5.0, durationMinutes: 15, fareUSD: 10.0)

        await coordinator.cancelRide(reason: "test")

        #expect(coordinator.stateMachine.stage == .idle)
        #expect(coordinator.stateMachine.pin == nil)
        #expect(coordinator.stateMachine.confirmationEventId == nil)
        #expect(coordinator.pickupLocation == nil)
        #expect(coordinator.destinationLocation == nil)
        #expect(coordinator.currentFareEstimate == nil)
        #expect(coordinator.chat.chatMessages.isEmpty)
    }

    // MARK: - Subscription Wiring Verification

    @MainActor
    @Test func cancelRideUnsubscribesFromAllRideEvents() async throws {
        let (coordinator, fake, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        try coordinator.stateMachine.startRide(
            offerEventId: "o1", driverPubkey: driver.publicKeyHex,
            paymentMethod: nil, fiatPaymentMethods: []
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        await coordinator.handleAcceptance(acceptanceEventId: "acc1", driverPubkey: driver.publicKeyHex)

        fake.resetRecording()
        await coordinator.cancelRide(reason: "test")

        #expect(fake.unsubscribeCalls.count >= 3)
    }
}
