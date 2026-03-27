import Foundation

/// Result of a state machine transition attempt.
public enum TransitionResult: Sendable {
    /// Transition succeeded.
    case success(from: RiderStage, to: RiderStage, context: RideContext)
    /// No valid transition exists for this state + event.
    case invalidTransition(currentState: RiderStage, eventType: String)
    /// Transition exists but guard failed.
    case guardFailed(currentState: RiderStage, eventType: String, guardName: String, reason: String)
}

/// Delegate for observing state machine transitions.
public protocol StateMachineDelegate: AnyObject, Sendable {
    func stateMachineDidTransition(from: RiderStage, to: RiderStage, event: RideEvent)
    func stateMachineTransitionFailed(result: TransitionResult, event: RideEvent)
}

/// Manages the rider-side ride lifecycle state machine.
///
/// ## Two Entry Points
///
/// **`processEvent(_:)`** — For rider-initiated actions (sending offers, confirming rides,
/// verifying PINs, cancelling). These go through the transition table with guard evaluation.
///
/// **`receiveDriverStateEvent(...)`** — For driver status updates received via Kind 30180.
/// The driver is the source of truth after confirmation (AtoB pattern). The rider's stage
/// is derived from the driver's authoritative status. No guards — just deduplication and
/// timestamp ordering.
///
/// ```
/// Rider actions → processEvent()     → transition table → guards → stage update
/// Driver status → receiveDriverState() → dedup + timestamp → direct stage update
/// ```
///
/// ## Observable
///
/// This class is `@Observable` for SwiftUI integration. Bind to `stage`, `pin`,
/// `driverPubkey`, etc. directly in your views. All properties project from the
/// internal `RideContext` struct (single source of truth).
@Observable
public final class RideStateMachine: @unchecked Sendable {
    /// Current ride stage.
    public private(set) var stage: RiderStage = .idle

    /// Current ride context (immutable struct, replaced on each transition).
    public private(set) var context: RideContext

    /// 4-digit PIN generated at acceptance, shown to driver for verification.
    public var pin: String? { context.pin }

    /// The confirmation event ID — canonical identifier for this ride.
    public var confirmationEventId: String? { context.confirmationEventId }

    /// The acceptance event ID (Kind 3174).
    public var acceptanceEventId: String? { context.acceptanceEventId }

    /// The offer event ID (Kind 3173) that started this ride.
    public var offerEventId: String? { context.offerEventId }

    /// Driver's public key.
    public var driverPubkey: String? { context.driverPubkey }

    /// Whether the PIN has been verified by the driver.
    public var pinVerified: Bool { context.pinVerified }

    /// Number of PIN verification attempts.
    public var pinAttempts: Int { context.pinAttempts }

    /// Whether the precise pickup has been shared with the driver.
    public var precisePickupShared: Bool { context.precisePickupShared }

    /// Whether the precise destination has been shared with the driver.
    public var preciseDestinationShared: Bool { context.preciseDestinationShared }

    /// Payment method for this ride.
    public var paymentMethod: String? { context.paymentMethod }

    /// Rider's fiat payment methods included in the offer.
    public var fiatPaymentMethods: [String] { context.fiatPaymentMethods }

    /// Rider ride state history (actions published in Kind 30181).
    public var riderStateHistory: [RiderRideAction] { context.riderStateHistory }

    /// Driver's last known status from Kind 30180.
    public var lastDriverStatus: String? { context.lastDriverStatus }

    /// Number of actions in the last processed driver state snapshot.
    public var lastDriverActionCount: Int { context.lastDriverActionCount }

    /// Delegate for observing transitions.
    public weak var delegate: (any StateMachineDelegate)?

    /// Set of processed driver state event IDs (deduplication).
    private var processedDriverStateEventIds: Set<String> = []

    /// Set of processed cancellation event IDs (deduplication).
    private var processedCancellationEventIds: Set<String> = []

    public init(riderPubkey: PublicKeyHex = "") {
        self.context = RideContext(riderPubkey: riderPubkey)
    }

    // MARK: - Core: processEvent()

    /// Process a rider event through the transition table.
    ///
    /// This is the canonical entry point for rider-initiated state changes.
    /// Driver state observations go through `receiveDriverStateEvent()` instead.
    @discardableResult
    public func processEvent(_ event: RideEvent) -> TransitionResult {
        let candidates = RideTransitions.findTransition(from: stage, eventType: event.eventType)

        if candidates.isEmpty {
            RidestrLogger.warning("[StateMachine] Invalid transition: \(event.eventType) not valid from \(stage)")
            let result = TransitionResult.invalidTransition(
                currentState: stage, eventType: event.eventType
            )
            delegate?.stateMachineTransitionFailed(result: result, event: event)
            return result
        }

        // Find the first transition whose guard passes
        for transition in candidates {
            if RideGuards.evaluate(transition.guard_, context: context, event: event) {
                let oldStage = stage

                // Apply context updates based on event
                let newContext = applyContextUpdate(for: event, current: context)
                context = newContext
                stage = transition.to

                RidestrLogger.debug("[StateMachine] \(oldStage) → \(transition.to) via \(event.eventType)")
                let result = TransitionResult.success(from: oldStage, to: transition.to, context: context)
                delegate?.stateMachineDidTransition(from: oldStage, to: transition.to, event: event)
                return result
            }
        }

        // All guards failed — report the first one
        let firstGuard = candidates.first?.guard_ ?? "unknown"
        let reason = RideGuards.explainFailure(firstGuard, context: context, event: event)
        let result = TransitionResult.guardFailed(
            currentState: stage, eventType: event.eventType,
            guardName: firstGuard, reason: reason
        )
        delegate?.stateMachineTransitionFailed(result: result, event: event)
        return result
    }

    /// Apply context updates for an event (pure function on context).
    private func applyContextUpdate(for event: RideEvent, current: RideContext) -> RideContext {
        switch event {
        case .sendOffer(let offerEventId, let driverPubkey, let paymentMethod, let fiatPaymentMethods):
            return RideContext(
                riderPubkey: current.riderPubkey, driverPubkey: driverPubkey,
                offerEventId: offerEventId,
                paymentMethod: paymentMethod, fiatPaymentMethods: fiatPaymentMethods
            )

        case .acceptanceReceived(let acceptanceEventId):
            let pin = Self.generatePin()
            return RideContext(
                riderPubkey: current.riderPubkey,
                driverPubkey: current.driverPubkey,
                offerEventId: current.offerEventId,
                acceptanceEventId: acceptanceEventId,
                confirmationEventId: current.confirmationEventId,
                pin: pin,
                pinAttempts: current.pinAttempts,
                pinVerified: current.pinVerified,
                maxPinAttempts: current.maxPinAttempts,
                paymentMethod: current.paymentMethod,
                fiatPaymentMethods: current.fiatPaymentMethods,
                precisePickupShared: current.precisePickupShared,
                preciseDestinationShared: current.preciseDestinationShared,
                lastDriverStatus: current.lastDriverStatus,
                lastDriverStateTimestamp: current.lastDriverStateTimestamp,
                lastDriverActionCount: current.lastDriverActionCount,
                riderStateHistory: current.riderStateHistory
            )

        case .confirm(let confirmationEventId):
            return current.withConfirmation(confirmationEventId: confirmationEventId)

        case .verifyPin(let verified, _):
            return current.withPinAttempt(verified: verified)

        case .cancel:
            // Reset context but keep riderPubkey
            return RideContext(riderPubkey: current.riderPubkey)

        case .confirmationTimeout:
            return RideContext(riderPubkey: current.riderPubkey)
        }
    }

    // MARK: - AtoB: Driver State Observations

    /// Handle a driver ride state update (Kind 30180).
    ///
    /// This is NOT routed through the transition table. The driver's state is
    /// authoritative (AtoB pattern) — the rider's stage reflects the driver's
    /// ground truth. Deduplication uses both event ID and timestamp ordering
    /// to prevent state regression from out-of-order events.
    ///
    /// - Returns: The driver status string if processed, nil if deduplicated/invalid.
    public func receiveDriverStateEvent(
        eventId: String,
        confirmationId: String,
        driverState: DriverRideStateContent,
        createdAt: Int = 0
    ) -> String? {
        // Event ID deduplication
        guard !processedDriverStateEventIds.contains(eventId) else { return nil }
        // Confirmation must match current ride
        guard confirmationId == confirmationEventId else { return nil }
        let actionCount = driverState.history.count
        // Timestamp ordering — prevent state regression from late events.
        // Android driver updates are second-granularity, so same-second snapshots must
        // be ordered by append-only history length rather than dropped outright.
        if createdAt > 0 {
            if createdAt < context.lastDriverStateTimestamp { return nil }
            if createdAt == context.lastDriverStateTimestamp &&
                actionCount <= context.lastDriverActionCount {
                return nil
            }
        }

        processedDriverStateEventIds.insert(eventId)

        if driverState.currentStatus == "cancelled" {
            processEvent(.cancel(eventId: eventId, confirmationId: confirmationId))
            return driverState.currentStatus
        }

        // Update context with driver status
        let newTimestamp = createdAt > 0 ? createdAt : context.lastDriverStateTimestamp
        context = RideContext(
            riderPubkey: context.riderPubkey, driverPubkey: context.driverPubkey,
            offerEventId: context.offerEventId, acceptanceEventId: context.acceptanceEventId,
            confirmationEventId: context.confirmationEventId, pin: context.pin,
            pinAttempts: context.pinAttempts, pinVerified: context.pinVerified,
            maxPinAttempts: context.maxPinAttempts,
            paymentMethod: context.paymentMethod, fiatPaymentMethods: context.fiatPaymentMethods,
            precisePickupShared: context.precisePickupShared,
            preciseDestinationShared: context.preciseDestinationShared,
            lastDriverStatus: driverState.currentStatus,
            lastDriverStateTimestamp: newTimestamp,
            lastDriverActionCount: actionCount,
            riderStateHistory: context.riderStateHistory
        )

        // AtoB: derive rider stage from driver status
        switch driverState.currentStatus {
        case "en_route_pickup":
            if stage == .rideConfirmed || stage == .driverAccepted {
                stage = .enRoute
            }
        case "arrived":
            stage = .driverArrived
        case "in_progress":
            stage = .inProgress
        case "completed":
            stage = .completed
        default:
            break
        }

        return driverState.currentStatus
    }

    // MARK: - Convenience Methods

    /// Record that precise pickup was shared.
    public func markPrecisePickupShared() {
        context = context.withPrecisePickupShared(true)
    }

    /// Record that precise destination was shared.
    public func markPreciseDestinationShared() {
        context = context.withPreciseDestinationShared(true)
    }

    /// Add an action to the rider state history.
    public func addRiderAction(_ action: RiderRideAction) {
        context = context.withRiderAction(action)
    }

    /// Check if a transition would be valid without executing it.
    public func canTransition(event: RideEvent) -> Bool {
        let candidates = RideTransitions.findTransition(from: stage, eventType: event.eventType)
        return candidates.contains { RideGuards.evaluate($0.guard_, context: context, event: event) }
    }

    // MARK: - Restore

    /// Restore state machine from persisted data after app relaunch.
    public func restore(
        stage: RiderStage,
        offerEventId: String?,
        acceptanceEventId: String?,
        confirmationEventId: String?,
        driverPubkey: String?,
        pin: String?,
        pinAttempts: Int = 0,
        pinVerified: Bool,
        paymentMethod: String?,
        fiatPaymentMethods: [String],
        precisePickupShared: Bool = false,
        preciseDestinationShared: Bool = false,
        lastDriverStatus: String? = nil,
        lastDriverStateTimestamp: Int = 0,
        lastDriverActionCount: Int = 0,
        riderStateHistory: [RiderRideAction] = []
    ) {
        // Validate that the stage has all IDs it needs to function.
        // Without these, the session would look active but have no way to proceed.
        let valid: Bool = {
            switch stage {
            case .idle, .completed:
                return true
            case .waitingForAcceptance:
                return driverPubkey?.isEmpty == false && offerEventId?.isEmpty == false
            case .driverAccepted:
                return driverPubkey?.isEmpty == false && acceptanceEventId?.isEmpty == false
            case .rideConfirmed, .enRoute, .driverArrived, .inProgress:
                return driverPubkey?.isEmpty == false && confirmationEventId?.isEmpty == false
            }
        }()
        guard valid else {
            reset()
            return
        }

        self.stage = stage
        self.context = RideContext(
            riderPubkey: context.riderPubkey,
            driverPubkey: driverPubkey,
            offerEventId: offerEventId,
            acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId,
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
            riderStateHistory: riderStateHistory
        )
    }

    /// Reset the state machine to idle for a new ride.
    public func reset() {
        stage = .idle
        context = RideContext(riderPubkey: context.riderPubkey)
        processedDriverStateEventIds.removeAll()
        processedCancellationEventIds.removeAll()
    }

    // MARK: - PIN Generation

    /// Generate a random 4-digit PIN.
    public static func generatePin() -> String {
        String(format: "%0\(RideConstants.pinDigits)d", Int.random(in: 0..<10000))
    }

    // MARK: - Deprecated Wrappers

    /// Start a ride by sending an offer.
    @available(*, deprecated, message: "Use processEvent(.sendOffer(...))")
    public func startRide(
        offerEventId: String,
        driverPubkey: String,
        paymentMethod: String?,
        fiatPaymentMethods: [String]
    ) throws {
        let result = processEvent(.sendOffer(
            offerEventId: offerEventId, driverPubkey: driverPubkey,
            paymentMethod: paymentMethod, fiatPaymentMethods: fiatPaymentMethods
        ))
        if case .invalidTransition = result {
            throw RidestrError.ride(.stateMachineViolation(from: stage.rawValue, to: "waitingForAcceptance"))
        }
    }

    /// Handle driver acceptance. Generates PIN and transitions.
    @available(*, deprecated, message: "Use processEvent(.acceptanceReceived(...))")
    public func handleAcceptance(acceptanceEventId: String) throws -> String {
        let result = processEvent(.acceptanceReceived(acceptanceEventId: acceptanceEventId))
        switch result {
        case .success(_, _, let ctx):
            return ctx.pin ?? Self.generatePin()
        case .invalidTransition:
            throw RidestrError.ride(.stateMachineViolation(from: stage.rawValue, to: "driverAccepted"))
        case .guardFailed(_, _, _, let reason):
            throw RidestrError.ride(.stateMachineViolation(from: stage.rawValue, to: "driverAccepted (\(reason))"))
        }
    }

    /// Record the confirmation event ID after auto-confirm publishes Kind 3175.
    @available(*, deprecated, message: "Use processEvent(.confirm(...))")
    public func recordConfirmation(confirmationEventId: String) throws {
        let result = processEvent(.confirm(confirmationEventId: confirmationEventId))
        if case .invalidTransition = result {
            throw RidestrError.ride(.stateMachineViolation(from: stage.rawValue, to: "rideConfirmed"))
        }
    }

    /// Handle a driver ride state update (Kind 30180).
    /// - Returns: The new driver status if processed, nil if deduplicated.
    @available(*, deprecated, message: "Use receiveDriverStateEvent(eventId:confirmationId:driverState:createdAt:)")
    public func handleDriverStateUpdate(
        eventId: String,
        confirmationId: String,
        driverState: DriverRideStateContent
    ) throws -> String? {
        receiveDriverStateEvent(
            eventId: eventId, confirmationId: confirmationId,
            driverState: driverState
        )
    }

    /// Record a PIN verification attempt result.
    @available(*, deprecated, message: "Use processEvent(.verifyPin(...))")
    public func recordPinVerification(verified: Bool) {
        processEvent(.verifyPin(verified: verified, attempt: context.pinAttempts + 1))
    }

    /// Handle a validated cancellation event. Returns true if processed, false if deduplicated.
    public func receiveCancellationEvent(eventId: String, confirmationId: String) -> Bool {
        guard !processedCancellationEventIds.contains(eventId) else { return false }
        guard confirmationId == confirmationEventId else { return false }
        processedCancellationEventIds.insert(eventId)

        processEvent(.cancel(eventId: eventId, confirmationId: confirmationId))
        return true
    }

    /// Handle a cancellation event. Returns true if processed, false if deduplicated.
    @available(*, deprecated, message: "Use receiveCancellationEvent(eventId:confirmationId:)")
    public func handleCancellation(eventId: String, confirmationId: String) -> Bool {
        receiveCancellationEvent(eventId: eventId, confirmationId: confirmationId)
    }

    /// Transition to a new stage (used internally by deprecated wrappers).
    @available(*, deprecated, message: "Use processEvent()")
    public func transition(to newStage: RiderStage) throws {
        guard isValidTransition(from: stage, to: newStage) else {
            throw RidestrError.ride(.stateMachineViolation(from: stage.rawValue, to: newStage.rawValue))
        }
        stage = newStage
    }

    /// Legacy transition validation (kept for deprecated wrappers).
    private func isValidTransition(from: RiderStage, to: RiderStage) -> Bool {
        if to == .idle { return true }
        switch (from, to) {
        case (.idle, .waitingForAcceptance): return true
        case (.waitingForAcceptance, .driverAccepted): return true
        case (.driverAccepted, .rideConfirmed): return true
        case (.rideConfirmed, .enRoute): return true
        case (.rideConfirmed, .driverArrived): return true
        case (.enRoute, .driverArrived): return true
        case (.driverArrived, .inProgress): return true
        case (.inProgress, .completed): return true
        case (.completed, .idle): return true
        case (.driverAccepted, .driverArrived): return true
        default: return false
        }
    }
}
