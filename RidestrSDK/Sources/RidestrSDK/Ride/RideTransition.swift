import Foundation

/// A valid state transition in the rider state machine.
public struct RideTransition: Sendable {
    /// Stage the machine must be in.
    public let from: RiderStage
    /// Event type that triggers this transition.
    public let eventType: String
    /// Stage to transition to.
    public let to: RiderStage
    /// Name of guard that must pass (nil = no guard).
    public let guard_: String?
    /// Human-readable description.
    public let description: String

    public init(from: RiderStage, eventType: String, to: RiderStage,
                guard_: String? = nil, description: String = "") {
        self.from = from
        self.eventType = eventType
        self.to = to
        self.guard_ = guard_
        self.description = description
    }
}

/// The complete transition table for the iOS rider state machine.
///
/// This is THE authoritative definition of all valid rider-side transitions.
/// Driver-initiated state changes are NOT in this table — they're handled
/// separately via `receiveDriverStateEvent()` (AtoB pattern).
///
/// ```
/// idle ──SEND_OFFER──► waitingForAcceptance ──ACCEPTANCE_RECEIVED──► driverAccepted
///                                                                        │
///     ┌──────────────────────────────────────────────────────────────────┘
///     │
///     └──CONFIRM──► rideConfirmed ──(AtoB)──► enRoute ──(AtoB)──► driverArrived
///                                                                      │
///     ┌────────────────────────────────────────────────────────────────┘
///     │
///     └──VERIFY_PIN(true)──► driverArrived (pin verified, waiting for driver ack)
///                                         └──(AtoB: in_progress)──► inProgress ──(AtoB)──► completed
///
/// Any cancellable stage can transition to idle via CANCEL.
/// ```
public enum RideTransitions {
    public static let all: [RideTransition] = [
        // idle
        RideTransition(
            from: .idle, eventType: "SEND_OFFER", to: .waitingForAcceptance,
            description: "Rider sends offer to driver"
        ),

        // waitingForAcceptance
        RideTransition(
            from: .waitingForAcceptance, eventType: "ACCEPTANCE_RECEIVED", to: .driverAccepted,
            description: "Driver accepted the ride offer"
        ),
        RideTransition(
            from: .waitingForAcceptance, eventType: "CANCEL", to: .idle,
            description: "Rider cancels before acceptance"
        ),
        RideTransition(
            from: .waitingForAcceptance, eventType: "CONFIRMATION_TIMEOUT", to: .idle,
            description: "Offer expired without acceptance"
        ),

        // driverAccepted
        RideTransition(
            from: .driverAccepted, eventType: "CONFIRM", to: .rideConfirmed,
            description: "Rider confirms with precise pickup"
        ),
        RideTransition(
            from: .driverAccepted, eventType: "CANCEL", to: .idle,
            description: "Either party cancels after acceptance"
        ),
        RideTransition(
            from: .driverAccepted, eventType: "CONFIRMATION_TIMEOUT", to: .idle,
            description: "Confirmation timeout"
        ),

        // rideConfirmed
        RideTransition(
            from: .rideConfirmed, eventType: "CANCEL", to: .idle,
            description: "Either party cancels after confirmation"
        ),

        // enRoute
        RideTransition(
            from: .enRoute, eventType: "CANCEL", to: .idle,
            description: "Either party cancels while driver en route"
        ),

        // driverArrived
        RideTransition(
            from: .driverArrived, eventType: "VERIFY_PIN", to: .driverArrived,
            guard_: "isPinVerified",
            description: "PIN verified, waiting for driver to acknowledge ride start"
        ),
        RideTransition(
            from: .driverArrived, eventType: "VERIFY_PIN", to: .idle,
            guard_: "isPinBruteForce",
            description: "PIN brute force limit exceeded"
        ),
        RideTransition(
            from: .driverArrived, eventType: "VERIFY_PIN", to: .driverArrived,
            description: "PIN failed, attempt recorded, stay at pickup"
        ),
        RideTransition(
            from: .driverArrived, eventType: "CANCEL", to: .idle,
            description: "Either party cancels at pickup"
        ),

        // inProgress
        RideTransition(
            from: .inProgress, eventType: "CANCEL", to: .idle,
            description: "Either party cancels during ride"
        ),
    ]

    /// Find transitions matching a state and event type.
    public static func findTransition(from state: RiderStage, eventType: String) -> [RideTransition] {
        all.filter { $0.from == state && $0.eventType == eventType }
    }

    /// Get all valid event types from a given state.
    public static func validEventsFrom(_ state: RiderStage) -> Set<String> {
        Set(all.filter { $0.from == state }.map(\.eventType))
    }

    /// Check if a transition exists (ignoring guards).
    public static func isValidTransition(from state: RiderStage, eventType: String) -> Bool {
        !findTransition(from: state, eventType: eventType).isEmpty
    }

    /// Get all states reachable from a given state.
    public static func reachableStatesFrom(_ state: RiderStage) -> Set<RiderStage> {
        Set(all.filter { $0.from == state }.map(\.to))
    }
}
