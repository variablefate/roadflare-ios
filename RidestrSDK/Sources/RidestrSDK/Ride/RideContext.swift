import Foundation

/// Immutable context for ride state machine evaluation.
///
/// Contains all data needed for guard evaluation and action execution.
/// Mutations produce new copies via `with*()` methods (value semantics).
/// Fiat-only for v1 — no escrow/HTLC/preimage fields.
public struct RideContext: Sendable {
    // MARK: - Participant Identity

    /// Rider's Nostr public key.
    public let riderPubkey: PublicKeyHex

    /// Driver's Nostr public key (nil until acceptance).
    public let driverPubkey: PublicKeyHex?

    // MARK: - Ride Identification

    /// Offer event ID (Kind 3173).
    public let offerEventId: EventID?

    /// Acceptance event ID (Kind 3174).
    public let acceptanceEventId: EventID?

    /// Confirmation event ID (Kind 3175) — canonical ride identifier.
    public let confirmationEventId: ConfirmationEventID?

    // MARK: - PIN Verification

    /// 4-digit PIN for pickup verification.
    public let pin: String?

    /// Number of PIN verification attempts.
    public let pinAttempts: Int

    /// Whether PIN has been verified.
    public let pinVerified: Bool

    /// Maximum PIN attempts before lockout.
    public let maxPinAttempts: Int

    // MARK: - Payment (Fiat v1)

    /// Selected payment method for this ride.
    public let paymentMethod: String?

    /// Rider's accepted fiat payment methods.
    public let fiatPaymentMethods: [String]

    // MARK: - Location Sharing

    /// Whether precise pickup has been shared with driver.
    public let precisePickupShared: Bool

    /// Whether precise destination has been shared with driver.
    public let preciseDestinationShared: Bool

    // MARK: - Driver State (AtoB)

    /// Driver's last known status from Kind 30180.
    public let lastDriverStatus: String?

    /// Timestamp of last processed driver state event (for ordering).
    public let lastDriverStateTimestamp: Int

    /// Number of actions in the last processed driver state snapshot.
    public let lastDriverActionCount: Int

    // MARK: - History

    /// Rider's action history (published in Kind 30181).
    public let riderStateHistory: [RiderRideAction]

    // MARK: - Init

    public init(
        riderPubkey: PublicKeyHex,
        driverPubkey: PublicKeyHex? = nil,
        offerEventId: EventID? = nil,
        acceptanceEventId: EventID? = nil,
        confirmationEventId: ConfirmationEventID? = nil,
        pin: String? = nil,
        pinAttempts: Int = 0,
        pinVerified: Bool = false,
        maxPinAttempts: Int = RideConstants.maxPinAttempts,
        paymentMethod: String? = nil,
        fiatPaymentMethods: [String] = [],
        precisePickupShared: Bool = false,
        preciseDestinationShared: Bool = false,
        lastDriverStatus: String? = nil,
        lastDriverStateTimestamp: Int = 0,
        lastDriverActionCount: Int = 0,
        riderStateHistory: [RiderRideAction] = []
    ) {
        self.riderPubkey = riderPubkey
        self.driverPubkey = driverPubkey
        self.offerEventId = offerEventId
        self.acceptanceEventId = acceptanceEventId
        self.confirmationEventId = confirmationEventId
        self.pin = pin
        self.pinAttempts = pinAttempts
        self.pinVerified = pinVerified
        self.maxPinAttempts = maxPinAttempts
        self.paymentMethod = paymentMethod
        self.fiatPaymentMethods = RoadflarePaymentPreferences(methods: fiatPaymentMethods).methods
        self.precisePickupShared = precisePickupShared
        self.preciseDestinationShared = preciseDestinationShared
        self.lastDriverStatus = lastDriverStatus
        self.lastDriverStateTimestamp = lastDriverStateTimestamp
        self.lastDriverActionCount = lastDriverActionCount
        self.riderStateHistory = riderStateHistory
    }

    // MARK: - Copy Methods

    /// Create a copy with driver assignment (after acceptance).
    public func withDriver(
        driverPubkey: String,
        acceptanceEventId: String? = nil
    ) -> RideContext {
        RideContext(
            riderPubkey: riderPubkey, driverPubkey: driverPubkey,
            offerEventId: offerEventId, acceptanceEventId: acceptanceEventId ?? self.acceptanceEventId,
            confirmationEventId: confirmationEventId, pin: pin,
            pinAttempts: pinAttempts, pinVerified: pinVerified, maxPinAttempts: maxPinAttempts,
            paymentMethod: paymentMethod, fiatPaymentMethods: fiatPaymentMethods,
            precisePickupShared: precisePickupShared, preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory
        )
    }

    /// Create a copy with confirmation data.
    public func withConfirmation(confirmationEventId: String) -> RideContext {
        RideContext(
            riderPubkey: riderPubkey, driverPubkey: driverPubkey,
            offerEventId: offerEventId, acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId, pin: pin,
            pinAttempts: pinAttempts, pinVerified: pinVerified, maxPinAttempts: maxPinAttempts,
            paymentMethod: paymentMethod, fiatPaymentMethods: fiatPaymentMethods,
            precisePickupShared: precisePickupShared, preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory
        )
    }

    /// Create a copy with PIN verification attempt.
    public func withPinAttempt(verified: Bool) -> RideContext {
        RideContext(
            riderPubkey: riderPubkey, driverPubkey: driverPubkey,
            offerEventId: offerEventId, acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId, pin: verified ? nil : pin,
            pinAttempts: pinAttempts + 1, pinVerified: verified || pinVerified,
            maxPinAttempts: maxPinAttempts,
            paymentMethod: paymentMethod, fiatPaymentMethods: fiatPaymentMethods,
            precisePickupShared: precisePickupShared, preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory
        )
    }

    /// Create a copy with generated PIN.
    public func withPin(_ pin: String) -> RideContext {
        RideContext(
            riderPubkey: riderPubkey, driverPubkey: driverPubkey,
            offerEventId: offerEventId, acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId, pin: pin,
            pinAttempts: pinAttempts, pinVerified: pinVerified, maxPinAttempts: maxPinAttempts,
            paymentMethod: paymentMethod, fiatPaymentMethods: fiatPaymentMethods,
            precisePickupShared: precisePickupShared, preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory
        )
    }

    // MARK: - Additional Copy Methods

    /// Create a copy with precise pickup shared flag.
    public func withPrecisePickupShared(_ shared: Bool) -> RideContext {
        RideContext(
            riderPubkey: riderPubkey, driverPubkey: driverPubkey,
            offerEventId: offerEventId, acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId, pin: pin,
            pinAttempts: pinAttempts, pinVerified: pinVerified, maxPinAttempts: maxPinAttempts,
            paymentMethod: paymentMethod, fiatPaymentMethods: fiatPaymentMethods,
            precisePickupShared: shared, preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory
        )
    }

    /// Create a copy with precise destination shared flag.
    public func withPreciseDestinationShared(_ shared: Bool) -> RideContext {
        RideContext(
            riderPubkey: riderPubkey, driverPubkey: driverPubkey,
            offerEventId: offerEventId, acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId, pin: pin,
            pinAttempts: pinAttempts, pinVerified: pinVerified, maxPinAttempts: maxPinAttempts,
            paymentMethod: paymentMethod, fiatPaymentMethods: fiatPaymentMethods,
            precisePickupShared: precisePickupShared, preciseDestinationShared: shared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory
        )
    }

    /// Create a copy with an appended rider action.
    public func withRiderAction(_ action: RiderRideAction) -> RideContext {
        RideContext(
            riderPubkey: riderPubkey, driverPubkey: driverPubkey,
            offerEventId: offerEventId, acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId, pin: pin,
            pinAttempts: pinAttempts, pinVerified: pinVerified, maxPinAttempts: maxPinAttempts,
            paymentMethod: paymentMethod, fiatPaymentMethods: fiatPaymentMethods,
            precisePickupShared: precisePickupShared, preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory + [action]
        )
    }

    // MARK: - Queries

    /// Whether PIN brute force limit has been reached.
    public var isPinBruteForceLimitReached: Bool { pinAttempts >= maxPinAttempts }
}
