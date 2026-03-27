import Testing
@testable import RidestrSDK

@Suite("RiderRideSession Tests")
@MainActor
struct RiderRideSessionTests {

    private func makeSession(
        configuration: RiderRideSession.Configuration = .default
    ) throws -> (session: RiderRideSession, relay: FakeRelayManager) {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let session = RiderRideSession(
            relayManager: relay,
            keypair: keypair,
            configuration: configuration
        )
        return (session, relay)
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
}
