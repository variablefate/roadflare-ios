import Foundation

/// Manages the rider-side ride lifecycle state machine.
///
/// Tracks the current stage, PIN, driver info, and active subscriptions.
/// Enforces valid state transitions and provides the canonical ride identifier.
@Observable
public final class RideStateMachine: @unchecked Sendable {
    /// Current ride stage.
    public private(set) var stage: RiderStage = .idle

    /// 4-digit PIN generated at confirmation, shown to driver for verification.
    public private(set) var pin: String?

    /// The confirmation event ID — canonical identifier for this ride.
    /// Used as the d-tag for Kind 30180/30181 replaceable events.
    public private(set) var confirmationEventId: String?

    /// The acceptance event ID (Kind 3174).
    public private(set) var acceptanceEventId: String?

    /// The offer event ID (Kind 3173) that started this ride.
    public private(set) var offerEventId: String?

    /// Driver's public key.
    public private(set) var driverPubkey: String?

    /// Whether the PIN has been verified by the driver.
    public private(set) var pinVerified: Bool = false

    /// Number of PIN verification attempts.
    public private(set) var pinAttempts: Int = 0

    /// Whether the precise pickup has been shared with the driver.
    public private(set) var precisePickupShared: Bool = false

    /// Whether the precise destination has been shared with the driver.
    public private(set) var preciseDestinationShared: Bool = false

    /// Payment method for this ride.
    public private(set) var paymentMethod: PaymentMethod?

    /// Rider's fiat payment methods included in the offer.
    public private(set) var fiatPaymentMethods: [PaymentMethod] = []

    /// Rider ride state history (actions published in Kind 30181).
    public private(set) var riderStateHistory: [RiderRideAction] = []

    /// Driver's last known status from Kind 30180.
    public private(set) var lastDriverStatus: String?

    /// Set of processed driver state event IDs (deduplication).
    private var processedDriverStateEventIds: Set<String> = []

    /// Set of processed cancellation event IDs (deduplication).
    private var processedCancellationEventIds: Set<String> = []

    public init() {}

    // MARK: - State Transitions

    /// Transition to a new stage. Throws if the transition is invalid.
    public func transition(to newStage: RiderStage) throws {
        guard isValidTransition(from: stage, to: newStage) else {
            throw RidestrError.rideStateMachineViolation(from: stage.rawValue, to: newStage.rawValue)
        }
        stage = newStage
    }

    /// Start a ride by sending an offer.
    public func startRide(
        offerEventId: String,
        driverPubkey: String,
        paymentMethod: PaymentMethod?,
        fiatPaymentMethods: [PaymentMethod]
    ) throws {
        try transition(to: .waitingForAcceptance)
        self.offerEventId = offerEventId
        self.driverPubkey = driverPubkey
        self.paymentMethod = paymentMethod
        self.fiatPaymentMethods = fiatPaymentMethods
    }

    /// Handle driver acceptance. Generates PIN and transitions.
    public func handleAcceptance(acceptanceEventId: String) throws -> String {
        try transition(to: .driverAccepted)
        self.acceptanceEventId = acceptanceEventId
        let generatedPin = Self.generatePin()
        self.pin = generatedPin
        return generatedPin
    }

    /// Record the confirmation event ID after auto-confirm publishes Kind 3175.
    public func recordConfirmation(confirmationEventId: String) throws {
        try transition(to: .rideConfirmed)
        self.confirmationEventId = confirmationEventId
    }

    /// Handle a driver ride state update (Kind 30180).
    /// Returns the new driver status if the event was processed, nil if deduplicated.
    public func handleDriverStateUpdate(
        eventId: String,
        confirmationId: String,
        driverState: DriverRideStateContent
    ) throws -> String? {
        // Deduplication
        guard !processedDriverStateEventIds.contains(eventId) else { return nil }
        // Validate confirmation ID matches current ride
        guard confirmationId == confirmationEventId else { return nil }

        processedDriverStateEventIds.insert(eventId)
        lastDriverStatus = driverState.currentStatus

        // AtoB pattern: rider stage derived from driver status
        switch driverState.currentStatus {
        case "en_route_pickup":
            if stage == .rideConfirmed || stage == .driverAccepted {
                stage = .rideConfirmed
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

    /// Record a PIN verification attempt result.
    public func recordPinVerification(verified: Bool) {
        pinAttempts += 1
        if verified {
            pinVerified = true
        }
    }

    /// Record that precise pickup was shared.
    public func markPrecisePickupShared() {
        precisePickupShared = true
    }

    /// Record that precise destination was shared.
    public func markPreciseDestinationShared() {
        preciseDestinationShared = true
    }

    /// Add an action to the rider state history.
    public func addRiderAction(_ action: RiderRideAction) {
        riderStateHistory.append(action)
    }

    /// Handle a cancellation event. Returns true if processed, false if deduplicated.
    public func handleCancellation(eventId: String, confirmationId: String) -> Bool {
        guard !processedCancellationEventIds.contains(eventId) else { return false }
        // Only process if confirmation IDs match, OR if we're pre-confirmation (waiting/accepted)
        let preConfirmation = (stage == .waitingForAcceptance || stage == .driverAccepted)
        guard confirmationId == confirmationEventId || preConfirmation else { return false }
        processedCancellationEventIds.insert(eventId)
        stage = .idle
        return true
    }

    /// Reset the state machine to idle for a new ride.
    public func reset() {
        stage = .idle
        pin = nil
        confirmationEventId = nil
        acceptanceEventId = nil
        offerEventId = nil
        driverPubkey = nil
        pinVerified = false
        pinAttempts = 0
        precisePickupShared = false
        preciseDestinationShared = false
        paymentMethod = nil
        fiatPaymentMethods = []
        riderStateHistory = []
        lastDriverStatus = nil
        processedDriverStateEventIds.removeAll()
        processedCancellationEventIds.removeAll()
    }

    // MARK: - PIN Generation

    /// Generate a random 4-digit PIN.
    public static func generatePin() -> String {
        String(format: "%0\(RideConstants.pinDigits)d", Int.random(in: 0..<10000))
    }

    // MARK: - Transition Validation

    private func isValidTransition(from: RiderStage, to: RiderStage) -> Bool {
        // Cancellation can happen from any stage
        if to == .idle { return true }

        switch (from, to) {
        case (.idle, .waitingForAcceptance): return true
        case (.waitingForAcceptance, .driverAccepted): return true
        case (.driverAccepted, .rideConfirmed): return true
        case (.rideConfirmed, .driverArrived): return true
        case (.driverArrived, .inProgress): return true
        case (.inProgress, .completed): return true
        case (.completed, .idle): return true
        // Allow skipping rideConfirmed if driver state arrives fast
        case (.driverAccepted, .driverArrived): return true
        default: return false
        }
    }
}
