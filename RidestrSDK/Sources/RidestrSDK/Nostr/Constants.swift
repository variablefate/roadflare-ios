import Foundation

// MARK: - Relay Constants

/// Relay connection and subscription constants matching Android implementation.
public enum RelayConstants {
    public static let connectTimeoutSeconds: TimeInterval = 10
    public static let readTimeoutSeconds: TimeInterval = 30
    public static let writeTimeoutSeconds: TimeInterval = 30
    public static let awaitConnectedTimeoutSeconds: TimeInterval = 15
    public static let eoseTimeoutSeconds: TimeInterval = 8
    public static let eoseQuickTimeoutSeconds: TimeInterval = 5
    public static let reconnectBaseDelaySeconds: TimeInterval = 5
    public static let reconnectMaxDelaySeconds: TimeInterval = 60
    public static let maxRelays = 10
    public static let staleSubscriptionAgeSeconds: TimeInterval = 1800  // 30 minutes
    public static let messageChannelCapacity = 256
}

/// Default Nostr relay URLs.
public enum DefaultRelays {
    public static let damus = URL(string: "wss://relay.damus.io")!
    public static let nosLol = URL(string: "wss://nos.lol")!
    public static let primal = URL(string: "wss://relay.primal.net")!

    public static let all: [URL] = [damus, nosLol, primal]
}

// MARK: - Ride Constants

/// Ride lifecycle constants matching Android implementation.
public enum RideConstants {
    public static let pinDigits = 4
    public static let maxPinAttempts = 3
    public static let progressiveRevealThresholdKm = 1.6  // ~1 mile
    public static let locationApproxDecimals = 2  // ~1km precision
    public static let batchSize = 3
    public static let batchDelaySeconds: TimeInterval = 15
    public static let acceptanceTimeoutSeconds: TimeInterval = 15
    public static let broadcastTimeoutSeconds: TimeInterval = 120
    public static let chatRefreshIntervalSeconds: TimeInterval = 15
    public static let nip33OrderingDelaySeconds: TimeInterval = 1.1
    public static let htlcExpirySeconds: TimeInterval = 900  // 15 minutes (future Cashu)
    public static let crossMintFeeBufferPercent = 0.02
}

// MARK: - Geohash Precision

/// Standard geohash precision levels for the protocol.
public enum GeohashPrecision {
    public static let expandedSearch = 3   // ~156km — expanded driver search
    public static let normalSearch = 4     // ~39km — normal driver search
    public static let ride = 5             // ~4.9km — ride location tags
    public static let history = 6          // ~1.2km — ride history storage
    public static let settlement = 7       // ~153m — settlement verification
}

// MARK: - Storage Constants

/// Storage limits matching Android implementation.
public enum StorageConstants {
    public static let maxRecentLocations = 15
    public static let duplicateLocationThresholdMeters = 50.0
    public static let maxRideHistory = 500
    public static let maxFavoriteAddresses = 10
    public static let clearGracePeriodSeconds: TimeInterval = 30
}

// MARK: - Admin

/// Admin configuration constants.
public enum AdminConstants {
    /// Hardcoded admin pubkey for Kind 30182 remote config events.
    public static let adminPubkey = "da790ba18e63ae79b16e172907301906957a45f38ef0c9f219d0f016eaf16128"

    /// Default fare configuration (used when remote config unavailable).
    public static let defaultFareRateUsdPerMile: Decimal = 0.50
    public static let defaultMinimumFareUsd: Decimal = 1.50
    public static let defaultRoadflareFareRateUsdPerMile: Decimal = 0.40
    public static let defaultRoadflareMinimumFareUsd: Decimal = 1.00

    /// RoadFlare iOS fare: $10 base + $1.30/mile. Simple, fair, better than rideshare apps.
    public static let roadflareBaseFareUsd: Decimal = 10.00
    public static let roadflareUIRateUsdPerMile: Decimal = 1.30
    public static let roadflareUIMinimumFareUsd: Decimal = 10.00
}

// MARK: - Location Constants

/// Geographic and unit conversion constants.
public enum LocationConstants {
    /// Mean radius of the Earth in kilometers (WGS-84 approximation).
    public static let earthRadiusKm = 6371.0
    /// Conversion factor: kilometers to miles.
    public static let kmToMiles = 0.621371
    /// Conversion factor: miles to kilometers.
    public static let milesToKm = 1.60934
}

// MARK: - Nostr Tags

/// Standard tag names used in Ridestr events.
public enum NostrTags {
    public static let eventRef = "e"
    public static let pubkeyRef = "p"
    public static let dTag = "d"
    public static let hashtag = "t"
    public static let geohash = "g"
    public static let expiration = "expiration"
    public static let keyVersion = "key_version"
    public static let keyUpdatedAt = "key_updated_at"
    public static let status = "status"
    public static let transition = "transition"

    // Hashtag values
    public static let rideshareTag = "rideshare"
    public static let roadflareTag = "roadflare"
    public static let rideRequestTag = "ride-request"
    public static let roadflareKeyTag = "roadflare-key"
    public static let roadflareKeyAckTag = "roadflare-key-ack"
    public static let roadflareFollowTag = "roadflare-follow"
    public static let roadflareLocationTag = "roadflare-location"
}
