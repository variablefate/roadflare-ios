import Foundation

/// Configures how a single sync domain applies remote state and publishes
/// local state. Provided by the app layer; consumed by `SyncDomainResolver`.
///
/// All closures are `@Sendable async` so they can cross actor boundaries.
/// Callers that need `@MainActor` state access should wrap their work in
/// `await MainActor.run { … }` inside the closure body.
public struct SyncDomainStrategy<Value: Sendable>: Sendable {
    public let domain: RoadflareSyncDomain
    /// Whether the app has any non-empty local state for this domain.
    /// Used to decide if legacy local state should seed the first publish.
    public let hasLocalState: @Sendable () async -> Bool
    /// Fires BEFORE resolution, whenever a snapshot is present.
    /// Only `profileBackup` needs this today (Android template preservation).
    public let onSnapshotSeen: (@Sendable (Value) async -> Void)?
    /// Fires when remote wins. The resolver calls `markPublished` immediately
    /// after, so this closure only handles state mutation + logging.
    public let applyRemote: @Sendable (Value) async -> Void
    /// Warning logged when the newest remote event is undecodable.
    /// Logged by the resolver via `RidestrLogger.warning`.
    public let undecodableWarning: String
    /// Extra guard checked before `markDirty` / `publishLocal` fire.
    /// Only `rideHistory` uses this today (`!rides.isEmpty`).
    public let shouldPublishGuard: @Sendable () async -> Bool
    /// Full publish flow INCLUDING `markPublished` on success.
    public let publishLocal: @Sendable () async -> Void

    public init(
        domain: RoadflareSyncDomain,
        hasLocalState: @escaping @Sendable () async -> Bool,
        applyRemote: @escaping @Sendable (Value) async -> Void,
        undecodableWarning: String,
        publishLocal: @escaping @Sendable () async -> Void,
        shouldPublishGuard: @escaping @Sendable () async -> Bool = { true },
        onSnapshotSeen: (@Sendable (Value) async -> Void)? = nil
    ) {
        self.domain = domain
        self.hasLocalState = hasLocalState
        self.applyRemote = applyRemote
        self.undecodableWarning = undecodableWarning
        self.publishLocal = publishLocal
        self.shouldPublishGuard = shouldPublishGuard
        self.onSnapshotSeen = onSnapshotSeen
    }
}

/// Generic startup-sync resolver for RoadFlare domains.
///
/// Given a `SyncDomainStrategy` and a `StartupRemoteDomain` fetched from the
/// relay, chooses between remote-wins, local-publish, or legacy-seed based on
/// the sync metadata. Logs a warning when the newest remote event is
/// undecodable so local state is preserved without silent data drops.
///
/// This is a pure control-flow helper — it does no network I/O itself and
/// mutates only the supplied `RoadflareSyncStateStore`.
public enum SyncDomainResolver {
    public static func apply<Value: Sendable>(
        strategy: SyncDomainStrategy<Value>,
        remote: RoadflareDomainService.StartupRemoteDomain<Value>,
        syncStore: RoadflareSyncStateStore
    ) async {
        let metadata = syncStore.metadata(for: strategy.domain)
        let resolution = RoadflareDomainService.resolve(
            domain: strategy.domain,
            metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt
        )
        let hasLocal = await strategy.hasLocalState()
        let shouldSeed = RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt,
            hasLocalState: hasLocal
        )

        if let snapshot = remote.snapshot {
            await strategy.onSnapshotSeen?(snapshot.value)
        }

        if resolution.source == .remote,
           let snapshot = remote.snapshot,
           snapshot.createdAt == remote.latestSeenCreatedAt {
            await strategy.applyRemote(snapshot.value)
            syncStore.markPublished(strategy.domain, at: snapshot.createdAt)
        } else if resolution.source == .remote, remote.latestSeenCreatedAt != nil {
            RidestrLogger.warning("[SyncDomainResolver] \(strategy.undecodableWarning)")
        } else if (resolution.shouldPublishLocal || shouldSeed), await strategy.shouldPublishGuard() {
            if shouldSeed { syncStore.markDirty(strategy.domain) }
            await strategy.publishLocal()
        }
    }
}
