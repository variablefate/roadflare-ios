import Foundation

/// SDK-owned coordinator for ride history backup sync.
///
/// Owns the fire-and-forget publish Task for any user-initiated ride history
/// mutation (add ride after ride completion, remove ride from history).
/// On publish failure, marks `.rideHistory` dirty so `flushPendingSyncPublishes`
/// retries on the next relay reconnect.
///
/// Thread safety: NSLock-protected state. Generation counter invalidates
/// in-flight publish Tasks that cross a `clearAll()` boundary (identity
/// replacement). Parallel to `ProfileBackupCoordinator`.
///
// @unchecked Sendable: all mutable state protected by `lock`.
public final class RideHistorySyncCoordinator: @unchecked Sendable {
    private let domainService: RoadflareDomainService
    private weak var syncStoreRef: RoadflareSyncStateStore?

    private let lock = NSLock()
    /// Bumped by `clearAll()` to invalidate in-flight publish Tasks.
    private var generation: UInt64 = 0

    public init(domainService: RoadflareDomainService, syncStore: RoadflareSyncStateStore) {
        self.domainService = domainService
        self.syncStoreRef = syncStore
    }

    // MARK: - Publish

    /// Publish ride history immediately (fire-and-forget Task).
    /// Marks `.rideHistory` dirty on failure so the reconnect flush retries.
    ///
    /// Call after any user-initiated ride history mutation:
    /// - after `rideHistory.addRide(entry)` (ride completion)
    /// - after `rideHistory.removeRide(id:)` (swipe-to-delete)
    ///
    /// Callers must be `@MainActor`. `generation` is NSLock-protected;
    /// `rideHistory.rides` is safe to read on `@MainActor` because all
    /// mutations also run on `@MainActor` (no concurrent read/write is
    /// possible). The generation guard's correctness requires callers and
    /// `clearAll()` to be serialized on the same actor — in practice all
    /// callers are `@MainActor` and `SyncCoordinator.teardown()` is also
    /// `@MainActor`.
    public func publishAndMark(from rideHistory: RideHistoryRepository) {
        let rides = rideHistory.rides
        let myGeneration: UInt64 = lock.withLock { generation }
        Task {
            let content = RideHistoryBackupContent(rides: rides)
            do {
                let event = try await domainService.publishRideHistoryBackup(content)
                lock.withLock {
                    guard generation == myGeneration else { return }
                    syncStoreRef?.markPublished(.rideHistory, at: event.createdAt)
                    RidestrLogger.info("[RideHistorySyncCoordinator] Published ride history backup")
                }
            } catch {
                lock.withLock {
                    guard generation == myGeneration else { return }
                    syncStoreRef?.markDirty(.rideHistory)
                    RidestrLogger.info("[RideHistorySyncCoordinator] Failed; marked dirty: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Cleanup

    /// Bump generation to invalidate any in-flight publish Task.
    /// Called by `SyncCoordinator.teardown()` on identity replacement.
    public func clearAll() {
        lock.withLock { generation &+= 1 }
    }
}
