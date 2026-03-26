import Foundation
import Testing
@testable import RidestrSDK

@Suite("Transition Table & Guard Tests")
struct TransitionTableTests {

    // MARK: - Transition Table Validation

    @Test func allGuardsExistInRegistry() {
        let errors = RideGuards.validateRegistry()
        #expect(errors.isEmpty, "Missing guards: \(errors)")
    }

    @Test func noTransitionsFromCompletedState() {
        let completedTransitions = RideTransitions.findTransition(from: .completed, eventType: "CANCEL")
        #expect(completedTransitions.isEmpty, "completed should have no transitions")
    }

    @Test func cancelAvailableFromAllActiveStages() {
        let cancellableStages: [RiderStage] = [
            .waitingForAcceptance, .driverAccepted, .rideConfirmed,
            .enRoute, .driverArrived, .inProgress
        ]
        for stage in cancellableStages {
            let transitions = RideTransitions.findTransition(from: stage, eventType: "CANCEL")
            #expect(!transitions.isEmpty, "CANCEL should be valid from \(stage)")
            #expect(transitions.allSatisfy { $0.to == .idle }, "CANCEL should go to idle from \(stage)")
        }
    }

    @Test func idleOnlyAcceptsSendOffer() {
        let validEvents = RideTransitions.validEventsFrom(.idle)
        #expect(validEvents == ["SEND_OFFER"])
    }

    @Test func driverArrivedAcceptsVerifyPinAndCancel() {
        let validEvents = RideTransitions.validEventsFrom(.driverArrived)
        #expect(validEvents.contains("VERIFY_PIN"))
        #expect(validEvents.contains("CANCEL"))
        #expect(validEvents.count == 2)
    }

    @Test func reachableStatesFromIdle() {
        let reachable = RideTransitions.reachableStatesFrom(.idle)
        #expect(reachable == [.waitingForAcceptance])
    }

    @Test func verifyPinHasThreeTransitions() {
        // success → driverArrived (pin verified, waiting for driver ack),
        // bruteForce → idle, failed → driverArrived (stay)
        let transitions = RideTransitions.findTransition(from: .driverArrived, eventType: "VERIFY_PIN")
        #expect(transitions.count == 3)
        let destinations = Set(transitions.map(\.to))
        #expect(destinations.contains(.idle))
        #expect(destinations.contains(.driverArrived))
    }

    // MARK: - Guard Isolation Tests

    @Test func isPinVerifiedGuardPassesOnSuccess() {
        let context = RideContext(riderPubkey: "r1", pinAttempts: 0, maxPinAttempts: 3)
        let result = RideGuards.isPinVerified(context, .verifyPin(verified: true, attempt: 1))
        #expect(result)
    }

    @Test func isPinVerifiedGuardFailsOnFailure() {
        let context = RideContext(riderPubkey: "r1", pinAttempts: 0, maxPinAttempts: 3)
        let result = RideGuards.isPinVerified(context, .verifyPin(verified: false, attempt: 1))
        #expect(!result)
    }

    @Test func isPinVerifiedGuardFailsAtBruteForceLimit() {
        let context = RideContext(riderPubkey: "r1", pinAttempts: 3, maxPinAttempts: 3)
        // Even if verified=true, brute force limit reached
        let result = RideGuards.isPinVerified(context, .verifyPin(verified: true, attempt: 4))
        #expect(!result)
    }

    @Test func isPinBruteForceGuardTriggersAtLimit() {
        let context = RideContext(riderPubkey: "r1", pinAttempts: 2, maxPinAttempts: 3)
        // pinAttempts + 1 = 3 >= maxPinAttempts(3), and verified=false
        let result = RideGuards.isPinBruteForce(context, .verifyPin(verified: false, attempt: 3))
        #expect(result)
    }

    @Test func isPinBruteForceGuardDoesNotTriggerBeforeLimit() {
        let context = RideContext(riderPubkey: "r1", pinAttempts: 1, maxPinAttempts: 3)
        let result = RideGuards.isPinBruteForce(context, .verifyPin(verified: false, attempt: 2))
        #expect(!result)
    }

    @Test func isPinBruteForceGuardDoesNotTriggerOnSuccess() {
        let context = RideContext(riderPubkey: "r1", pinAttempts: 2, maxPinAttempts: 3)
        let result = RideGuards.isPinBruteForce(context, .verifyPin(verified: true, attempt: 3))
        #expect(!result)
    }

    @Test func evaluateNilGuardAlwaysPasses() {
        let context = RideContext(riderPubkey: "r1")
        let result = RideGuards.evaluate(nil, context: context, event: .confirmationTimeout)
        #expect(result)
    }

    @Test func evaluateUnknownGuardFails() {
        let context = RideContext(riderPubkey: "r1")
        let result = RideGuards.evaluate("nonexistent", context: context, event: .confirmationTimeout)
        #expect(!result)
    }

    @Test func explainFailureReturnsUsefulMessage() {
        let context = RideContext(riderPubkey: "r1", pinVerified: false)
        let reason = RideGuards.explainFailure("isPinVerified", context: context, event: .verifyPin(verified: false, attempt: 1))
        #expect(reason.contains("PIN"))
    }
}
