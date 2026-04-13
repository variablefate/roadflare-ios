import Foundation

/// Wires repository change callbacks to `RoadflareSyncStateStore.markDirty()`
/// so the protocol-level mapping of "which local mutation dirties which sync
/// domain" lives in the SDK rather than in the app layer.
///
/// Callbacks are wired in `init` and nil'd in `detach()`. `deinit` calls
/// `detach()` as a safety net so repositories are never left pointing at a
/// deallocated tracker.
///
/// `@unchecked Sendable`: all `let` properties are themselves `@unchecked
/// Sendable`. `driversRepo` is `weak var` written only in `wireCallbacks()`
/// and `detach()`, both called exclusively through `SyncCoordinator`
/// (`@MainActor`), so access is always main-actor-serialized. `markDirty`
/// inside `RoadflareSyncStateStore` is NSLock-protected.
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
    ///   - rideHistory: Ride history repository (rideHistory domain).
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
    /// repositories to prevent stale dirty flags after logout.
    /// `deinit` also calls `detach()` as a safety net.
    @MainActor public func detach() {
        settings.onProfileChanged = nil
        settings.onProfileBackupChanged = nil
        driversRepo?.onDriversChanged = nil
        rideHistory.onRidesChanged = nil
        savedLocations.onChange = nil
        // onFavoritesChanged is intentionally NOT wired (onChange already fires
        // for all location mutations including favorites, making a separate
        // onFavoritesChanged → profileBackup mapping redundant). It is nil'd
        // here for safety to match pre-refactor SyncCoordinator.teardown().
        savedLocations.onFavoritesChanged = nil
    }

    deinit {
        // detach() is @MainActor. SyncCoordinator (@MainActor) always calls
        // detach() explicitly before releasing this tracker, so by deinit time
        // all callbacks are already nil. assumeIsolated asserts the invariant.
        MainActor.assumeIsolated { detach() }
    }

    // MARK: - Private

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
        rideHistory.onRidesChanged = { [weak store] in
            store?.markDirty(.rideHistory)
        }
        savedLocations.onChange = { [weak store] in
            store?.markDirty(.profileBackup)
        }
    }
}
