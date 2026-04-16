import Foundation

/// Result of a Kind 3189 driver ping attempt.
public enum DriverPingResult: Sendable, Equatable {
    case sent
    case rateLimited(retryAfter: Date)
    case missingKey
    case ineligible
    case publishFailed(String)
}
