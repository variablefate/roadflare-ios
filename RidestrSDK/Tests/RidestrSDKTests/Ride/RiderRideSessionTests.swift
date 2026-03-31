import Foundation
import Testing
@testable import RidestrSDK

@Suite("RiderRideSession Tests")
@MainActor
struct RiderRideSessionTests {

    private func makeSession(
        configuration: RiderRideSession.Configuration = .default
    ) throws -> (session: RiderRideSession, relay: FakeRelayManager) {
        let bundle = try makeSessionBundle(configuration: configuration)
        return (bundle.session, bundle.relay)
    }

    private func makeSessionBundle(
        configuration: RiderRideSession.Configuration = .default
    ) throws -> (session: RiderRideSession, relay: FakeRelayManager, keypair: NostrKeypair) {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let session = RiderRideSession(
            relayManager: relay,
            keypair: keypair,
            configuration: configuration
        )
        return (session, relay, keypair)
    }

    // MARK: - Construction

    @Test func constructionStartsAtIdle() throws {
        let session = try makeSession().session
        #expect(session.stage == .idle)
        #expect(session.pin == nil)
        #expect(session.driverPubkey == nil)
        #expect(session.confirmationEventId == nil)
        #expect(session.offerEventId == nil)
        #expect(session.acceptanceEventId == nil)
        #expect(session.pinVerified == false)
        #expect(session.pinAttempts == 0)
        #expect(session.precisePickup == nil)
        #expect(session.preciseDestination == nil)
        #expect(session.processedPinActionKeys.isEmpty)
        #expect(session.lastError == nil)
        #expect(session.lastDriverStatus == nil)
        #expect(session.lastDriverStateTimestamp == 0)
        #expect(session.lastDriverActionCount == 0)
    }

    // MARK: - Property forwarding

    @Test func propertiesForwardFromStateMachine() throws {
        let session = try makeSession().session
        let driverPubkey = String(repeating: "a", count: 64)
        session.stateMachine.restore(
            stage: .driverArrived,
            offerEventId: "offer1",
            acceptanceEventId: "accept1",
            confirmationEventId: "confirm1",
            driverPubkey: driverPubkey,
            pin: "1234",
            pinAttempts: 1,
            pinVerified: false,
            paymentMethod: "venmo",
            fiatPaymentMethods: ["venmo", "zelle"],
            precisePickupShared: true,
            preciseDestinationShared: false
        )

        #expect(session.stage == .driverArrived)
        #expect(session.offerEventId == "offer1")
        #expect(session.acceptanceEventId == "accept1")
        #expect(session.confirmationEventId == "confirm1")
        #expect(session.driverPubkey == driverPubkey)
        #expect(session.pin == "1234")
        #expect(session.pinAttempts == 1)
        #expect(session.pinVerified == false)
        #expect(session.paymentMethod == "venmo")
        #expect(session.fiatPaymentMethods == ["venmo", "zelle"])
        #expect(session.precisePickupShared == true)
        #expect(session.preciseDestinationShared == false)
    }

    // MARK: - Restore

    @Test func restorePopulatesAllState() throws {
        let session = try makeSession().session
        let driverPubkey = String(repeating: "b", count: 64)
        let pickup = Location(latitude: 37.7749, longitude: -122.4194)
        let destination = Location(latitude: 37.3382, longitude: -121.8863)

        session.restore(
            stage: .enRoute,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "c1",
            driverPubkey: driverPubkey,
            pin: "5678",
            pinAttempts: 0,
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"],
            precisePickupShared: true,
            lastDriverStatus: "en_route_pickup",
            lastDriverStateTimestamp: 1000,
            lastDriverActionCount: 2,
            processedPinActionKeys: ["pin_submit:100:enc"],
            precisePickup: pickup,
            preciseDestination: destination,
            savedAt: 999
        )

        #expect(session.stage == .enRoute)
        #expect(session.offerEventId == "o1")
        #expect(session.confirmationEventId == "c1")
        #expect(session.driverPubkey == driverPubkey)
        #expect(session.pin == "5678")
        #expect(session.precisePickup?.latitude == 37.7749)
        #expect(session.preciseDestination?.latitude == 37.3382)
        #expect(session.processedPinActionKeys == ["pin_submit:100:enc"])
        #expect(session.lastDriverStatus == "en_route_pickup")
        #expect(session.lastDriverStateTimestamp == 1000)
        #expect(session.lastDriverActionCount == 2)
        #expect(session.restoredSavedAt == 999)
    }

    @Test func restoreWithInvalidDriverPubkeyResetsCompletely() throws {
        let session = try makeSession().session
        session.restore(
            stage: .driverAccepted,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: nil,
            driverPubkey: nil,
            pin: nil,
            pinVerified: false,
            paymentMethod: nil,
            fiatPaymentMethods: [],
            processedPinActionKeys: ["stale_key"],
            precisePickup: Location(latitude: 1, longitude: 2),
            preciseDestination: Location(latitude: 3, longitude: 4),
            savedAt: 999
        )
        // State machine rejects nil driverPubkey for non-idle stages.
        // Session must also clear its own state — no stale data left behind.
        #expect(session.stage == .idle)
        #expect(session.processedPinActionKeys.isEmpty)
        #expect(session.precisePickup == nil)
        #expect(session.preciseDestination == nil)
        #expect(session.lastDriverStatus == nil)
        #expect(session.restoredSavedAt == 0)
    }

    // MARK: - Reset

    @Test func resetClearsEverything() throws {
        let session = try makeSession().session
        let driverPubkey = String(repeating: "c", count: 64)
        session.restore(
            stage: .inProgress,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "c1",
            driverPubkey: driverPubkey,
            pin: "0000",
            pinVerified: true,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            precisePickupShared: true,
            preciseDestinationShared: true,
            processedPinActionKeys: ["key1"],
            precisePickup: Location(latitude: 1, longitude: 2),
            preciseDestination: Location(latitude: 3, longitude: 4),
            savedAt: 500
        )

        session.reset()

        #expect(session.stage == .idle)
        #expect(session.pin == nil)
        #expect(session.driverPubkey == nil)
        #expect(session.processedPinActionKeys.isEmpty)
        #expect(session.precisePickup == nil)
        #expect(session.preciseDestination == nil)
        #expect(session.lastError == nil)
        #expect(session.lastDriverStatus == nil)
        #expect(session.lastDriverStateTimestamp == 0)
        #expect(session.lastDriverActionCount == 0)
        #expect(session.restoredSavedAt == 0)
    }

    // MARK: - Configuration

    @Test func defaultConfigurationMatchesConstants() throws {
        let config = RiderRideSession.Configuration.default
        #expect(config.stageTimeouts.waitingForAcceptance == .seconds(120))
        #expect(config.stageTimeouts.driverAccepted == .seconds(30))
        #expect(config.confirmationRetryDelays == [.zero, .seconds(1), .seconds(3)])
        #expect(config.maxPinActionSetSize == 10)
    }

    @Test func customConfigurationIsRespected() throws {
        let config = RiderRideSession.Configuration(
            stageTimeouts: .init(waitingForAcceptance: .milliseconds(50), driverAccepted: .milliseconds(25)),
            confirmationRetryDelays: [.zero],
            maxPinActionSetSize: 3
        )
        let (session, _) = try makeSession(configuration: config)

        #expect(session.configuration.stageTimeouts.waitingForAcceptance == .milliseconds(50))
        #expect(session.configuration.maxPinActionSetSize == 3)
    }

    // MARK: - Send Offer

    @Test func sendOfferTransitionsToWaitingForAcceptance() async throws {
        let (session, relay) = try makeSession()
        relay.keepSubscriptionsAlive = true

        await session.sendOffer(
            driverPubkey: String(repeating: "d", count: 64),
            content: makeOfferContent(),
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )

        #expect(session.stage == .waitingForAcceptance)
        #expect(session.precisePickup != nil)
        #expect(session.preciseDestination != nil)
        #expect(relay.publishedEvents.count == 1)
        // Subscription task starts asynchronously — yield to let it run
        try await Task.sleep(for: .milliseconds(50))
        #expect(relay.subscribeCalls.count == 1) // acceptance subscription
    }

    @Test func sendOfferSetsErrorOnPublishFailure() async throws {
        let (session, relay) = try makeSession()
        relay.shouldFailPublish = true

        await session.sendOffer(
            driverPubkey: String(repeating: "d", count: 64),
            content: makeOfferContent(),
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )

        #expect(session.stage == .idle) // Should not advance
        #expect(session.lastError != nil)
    }

    @Test func sendOfferFromNonIdleDoesNotPublishGhostOffer() async throws {
        let (session, relay) = try makeSession()
        let tracker = DelegateTracker()
        session.delegate = tracker
        let driverPubkey = String(repeating: "d", count: 64)

        session.restore(
            stage: .waitingForAcceptance,
            offerEventId: "o1",
            acceptanceEventId: nil,
            confirmationEventId: nil,
            driverPubkey: driverPubkey,
            pin: nil,
            pinVerified: false,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"]
        )

        await session.sendOffer(
            driverPubkey: driverPubkey,
            content: makeOfferContent(),
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )

        #expect(session.stage == .waitingForAcceptance)
        #expect(relay.publishedEvents.isEmpty)
        #expect(tracker.errors.count == 1)
        #expect(tracker.persistCount == 0)
    }

    // MARK: - Cancel Ride

    @Test func cancelRideFromWaitingResetsToIdle() async throws {
        let (session, relay) = try makeSession()
        relay.keepSubscriptionsAlive = true

        await session.sendOffer(
            driverPubkey: String(repeating: "d", count: 64),
            content: makeOfferContent(),
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )
        #expect(session.stage == .waitingForAcceptance)

        await session.cancelRide(reason: "changed my mind")
        #expect(session.stage == .idle)
        // Offer deletion event should be published
        #expect(relay.publishedEvents.count >= 2) // offer + deletion
    }

    // MARK: - Dismiss Completed Ride

    @Test func dismissCompletedRideClearsAllState() async throws {
        let (session, _) = try makeSession()
        let driverPubkey = String(repeating: "d", count: 64)
        session.restore(
            stage: .completed,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "c1",
            driverPubkey: driverPubkey,
            pin: "1234",
            pinVerified: true,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            precisePickupShared: true,
            preciseDestinationShared: true,
            lastDriverStatus: "completed",
            lastDriverStateTimestamp: 999,
            lastDriverActionCount: 5,
            processedPinActionKeys: ["key1"],
            precisePickup: Location(latitude: 1, longitude: 2),
            preciseDestination: Location(latitude: 3, longitude: 4),
            savedAt: 500
        )
        #expect(session.stage == .completed)

        await session.dismissCompletedRide()
        #expect(session.stage == .idle)
        #expect(session.precisePickup == nil)
        #expect(session.preciseDestination == nil)
        #expect(session.processedPinActionKeys.isEmpty)
        #expect(session.lastDriverStatus == nil)
        #expect(session.lastDriverStateTimestamp == 0)
        #expect(session.lastDriverActionCount == 0)
        #expect(session.lastError == nil)
        #expect(session.restoredSavedAt == 0)
    }

    @Test func dismissCompletedRideIgnoredIfNotCompleted() async throws {
        let (session, _) = try makeSession()
        #expect(session.stage == .idle)
        await session.dismissCompletedRide()
        #expect(session.stage == .idle) // No crash, no-op
    }

    // MARK: - Restore Subscriptions

    @Test func restoreSubscriptionsFromConfirmedRideStartsSubs() async throws {
        let (session, relay) = try makeSession()
        relay.keepSubscriptionsAlive = true
        let driverPubkey = String(repeating: "d", count: 64)

        session.restore(
            stage: .rideConfirmed,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "c1",
            driverPubkey: driverPubkey,
            pin: "1234",
            pinVerified: false,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            precisePickupShared: true
        )

        await session.restoreSubscriptions()
        try await Task.sleep(for: .milliseconds(50))

        // Should have 2 subs: driver-state + cancellation
        #expect(relay.subscribeCalls.count == 2)
    }

    @Test func restoreSubscriptionsFromWaitingStartsAcceptanceSub() async throws {
        let (session, relay) = try makeSession()
        relay.keepSubscriptionsAlive = true
        let driverPubkey = String(repeating: "d", count: 64)

        session.restore(
            stage: .waitingForAcceptance,
            offerEventId: "o1",
            acceptanceEventId: nil,
            confirmationEventId: nil,
            driverPubkey: driverPubkey,
            pin: nil,
            pinVerified: false,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"]
        )

        await session.restoreSubscriptions()
        try await Task.sleep(for: .milliseconds(50))

        #expect(relay.subscribeCalls.count == 1) // acceptance sub
    }

    @Test func restoreSubscriptionsRecoveryFiresStageChangeAndStartsConfirmedSubscriptions() async throws {
        let (session, relay, rider) = try makeSessionBundle()
        relay.keepSubscriptionsAlive = true
        let driver = try NostrKeypair.generate()
        let tracker = DelegateTracker()
        session.delegate = tracker
        let offerEventId = String(repeating: "d", count: 64)
        let acceptanceEventId = String(repeating: "a", count: 64)

        session.restore(
            stage: .driverAccepted,
            offerEventId: offerEventId,
            acceptanceEventId: acceptanceEventId,
            confirmationEventId: nil,
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinVerified: false,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            precisePickupShared: false
        )

        relay.fetchResults = [
            try await RideshareEventBuilder.rideConfirmation(
                driverPubkey: driver.publicKeyHex,
                acceptanceEventId: acceptanceEventId,
                precisePickup: Location(latitude: 40.71, longitude: -74.01),
                keypair: rider
            )
        ]

        await session.restoreSubscriptions()
        try await Task.sleep(for: .milliseconds(50))

        #expect(session.stage == .rideConfirmed)
        #expect(tracker.stageChanges.count == 1)
        #expect(tracker.stageChanges.first?.from == .driverAccepted)
        #expect(tracker.stageChanges.first?.to == .rideConfirmed)
        #expect(tracker.persistCount >= 1)
        #expect(relay.subscribeCalls.count == 2)
        #expect(relay.subscribeCalls.contains { $0.id.rawValue.hasPrefix("driver-state-") })
        #expect(relay.subscribeCalls.contains { $0.id.rawValue.hasPrefix("cancel-") })
    }

    // MARK: - Delegate Tracking

    @Test func sendOfferFiresDelegateCallbacks() async throws {
        let (session, relay) = try makeSession()
        relay.keepSubscriptionsAlive = true
        let tracker = DelegateTracker()
        session.delegate = tracker

        await session.sendOffer(
            driverPubkey: String(repeating: "d", count: 64),
            content: makeOfferContent(),
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )

        #expect(tracker.stageChanges.count == 1)
        #expect(tracker.stageChanges.first?.from == .idle)
        #expect(tracker.stageChanges.first?.to == .waitingForAcceptance)
        #expect(tracker.persistCount >= 1)
    }

    @Test func cancelRideFiresTerminalCallback() async throws {
        let (session, relay) = try makeSession()
        relay.keepSubscriptionsAlive = true
        let tracker = DelegateTracker()
        session.delegate = tracker

        await session.sendOffer(
            driverPubkey: String(repeating: "d", count: 64),
            content: makeOfferContent(),
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )
        tracker.reset()

        await session.cancelRide(reason: "test")

        #expect(tracker.stageChanges.count == 1)
        #expect(tracker.stageChanges.first?.to == .idle)
        #expect(tracker.terminalOutcomes.count == 1)
        if case .cancelledByRider = tracker.terminalOutcomes.first {} else {
            Issue.record("Expected cancelledByRider, got \(String(describing: tracker.terminalOutcomes.first))")
        }
        #expect(tracker.persistCount >= 1)
    }

    @Test func bruteForcePinFiresTerminalCallbackAndPublishesCancellation() async throws {
        let (session, relay, rider) = try makeSessionBundle()
        let driver = try NostrKeypair.generate()
        let tracker = DelegateTracker()
        session.delegate = tracker
        let offerEventId = String(repeating: "a", count: 64)
        let acceptanceEventId = String(repeating: "b", count: 64)
        let confirmationEventId = String(repeating: "c", count: 64)

        session.restore(
            stage: .driverArrived,
            offerEventId: offerEventId,
            acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId,
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinAttempts: RideConstants.maxPinAttempts - 1,
            pinVerified: false,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            precisePickupShared: true,
            preciseDestinationShared: false,
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )

        let wrongPinEncrypted = try NIP44.encrypt(
            plaintext: "9999",
            senderKeypair: driver,
            recipientPublicKeyHex: rider.publicKeyHex
        )

        await session.respondToPin(pinEncrypted: wrongPinEncrypted)

        #expect(session.stage == .idle)
        #expect(tracker.stageChanges.count == 1)
        #expect(tracker.stageChanges.first?.from == .driverArrived)
        #expect(tracker.stageChanges.first?.to == .idle)
        #expect(tracker.terminalOutcomes.count == 1)
        if case .bruteForcePin = tracker.terminalOutcomes.first {} else {
            Issue.record("Expected .bruteForcePin terminal outcome, got \(String(describing: tracker.terminalOutcomes.first))")
        }
        #expect(tracker.persistCount >= 1)
        #expect(relay.publishedEvents.contains { $0.kind == EventKind.riderRideState.rawValue })
        #expect(relay.publishedEvents.contains { $0.kind == EventKind.cancellation.rawValue })
        #expect(session.precisePickup == nil)
        #expect(session.preciseDestination == nil)
    }

    @Test func bruteForcePinCancelsEvenWhenRiderStatePublishFails() async throws {
        let (session, relay, rider) = try makeSessionBundle()
        let driver = try NostrKeypair.generate()
        let tracker = DelegateTracker()
        session.delegate = tracker

        relay.shouldFailPublish = true

        session.restore(
            stage: .driverArrived,
            offerEventId: String(repeating: "a", count: 64),
            acceptanceEventId: String(repeating: "b", count: 64),
            confirmationEventId: String(repeating: "c", count: 64),
            driverPubkey: driver.publicKeyHex,
            pin: "1234",
            pinAttempts: RideConstants.maxPinAttempts - 1,
            pinVerified: false,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            precisePickupShared: true,
            preciseDestinationShared: false,
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )

        let wrongPinEncrypted = try NIP44.encrypt(
            plaintext: "9999",
            senderKeypair: driver,
            recipientPublicKeyHex: rider.publicKeyHex
        )

        await session.respondToPin(pinEncrypted: wrongPinEncrypted)

        #expect(session.stage == .idle)
        #expect(tracker.errors.count == 1)
        #expect(tracker.stageChanges.count == 1)
        #expect(tracker.stageChanges.first?.from == .driverArrived)
        #expect(tracker.stageChanges.first?.to == .idle)
        #expect(tracker.persistCount >= 1)
        #expect(tracker.terminalOutcomes.count == 1)
        if case .bruteForcePin = tracker.terminalOutcomes.first {} else {
            Issue.record("Expected .bruteForcePin terminal outcome, got \(String(describing: tracker.terminalOutcomes.first))")
        }
        #expect(relay.publishedEvents.isEmpty)
    }

    @Test func dismissCompletedFiresStageChangeNotTerminal() async throws {
        let (session, _) = try makeSession()
        let tracker = DelegateTracker()
        session.delegate = tracker

        session.restore(
            stage: .completed,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "c1",
            driverPubkey: String(repeating: "d", count: 64),
            pin: "1234",
            pinVerified: true,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            precisePickupShared: true,
            preciseDestinationShared: true
        )

        await session.dismissCompletedRide()

        #expect(tracker.stageChanges.count == 1)
        #expect(tracker.stageChanges.first?.from == .completed)
        #expect(tracker.stageChanges.first?.to == .idle)
        #expect(tracker.terminalOutcomes.isEmpty) // No terminal callback for dismiss
    }

    // MARK: - Stage Timeouts

    @Test func waitingForAcceptanceTimesOut() async throws {
        let config = RiderRideSession.Configuration(
            stageTimeouts: .init(waitingForAcceptance: .milliseconds(50), driverAccepted: .milliseconds(50)),
            confirmationRetryDelays: [.zero],
            maxPinActionSetSize: 10
        )
        let (session, relay) = try makeSession(configuration: config)
        relay.keepSubscriptionsAlive = true
        let tracker = DelegateTracker()
        session.delegate = tracker

        await session.sendOffer(
            driverPubkey: String(repeating: "d", count: 64),
            content: makeOfferContent(),
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )
        #expect(session.stage == .waitingForAcceptance)
        tracker.reset()

        // Wait for timeout to fire
        try await Task.sleep(for: .milliseconds(200))

        #expect(session.stage == .idle)
        #expect(tracker.terminalOutcomes.count == 1)
        if case .expired(let stage) = tracker.terminalOutcomes.first {
            #expect(stage == .waitingForAcceptance)
        } else {
            Issue.record("Expected .expired(.waitingForAcceptance)")
        }
        #expect(tracker.persistCount >= 1)
    }

    @Test func timeoutCancelledWhenStageAdvances() async throws {
        let config = RiderRideSession.Configuration(
            stageTimeouts: .init(waitingForAcceptance: .milliseconds(200), driverAccepted: .milliseconds(200)),
            confirmationRetryDelays: [.zero],
            maxPinActionSetSize: 10
        )
        let (session, relay) = try makeSession(configuration: config)
        relay.keepSubscriptionsAlive = true

        await session.sendOffer(
            driverPubkey: String(repeating: "d", count: 64),
            content: makeOfferContent(),
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )
        #expect(session.stage == .waitingForAcceptance)

        // Cancel before timeout fires
        await session.cancelRide(reason: "test")
        #expect(session.stage == .idle)

        // Wait past the original timeout
        try await Task.sleep(for: .milliseconds(300))

        // Should still be idle (timeout should not have fired)
        #expect(session.stage == .idle)
    }

    @Test func restoreWithExpiredTimeoutFiresImmediately() async throws {
        let config = RiderRideSession.Configuration(
            stageTimeouts: .init(waitingForAcceptance: .milliseconds(50), driverAccepted: .milliseconds(50)),
            confirmationRetryDelays: [.zero],
            maxPinActionSetSize: 10
        )
        let (session, relay) = try makeSession(configuration: config)
        relay.keepSubscriptionsAlive = true
        let tracker = DelegateTracker()
        session.delegate = tracker

        let driverPubkey = String(repeating: "d", count: 64)
        // Restore with savedAt far in the past (timeout already expired)
        session.restore(
            stage: .waitingForAcceptance,
            offerEventId: "o1",
            acceptanceEventId: nil,
            confirmationEventId: nil,
            driverPubkey: driverPubkey,
            pin: nil,
            pinVerified: false,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            savedAt: Int(Date.now.timeIntervalSince1970) - 300 // 5 minutes ago
        )

        await session.restoreSubscriptions()

        // Give timeout task time to fire
        try await Task.sleep(for: .milliseconds(100))

        #expect(session.stage == .idle)
        if case .expired = tracker.terminalOutcomes.first {} else {
            Issue.record("Expected .expired terminal outcome, got \(tracker.terminalOutcomes)")
        }
    }

    // MARK: - Cancel Guard

    @Test func cancelRideNoOpsFromIdle() async throws {
        let (session, _) = try makeSession()
        let tracker = DelegateTracker()
        session.delegate = tracker

        await session.cancelRide(reason: "test")

        #expect(session.stage == .idle)
        #expect(tracker.terminalOutcomes.isEmpty) // No terminal callback
        #expect(tracker.persistCount == 0) // No persist
    }

    @Test func cancelRideNoOpsFromCompleted() async throws {
        let (session, _) = try makeSession()
        session.restore(
            stage: .completed,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "c1",
            driverPubkey: String(repeating: "d", count: 64),
            pin: "1234",
            pinVerified: true,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            precisePickupShared: true,
            preciseDestinationShared: true
        )
        let tracker = DelegateTracker()
        session.delegate = tracker

        await session.cancelRide(reason: "test")

        #expect(session.stage == .completed) // Not reset
        #expect(tracker.terminalOutcomes.isEmpty)
    }

    // MARK: - Subscription Resilience

    @Test func subscribeThrowCleansUpEntry() async throws {
        let (session, relay) = try makeSession()
        relay.keepSubscriptionsAlive = true
        relay.shouldFailSubscribe = true

        await session.sendOffer(
            driverPubkey: String(repeating: "d", count: 64),
            content: makeOfferContent(),
            precisePickup: Location(latitude: 40.71, longitude: -74.01),
            preciseDestination: Location(latitude: 40.76, longitude: -73.98)
        )
        // Subscription should have failed — give task time to run and clean up
        try await Task.sleep(for: .milliseconds(50))

        // Re-enable subscriptions and reconcile — should restart
        relay.shouldFailSubscribe = false
        await session.restoreSubscriptions()
        try await Task.sleep(for: .milliseconds(50))

        // Should have attempted subscribe again successfully
        let successfulCalls = relay.subscribeCalls.filter { !$0.id.rawValue.isEmpty }
        #expect(successfulCalls.count >= 1)
    }

    @Test func streamFinishThenRestoreRestartsSubscription() async throws {
        let (session, relay) = try makeSession()
        relay.keepSubscriptionsAlive = true
        let driverPubkey = String(repeating: "d", count: 64)

        session.restore(
            stage: .rideConfirmed,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "c1",
            driverPubkey: driverPubkey,
            pin: "1234",
            pinVerified: false,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            precisePickupShared: true
        )

        await session.restoreSubscriptions()
        try await Task.sleep(for: .milliseconds(50))
        let initialSubCount = relay.subscribeCalls.count
        #expect(initialSubCount == 2) // driver-state + cancellation

        // Simulate relay closing the stream
        relay.finishSubscription("driver-state-c1")
        try await Task.sleep(for: .milliseconds(50))

        // Restore again (reconnect scenario) — should restart the dead sub
        relay.resetRecording()
        await session.restoreSubscriptions()
        try await Task.sleep(for: .milliseconds(50))

        #expect(relay.subscribeCalls.count == 2) // Both restarted
    }

    @Test func repeatedRestoreThenTeardownLeavesNoLiveSubscriptions() async throws {
        let (session, relay) = try makeSession()
        relay.keepSubscriptionsAlive = true
        let driverPubkey = String(repeating: "d", count: 64)

        session.restore(
            stage: .rideConfirmed,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "c1",
            driverPubkey: driverPubkey,
            pin: "1234",
            pinVerified: false,
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"],
            precisePickupShared: true
        )

        await session.restoreSubscriptions()
        try await Task.sleep(for: .milliseconds(50))
        await session.restoreSubscriptions()
        try await Task.sleep(for: .milliseconds(50))
        await session.teardownAll()
        try await Task.sleep(for: .milliseconds(50))

        #expect(relay.activeSubscriptionCount == 0)
    }

    // MARK: - Helpers

    private func makeOfferContent() -> RideOfferContent {
        RideOfferContent(
            fareEstimate: 10_000,
            destination: Location(latitude: 40.758, longitude: -73.985),
            approxPickup: Location(latitude: 40.710, longitude: -74.010),
            paymentMethod: "cash",
            fiatPaymentMethods: ["cash"]
        )
    }
}

// MARK: - Delegate Tracker

@MainActor
private final class DelegateTracker: RiderRideSessionDelegate {
    var stageChanges: [(from: RiderStage, to: RiderStage)] = []
    var terminalOutcomes: [RideSessionTerminalOutcome] = []
    var errors: [Error] = []
    var persistCount = 0

    func sessionDidReachTerminal(_ outcome: RideSessionTerminalOutcome) {
        terminalOutcomes.append(outcome)
    }

    func sessionDidEncounterError(_ error: Error) {
        errors.append(error)
    }

    func sessionDidChangeStage(from: RiderStage, to: RiderStage) {
        stageChanges.append((from: from, to: to))
    }

    func sessionShouldPersist() {
        persistCount += 1
    }

    func reset() {
        stageChanges.removeAll()
        terminalOutcomes.removeAll()
        errors.removeAll()
        persistCount = 0
    }
}
