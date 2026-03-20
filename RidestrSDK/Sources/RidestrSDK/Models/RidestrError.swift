import Foundation

/// All errors thrown by RidestrSDK, organized by domain.
public enum RidestrError: Error, Sendable {
    case relay(RelayError)
    case crypto(CryptoError)
    case ride(RideError)
    case keychain(KeychainError)
    case location(LocationError)
    case profile(ProfileError)

    // MARK: - Relay Errors

    public enum RelayError: Error, Sendable {
        case connectionFailed(URL, underlying: any Error)
        case notConnected
        case timeout
    }

    // MARK: - Crypto Errors

    public enum CryptoError: Error, Sendable {
        case encryptionFailed(underlying: any Error)
        case decryptionFailed(underlying: any Error)
        case signingFailed(underlying: any Error)
        case invalidKey(String)
    }

    // MARK: - Ride Errors

    public enum RideError: Error, Sendable {
        case stateMachineViolation(from: String, to: String)
        case invalidEvent(String)
    }

    // MARK: - Keychain Errors

    public enum KeychainError: Error, Sendable {
        case osError(OSStatus)
        case dataCorrupted
    }

    // MARK: - Location Errors

    public enum LocationError: Error, Sendable {
        case invalidGeohash(String)
        case routeCalculationFailed(underlying: any Error)
        case geocodingFailed(underlying: any Error)
    }

    // MARK: - Profile Errors

    public enum ProfileError: Error, Sendable {
        case syncFailed(underlying: any Error)
    }

}

extension RidestrError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .crypto(let error):
            switch error {
            case .invalidKey(let detail): "Invalid key: \(detail)"
            case .encryptionFailed(let error): "Encryption failed: \(error.localizedDescription)"
            case .decryptionFailed(let error): "Decryption failed: \(error.localizedDescription)"
            case .signingFailed(let error): "Event signing failed: \(error.localizedDescription)"
            }
        case .keychain(let error):
            switch error {
            case .osError(let status): "Keychain error: OSStatus \(status)"
            case .dataCorrupted: "Keychain data corrupted"
            }
        case .relay(let error):
            switch error {
            case .connectionFailed(let url, let error): "Relay connection to \(url) failed: \(error.localizedDescription)"
            case .notConnected: "Not connected to any relay"
            case .timeout: "Relay operation timed out"
            }
        case .ride(let error):
            switch error {
            case .stateMachineViolation(let from, let to): "Invalid state transition: \(from) → \(to)"
            case .invalidEvent(let detail): "Invalid event: \(detail)"
            }
        case .location(let error):
            switch error {
            case .invalidGeohash(let detail): "Invalid geohash: \(detail)"
            case .routeCalculationFailed(let error): "Route calculation failed: \(error.localizedDescription)"
            case .geocodingFailed(let error): "Geocoding failed: \(error.localizedDescription)"
            }
        case .profile(let error):
            switch error {
            case .syncFailed(let error): "Profile sync failed: \(error.localizedDescription)"
            }
        }
    }
}
