import Foundation

/// All Nostr event kinds used by the Ridestr rideshare protocol.
public enum EventKind: UInt16, Sendable, CaseIterable {
    // Standard Nostr
    case metadata = 0

    // Ride lifecycle (regular events)
    case rideOffer = 3173
    case rideAcceptance = 3174
    case rideConfirmation = 3175
    case chatMessage = 3178
    case cancellation = 3179

    // RoadFlare (regular events)
    case keyShare = 3186
    case followNotification = 3187  // DEPRECATED — use p-tag queries on Kind 30011
    case keyAcknowledgement = 3188

    // NIP-60 wallet (future)
    case nip60ProofStorage = 7375
    case nip60ProofHistory = 7376
    case nip60PendingProof = 17375

    // RoadFlare (parameterized replaceable)
    case followedDriversList = 30011
    case driverRoadflareState = 30012
    case shareableDriverList = 30013
    case roadflareLocation = 30014

    // Ride state (parameterized replaceable)
    case driverAvailability = 30173
    case rideHistoryBackup = 30174
    case unifiedProfile = 30177
    case driverRideState = 30180
    case riderRideState = 30181
    case remoteConfig = 30182

    /// Whether this event kind uses parameterized replaceable semantics (NIP-33).
    /// Relays keep only the latest event per (pubkey, kind, d-tag) tuple.
    public var isReplaceable: Bool {
        rawValue >= 30000 && rawValue < 40000
    }

    /// Whether this event kind is ephemeral (NIP-16).
    /// Relays should not store these events.
    public var isEphemeral: Bool {
        rawValue >= 20000 && rawValue < 30000
    }

    /// Default d-tag value for replaceable events (nil if not replaceable or d-tag is dynamic).
    public var dTag: String? {
        switch self {
        case .driverAvailability: "rideshare-availability"
        case .rideHistoryBackup: "rideshare-history"
        case .unifiedProfile: "rideshare-profile"
        case .followedDriversList: "roadflare-drivers"
        case .driverRoadflareState: "roadflare-state"
        case .roadflareLocation: "roadflare-location"
        case .remoteConfig: "ridestr-admin-config"
        // driverRideState and riderRideState use confirmationEventId as d-tag (dynamic)
        // shareableDriverList uses a generated ID as d-tag (dynamic)
        default: nil
        }
    }

    /// Default NIP-40 expiration for this event kind, in seconds. Nil means no expiration.
    public var defaultExpirationSeconds: TimeInterval? {
        switch self {
        case .driverAvailability: EventExpiration.driverAvailabilityMinutes * 60
        case .rideOffer: EventExpiration.rideOfferMinutes * 60
        case .rideAcceptance: EventExpiration.rideAcceptanceMinutes * 60
        case .rideConfirmation: EventExpiration.rideConfirmationHours * 3600
        case .driverRideState: EventExpiration.rideStateHours * 3600
        case .riderRideState: EventExpiration.rideStateHours * 3600
        case .chatMessage: EventExpiration.chatHours * 3600
        case .cancellation: EventExpiration.cancellationHours * 3600
        case .roadflareLocation: EventExpiration.roadflareLocationMinutes * 60
        case .keyShare: EventExpiration.roadflareKeyShareHours * 3600
        case .keyAcknowledgement: EventExpiration.roadflareKeyAckMinutes * 60
        case .followNotification: EventExpiration.roadflareFollowNotifyMinutes * 60
        case .shareableDriverList: EventExpiration.shareableListDays * 86400
        default: nil
        }
    }
}

/// NIP-40 expiration times matching the Android implementation.
public enum EventExpiration {
    // Pre-ride
    public static let driverAvailabilityMinutes: TimeInterval = 30
    public static let rideOfferMinutes: TimeInterval = 15
    public static let rideAcceptanceMinutes: TimeInterval = 10

    // During ride (8 hours)
    public static let rideConfirmationHours: TimeInterval = 8
    public static let rideStateHours: TimeInterval = 8
    public static let chatHours: TimeInterval = 8

    // Post-ride
    public static let cancellationHours: TimeInterval = 24

    // RoadFlare
    public static let roadflareLocationMinutes: TimeInterval = 5
    public static let roadflareKeyShareHours: TimeInterval = 12
    public static let roadflareKeyAckMinutes: TimeInterval = 5
    public static let roadflareFollowNotifyMinutes: TimeInterval = 5
    public static let shareableListDays: TimeInterval = 30
}
