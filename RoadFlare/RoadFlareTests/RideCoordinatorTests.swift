import Testing
import Foundation
@testable import RoadFlareCore
@testable import RidestrSDK

private let rideCoordinatorAcceptanceEventId = String(repeating: "a", count: 64)
private let rideCoordinatorConfirmationEventId = String(repeating: "b", count: 64)

@Suite("RideCoordinator Tests")
struct RideCoordinatorTests {

    @MainActor
    private func makeCoordinator(
        keypair existingKeypair: NostrKeypair? = nil,
        keepSubscriptionsAlive: Bool = false,
        clearRidePersistence: Bool = true,
        roadflarePaymentMethods: [String] = ["zelle"],
        rideStatePersistence: InMemoryRideStatePersistence? = nil,
        stageTimeouts: RideCoordinator.StageTimeouts = .interopDefault
    ) async throws -> (RideCoordinator, FakeRelayManager, NostrKeypair, RideHistoryRepository, InMemoryRideStatePersistence) {
        let persistence = rideStatePersistence ?? InMemoryRideStatePersistence()
        if clearRidePersistence {
            persistence.clear()
        }
        let keypair = try existingKeypair ?? NostrKeypair.generate()
        let fake = FakeRelayManager()
        fake.keepSubscriptionsAlive = keepSubscriptionsAlive
        try await fake.connect(to: DefaultRelays.all)

        let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        let settings = UserSettingsRepository(persistence: InMemoryUserSettingsPersistence())
        settings.setRoadflarePaymentMethods(roadflarePaymentMethods)
        let history = RideHistoryRepository(persistence: InMemoryRideHistoryPersistence())
        let bitcoinPrice = BitcoinPriceService()
        bitcoinPrice.btcPriceUsdForTesting = 100_000

        let coordinator = RideCoordinator(
            relayManager: fake,
            keypair: keypair,
            driversRepository: repo,
            settings: settings,
            rideHistory: history,
            bitcoinPrice: bitcoinPrice,
            rideStatePersistence: persistence,
            stageTimeouts: stageTimeouts
        )
        return (coordinator, fake, keypair, history, persistence)
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

    @MainActor
    private func makeRestoredSession(
        keypair: NostrKeypair,
        stage: RiderStage,
        offerEventId: String? = "offer-1",
        acceptanceEventId: String? = rideCoordinatorAcceptanceEventId,
        confirmationEventId: String? = rideCoordinatorConfirmationEventId,
        driverPubkey: String? = nil,
        pin: String? = "1234",
        pinAttempts: Int = 0,
        pinVerified: Bool = false,
        paymentMethod: String? = "zelle",
        fiatPaymentMethods: [String] = ["zelle"],
        precisePickupShared: Bool = false,
        preciseDestinationShared: Bool = false,
        lastDriverStatus: String? = nil,
        lastDriverStateTimestamp: Int = 0,
        lastDriverActionCount: Int = 0,
        riderStateHistory: [RiderRideAction] = [],
        processedPinActionKeys: Set<String> = []
    ) -> RiderRideSession {
        let relay = FakeRelayManager()
        let session = RiderRideSession(relayManager: relay, keypair: keypair)
        session.restore(
            stage: stage,
            offerEventId: offerEventId,
            acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId,
            driverPubkey: driverPubkey,
            pin: pin,
            pinAttempts: pinAttempts,
            pinVerified: pinVerified,
            paymentMethod: paymentMethod,
            fiatPaymentMethods: fiatPaymentMethods,
            precisePickupShared: precisePickupShared,
            preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory,
            processedPinActionKeys: processedPinActionKeys
        )
        return session
    }

    @MainActor
    private func makePersistedState(
        session: RiderRideSession,
        pickup: Location? = nil,
        destination: Location? = nil,
        fare: FareEstimate? = nil,
        savedAt: Int = Int(Date.now.timeIntervalSince1970)
    ) -> PersistedRideState {
        let p = pickup ?? session.precisePickup
        let d = destination ?? session.preciseDestination
        return PersistedRideState(
            stage: session.stage.rawValue,
            offerEventId: session.offerEventId,
            acceptanceEventId: session.acceptanceEventId,
            confirmationEventId: session.confirmationEventId,
            driverPubkey: session.driverPubkey,
            pin: session.pin,
            pinVerified: session.pinVerified,
            paymentMethodRaw: session.paymentMethod,
            fiatPaymentMethodsRaw: session.fiatPaymentMethods,
            pickupLat: p?.latitude, pickupLon: p?.longitude, pickupAddress: p?.address,
            destLat: d?.latitude, destLon: d?.longitude, destAddress: d?.address,
            fareUSD: fare.map { "\($0.fareUSD)" },
            fareDistanceMiles: fare?.distanceMiles,
            fareDurationMinutes: fare?.durationMinutes,
            savedAt: savedAt,
            processedPinActionKeys: session.processedPinActionKeys.isEmpty ? nil : Array(session.processedPinActionKeys),
            processedPinTimestamps: nil,
            pinAttempts: session.pinAttempts > 0 ? session.pinAttempts : nil,
            precisePickupShared: session.precisePickupShared ? true : nil,
            preciseDestinationShared: session.preciseDestinationShared ? true : nil,
            lastDriverStatus: session.lastDriverStatus,
            lastDriverStateTimestamp: session.lastDriverStateTimestamp > 0 ? session.lastDriverStateTimestamp : nil,
            lastDriverActionCount: session.lastDriverActionCount > 0 ? session.lastDriverActionCount : nil,
            riderStateHistory: session.riderStateHistory.isEmpty ? nil : session.riderStateHistory
        )
    }

    private func makeDriverStateEvent(
        driverKeypair: NostrKeypair,
        riderPubkey: String,
        confirmationEventId: String,
        status: String,
        history: [DriverRideAction] = [],
        eventId: String = UUID().uuidString,
        createdAt: Int = Int(Date.now.timeIntervalSince1970)
    ) throws -> NostrEvent {
        let content = DriverRideStateContent(currentStatus: status, history: history)
        let json = try JSONEncoder().encode(content)
        return NostrEvent(
            id: eventId,
            pubkey: driverKeypair.publicKeyHex,
            createdAt: createdAt,
            kind: EventKind.driverRideState.rawValue,
            tags: [["p", riderPubkey], ["d", confirmationEventId], ["e", confirmationEventId]],
            content: String(decoding: json, as: UTF8.self),
            sig: "sig"
        )
    }

    // MARK: - Location + Chat

    @MainActor
    @Test func handleKeyShareUpdatesDriverAndPublishesAck() async throws {
        let (coordinator, fake, riderKeypair, _, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()
        let roadflareKey = try NostrKeypair.generate()

        coordinator.driversRepository.addDriver(FollowedDriver(pubkey: driver.publicKeyHex))

        let content = KeyShareContent(
            roadflareKey: RoadflareKey(
                privateKeyHex: roadflareKey.privateKeyHex,
                publicKeyHex: roadflareKey.publicKeyHex,
                version: 1,
                keyUpdatedAt: 1_700_000_000
            ),
            keyUpdatedAt: 1_700_000_000,
            driverPubKey: driver.publicKeyHex
        )
        let json = try JSONEncoder().encode(content)
        let encrypted = try NIP44.encrypt(
            plaintext: String(decoding: json, as: UTF8.self),
            senderPrivateKeyHex: driver.privateKeyHex,
            recipientPublicKeyHex: riderKeypair.publicKeyHex
        )
        let event = NostrEvent(
            id: "ks1",
            pubkey: driver.publicKeyHex,
            createdAt: Int(Date.now.timeIntervalSince1970),
            kind: EventKind.keyShare.rawValue,
            tags: [["p", riderKeypair.publicKeyHex], ["expiration", "\(Int(Date.now.timeIntervalSince1970) + 300)"]],
            content: encrypted,
            sig: "sig"
        )

        await coordinator.location.handleKeyShareEvent(event)

        #expect(coordinator.driversRepository.getDriver(pubkey: driver.publicKeyHex)?.hasKey == true)
        #expect(fake.publishedEvents.contains { $0.kind == EventKind.keyAcknowledgement.rawValue })
    }

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
        #expect(fake.publishedEvents.contains { $0.kind == EventKind.followedDriversList.rawValue },
                "appliedNewer key share must republish the followed-drivers list (Kind 30011)")
    }

    @MainActor
    @Test func handleChatEventDeduplicatesAndSorts() async throws {
        let (coordinator, _, riderKeypair, _, _) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        let newer = try await RideshareEventBuilder.chatMessage(
            recipientPubkey: riderKeypair.publicKeyHex,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            message: "newer",
            keypair: driver
        )
        let older = NostrEvent(
            id: "older",
            pubkey: newer.pubkey,
            createdAt: newer.createdAt - 10,
            kind: newer.kind,
            tags: newer.tags,
            content: newer.content,
            sig: newer.sig
        )

        await coordinator.chat.handleChatEvent(newer)
        await coordinator.chat.handleChatEvent(older)
        await coordinator.chat.handleChatEvent(older)

        #expect(coordinator.chat.chatMessages.count == 2)
        #expect(coordinator.chat.chatMessages[0].timestamp < coordinator.chat.chatMessages[1].timestamp)
    }

    // MARK: - Send Offer

    @MainActor
    @Test func sendRideOfferPublishesOfferTransitionsSessionAndPersists() async throws {
        let (coordinator, fake, _, _, persistence) = try await makeCoordinator()
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

        #expect(coordinator.session.stage == .waitingForAcceptance)
        #expect(coordinator.session.driverPubkey == driver.publicKeyHex)
        #expect(fake.publishedEvents.contains { $0.kind == EventKind.rideOffer.rawValue })
        #expect(persistence.loadRaw()?.stage == RiderStage.waitingForAcceptance.rawValue)
    }

    @MainActor
    @Test func sendRideOfferUsesOrderedRoadflarePaymentMethods() async throws {
        let (coordinator, fake, riderKeypair, _, _) = try await makeCoordinator(
            roadflarePaymentMethods: ["venmo-business", "zelle", "cash"]
        )
        let driver = try NostrKeypair.generate()

        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: Location(latitude: 40.71, longitude: -74.01),
            destination: Location(latitude: 40.76, longitude: -73.98),
            fareEstimate: FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
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
    @Test func sendRideOfferFailureSurfacesError() async throws {
        let (coordinator, fake, _, _, _) = try await makeCoordinator()
        fake.shouldFailPublish = true

        await coordinator.sendRideOffer(
            driverPubkey: String(repeating: "d", count: 64),
            pickup: Location(latitude: 40.71, longitude: -74.01),
            destination: Location(latitude: 40.76, longitude: -73.98),
            fareEstimate: FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
        )

        #expect(coordinator.session.stage == .idle)
        #expect(coordinator.lastError != nil)
        #expect(coordinator.pickupLocation == nil)
        #expect(coordinator.destinationLocation == nil)
        #expect(coordinator.currentFareEstimate == nil)
    }

    @MainActor
    @Test func sendRideOfferWhileNonIdleLeavesCurrentRideWiringUntouched() async throws {
        let (coordinator, fake, _, _, _) = try await makeCoordinator()
        let activeDriver = String(repeating: "d", count: 64)
        let replacementDriver = String(repeating: "e", count: 64)
        let existingPickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let existingDestination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        let existingFare = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)

        coordinator.session.restore(
            stage: .rideConfirmed,
            offerEventId: "offer",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            driverPubkey: activeDriver,
            pin: "1234",
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        coordinator.pickupLocation = existingPickup
        coordinator.destinationLocation = existingDestination
        coordinator.currentFareEstimate = existingFare
        coordinator.selectedPaymentMethod = "zelle"

        await coordinator.sendRideOffer(
            driverPubkey: replacementDriver,
            pickup: Location(latitude: 37.77, longitude: -122.42, address: "New pickup"),
            destination: Location(latitude: 37.78, longitude: -122.41, address: "New destination"),
            fareEstimate: FareEstimate(distanceMiles: 2, durationMinutes: 8, fareUSD: 9.0)
        )

        #expect(coordinator.session.stage == .rideConfirmed)
        #expect(coordinator.session.driverPubkey == activeDriver)
        #expect(coordinator.pickupLocation == existingPickup)
        #expect(coordinator.destinationLocation == existingDestination)
        #expect(coordinator.currentFareEstimate == existingFare)
        #expect(coordinator.selectedPaymentMethod == "zelle")
        #expect(coordinator.lastError != nil)
        #expect(fake.publishedEvents.allSatisfy { $0.kind != EventKind.rideOffer.rawValue })
    }

    // MARK: - Restore

    @MainActor
    @Test func restoreRideStatePopulatesSessionAndUI() async throws {
        let keypair = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let savedSession = makeRestoredSession(
            keypair: keypair,
            stage: .rideConfirmed,
            driverPubkey: driver.publicKeyHex,
            precisePickupShared: true,
            processedPinActionKeys: ["pin_submit:100:enc"]
        )
        let pickup = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        let destination = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        let fare = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
        let persistence = InMemoryRideStatePersistence()
        persistence.saveRaw(makePersistedState(session: savedSession, pickup: pickup, destination: destination, fare: fare))

        let (coordinator, _, _, _, _) = try await makeCoordinator(
            keypair: keypair,
            clearRidePersistence: false,
            rideStatePersistence: persistence
        )

        #expect(coordinator.session.stage == .rideConfirmed)
        #expect(coordinator.session.driverPubkey == driver.publicKeyHex)
        #expect(coordinator.pickupLocation?.address == "Penn Station")
        #expect(coordinator.destinationLocation?.address == "Central Park")
        #expect(coordinator.currentFareEstimate?.fareUSD == 12.5)
    }

    @MainActor
    @Test func restoreRideStateRespectsConfiguredTimeoutWindow() async throws {
        let keypair = try NostrKeypair.generate()
        let savedSession = makeRestoredSession(
            keypair: keypair,
            stage: .waitingForAcceptance,
            driverPubkey: String(repeating: "d", count: 64)
        )
        let persistence = InMemoryRideStatePersistence()
        persistence.saveRaw(makePersistedState(
            session: savedSession,
            pickup: Location(latitude: 40.71, longitude: -74.01, address: "Penn Station"),
            destination: Location(latitude: 40.76, longitude: -73.98, address: "Central Park"),
            fare: FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5),
            savedAt: Int(Date.now.timeIntervalSince1970) - 2
        ))

        let (coordinator, _, _, _, _) = try await makeCoordinator(
            keypair: keypair,
            clearRidePersistence: false,
            rideStatePersistence: persistence,
            stageTimeouts: .init(waitingForAcceptance: 1, driverAccepted: 30)
        )

        #expect(coordinator.session.stage == .idle)
        #expect(persistence.loadRaw() == nil)
    }

    @MainActor
    @Test func restoreLiveSubscriptionsFromDriverAcceptedRecoversConfirmationAndStartsRideSubscriptions() async throws {
        let keypair = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let savedSession = makeRestoredSession(
            keypair: keypair,
            stage: .driverAccepted,
            confirmationEventId: nil,
            driverPubkey: driver.publicKeyHex,
            precisePickupShared: false
        )
        let persistence = InMemoryRideStatePersistence()
        persistence.saveRaw(makePersistedState(
            session: savedSession,
            pickup: Location(latitude: 40.71, longitude: -74.01, address: "Penn Station"),
            destination: Location(latitude: 40.76, longitude: -73.98, address: "Central Park"),
            fare: FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
        ))

        let (coordinator, fake, _, _, _) = try await makeCoordinator(
            keypair: keypair,
            keepSubscriptionsAlive: true,
            clearRidePersistence: false,
            rideStatePersistence: persistence
        )
        let confirmation = try await RideshareEventBuilder.rideConfirmation(
            driverPubkey: driver.publicKeyHex,
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            keypair: keypair
        )
        fake.fetchResults = [confirmation]

        await coordinator.restoreLiveSubscriptions()

        let recovered = await eventually {
            coordinator.session.stage == .rideConfirmed &&
                coordinator.session.confirmationEventId == confirmation.id &&
                fake.subscribeCalls.contains { $0.id.rawValue == "driver-state-\(confirmation.id)" } &&
                fake.subscribeCalls.contains { $0.id.rawValue == "cancel-\(confirmation.id)" } &&
                fake.subscribeCalls.contains { $0.id.rawValue == "chat-\(confirmation.id)" }
        }
        #expect(recovered)
        await coordinator.stopAll()
    }

    @MainActor
    @Test func restoreLiveSubscriptionsFromActiveRideStartsChatWithoutStageTransition() async throws {
        let keypair = try NostrKeypair.generate()
        let driver = try NostrKeypair.generate()
        let savedSession = makeRestoredSession(
            keypair: keypair,
            stage: .rideConfirmed,
            driverPubkey: driver.publicKeyHex
        )
        let persistence = InMemoryRideStatePersistence()
        persistence.saveRaw(makePersistedState(
            session: savedSession,
            pickup: Location(latitude: 40.71, longitude: -74.01),
            destination: Location(latitude: 40.76, longitude: -73.98),
            fare: FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
        ))

        let (coordinator, fake, _, _, _) = try await makeCoordinator(
            keypair: keypair,
            keepSubscriptionsAlive: true,
            clearRidePersistence: false,
            rideStatePersistence: persistence
        )

        await coordinator.restoreLiveSubscriptions()

        let wired = await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue == "key-shares" } &&
                fake.subscribeCalls.contains { $0.id.rawValue == "driver-state-\(rideCoordinatorConfirmationEventId)" } &&
                fake.subscribeCalls.contains { $0.id.rawValue == "cancel-\(rideCoordinatorConfirmationEventId)" } &&
                fake.subscribeCalls.contains { $0.id.rawValue == "chat-\(rideCoordinatorConfirmationEventId)" }
        }
        #expect(wired)
        await coordinator.stopAll()
    }

    @MainActor
    @Test func restoreLiveSubscriptionsChecksForStaleKeysWhenDriversExist() async throws {
        let (coordinator, fake, _, _, _) = try await makeCoordinator()
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

    // MARK: - Delegate behavior

    @MainActor
    @Test func sessionDidChangeStageEnteringActiveRideSubscribesChat() async throws {
        let (coordinator, fake, _, _, _) = try await makeCoordinator(keepSubscriptionsAlive: true)
        coordinator.session.restore(
            stage: .rideConfirmed,
            offerEventId: "offer",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            driverPubkey: String(repeating: "d", count: 64),
            pin: "1234",
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )

        coordinator.sessionDidChangeStage(from: .driverAccepted, to: .rideConfirmed)

        let subscribed = await eventually {
            fake.subscribeCalls.contains { $0.id.rawValue == "chat-\(rideCoordinatorConfirmationEventId)" }
        }
        #expect(subscribed)
        await coordinator.stopAll()
    }

    @MainActor
    @Test func sessionDidChangeStageWithinActiveRideDoesNotResubscribeChat() async throws {
        let (coordinator, fake, _, _, _) = try await makeCoordinator(keepSubscriptionsAlive: true)
        coordinator.session.restore(
            stage: .rideConfirmed,
            offerEventId: "offer",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            driverPubkey: String(repeating: "d", count: 64),
            pin: "1234",
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )

        coordinator.sessionDidChangeStage(from: .driverAccepted, to: .rideConfirmed)
        try await Task.sleep(for: .milliseconds(50))
        fake.resetRecording()

        coordinator.sessionDidChangeStage(from: .rideConfirmed, to: .enRoute)
        try await Task.sleep(for: .milliseconds(50))

        #expect(fake.subscribeCalls.isEmpty)
        await coordinator.stopAll()
    }

    @MainActor
    @Test func sessionDidReachTerminalCompletedRecordsHistoryAndKeepsUI() async throws {
        let (coordinator, _, _, history, _) = try await makeCoordinator()
        coordinator.session.restore(
            stage: .completed,
            offerEventId: "offer",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            driverPubkey: String(repeating: "d", count: 64),
            pin: "1234",
            pinVerified: true,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"],
            precisePickupShared: true,
            preciseDestinationShared: true
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)

        coordinator.sessionDidReachTerminal(.completed)

        #expect(history.rides.count == 1)
        #expect(coordinator.pickupLocation != nil)
        #expect(coordinator.destinationLocation != nil)
        #expect(coordinator.currentFareEstimate != nil)
    }

    @MainActor
    @Test func closeCompletedRideClearsUIAndResetsSession() async throws {
        let (coordinator, _, _, _, _) = try await makeCoordinator()
        coordinator.session.restore(
            stage: .completed,
            offerEventId: "offer",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            driverPubkey: String(repeating: "d", count: 64),
            pin: "1234",
            pinVerified: true,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
        coordinator.selectedPaymentMethod = "zelle"
        coordinator.lastError = "stale"

        await coordinator.closeCompletedRide()

        #expect(coordinator.session.stage == .idle)
        #expect(coordinator.pickupLocation == nil)
        #expect(coordinator.destinationLocation == nil)
        #expect(coordinator.currentFareEstimate == nil)
        #expect(coordinator.selectedPaymentMethod == nil)
        #expect(coordinator.lastError == nil)
    }

    @MainActor
    @Test func sessionDidReachTerminalCancelledByRiderClearsUIAndChatWithoutError() async throws {
        let (coordinator, _, _, _, _) = try await makeCoordinator()
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
        coordinator.selectedPaymentMethod = "zelle"
        coordinator.lastError = "stale"
        coordinator.chat.chatMessages = [(id: "m1", text: "hello", isMine: false, timestamp: 1)]

        coordinator.sessionDidReachTerminal(.cancelledByRider(reason: "Changed plans"))

        #expect(coordinator.pickupLocation == nil)
        #expect(coordinator.destinationLocation == nil)
        #expect(coordinator.currentFareEstimate == nil)
        #expect(coordinator.selectedPaymentMethod == nil)
        #expect(coordinator.lastError == nil)
        #expect(coordinator.chat.chatMessages.isEmpty)
    }

    @MainActor
    @Test func sessionDidReachTerminalCancelledByDriverSurfacesMessage() async throws {
        let (coordinator, _, _, _, _) = try await makeCoordinator()
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
        coordinator.selectedPaymentMethod = "zelle"
        coordinator.lastError = "stale"
        coordinator.chat.chatMessages = [(id: "m1", text: "hello", isMine: false, timestamp: 1)]

        coordinator.sessionDidReachTerminal(.cancelledByDriver(reason: "No longer available"))

        #expect(coordinator.pickupLocation == nil)
        #expect(coordinator.destinationLocation == nil)
        #expect(coordinator.currentFareEstimate == nil)
        #expect(coordinator.selectedPaymentMethod == nil)
        #expect(coordinator.lastError == "Driver cancelled the ride: No longer available")
        #expect(coordinator.chat.chatMessages.isEmpty)
    }

    @MainActor
    @Test func sessionDidReachTerminalExpiredSetsTimeoutMessage() async throws {
        let (coordinator, _, _, _, _) = try await makeCoordinator()
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
        coordinator.selectedPaymentMethod = "zelle"
        coordinator.lastError = "stale"
        coordinator.chat.chatMessages = [(id: "m1", text: "hello", isMine: false, timestamp: 1)]

        coordinator.sessionDidReachTerminal(.expired(stage: .waitingForAcceptance))

        #expect(coordinator.pickupLocation == nil)
        #expect(coordinator.destinationLocation == nil)
        #expect(coordinator.currentFareEstimate == nil)
        #expect(coordinator.selectedPaymentMethod == nil)
        #expect(coordinator.lastError == "Ride request expired before a driver responded.")
        #expect(coordinator.chat.chatMessages.isEmpty)
    }

    @MainActor
    @Test func sessionDidReachTerminalBruteForcePinSetsMessage() async throws {
        let (coordinator, _, _, _, _) = try await makeCoordinator()
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
        coordinator.selectedPaymentMethod = "zelle"
        coordinator.lastError = "stale"
        coordinator.chat.chatMessages = [(id: "m1", text: "hello", isMine: false, timestamp: 1)]

        coordinator.sessionDidReachTerminal(.bruteForcePin)

        #expect(coordinator.pickupLocation == nil)
        #expect(coordinator.destinationLocation == nil)
        #expect(coordinator.currentFareEstimate == nil)
        #expect(coordinator.selectedPaymentMethod == nil)
        #expect(coordinator.lastError == "Ride cancelled after too many incorrect PIN attempts.")
        #expect(coordinator.chat.chatMessages.isEmpty)
    }

    @MainActor
    @Test func sessionShouldPersistSavesActiveSessionAndClearsIdleOrCompleted() async throws {
        let (coordinator, _, _, _, persistence) = try await makeCoordinator()
        coordinator.session.restore(
            stage: .waitingForAcceptance,
            offerEventId: "offer",
            acceptanceEventId: nil,
            confirmationEventId: nil,
            driverPubkey: String(repeating: "d", count: 64),
            pin: nil,
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01)
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98)
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)

        coordinator.sessionShouldPersist()
        #expect(persistence.loadRaw()?.stage == RiderStage.waitingForAcceptance.rawValue)

        coordinator.session.reset()
        coordinator.sessionShouldPersist()
        #expect(persistence.loadRaw() == nil)

        coordinator.session.restore(
            stage: .completed,
            offerEventId: "offer",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            driverPubkey: String(repeating: "d", count: 64),
            pin: "1234",
            pinVerified: true,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        coordinator.sessionShouldPersist()
        #expect(persistence.loadRaw() == nil)
    }

    // MARK: - Ride actions

    @MainActor
    @Test func cancelRidePublishesTerminationAndClearsPersistence() async throws {
        let (coordinator, fake, _, _, persistence) = try await makeCoordinator()
        let driver = try NostrKeypair.generate()

        await coordinator.sendRideOffer(
            driverPubkey: driver.publicKeyHex,
            pickup: Location(latitude: 40.71, longitude: -74.01),
            destination: Location(latitude: 40.76, longitude: -73.98),
            fareEstimate: FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
        )

        await coordinator.cancelRide(reason: "Changed plans")

        #expect(coordinator.session.stage == .idle)
        #expect(persistence.loadRaw() == nil)
        #expect(fake.publishedEvents.contains { $0.kind == EventKind.deletion.rawValue })
    }

    @MainActor
    @Test func sendChatMessagePublishesWhenRideIsActive() async throws {
        let (coordinator, fake, _, _, _) = try await makeCoordinator()
        coordinator.session.restore(
            stage: .rideConfirmed,
            offerEventId: "offer",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            driverPubkey: String(repeating: "d", count: 64),
            pin: "1234",
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )

        await coordinator.sendChatMessage("On my way out")

        #expect(fake.publishedEvents.contains { $0.kind == EventKind.chatMessage.rawValue })
        #expect(coordinator.chat.chatMessages.count == 1)
        #expect(coordinator.chat.chatMessages.first?.text == "On my way out")
    }

    @MainActor
    @Test func driverStateCompletionRecordsHistoryViaDelegateFlow() async throws {
        let (coordinator, fake, riderKeypair, history, persistence) = try await makeCoordinator(keepSubscriptionsAlive: true)
        let driver = try NostrKeypair.generate()

        coordinator.session.restore(
            stage: .rideConfirmed,
            offerEventId: "offer",
            acceptanceEventId: rideCoordinatorAcceptanceEventId,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"]
        )
        coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
        coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
        coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)

        await coordinator.restoreLiveSubscriptions()
        let completionEvent = try makeDriverStateEvent(
            driverKeypair: driver,
            riderPubkey: riderKeypair.publicKeyHex,
            confirmationEventId: rideCoordinatorConfirmationEventId,
            status: "completed"
        )

        #expect(fake.injectEvent(completionEvent, subscriptionId: "driver-state-\(rideCoordinatorConfirmationEventId)"))
        let completed = await eventually { coordinator.session.stage == .completed }
        let recorded = await eventually { history.rides.count == 1 }
        let cleared = await eventually { persistence.loadRaw() == nil }

        #expect(completed)
        #expect(recorded)
        #expect(cleared)
        await coordinator.stopAll()
    }
}
