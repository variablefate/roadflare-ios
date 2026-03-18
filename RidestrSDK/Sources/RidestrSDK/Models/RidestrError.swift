import Foundation

/// All errors thrown by RidestrSDK.
public enum RidestrError: Error, Sendable {
    case invalidKey(String)
    case invalidEvent(String)
    case invalidGeohash(String)
    case encryptionFailed(underlying: any Error)
    case decryptionFailed(underlying: any Error)
    case eventSigningFailed(underlying: any Error)
    case keychainError(OSStatus)
    case keychainDataCorrupted
    case relayConnectionFailed(URL, underlying: any Error)
    case relayNotConnected
    case relayTimeout
    case rideStateMachineViolation(from: String, to: String)
    case routeCalculationFailed(underlying: any Error)
    case geocodingFailed(underlying: any Error)
    case profileSyncFailed(underlying: any Error)
}

extension RidestrError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidKey(let detail):
            "Invalid key: \(detail)"
        case .invalidEvent(let detail):
            "Invalid event: \(detail)"
        case .invalidGeohash(let detail):
            "Invalid geohash: \(detail)"
        case .encryptionFailed(let error):
            "Encryption failed: \(error.localizedDescription)"
        case .decryptionFailed(let error):
            "Decryption failed: \(error.localizedDescription)"
        case .eventSigningFailed(let error):
            "Event signing failed: \(error.localizedDescription)"
        case .keychainError(let status):
            "Keychain error: OSStatus \(status)"
        case .keychainDataCorrupted:
            "Keychain data corrupted"
        case .relayConnectionFailed(let url, let error):
            "Relay connection to \(url) failed: \(error.localizedDescription)"
        case .relayNotConnected:
            "Not connected to any relay"
        case .relayTimeout:
            "Relay operation timed out"
        case .rideStateMachineViolation(let from, let to):
            "Invalid state transition: \(from) → \(to)"
        case .routeCalculationFailed(let error):
            "Route calculation failed: \(error.localizedDescription)"
        case .geocodingFailed(let error):
            "Geocoding failed: \(error.localizedDescription)"
        case .profileSyncFailed(let error):
            "Profile sync failed: \(error.localizedDescription)"
        }
    }
}
