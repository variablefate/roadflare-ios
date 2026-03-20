import Foundation
import Testing
@testable import RidestrSDK

@Suite("processEvent() Direct Tests")
struct ProcessEventTests {

    // MARK: - Happy Path via processEvent()

    @Test func sendOfferFromIdle() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        let result = sm.processEvent(.sendOffer(
            offerEventId: "o1", driverPubkey: "driver1",
            paymentMethod: .zelle, fiatPaymentMethods: [.zelle, .venmo]
        ))

        if case .success(let from, let to, let ctx) = result {
            #expect(from == .idle)
            #expect(to == .waitingForAcceptance)
            #expect(ctx.offerEventId == "o1")
            #expect(ctx.driverPubkey == "driver1")
            #expect(ctx.paymentMethod == .zelle)
            #expect(sm.stage == .waitingForAcceptance)
        } else {
            Issue.record("Expected success, got \(result)")
        }
    }

    @Test func acceptanceReceivedGeneratesPin() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        sm.processEvent(.sendOffer(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: []))
        let result = sm.processEvent(.acceptanceReceived(acceptanceEventId: "acc1"))

        if case .success(_, let to, let ctx) = result {
            #expect(to == .driverAccepted)
            #expect(ctx.pin != nil)
            #expect(ctx.pin!.count == RideConstants.pinDigits)
            #expect(ctx.acceptanceEventId == "acc1")
        } else {
            Issue.record("Expected success")
        }
    }

    @Test func confirmRecordsConfirmationId() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        sm.processEvent(.sendOffer(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: []))
        sm.processEvent(.acceptanceReceived(acceptanceEventId: "acc1"))
        let result = sm.processEvent(.confirm(confirmationEventId: "conf1"))

        if case .success(_, let to, let ctx) = result {
            #expect(to == .rideConfirmed)
            #expect(ctx.confirmationEventId == "conf1")
        } else {
            Issue.record("Expected success")
        }
    }

    @Test func cancelFromAnyActiveStage() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        sm.processEvent(.sendOffer(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: []))
        #expect(sm.stage == .waitingForAcceptance)

        let result = sm.processEvent(.cancel(eventId: "c1", confirmationId: ""))
        if case .success(_, let to, _) = result {
            #expect(to == .idle)
            #expect(sm.stage == .idle)
        } else {
            Issue.record("Expected success")
        }
    }

    @Test func confirmationTimeoutFromWaiting() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        sm.processEvent(.sendOffer(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: []))
        let result = sm.processEvent(.confirmationTimeout)

        if case .success(_, let to, _) = result {
            #expect(to == .idle)
        } else {
            Issue.record("Expected success")
        }
    }

    // MARK: - Invalid Transitions

    @Test func confirmFromIdleIsInvalid() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        let result = sm.processEvent(.confirm(confirmationEventId: "c1"))

        if case .invalidTransition(let state, let eventType) = result {
            #expect(state == .idle)
            #expect(eventType == "CONFIRM")
        } else {
            Issue.record("Expected invalidTransition")
        }
    }

    @Test func verifyPinFromIdleIsInvalid() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        let result = sm.processEvent(.verifyPin(verified: true, attempt: 1))

        if case .invalidTransition = result {
            // Expected
        } else {
            Issue.record("Expected invalidTransition")
        }
    }

    // MARK: - PIN Verification via processEvent()

    @Test func pinVerifiedTransitionsToInProgress() {
        let sm = setupAtDriverArrived()
        let result = sm.processEvent(.verifyPin(verified: true, attempt: 1))

        if case .success(_, let to, let ctx) = result {
            #expect(to == .inProgress)
            #expect(ctx.pinVerified)
            #expect(ctx.pinAttempts == 1)
        } else {
            Issue.record("Expected success")
        }
    }

    @Test func pinBruteForceTransitionsToIdle() {
        let sm = setupAtDriverArrived()
        // Fail twice first (via processEvent)
        sm.processEvent(.verifyPin(verified: false, attempt: 1))
        sm.processEvent(.verifyPin(verified: false, attempt: 2))
        #expect(sm.stage == .driverArrived)
        #expect(sm.pinAttempts == 2)

        // Third failure triggers brute force guard
        let result = sm.processEvent(.verifyPin(verified: false, attempt: 3))
        if case .success(_, let to, _) = result {
            #expect(to == .idle)
        } else {
            Issue.record("Expected success (brute force → idle)")
        }
    }

    @Test func pinFailedStaysAtDriverArrived() {
        let sm = setupAtDriverArrived()
        let result = sm.processEvent(.verifyPin(verified: false, attempt: 1))

        if case .success(_, let to, let ctx) = result {
            #expect(to == .driverArrived)
            #expect(!ctx.pinVerified)
            #expect(ctx.pinAttempts == 1)
        } else {
            Issue.record("Expected success (self-transition)")
        }
    }

    // MARK: - Timestamp Deduplication

    @Test func receiveDriverStateRejectsOlderTimestamp() throws {
        let sm = RideStateMachine(riderPubkey: "rider1")
        sm.processEvent(.sendOffer(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: []))
        sm.processEvent(.acceptanceReceived(acceptanceEventId: "a1"))
        sm.processEvent(.confirm(confirmationEventId: "c1"))

        let state1 = DriverRideStateContent(currentStatus: "en_route_pickup", history: [])
        let r1 = sm.receiveDriverStateEvent(eventId: "e1", confirmationId: "c1", driverState: state1, createdAt: 1000)
        #expect(r1 == "en_route_pickup")
        #expect(sm.stage == .enRoute)

        // Older timestamp should be rejected
        let state2 = DriverRideStateContent(currentStatus: "arrived", history: [])
        let r2 = sm.receiveDriverStateEvent(eventId: "e2", confirmationId: "c1", driverState: state2, createdAt: 900)
        #expect(r2 == nil)
        #expect(sm.stage == .enRoute) // Unchanged
    }

    @Test func receiveDriverStateAcceptsNewerTimestamp() throws {
        let sm = RideStateMachine(riderPubkey: "rider1")
        sm.processEvent(.sendOffer(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: []))
        sm.processEvent(.acceptanceReceived(acceptanceEventId: "a1"))
        sm.processEvent(.confirm(confirmationEventId: "c1"))

        let state1 = DriverRideStateContent(currentStatus: "en_route_pickup", history: [])
        _ = sm.receiveDriverStateEvent(eventId: "e1", confirmationId: "c1", driverState: state1, createdAt: 1000)

        let state2 = DriverRideStateContent(currentStatus: "arrived", history: [])
        let r2 = sm.receiveDriverStateEvent(eventId: "e2", confirmationId: "c1", driverState: state2, createdAt: 1100)
        #expect(r2 == "arrived")
        #expect(sm.stage == .driverArrived)
    }

    // MARK: - RideContext Copy Methods

    @Test func rideContextWithDriverPreservesFields() {
        let ctx = RideContext(riderPubkey: "r1", offerEventId: "o1", paymentMethod: .zelle, fiatPaymentMethods: [.zelle])
        let ctx2 = ctx.withDriver(driverPubkey: "d1", acceptanceEventId: "a1")

        #expect(ctx2.driverPubkey == "d1")
        #expect(ctx2.acceptanceEventId == "a1")
        #expect(ctx2.offerEventId == "o1")
        #expect(ctx2.paymentMethod == .zelle)
        #expect(ctx2.riderPubkey == "r1")
    }

    @Test func rideContextWithPinAttemptIncrements() {
        let ctx = RideContext(riderPubkey: "r1", pinAttempts: 1, pinVerified: false)
        let ctx2 = ctx.withPinAttempt(verified: false)
        #expect(ctx2.pinAttempts == 2)
        #expect(!ctx2.pinVerified)

        let ctx3 = ctx2.withPinAttempt(verified: true)
        #expect(ctx3.pinAttempts == 3)
        #expect(ctx3.pinVerified)
    }

    @Test func rideContextWithPrecisePickupShared() {
        let ctx = RideContext(riderPubkey: "r1", precisePickupShared: false)
        let ctx2 = ctx.withPrecisePickupShared(true)
        #expect(ctx2.precisePickupShared)
        #expect(!ctx2.preciseDestinationShared)
    }

    @Test func rideContextWithRiderAction() {
        let ctx = RideContext(riderPubkey: "r1")
        #expect(ctx.riderStateHistory.isEmpty)

        let action = RiderRideAction(type: "pin_verify", at: 1000, locationType: nil, locationEncrypted: nil, status: "verified", attempt: 1)
        let ctx2 = ctx.withRiderAction(action)
        #expect(ctx2.riderStateHistory.count == 1)
        #expect(ctx2.riderStateHistory[0].type == "pin_verify")
    }

    // MARK: - canTransition()

    @Test func canTransitionFromIdle() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        #expect(sm.canTransition(event: .sendOffer(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])))
        #expect(!sm.canTransition(event: .confirm(confirmationEventId: "c1")))
    }

    // MARK: - Delegate Callbacks

    @Test func delegateNotifiedOnTransition() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        let delegate = MockDelegate()
        sm.delegate = delegate

        sm.processEvent(.sendOffer(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: []))

        #expect(delegate.transitionCount == 1)
        #expect(delegate.lastFrom == .idle)
        #expect(delegate.lastTo == .waitingForAcceptance)
    }

    @Test func delegateNotifiedOnFailure() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        let delegate = MockDelegate()
        sm.delegate = delegate

        sm.processEvent(.confirm(confirmationEventId: "c1"))

        #expect(delegate.failureCount == 1)
    }

    // MARK: - State Consistency

    @Test func contextAndStageStaySynced() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        sm.processEvent(.sendOffer(offerEventId: "o1", driverPubkey: "d1", paymentMethod: .cash, fiatPaymentMethods: [.cash]))

        // All computed properties should reflect context
        #expect(sm.offerEventId == sm.context.offerEventId)
        #expect(sm.driverPubkey == sm.context.driverPubkey)
        #expect(sm.paymentMethod == sm.context.paymentMethod)
    }

    @Test func markPrecisePickupUpdatesContext() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        #expect(!sm.precisePickupShared)
        #expect(!sm.context.precisePickupShared)

        sm.markPrecisePickupShared()

        #expect(sm.precisePickupShared)
        #expect(sm.context.precisePickupShared) // Must be in sync
    }

    @Test func addRiderActionUpdatesContext() {
        let sm = RideStateMachine(riderPubkey: "rider1")
        let action = RiderRideAction(type: "location_reveal", at: 1000, locationType: "pickup", locationEncrypted: "enc", status: nil, attempt: nil)
        sm.addRiderAction(action)

        #expect(sm.riderStateHistory.count == 1)
        #expect(sm.context.riderStateHistory.count == 1) // Must be in sync
    }

    // MARK: - Helpers

    private func setupAtDriverArrived() -> RideStateMachine {
        let sm = RideStateMachine(riderPubkey: "rider1")
        sm.processEvent(.sendOffer(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: []))
        sm.processEvent(.acceptanceReceived(acceptanceEventId: "a1"))
        sm.processEvent(.confirm(confirmationEventId: "c1"))
        let arrived = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = sm.receiveDriverStateEvent(eventId: "ds1", confirmationId: "c1", driverState: arrived)
        return sm
    }
}

// MARK: - Mock Delegate

final class MockDelegate: StateMachineDelegate, @unchecked Sendable {
    var transitionCount = 0
    var failureCount = 0
    var lastFrom: RiderStage?
    var lastTo: RiderStage?

    func stateMachineDidTransition(from: RiderStage, to: RiderStage, event: RideEvent) {
        transitionCount += 1
        lastFrom = from
        lastTo = to
    }

    func stateMachineTransitionFailed(result: TransitionResult, event: RideEvent) {
        failureCount += 1
    }
}
