import Foundation

/// RoadFlare sync domains tracked independently during startup and publish.
public enum RoadflareSyncDomain: String, Codable, CaseIterable, Sendable {
    case profile
    case followedDrivers
    case profileBackup
}

/// Per-domain local sync metadata.
///
/// `lastSuccessfulPublishAt` is the authoritative local freshness marker for the last
/// confirmed local publish. `isDirty` indicates the local app state has diverged and
/// should not be overwritten by remote data during startup sync.
public struct RoadflareSyncMetadata: Codable, Sendable, Equatable {
    public var lastSuccessfulPublishAt: Int
    public var isDirty: Bool

    public init(lastSuccessfulPublishAt: Int = 0, isDirty: Bool = false) {
        self.lastSuccessfulPublishAt = lastSuccessfulPublishAt
        self.isDirty = isDirty
    }
}

/// Complete sync state for all RoadFlare domains.
public struct RoadflareSyncState: Codable, Sendable, Equatable {
    public var profile: RoadflareSyncMetadata
    public var followedDrivers: RoadflareSyncMetadata
    public var profileBackup: RoadflareSyncMetadata

    public init(
        profile: RoadflareSyncMetadata = RoadflareSyncMetadata(),
        followedDrivers: RoadflareSyncMetadata = RoadflareSyncMetadata(),
        profileBackup: RoadflareSyncMetadata = RoadflareSyncMetadata()
    ) {
        self.profile = profile
        self.followedDrivers = followedDrivers
        self.profileBackup = profileBackup
    }

    public subscript(domain: RoadflareSyncDomain) -> RoadflareSyncMetadata {
        get {
            switch domain {
            case .profile: profile
            case .followedDrivers: followedDrivers
            case .profileBackup: profileBackup
            }
        }
        set {
            switch domain {
            case .profile: profile = newValue
            case .followedDrivers: followedDrivers = newValue
            case .profileBackup: profileBackup = newValue
            }
        }
    }
}

/// A remote event paired with its decoded value.
public struct RoadflareRemoteSnapshot<Value: Sendable>: Sendable {
    public let eventId: String
    public let createdAt: Int
    public let value: Value

    public init(eventId: String, createdAt: Int, value: Value) {
        self.eventId = eventId
        self.createdAt = createdAt
        self.value = value
    }
}

/// Resolution result for a sync domain.
public struct RoadflareSyncResolution: Sendable, Equatable {
    public let domain: RoadflareSyncDomain
    public let source: RoadflareSyncSource
    public let remoteCreatedAt: Int?
    public let shouldPublishLocal: Bool

    public init(
        domain: RoadflareSyncDomain,
        source: RoadflareSyncSource,
        remoteCreatedAt: Int?,
        shouldPublishLocal: Bool
    ) {
        self.domain = domain
        self.source = source
        self.remoteCreatedAt = remoteCreatedAt
        self.shouldPublishLocal = shouldPublishLocal
    }
}

/// Where a sync decision came from.
public enum RoadflareSyncSource: String, Codable, Sendable, Equatable {
    case local
    case remote
}
