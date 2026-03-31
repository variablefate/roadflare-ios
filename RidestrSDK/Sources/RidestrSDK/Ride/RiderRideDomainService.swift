import Foundation

/// SDK-owned rider ride-session backend helpers.
///
/// This service composes filters, parsers, event builders, relay publication, and
/// state-machine transitions into a higher-level rider API. It is designed so app
/// clients can eventually delegate ride protocol wiring into the SDK instead of
/// rebuilding the session backend themselves.
public final class RiderRideDomainService: @unchecked Sendable {
    public enum LiveSubscription: Sendable, Hashable {
        case acceptance(offerEventId: EventID, driverPubkey: PublicKeyHex)
        case driverState(confirmationEventId: ConfirmationEventID, driverPubkey: PublicKeyHex)
        case cancellation(confirmationEventId: ConfirmationEventID, driverPubkey: PublicKeyHex)
    }

    public enum PendingAction: Sendable, Equatable {
        case recoverOrPublishConfirmation(acceptanceEventId: EventID, driverPubkey: PublicKeyHex)
    }

    public struct RuntimePlan: Sendable, Equatable {
        public let subscriptions: [LiveSubscription]
        public let pendingAction: PendingAction?

        public init(subscriptions: [LiveSubscription] = [], pendingAction: PendingAction? = nil) {
            self.subscriptions = subscriptions
            self.pendingAction = pendingAction
        }
    }

    public struct OfferPublication: Sendable {
        public let event: NostrEvent
        public let runtimePlan: RuntimePlan

        public init(event: NostrEvent, runtimePlan: RuntimePlan) {
            self.event = event
            self.runtimePlan = runtimePlan
        }
    }

    public struct AcceptanceResolution: Sendable {
        public let envelope: RideAcceptanceEnvelope
        public let content: RideAcceptanceContent
        public let didAdvanceState: Bool
        public let pin: String?
        public let shouldPublishConfirmation: Bool
        public let runtimePlan: RuntimePlan

        public init(
            envelope: RideAcceptanceEnvelope,
            content: RideAcceptanceContent,
            didAdvanceState: Bool,
            pin: String?,
            shouldPublishConfirmation: Bool,
            runtimePlan: RuntimePlan
        ) {
            self.envelope = envelope
            self.content = content
            self.didAdvanceState = didAdvanceState
            self.pin = pin
            self.shouldPublishConfirmation = shouldPublishConfirmation
            self.runtimePlan = runtimePlan
        }
    }

    public struct ConfirmationResolution: Sendable {
        public let event: NostrEvent
        public let envelope: RideConfirmationEnvelope
        public let runtimePlan: RuntimePlan

        public init(event: NostrEvent, envelope: RideConfirmationEnvelope, runtimePlan: RuntimePlan) {
            self.event = event
            self.envelope = envelope
            self.runtimePlan = runtimePlan
        }
    }

    public enum DriverStateEventResolution: Sendable {
        case ignored
        case processed(DriverStateUpdate)
    }

    public struct DriverStateUpdate: Sendable {
        public enum TerminalOutcome: String, Sendable, Equatable {
            case cancelled
            case completed
        }

        public let status: String
        public let content: DriverRideStateContent
        public let pinActions: [DriverRideAction]
        public let terminalOutcome: TerminalOutcome?

        public init(
            status: String,
            content: DriverRideStateContent,
            pinActions: [DriverRideAction],
            terminalOutcome: TerminalOutcome?
        ) {
            self.status = status
            self.content = content
            self.pinActions = pinActions
            self.terminalOutcome = terminalOutcome
        }
    }

    public struct PinVerificationPlan: Sendable {
        public let driverPubkey: PublicKeyHex
        public let confirmationEventId: ConfirmationEventID
        public let isCorrect: Bool
        public let attempt: Int
        public let riderAction: RiderRideAction
        public let destinationAction: RiderRideAction?
        public let phase: String
        public let history: [RiderRideAction]
        public let shouldCancelForBruteForce: Bool

        public init(
            driverPubkey: PublicKeyHex,
            confirmationEventId: ConfirmationEventID,
            isCorrect: Bool,
            attempt: Int,
            riderAction: RiderRideAction,
            destinationAction: RiderRideAction?,
            phase: String,
            history: [RiderRideAction],
            shouldCancelForBruteForce: Bool
        ) {
            self.driverPubkey = driverPubkey
            self.confirmationEventId = confirmationEventId
            self.isCorrect = isCorrect
            self.attempt = attempt
            self.riderAction = riderAction
            self.destinationAction = destinationAction
            self.phase = phase
            self.history = history
            self.shouldCancelForBruteForce = shouldCancelForBruteForce
        }
    }

    public struct PinVerificationPublication: Sendable {
        public let event: NostrEvent
        public let plan: PinVerificationPlan

        public init(event: NostrEvent, plan: PinVerificationPlan) {
            self.event = event
            self.plan = plan
        }
    }

    public enum TerminationPublication: Sendable {
        case cancellation(NostrEvent)
        case offerDeletion(NostrEvent)
        case none
    }

    public enum CancellationEventResolution: Sendable {
        case ignored
        case processed(CancellationUpdate)
    }

    public struct CancellationUpdate: Sendable {
        public let content: CancellationContent

        public init(content: CancellationContent) {
            self.content = content
        }
    }

    private let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair
    private let fetchTimeout: TimeInterval

    public init(
        relayManager: any RelayManagerProtocol,
        keypair: NostrKeypair,
        fetchTimeout: TimeInterval = 5
    ) {
        self.relayManager = relayManager
        self.keypair = keypair
        self.fetchTimeout = fetchTimeout
    }

    public func runtimePlan(for stateMachine: RideStateMachine) -> RuntimePlan {
        guard let driverPubkey = stateMachine.driverPubkey else {
            return RuntimePlan()
        }

        switch stateMachine.stage {
        case .waitingForAcceptance:
            guard let offerEventId = stateMachine.offerEventId else { return RuntimePlan() }
            return RuntimePlan(
                subscriptions: [
                    .acceptance(offerEventId: offerEventId, driverPubkey: driverPubkey)
                ]
            )

        case .driverAccepted:
            guard stateMachine.confirmationEventId == nil,
                  let acceptanceEventId = stateMachine.acceptanceEventId else {
                return RuntimePlan()
            }
            return RuntimePlan(
                pendingAction: .recoverOrPublishConfirmation(
                    acceptanceEventId: acceptanceEventId,
                    driverPubkey: driverPubkey
                )
            )

        case .rideConfirmed, .enRoute, .driverArrived, .inProgress:
            guard let confirmationEventId = stateMachine.confirmationEventId else {
                return RuntimePlan()
            }
            return RuntimePlan(
                subscriptions: [
                    .driverState(
                        confirmationEventId: confirmationEventId,
                        driverPubkey: driverPubkey
                    ),
                    .cancellation(
                        confirmationEventId: confirmationEventId,
                        driverPubkey: driverPubkey
                    ),
                ]
            )

        case .idle, .completed:
            return RuntimePlan()
        }
    }

    public func filter(for subscription: LiveSubscription) -> NostrFilter {
        switch subscription {
        case .acceptance(let offerEventId, let driverPubkey):
            return NostrFilter.rideAcceptances(
                offerEventId: offerEventId,
                riderPubkey: keypair.publicKeyHex,
                driverPubkey: driverPubkey
            )
        case .driverState(let confirmationEventId, let driverPubkey):
            return NostrFilter.driverRideState(
                driverPubkey: driverPubkey,
                confirmationEventId: confirmationEventId
            )
        case .cancellation(let confirmationEventId, _):
            return NostrFilter.cancellations(
                counterpartyPubkey: keypair.publicKeyHex,
                confirmationEventId: confirmationEventId
            )
        }
    }

    @discardableResult
    public func publishRideOffer(
        driverPubkey: PublicKeyHex,
        driverAvailabilityEventId: EventID? = nil,
        content: RideOfferContent,
        stateMachine: RideStateMachine? = nil
    ) async throws -> OfferPublication {
        if let stateMachine,
           stateMachine.stage != .idle {
            throw RidestrError.ride(
                .stateMachineViolation(
                    from: stateMachine.stage.rawValue,
                    to: RiderStage.waitingForAcceptance.rawValue
                )
            )
        }

        let offerEvent = try await RideshareEventBuilder.rideOffer(
            driverPubkey: driverPubkey,
            driverAvailabilityEventId: driverAvailabilityEventId,
            content: content,
            keypair: keypair
        )
        _ = try await relayManager.publishWithRetry(offerEvent)

        if let stateMachine {
            try requireSuccess(
                stateMachine.processEvent(.sendOffer(
                    offerEventId: offerEvent.id,
                    driverPubkey: driverPubkey,
                    paymentMethod: content.paymentMethod,
                    fiatPaymentMethods: content.fiatPaymentMethods
                )),
                target: .waitingForAcceptance
            )
            return OfferPublication(event: offerEvent, runtimePlan: runtimePlan(for: stateMachine))
        }

        return OfferPublication(
            event: offerEvent,
            runtimePlan: RuntimePlan(
                subscriptions: [
                    .acceptance(offerEventId: offerEvent.id, driverPubkey: driverPubkey)
                ]
            )
        )
    }

    public func receiveAcceptanceEvent(
        _ event: NostrEvent,
        expectedOfferEventId: EventID,
        expectedDriverPubkey: PublicKeyHex? = nil,
        stateMachine: RideStateMachine
    ) throws -> AcceptanceResolution {
        let envelope = try RideshareEventParser.parseAcceptanceEnvelope(
            event: event,
            keypair: keypair,
            expectedDriverPubkey: expectedDriverPubkey,
            expectedOfferEventId: expectedOfferEventId
        )
        let content = try RideshareEventParser.parseAcceptance(
            event: event,
            keypair: keypair,
            expectedDriverPubkey: expectedDriverPubkey,
            expectedOfferEventId: expectedOfferEventId
        )

        var didAdvanceState = false
        if content.status == "accepted" {
            switch stateMachine.stage {
            case .waitingForAcceptance:
                try requireSuccess(
                    stateMachine.processEvent(.acceptanceReceived(acceptanceEventId: envelope.eventId)),
                    target: .driverAccepted
                )
                didAdvanceState = true
            case .driverAccepted:
                guard stateMachine.acceptanceEventId == envelope.eventId,
                      stateMachine.confirmationEventId == nil,
                      stateMachine.driverPubkey == envelope.driverPubkey else {
                    throw RidestrError.ride(
                        .stateMachineViolation(
                            from: stateMachine.stage.rawValue,
                            to: RiderStage.driverAccepted.rawValue
                        )
                    )
                }
            default:
                throw RidestrError.ride(
                    .stateMachineViolation(
                        from: stateMachine.stage.rawValue,
                        to: RiderStage.driverAccepted.rawValue
                    )
                )
            }
        }

        return AcceptanceResolution(
            envelope: envelope,
            content: content,
            didAdvanceState: didAdvanceState,
            pin: stateMachine.pin,
            shouldPublishConfirmation: content.status == "accepted" && stateMachine.confirmationEventId == nil,
            runtimePlan: runtimePlan(for: stateMachine)
        )
    }

    @discardableResult
    public func publishConfirmation(
        driverPubkey: PublicKeyHex,
        acceptanceEventId: EventID,
        precisePickup: Location,
        paymentHash: String? = nil,
        escrowToken: String? = nil,
        stateMachine: RideStateMachine? = nil
    ) async throws -> ConfirmationResolution {
        let event = try await RideshareEventBuilder.rideConfirmation(
            driverPubkey: driverPubkey,
            acceptanceEventId: acceptanceEventId,
            precisePickup: precisePickup,
            paymentHash: paymentHash,
            escrowToken: escrowToken,
            keypair: keypair
        )
        _ = try await relayManager.publishWithRetry(event)

        let envelope = try RideshareEventParser.parseConfirmationEnvelope(
            event: event,
            expectedRiderPubkey: keypair.publicKeyHex,
            expectedDriverPubkey: driverPubkey,
            expectedAcceptanceEventId: acceptanceEventId
        )

        if let stateMachine {
            try requireSuccess(
                stateMachine.processEvent(.confirm(confirmationEventId: envelope.eventId)),
                target: .rideConfirmed
            )
            stateMachine.markPrecisePickupShared()
            return ConfirmationResolution(event: event, envelope: envelope, runtimePlan: runtimePlan(for: stateMachine))
        }

        return ConfirmationResolution(
            event: event,
            envelope: envelope,
            runtimePlan: RuntimePlan(
                subscriptions: [
                    .driverState(
                        confirmationEventId: envelope.eventId,
                        driverPubkey: driverPubkey
                    ),
                    .cancellation(
                        confirmationEventId: envelope.eventId,
                        driverPubkey: driverPubkey
                    ),
                ]
            )
        )
    }

    public func recoverExistingConfirmation(
        driverPubkey: PublicKeyHex,
        acceptanceEventId: EventID,
        stateMachine: RideStateMachine? = nil
    ) async throws -> ConfirmationResolution? {
        let filter = NostrFilter.rideConfirmations(
            acceptanceEventId: acceptanceEventId,
            riderPubkey: keypair.publicKeyHex
        )
        let events = try await relayManager.fetchEvents(filter: filter, timeout: fetchTimeout)
        let envelope = events
            .sorted(by: { $0.createdAt > $1.createdAt })
            .compactMap { event in
                try? RideshareEventParser.parseConfirmationEnvelope(
                    event: event,
                    expectedRiderPubkey: keypair.publicKeyHex,
                    expectedDriverPubkey: driverPubkey,
                    expectedAcceptanceEventId: acceptanceEventId
                )
            }
            .first

        guard let envelope,
              let event = events.first(where: { $0.id == envelope.eventId }) else {
            return nil
        }

        if let stateMachine {
            if stateMachine.confirmationEventId == envelope.eventId,
               stateMachine.stage.isActiveRide {
                stateMachine.markPrecisePickupShared()
                return ConfirmationResolution(event: event, envelope: envelope, runtimePlan: runtimePlan(for: stateMachine))
            }
            try requireSuccess(
                stateMachine.processEvent(.confirm(confirmationEventId: envelope.eventId)),
                target: .rideConfirmed
            )
            stateMachine.markPrecisePickupShared()
            return ConfirmationResolution(event: event, envelope: envelope, runtimePlan: runtimePlan(for: stateMachine))
        }

        return ConfirmationResolution(
            event: event,
            envelope: envelope,
            runtimePlan: RuntimePlan(
                subscriptions: [
                    .driverState(
                        confirmationEventId: envelope.eventId,
                        driverPubkey: driverPubkey
                    ),
                    .cancellation(
                        confirmationEventId: envelope.eventId,
                        driverPubkey: driverPubkey
                    ),
                ]
            )
        )
    }

    public func receiveDriverStateEvent(
        _ event: NostrEvent,
        confirmationEventId: ConfirmationEventID,
        expectedDriverPubkey: PublicKeyHex? = nil,
        stateMachine: RideStateMachine
    ) throws -> DriverStateEventResolution {
        let driverState = try RideshareEventParser.parseDriverRideState(
            event: event,
            keypair: keypair,
            expectedDriverPubkey: expectedDriverPubkey,
            expectedConfirmationEventId: confirmationEventId
        )
        guard let status = stateMachine.receiveDriverStateEvent(
            eventId: event.id,
            confirmationId: confirmationEventId,
            driverState: driverState,
            createdAt: event.createdAt
        ) else {
            return .ignored
        }

        let terminalOutcome: DriverStateUpdate.TerminalOutcome?
        if status == "cancelled" {
            terminalOutcome = .cancelled
        } else if stateMachine.stage == .completed {
            terminalOutcome = .completed
        } else {
            terminalOutcome = nil
        }

        return .processed(
            DriverStateUpdate(
                status: status,
                content: driverState,
                pinActions: driverState.history.filter(\.isPinSubmitAction),
                terminalOutcome: terminalOutcome
            )
        )
    }

    public func preparePinVerificationResponse(
        pinEncrypted: String,
        driverPubkey: PublicKeyHex,
        confirmationEventId: ConfirmationEventID,
        destination: Location? = nil,
        stateMachine: RideStateMachine
    ) throws -> PinVerificationPlan {
        let decryptedPin = try RideshareEventParser.decryptPin(
            pinEncrypted: pinEncrypted,
            driverPubkey: driverPubkey,
            keypair: keypair
        )
        let isCorrect = decryptedPin == stateMachine.pin
        let attempt = stateMachine.pinAttempts + 1
        let shouldCancelForBruteForce = !isCorrect && attempt >= RideConstants.maxPinAttempts

        let riderAction = RiderRideAction(
            type: "pin_verify",
            at: Int(Date.now.timeIntervalSince1970),
            locationType: nil,
            locationEncrypted: nil,
            status: isCorrect ? "verified" : "rejected",
            attempt: attempt
        )

        let destinationAction: RiderRideAction?
        if isCorrect, let destination {
            let encryptedDestination = try RideshareEventParser.encryptLocation(
                location: destination,
                recipientPubkey: driverPubkey,
                keypair: keypair
            )
            destinationAction = RiderRideAction(
                type: "location_reveal",
                at: Int(Date.now.timeIntervalSince1970),
                locationType: "destination",
                locationEncrypted: encryptedDestination,
                status: nil,
                attempt: nil
            )
        } else {
            destinationAction = nil
        }

        var history = stateMachine.riderStateHistory + [riderAction]
        if let destinationAction {
            history.append(destinationAction)
        }

        return PinVerificationPlan(
            driverPubkey: driverPubkey,
            confirmationEventId: confirmationEventId,
            isCorrect: isCorrect,
            attempt: attempt,
            riderAction: riderAction,
            destinationAction: destinationAction,
            phase: isCorrect ? "verified" : "awaiting_pin",
            history: history,
            shouldCancelForBruteForce: shouldCancelForBruteForce
        )
    }

    @discardableResult
    public func publishRiderRideState(
        driverPubkey: PublicKeyHex,
        confirmationEventId: ConfirmationEventID,
        phase: String,
        history: [RiderRideAction],
        lastTransitionId: EventID? = nil
    ) async throws -> NostrEvent {
        let event = try await RideshareEventBuilder.riderRideState(
            driverPubkey: driverPubkey,
            confirmationEventId: confirmationEventId,
            phase: phase,
            history: history,
            keypair: keypair,
            lastTransitionId: lastTransitionId
        )
        _ = try await relayManager.publishWithRetry(event)
        return event
    }

    @discardableResult
    public func publishPinVerificationResponse(
        _ plan: PinVerificationPlan,
        stateMachine: RideStateMachine? = nil,
        lastTransitionId: EventID? = nil
    ) async throws -> PinVerificationPublication {
        if plan.isCorrect {
            try await Task.sleep(for: .seconds(RideConstants.nip33OrderingDelaySeconds))
        }

        let event = try await publishRiderRideState(
            driverPubkey: plan.driverPubkey,
            confirmationEventId: plan.confirmationEventId,
            phase: plan.phase,
            history: plan.history,
            lastTransitionId: lastTransitionId
        )

        if let stateMachine {
            try requireSuccess(
                stateMachine.processEvent(.verifyPin(verified: plan.isCorrect, attempt: plan.attempt)),
                target: plan.shouldCancelForBruteForce ? .idle : .driverArrived
            )
            stateMachine.addRiderAction(plan.riderAction)
            if let destinationAction = plan.destinationAction {
                stateMachine.addRiderAction(destinationAction)
                stateMachine.markPreciseDestinationShared()
            }
        }

        return PinVerificationPublication(event: event, plan: plan)
    }

    @discardableResult
    public func publishTermination(
        for stateMachine: RideStateMachine,
        reason: String? = nil
    ) async throws -> TerminationPublication {
        guard stateMachine.stage != .completed else {
            return .none
        }
        if let confirmationEventId = stateMachine.confirmationEventId,
           let driverPubkey = stateMachine.driverPubkey {
            let event = try await RideshareEventBuilder.cancellation(
                counterpartyPubkey: driverPubkey,
                confirmationEventId: confirmationEventId,
                reason: reason,
                keypair: keypair
            )
            _ = try await relayManager.publishWithRetry(event)
            return .cancellation(event)
        }

        if let offerEventId = stateMachine.offerEventId,
           stateMachine.stage == .waitingForAcceptance {
            let event = try await RideshareEventBuilder.deletion(
                eventIds: [offerEventId],
                reason: reason ?? "rider cancelled",
                kinds: [.rideOffer],
                keypair: keypair
            )
            _ = try await relayManager.publishWithRetry(event)
            return .offerDeletion(event)
        }

        return .none
    }

    public func receiveCancellationEvent(
        _ event: NostrEvent,
        confirmationEventId: ConfirmationEventID,
        expectedDriverPubkey: PublicKeyHex? = nil,
        stateMachine: RideStateMachine
    ) throws -> CancellationEventResolution {
        let content = try RideshareEventParser.parseCancellation(
            event: event,
            keypair: keypair,
            expectedDriverPubkey: expectedDriverPubkey,
            expectedConfirmationEventId: confirmationEventId
        )
        let didCancel = stateMachine.receiveCancellationEvent(
            eventId: event.id,
            confirmationId: confirmationEventId
        )
        guard didCancel else { return .ignored }
        return .processed(CancellationUpdate(content: content))
    }

    private func requireSuccess(_ result: TransitionResult, target: RiderStage) throws {
        switch result {
        case .success:
            return
        case .invalidTransition(let currentState, _):
            throw RidestrError.ride(
                .stateMachineViolation(from: currentState.rawValue, to: target.rawValue)
            )
        case .guardFailed(let currentState, _, _, let reason):
            throw RidestrError.ride(
                .stateMachineViolation(
                    from: currentState.rawValue,
                    to: "\(target.rawValue) (\(reason))"
                )
            )
        }
    }
}
