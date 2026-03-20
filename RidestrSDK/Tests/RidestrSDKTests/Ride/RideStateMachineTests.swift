import Foundation
import Testing
@testable import RidestrSDK

@Suite("RideStateMachine Tests")
struct RideStateMachineTests {
    @Test func initialState() {
        let sm = RideStateMachine()
        #expect(sm.stage == .idle)
        #expect(sm.pin == nil)
        #expect(sm.confirmationEventId == nil)
        #expect(sm.driverPubkey == nil)
        #expect(!sm.pinVerified)
        #expect(sm.pinAttempts == 0)
    }

    @Test func startRide() throws {
        let sm = RideStateMachine()
        try sm.startRide(
            offerEventId: "offer1",
            driverPubkey: "driver_pub",
            paymentMethod: .zelle,
            fiatPaymentMethods: [.zelle, .venmo]
        )
        #expect(sm.stage == .waitingForAcceptance)
        #expect(sm.offerEventId == "offer1")
        #expect(sm.driverPubkey == "driver_pub")
        #expect(sm.paymentMethod == .zelle)
        #expect(sm.fiatPaymentMethods == [.zelle, .venmo])
    }

    @Test func handleAcceptanceGeneratesPin() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: .cash, fiatPaymentMethods: [])
        let pin = try sm.handleAcceptance(acceptanceEventId: "acc1")
        #expect(sm.stage == .driverAccepted)
        #expect(pin.count == RideConstants.pinDigits)
        #expect(sm.pin == pin)
        #expect(sm.acceptanceEventId == "acc1")
    }

    @Test func recordConfirmation() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")
        #expect(sm.stage == .rideConfirmed)
        #expect(sm.confirmationEventId == "conf1")
    }

    @Test func fullHappyPathTransitions() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: .venmo, fiatPaymentMethods: [.venmo])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        // Driver state updates (AtoB pattern)
        let driverEnRoute = DriverRideStateContent(
            currentStatus: "en_route_pickup",
            history: [DriverRideAction(type: "status", at: 100, status: "en_route_pickup", approxLocation: nil, finalFare: nil, invoice: nil, pinEncrypted: nil)]
        )
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: driverEnRoute)
        #expect(sm.stage == .enRoute)

        let driverArrived = DriverRideStateContent(
            currentStatus: "arrived",
            history: []
        )
        _ = try sm.handleDriverStateUpdate(eventId: "ds2", confirmationId: "conf1", driverState: driverArrived)
        #expect(sm.stage == .driverArrived)

        let driverInProgress = DriverRideStateContent(
            currentStatus: "in_progress",
            history: []
        )
        _ = try sm.handleDriverStateUpdate(eventId: "ds3", confirmationId: "conf1", driverState: driverInProgress)
        #expect(sm.stage == .inProgress)

        let driverCompleted = DriverRideStateContent(
            currentStatus: "completed",
            history: []
        )
        _ = try sm.handleDriverStateUpdate(eventId: "ds4", confirmationId: "conf1", driverState: driverCompleted)
        #expect(sm.stage == .completed)
    }

    @Test func invalidTransitionThrows() {
        let sm = RideStateMachine()
        #expect(throws: RidestrError.self) {
            try sm.transition(to: .inProgress)  // Can't go from idle to inProgress
        }
    }

    @Test func cancellationFromAnyStage() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")
        #expect(sm.stage == .rideConfirmed)

        let processed = sm.handleCancellation(eventId: "cancel1", confirmationId: "conf1")
        #expect(processed)
        #expect(sm.stage == .idle)
    }

    @Test func deduplicateDriverStateEvents() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        let state = DriverRideStateContent(currentStatus: "arrived", history: [])
        let first = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: state)
        #expect(first == "arrived")
        let second = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: state)
        #expect(second == nil)  // Deduplicated
    }

    @Test func wrongConfirmationIdIgnored() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        let state = DriverRideStateContent(currentStatus: "arrived", history: [])
        let result = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "wrong_conf", driverState: state)
        #expect(result == nil)
        #expect(sm.stage == .rideConfirmed)  // Unchanged
    }

    @Test func deduplicateCancellations() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        let first = sm.handleCancellation(eventId: "c1", confirmationId: "conf1")
        #expect(first)
        // Reset for testing - normally you wouldn't re-enter a ride after cancel
        try sm.startRide(offerEventId: "o2", driverPubkey: "d2", paymentMethod: nil, fiatPaymentMethods: [])
        let second = sm.handleCancellation(eventId: "c1", confirmationId: "conf1")
        #expect(!second)  // Deduplicated
    }

    @Test func pinVerification() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")
        let arrived = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: arrived)
        #expect(!sm.pinVerified)
        #expect(sm.pinAttempts == 0)

        sm.recordPinVerification(verified: false)
        #expect(!sm.pinVerified)
        #expect(sm.pinAttempts == 1)

        sm.recordPinVerification(verified: true)
        #expect(sm.pinVerified)
        #expect(sm.pinAttempts == 2)
    }

    @Test func maxPinAttemptsReached() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")
        let arrived = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: arrived)

        for _ in 0..<RideConstants.maxPinAttempts {
            sm.recordPinVerification(verified: false)
        }
        #expect(sm.pinAttempts == RideConstants.maxPinAttempts)
        #expect(!sm.pinVerified)
    }

    @Test func locationSharingFlags() {
        let sm = RideStateMachine()
        #expect(!sm.precisePickupShared)
        #expect(!sm.preciseDestinationShared)

        sm.markPrecisePickupShared()
        #expect(sm.precisePickupShared)

        sm.markPreciseDestinationShared()
        #expect(sm.preciseDestinationShared)
    }

    @Test func reset() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: .zelle, fiatPaymentMethods: [.zelle])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")
        sm.recordPinVerification(verified: true)
        sm.markPrecisePickupShared()

        sm.reset()
        #expect(sm.stage == .idle)
        #expect(sm.pin == nil)
        #expect(sm.confirmationEventId == nil)
        #expect(sm.driverPubkey == nil)
        #expect(!sm.pinVerified)
        #expect(sm.pinAttempts == 0)
        #expect(!sm.precisePickupShared)
        #expect(!sm.preciseDestinationShared)
        #expect(sm.paymentMethod == nil)
        #expect(sm.fiatPaymentMethods.isEmpty)
        #expect(sm.riderStateHistory.isEmpty)
    }

    @Test func pinGeneration() {
        // Generate many PINs and verify format
        for _ in 0..<100 {
            let pin = RideStateMachine.generatePin()
            #expect(pin.count == RideConstants.pinDigits)
            #expect(Int(pin) != nil)
            #expect(Int(pin)! >= 0 && Int(pin)! <= 9999)
        }
    }

    @Test func resetClearsDeduplication() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        let state = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "reused_id", confirmationId: "conf1", driverState: state)

        sm.reset()

        // After reset, same event ID should be processable in a new ride
        try sm.startRide(offerEventId: "o2", driverPubkey: "d2", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc2")
        try sm.recordConfirmation(confirmationEventId: "conf2")

        let result = try sm.handleDriverStateUpdate(eventId: "reused_id", confirmationId: "conf2", driverState: state)
        #expect(result != nil)  // Should NOT be deduplicated after reset
    }

    @Test func acceptanceAfterCancelIgnored() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        #expect(sm.stage == .waitingForAcceptance)

        // User cancels before acceptance arrives
        sm.reset()
        #expect(sm.stage == .idle)

        // Late acceptance should not be processable (can't go from idle to driverAccepted)
        #expect(throws: RidestrError.self) {
            _ = try sm.handleAcceptance(acceptanceEventId: "late_acc")
        }
    }

    @Test func restoreFromPersistence() throws {
        let sm = RideStateMachine()
        sm.restore(
            stage: .driverArrived,
            offerEventId: "offer1",
            acceptanceEventId: "acc1",
            confirmationEventId: "conf1",
            driverPubkey: "driver_pub",
            pin: "4321",
            pinVerified: false,
            paymentMethod: .zelle,
            fiatPaymentMethods: [.zelle, .venmo]
        )

        #expect(sm.stage == .driverArrived)
        #expect(sm.pin == "4321")
        #expect(sm.confirmationEventId == "conf1")
        #expect(sm.driverPubkey == "driver_pub")
        #expect(!sm.pinVerified)
        #expect(sm.paymentMethod == .zelle)
        #expect(sm.fiatPaymentMethods == [.zelle, .venmo])

        // Should be able to process driver state events after restore
        let state = DriverRideStateContent(currentStatus: "in_progress", history: [])
        let result = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: state)
        #expect(result == "in_progress")
        #expect(sm.stage == .inProgress)
    }

    @Test func restoreWithPinThenVerify() throws {
        let sm = RideStateMachine()
        sm.restore(
            stage: .driverArrived,
            offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: "c1", driverPubkey: "d1",
            pin: "5678", pinVerified: false,
            paymentMethod: nil, fiatPaymentMethods: []
        )

        // PIN should survive restore and be verifiable
        #expect(sm.pin == "5678")
        sm.recordPinVerification(verified: true)
        #expect(sm.pinVerified)
        #expect(sm.pinAttempts == 1)
    }

    @Test func rapidDriverStateTransitions() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        // Driver sends multiple rapid updates (en_route, arrived, in_progress)
        let states = ["en_route_pickup", "arrived", "in_progress", "completed"]
        for (i, status) in states.enumerated() {
            let state = DriverRideStateContent(currentStatus: status, history: [])
            let result = try sm.handleDriverStateUpdate(
                eventId: "ds_\(i)",
                confirmationId: "conf1",
                driverState: state
            )
            #expect(result == status)
        }
        #expect(sm.stage == .completed)
    }

    @Test func atoBPatternDriverIsSourceOfTruth() throws {
        let sm = RideStateMachine()
        try sm.startRide(offerEventId: "o1", driverPubkey: "d1", paymentMethod: nil, fiatPaymentMethods: [])
        _ = try sm.handleAcceptance(acceptanceEventId: "acc1")
        try sm.recordConfirmation(confirmationEventId: "conf1")

        // Rider should NOT be able to skip to inProgress by themselves
        #expect(throws: RidestrError.self) {
            try sm.transition(to: .inProgress)
        }

        // But driver state update CAN move it
        let state = DriverRideStateContent(currentStatus: "arrived", history: [])
        _ = try sm.handleDriverStateUpdate(eventId: "ds1", confirmationId: "conf1", driverState: state)
        #expect(sm.stage == .driverArrived)
    }
}
