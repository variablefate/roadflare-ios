import Foundation

/// Wires repository change callbacks to `RoadflareSyncStateStore.markDirty()`
/// so the protocol-level mapping of "which local mutation dirties which sync
/// domain" lives in the SDK rather than in the app layer.
///
/// Callbacks are wired in `init` and nil'd in `detach()`. `deinit` calls
/// the same nil-assignments directly as a thread-safe defensive no-op:
/// `SyncCoordinator` always calls `detach()` before releasing the tracker,
/// so callbacks are already nil by the time `deinit` fires.
///
/// Note: `.rideHistory` is NOT wired here. `RideHistorySyncCoordinator`
/// calls `markDirty(.rideHistory)` on publish failure; passive wiring via
/// `onRidesChanged` caused a false-dirty on `restoreFromBackup` at startup.
///
/// `@unchecked Sendable`: all `let` properties are themselves `@unchecked
/// Sendable`. `driversRepo` is `weak var` written only in `wireCallbacks()`
/// and `_detachUnchecked()`, both called exclusively from `@MainActor`
/// context (via `SyncCoordinator`), so access is always main-actor-serialized.
/// `markDirty` inside `RoadflareSyncStateStore` is NSLock-protected.
public final class SyncDomainTracker: @unchecked Sendable {

    // MARK: - Stored References

    private let store: RoadflareSyncStateStore
    private let settings: UserSettingsRepository
    private weak var driversRepo: FollowedDriversRepository?
    private let rideHistory: RideHistoryRepository
    private let savedLocations: SavedLocationsRepository

    // MARK: - Init

    /// Wire all change-tracking callbacks immediately.
    ///
    /// - Parameters:
    ///   - store: The sync state store that receives `markDirty` calls.
    ///   - settings: User settings repository (profile + profileBackup domains).
    ///   - driversRepo: Followed drivers repository (stored weakly). Only
    ///     `.local` mutations dirty `.followedDrivers`; `.sync` mutations are
    ///     ignored — they originate from the relay, not from local edits.
    ///   - rideHistory: Ride history repository — accepted so `detach()` can nil
    ///     its `onRidesChanged` callback. `.rideHistory` dirty marking is handled
    ///     by `RideHistorySyncCoordinator`, not this tracker (see class-level note).
    ///   - savedLocations: Saved locations repository (profileBackup domain).
    public init(
        store: RoadflareSyncStateStore,
        settings: UserSettingsRepository,
        driversRepo: FollowedDriversRepository,
        rideHistory: RideHistoryRepository,
        savedLocations: SavedLocationsRepository
    ) {
        self.store = store
        self.settings = settings
        self.driversRepo = driversRepo
        self.rideHistory = rideHistory
        self.savedLocations = savedLocations
        wireCallbacks()
    }

    // MARK: - Detach

    /// Nil out all repository callbacks. Call before any `clearAll()` on the
    /// repositories to prevent stale dirty flags after logout. `SyncCoordinator`
    /// always calls this before releasing the tracker, so `deinit`'s own call
    /// to `_detachUnchecked()` is a defensive no-op by the time it fires.
    @MainActor public func detach() {
        _detachUnchecked()
    }

    deinit {
        // `_detachUnchecked()` has no actor isolation and is safe to call from
        // any thread. SyncCoordinator (@MainActor) always calls detach() before
        // releasing this tracker, so callbacks are already nil here — this is
        // purely a defensive safety net against programmer error.
        _detachUnchecked()
    }

    // MARK: - Private

    /// Nil-assignment implementation with no actor isolation so it is safe to
    /// call from `deinit` on any thread. External callers must use `detach()`.
    private func _detachUnchecked() {
        settings.onProfileChanged = nil
        settings.onProfileBackupChanged = nil
        driversRepo?.onDriversChanged = nil
        rideHistory.onRidesChanged = nil
        savedLocations.onChange = nil
    }

    private func wireCallbacks() {
        let store = self.store

        settings.onProfileChanged = { [weak store] in
            store?.markDirty(.profile)
        }
        settings.onProfileBackupChanged = { [weak store] in
            store?.markDirty(.profileBackup)
        }
        driversRepo?.onDriversChanged = { [weak store] source in
            guard source == .local else { return }
            store?.markDirty(.followedDrivers)
        }
        savedLocations.onChange = { [weak store] in
            store?.markDirty(.profileBackup)
        }
    }
}
