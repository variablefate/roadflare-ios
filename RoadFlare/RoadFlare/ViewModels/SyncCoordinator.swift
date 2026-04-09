import Foundation
import os
import RidestrSDK

/// Progress updates from startup sync, consumed by AppState for UI.
enum SyncProgress {
    case status(String)
    case profileRestored(nameFound: Bool)
    case driversRestored(count: Int)
    case locationsRestored(count: Int)
}

/// Owns Nostr sync orchestration: startup resolution, callback wiring, and
/// teardown. Publish wrappers and state machines live in the SDK (see
/// `ProfileBackupCoordinator` and `RoadflareDomainService.publishXAndMark`
/// helpers). This class is pure wiring between AppState-owned state and
/// SDK-provided sync primitives.
@MainActor
final class SyncCoordinator {
    // MARK: - Owned State

    private(set) var roadflareSyncStore: RoadflareSyncStateStore?
    private(set) var roadflareDomainService: RoadflareDomainService?
    private(set) var profileBackupCoordinator: ProfileBackupCoordinator?

    // MARK: - Injected References (owned by AppState)

    private let settings: UserSettingsRepository
    private let savedLocations: SavedLocationsRepository
    private let rideHistory: RideHistoryRepository

    // Weak ref for callback teardown
    private weak var trackedDriversRepo: FollowedDriversRepository?

    // MARK: - Init

    init(settings: UserSettingsRepository, savedLocations: SavedLocationsRepository,
         rideHistory: RideHistoryRepository) {
        self.settings = settings
        self.savedLocations = savedLocations
        self.rideHistory = rideHistory
    }

    /// Set owned services after relay connection is established.
    func configure(syncStore: RoadflareSyncStateStore, domainService: RoadflareDomainService) {
        self.roadflareSyncStore = syncStore
        self.roadflareDomainService = domainService
        self.profileBackupCoordinator = ProfileBackupCoordinator(
            domainService: domainService, syncStore: syncStore
        )
    }

    /// Forward markDirty for AppState methods that need it (completeProfileSetup, etc.)
    func markDirty(_ domain: RoadflareSyncDomain) {
        roadflareSyncStore?.markDirty(domain)
    }

    // MARK: - Tracking Callbacks

    /// Wire ALL change-tracking callbacks: settings + repositories.
    /// MUST be called after configure() so roadflareSyncStore is set.
    func wireTrackingCallbacks(driversRepo: FollowedDriversRepository) {
        let store = roadflareSyncStore
        trackedDriversRepo = driversRepo

        settings.onProfileChanged = { store?.markDirty(.profile) }
        settings.onProfileBackupChanged = { store?.markDirty(.profileBackup) }

        driversRepo.onDriversChanged = { source in
            guard source == .local else { return }
            store?.markDirty(.followedDrivers)
        }
        rideHistory.onRidesChanged = { store?.markDirty(.rideHistory) }
        savedLocations.onChange = { store?.markDirty(.profileBackup) }
    }

    // MARK: - Teardown

    /// Detach ALL callbacks, clear sync state, and release the profile backup
    /// coordinator. Called during identity replacement. MUST be called BEFORE
    /// any clearAll() calls on repositories to prevent stale callbacks from
    /// writing dirty flags.
    func teardown(clearPersistedState: Bool) {
        settings.onProfileChanged = nil
        settings.onProfileBackupChanged = nil
        trackedDriversRepo?.onDriversChanged = nil
        rideHistory.onRidesChanged = nil
        savedLocations.onChange = nil
        savedLocations.onFavoritesChanged = nil

        profileBackupCoordinator?.clearAll()
        profileBackupCoordinator = nil

        if clearPersistedState {
            roadflareSyncStore?.clearAll()
        }
        roadflareSyncStore = nil
        roadflareDomainService = nil
    }

    // MARK: - Startup Sync

    /// Orchestrate startup sync across all 4 domains using SyncDomainResolver.
    /// - Parameters:
    ///   - repo: The followed drivers repository (created by AppState during setup).
    ///   - importFlow: Whether to report progress for the sync UI screen.
    ///   - onProgress: Callback for UI state updates (maps to AppState's sync properties).
    func performStartupSync(
        repo: FollowedDriversRepository,
        importFlow: Bool,
        onProgress: (@MainActor (SyncProgress) -> Void)? = nil
    ) async {
        guard let service = roadflareDomainService,
              let syncStore = roadflareSyncStore,
              let backupCoordinator = profileBackupCoordinator else { return }

        let remote = await service.fetchStartupRemoteState()

        // Strategy captures (non-isolated Sendable closures wrap @MainActor state)
        let settings = self.settings
        let savedLocations = self.savedLocations
        let rideHistory = self.rideHistory

        // Profile (Kind 0)
        let profileStrategy = SyncDomainStrategy<UserProfileContent>(
            domain: .profile,
            hasLocalState: { @Sendable in
                await MainActor.run { !settings.profileName.isEmpty }
            },
            applyRemote: { @Sendable value in
                await MainActor.run {
                    let name = value.displayName ?? value.name ?? ""
                    settings.performWithoutChangeTracking {
                        _ = settings.setProfileName(name)
                    }
                    if !name.isEmpty {
                        AppLogger.auth.info("Restored profile name from Nostr: \(name)")
                    }
                }
            },
            undecodableWarning: "Latest profile metadata is not decodable; preserving local profile state",
            publishLocal: { @Sendable in
                await service.publishProfileAndMark(from: settings, syncStore: syncStore)
            }
        )

        if importFlow { onProgress?(.status("Restoring your profile...")) }
        await SyncDomainResolver.apply(strategy: profileStrategy, remote: remote.profile, syncStore: syncStore)
        if importFlow { onProgress?(.profileRestored(nameFound: !settings.profileName.isEmpty)) }

        // Followed Drivers (Kind 30011)
        let driversStrategy = SyncDomainStrategy<FollowedDriversContent>(
            domain: .followedDrivers,
            hasLocalState: { @Sendable [weak repo] in
                await MainActor.run { repo?.hasDrivers ?? false }
            },
            applyRemote: { @Sendable [weak repo] value in
                await MainActor.run {
                    repo?.restoreFromNostr(content: value)
                    if !value.drivers.isEmpty {
                        AppLogger.auth.info("Restored \(value.drivers.count) drivers from Nostr")
                    }
                }
            },
            undecodableWarning: "Latest followed-drivers snapshot is not decodable; preserving local driver state",
            publishLocal: { @Sendable [weak repo] in
                guard let repo else { return }
                await service.publishFollowedDriversListAndMark(from: repo, syncStore: syncStore)
            }
        )

        if importFlow { onProgress?(.status("Restoring your drivers...")) }
        await SyncDomainResolver.apply(strategy: driversStrategy, remote: remote.followedDrivers, syncStore: syncStore)
        if importFlow { onProgress?(.driversRestored(count: repo.drivers.count)) }

        // Profile Backup (Kind 30177)
        let backupStrategy = SyncDomainStrategy<ProfileBackupContent>(
            domain: .profileBackup,
            hasLocalState: { @Sendable in
                await MainActor.run {
                    !settings.roadflarePaymentMethods.isEmpty || !savedLocations.locations.isEmpty
                }
            },
            applyRemote: { @Sendable value in
                await MainActor.run {
                    backupCoordinator.applyRemote(value, settings: settings, savedLocations: savedLocations)
                }
            },
            undecodableWarning: "Latest profile backup is not decodable; preserving local backup state",
            publishLocal: { @Sendable in
                await backupCoordinator.publishAndMark(settings: settings, savedLocations: savedLocations)
            },
            onSnapshotSeen: { @Sendable value in
                backupCoordinator.preserveSettingsTemplate(value.settings)
            }
        )

        if importFlow { onProgress?(.status("Restoring settings...")) }
        await SyncDomainResolver.apply(strategy: backupStrategy, remote: remote.profileBackup, syncStore: syncStore)
        if importFlow { onProgress?(.locationsRestored(count: savedLocations.locations.count)) }

        // Ride History (Kind 30174)
        let historyStrategy = SyncDomainStrategy<RideHistoryBackupContent>(
            domain: .rideHistory,
            hasLocalState: { @Sendable in
                await MainActor.run { !rideHistory.rides.isEmpty }
            },
            applyRemote: { @Sendable value in
                await MainActor.run {
                    rideHistory.restoreFromBackup(value.rides)
                    if !value.rides.isEmpty {
                        AppLogger.auth.info("Restored \(value.rides.count) ride(s) from Nostr")
                    }
                }
            },
            undecodableWarning: "Latest ride history backup is not decodable; preserving local history state",
            publishLocal: { @Sendable in
                await service.publishRideHistoryAndMark(from: rideHistory, syncStore: syncStore)
            },
            shouldPublishGuard: { @Sendable in
                await MainActor.run { !rideHistory.rides.isEmpty }
            }
        )

        if importFlow { onProgress?(.status("Restoring ride history...")) }
        await SyncDomainResolver.apply(strategy: historyStrategy, remote: remote.rideHistory, syncStore: syncStore)

        if importFlow { onProgress?(.status("Loading driver info...")) }
        let driverProfiles = await service.fetchDriverProfiles(pubkeys: repo.allPubkeys)
        for (pubkey, snapshot) in driverProfiles {
            repo.cacheDriverProfile(pubkey: pubkey, profile: snapshot.value)
        }
        if !driverProfiles.isEmpty {
            AppLogger.auth.info("Fetched profiles for \(driverProfiles.count) driver(s)")
        }

        if importFlow {
            onProgress?(.status("Done!"))
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Flush on Reconnect

    /// Publish any dirty sync domains. Caller must verify relay connectivity first.
    func flushPendingSyncPublishes(rideCoordinator: RideCoordinator?) async {
        guard let syncStore = roadflareSyncStore,
              let service = roadflareDomainService,
              let backupCoordinator = profileBackupCoordinator else { return }

        if syncStore.metadata(for: .profile).isDirty {
            await service.publishProfileAndMark(from: settings, syncStore: syncStore)
        }
        if syncStore.metadata(for: .followedDrivers).isDirty {
            await rideCoordinator?.publishFollowedDriversList()
        }
        if syncStore.metadata(for: .profileBackup).isDirty {
            await backupCoordinator.publishAndMark(settings: settings, savedLocations: savedLocations)
        }
        if syncStore.metadata(for: .rideHistory).isDirty {
            await service.publishRideHistoryAndMark(from: rideHistory, syncStore: syncStore)
        }
    }
}
