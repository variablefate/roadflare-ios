import Foundation

/// Outcome that ends a ride session.
public enum RideSessionTerminalOutcome: Sendable {
    case completed
    case cancelledByRider(reason: String?)
    case cancelledByDriver(reason: String?)
    case expired(stage: RiderStage)
    case bruteForcePin
}

/// Delegate for receiving notifications from a `RiderRideSession`.
///
/// All methods are notification-only — the session never pulls data from the delegate.
@MainActor
public protocol RiderRideSessionDelegate: AnyObject {
    /// The ride reached a terminal state.
    func sessionDidReachTerminal(_ outcome: RideSessionTerminalOutcome)
    /// A non-fatal error occurred (e.g., publish failed, subscription error).
    func sessionDidEncounterError(_ error: Error)
    /// The ride stage changed. Fired for every real state machine transition.
    func sessionDidChangeStage(from: RiderStage, to: RiderStage)
    /// Session state changed and the app should persist. Read session properties directly.
    func sessionShouldPersist()
}

// Default implementations so delegates only implement what they need.
public extension RiderRideSessionDelegate {
    func sessionDidChangeStage(from: RiderStage, to: RiderStage) {}
    func sessionShouldPersist() {}
}
