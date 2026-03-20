import Foundation

/// Events that trigger state transitions in the rider state machine.
///
/// Each event corresponds to a rider action or system event.
/// Driver-initiated state changes (Kind 30180) are NOT events — they're
/// handled separately via `receiveDriverStateEvent()` (AtoB pattern).
public enum RideEvent: Sendable {
    /// Rider sends a ride offer (Kind 3173).
    /// Transition: idle → waitingForAcceptance
    case sendOffer(
        offerEventId: EventID,
        driverPubkey: PublicKeyHex,
        paymentMethod: PaymentMethod?,
        fiatPaymentMethods: [PaymentMethod]
    )

    /// Driver's acceptance received (Kind 3174).
    /// Transition: waitingForAcceptance → driverAccepted
    case acceptanceReceived(acceptanceEventId: EventID)

    /// Rider confirms ride with precise pickup (Kind 3175).
    /// Transition: driverAccepted → rideConfirmed
    case confirm(confirmationEventId: ConfirmationEventID)

    /// PIN verification result from driver's submission.
    /// Transition: driverArrived → inProgress (if verified)
    ///           : driverArrived → idle (if brute force limit reached)
    case verifyPin(verified: Bool, attempt: Int)

    /// Either party cancels the ride (Kind 3179).
    /// Transition: any cancellable stage → idle
    case cancel(eventId: EventID, confirmationId: ConfirmationEventID)

    /// Offer/confirmation timeout expired (system timer).
    /// Transition: waitingForAcceptance/driverAccepted → idle
    case confirmationTimeout

    /// Event type string for logging and transition table lookup.
    public var eventType: String {
        switch self {
        case .sendOffer: "SEND_OFFER"
        case .acceptanceReceived: "ACCEPTANCE_RECEIVED"
        case .confirm: "CONFIRM"
        case .verifyPin: "VERIFY_PIN"
        case .cancel: "CANCEL"
        case .confirmationTimeout: "CONFIRMATION_TIMEOUT"
        }
    }
}
