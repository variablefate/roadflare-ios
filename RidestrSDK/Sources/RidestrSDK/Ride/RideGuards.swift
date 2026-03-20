import Foundation

/// Guard function type for transition evaluation.
public typealias RideGuard = @Sendable (RideContext, RideEvent) -> Bool

/// Named guard functions for the rider state machine.
///
/// Guards determine whether a transition is allowed based on context and event.
/// Simplified for rider-only app — no identity guards (isRider/isDriver) since
/// only the rider triggers local transitions.
public enum RideGuards {
    /// Registry of all named guards.
    public static let registry: [String: RideGuard] = [
        "isPinVerified": isPinVerified,
        "isPinBruteForce": isPinBruteForce,
    ]

    /// Evaluate a guard by name.
    /// Returns true if guard passes, or if guard name is nil (no guard = always pass).
    public static func evaluate(_ name: String?, context: RideContext, event: RideEvent) -> Bool {
        guard let name else { return true }
        guard let guard_ = registry[name] else { return false }
        return guard_(context, event)
    }

    // MARK: - PIN Guards

    /// PIN was verified successfully in this event.
    public static let isPinVerified: RideGuard = { context, event in
        switch event {
        case .verifyPin(let verified, _):
            verified && !context.isPinBruteForceLimitReached
        default:
            context.pinVerified
        }
    }

    /// PIN brute force limit reached by this attempt.
    /// Uses context.pinAttempts + 1 (the attempt about to be recorded) for evaluation.
    public static let isPinBruteForce: RideGuard = { context, event in
        switch event {
        case .verifyPin(let verified, _):
            !verified && (context.pinAttempts + 1) >= context.maxPinAttempts
        default:
            context.isPinBruteForceLimitReached
        }
    }

    // MARK: - Diagnostics

    /// Human-readable explanation of why a guard failed.
    public static func explainFailure(_ guardName: String, context: RideContext, event: RideEvent) -> String {
        switch guardName {
        case "isPinVerified":
            "PIN verification required. Verified: \(context.pinVerified), brute force: \(context.isPinBruteForceLimitReached)"
        case "isPinBruteForce":
            "PIN attempt limit (\(context.maxPinAttempts)) not yet reached. Attempts: \(context.pinAttempts)"
        default:
            "Unknown guard: \(guardName)"
        }
    }

    /// Validate that all guards referenced in the transition table exist.
    public static func validateRegistry() -> [String] {
        var errors: [String] = []
        for transition in RideTransitions.all {
            if let guardName = transition.guard_, registry[guardName] == nil {
                errors.append("Unknown guard '\(guardName)' in transition \(transition.from) → \(transition.to)")
            }
        }
        return errors
    }
}
