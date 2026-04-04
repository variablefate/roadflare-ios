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

/// Owns Nostr sync orchestration: startup resolution, publish methods,
/// dirty tracking callbacks, and flush-on-reconnect.
///
/// AppState creates and holds this privately. Views never access it directly.
/// All sync-related state (roadflareSyncStore, publish flags, backup template)
/// lives here instead of on AppState, reducing AppState's responsibility surface.
@MainActor
final class SyncCoordinator {
    // MARK: - Owned State

    private(set) var roadflareSyncStore: RoadflareSyncStateStore?
    private(set) var roadflareDomainService: RoadflareDomainService?
    private var isPublishingProfileBackup = false
    private var profileBackupRepublishRequested = false
    private var profileBackupSettingsTemplate = SettingsBackupContent()

    // MARK: - Injected References (owned by AppState)

    private let settings: UserSettings
    private let savedLocations: SavedLocationsRepository
    private let rideHistory: RideHistoryRepository

    // Weak ref for callback teardown
    private weak var trackedDriversRepo: FollowedDriversRepository?

    // MARK: - Init

    init(settings: UserSettings, savedLocations: SavedLocationsRepository,
         rideHistory: RideHistoryRepository) {
        self.settings = settings
        self.savedLocations = savedLocations
        self.rideHistory = rideHistory
    }

    /// Set owned services after relay connection is established.
    func configure(syncStore: RoadflareSyncStateStore, domainService: RoadflareDomainService) {
        self.roadflareSyncStore = syncStore
        self.roadflareDomainService = domainService
    }

    /// Forward markDirty for AppState methods that need it (completeProfileSetup, etc.)
    func markDirty(_ domain: RoadflareSyncDomain) {
        roadflareSyncStore?.markDirty(domain)
    }

    // MARK: - Tracking Callbacks

    /// Wire ALL change-tracking callbacks: settings + repositories.
    /// Replaces: configureDriversRepositoryTracking, configureRideHistoryTracking,
    ///           configureSavedLocationsTracking, and settings callbacks from AppState.init().
    /// MUST be called after configure() so roadflareSyncStore is set.
    func wireTrackingCallbacks(driversRepo: FollowedDriversRepository) {
        let store = roadflareSyncStore
        trackedDriversRepo = driversRepo

        // Settings callbacks (previously in AppState.init — safe to move since
        // they no-op before setup via optional chaining anyway)
        settings.onProfileChanged = { store?.markDirty(.profile) }
        settings.onProfileBackupChanged = { store?.markDirty(.profileBackup) }

        // Repository callbacks
        driversRepo.onDriversChanged = { source in
            guard source == .local else { return }
            store?.markDirty(.followedDrivers)
        }
        rideHistory.onRidesChanged = { store?.markDirty(.rideHistory) }
        savedLocations.onChange = { store?.markDirty(.profileBackup) }
    }

    // MARK: - Teardown

    /// Detach ALL callbacks and clear sync state. Called during identity replacement.
    /// MUST be called BEFORE any clearAll() calls on repositories to prevent
    /// stale callbacks from writing dirty flags.
    func teardown(clearPersistedState: Bool) {
        // Detach all callbacks first
        settings.onProfileChanged = nil
        settings.onProfileBackupChanged = nil
        trackedDriversRepo?.onDriversChanged = nil
        rideHistory.onRidesChanged = nil
        savedLocations.onChange = nil
        savedLocations.onFavoritesChanged = nil

        // Clear sync store
        if clearPersistedState {
            roadflareSyncStore?.clearAll()
        }
        roadflareSyncStore = nil
        roadflareDomainService = nil
        profileBackupSettingsTemplate = SettingsBackupContent()
    }

    // MARK: - Startup Sync

    /// Orchestrate startup sync across all 4 domains.
    /// - Parameters:
    ///   - repo: The followed drivers repository (created by AppState during setup).
    ///   - importFlow: Whether to report progress for the sync UI screen.
    ///   - onProgress: Callback for UI state updates (maps to AppState's sync properties).
    func performStartupSync(
        repo: FollowedDriversRepository,
        importFlow: Bool,
        onProgress: (@MainActor (SyncProgress) -> Void)? = nil
    ) async {
        guard let service = roadflareDomainService else { return }

        let remote = await service.fetchStartupRemoteState()

        if importFlow { onProgress?(.status("Restoring your profile...")) }
        await applyProfileResolution(remote: remote.profile)
        if importFlow { onProgress?(.profileRestored(nameFound: !settings.profileName.isEmpty)) }

        if importFlow { onProgress?(.status("Restoring your drivers...")) }
        await applyFollowedDriversResolution(repo: repo, remote: remote.followedDrivers)
        if importFlow { onProgress?(.driversRestored(count: repo.drivers.count)) }

        if importFlow { onProgress?(.status("Restoring settings...")) }
        await applyProfileBackupResolution(remote: remote.profileBackup)
        if importFlow { onProgress?(.locationsRestored(count: savedLocations.locations.count)) }

        if importFlow { onProgress?(.status("Restoring ride history...")) }
        await applyRideHistoryResolution(remote: remote.rideHistory)

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

    // MARK: - Publish Methods

    /// Publish Kind 0 metadata to Nostr.
    func publishProfile() async {
        guard let service = roadflareDomainService else { return }
        let profile = UserProfileContent(
            name: settings.profileName,
            displayName: settings.profileName
        )
        do {
            let event = try await service.publishProfile(profile)
            roadflareSyncStore?.markPublished(.profile, at: event.createdAt)
            AppLogger.auth.info("Published profile to Nostr")
        } catch {
            AppLogger.auth.info("Failed to publish profile: \(error)")
        }
    }

    /// Publish Kind 30177 encrypted profile backup (settings + saved locations) to Nostr.
    func publishProfileBackup() async {
        guard let service = roadflareDomainService else { return }
        if isPublishingProfileBackup {
            profileBackupRepublishRequested = true
            return
        }

        isPublishingProfileBackup = true
        defer { isPublishingProfileBackup = false }

        repeat {
            profileBackupRepublishRequested = false
            let backup = buildProfileBackupContent()
            do {
                let event = try await service.publishProfileBackup(backup)
                roadflareSyncStore?.markPublished(.profileBackup, at: event.createdAt)
                AppLogger.auth.info("Published profile backup to Nostr")
            } catch {
                AppLogger.auth.info("Failed to publish profile backup: \(error)")
            }
        } while profileBackupRepublishRequested
    }

    /// Publish both Kind 0 and Kind 30177.
    func saveAndPublishSettings() async {
        await publishProfile()
        await publishProfileBackup()
    }

    func buildProfileBackupContent() -> ProfileBackupContent {
        var settingsBackup = profileBackupSettingsTemplate
        settingsBackup.roadflarePaymentMethods = settings.roadflarePaymentMethods

        return ProfileBackupContent(
            savedLocations: savedLocations.locations.map { loc in
                SavedLocationBackup(
                    displayName: loc.displayName, lat: loc.latitude, lon: loc.longitude,
                    addressLine: loc.addressLine,
                    isPinned: loc.isPinned,
                    nickname: loc.nickname,
                    timestampMs: loc.timestampMs
                )
            },
            settings: settingsBackup
        )
    }

    func preserveProfileBackupSettingsTemplate(_ settings: SettingsBackupContent) {
        profileBackupSettingsTemplate = settings
    }

    // MARK: - Flush on Reconnect

    /// Publish any dirty sync domains. Caller must verify relay connectivity first.
    func flushPendingSyncPublishes(rideCoordinator: RideCoordinator?) async {
        guard let syncStore = roadflareSyncStore else { return }

        if syncStore.metadata(for: .profile).isDirty {
            await publishProfile()
        }
        if syncStore.metadata(for: .followedDrivers).isDirty {
            await rideCoordinator?.publishFollowedDriversList()
        }
        if syncStore.metadata(for: .profileBackup).isDirty {
            await publishProfileBackup()
        }
        if syncStore.metadata(for: .rideHistory).isDirty, !rideHistory.rides.isEmpty {
            do {
                let content = RideHistoryBackupContent(rides: rideHistory.rides)
                if let service = roadflareDomainService {
                    let event = try await service.publishRideHistoryBackup(content)
                    syncStore.markPublished(.rideHistory, at: event.createdAt)
                }
            } catch {
                // Will retry on next reconnect
            }
        }
    }

    // MARK: - Resolution Methods

    private func applyProfileResolution(
        remote: RoadflareDomainService.StartupRemoteDomain<UserProfileContent>
    ) async {
        guard let syncStore = roadflareSyncStore else { return }
        let metadata = syncStore.metadata(for: .profile)
        let resolution = RoadflareDomainService.resolve(
            domain: .profile, metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt
        )
        let shouldSeedLegacyLocal = RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: metadata, remoteCreatedAt: remote.latestSeenCreatedAt,
            hasLocalState: !settings.profileName.isEmpty
        )

        if resolution.source == .remote,
           let snapshot = remote.snapshot,
           snapshot.createdAt == remote.latestSeenCreatedAt {
            let name = snapshot.value.displayName ?? snapshot.value.name ?? ""
            settings.performWithoutChangeTracking {
                settings.profileName = name
            }
            if !name.isEmpty {
                AppLogger.auth.info("Restored profile name from Nostr: \(name)")
            }
            syncStore.markPublished(.profile, at: snapshot.createdAt)
        } else if resolution.source == .remote, remote.latestSeenCreatedAt != nil {
            AppLogger.auth.warning("Latest profile metadata is not decodable; preserving local profile state")
        } else if resolution.shouldPublishLocal || shouldSeedLegacyLocal {
            if shouldSeedLegacyLocal { syncStore.markDirty(.profile) }
            await publishProfile()
        }
    }

    private func applyFollowedDriversResolution(
        repo: FollowedDriversRepository,
        remote: RoadflareDomainService.StartupRemoteDomain<FollowedDriversContent>
    ) async {
        guard let service = roadflareDomainService else { return }
        guard let syncStore = roadflareSyncStore else { return }
        let metadata = syncStore.metadata(for: .followedDrivers)
        let resolution = RoadflareDomainService.resolve(
            domain: .followedDrivers, metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt
        )
        let shouldSeedLegacyLocal = RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: metadata, remoteCreatedAt: remote.latestSeenCreatedAt,
            hasLocalState: repo.hasDrivers
        )

        if resolution.source == .remote,
           let snapshot = remote.snapshot,
           snapshot.createdAt == remote.latestSeenCreatedAt {
            repo.restoreFromNostr(content: snapshot.value)
            syncStore.markPublished(.followedDrivers, at: snapshot.createdAt)
            if !snapshot.value.drivers.isEmpty {
                AppLogger.auth.info("Restored \(snapshot.value.drivers.count) drivers from Nostr")
            }
        } else if resolution.source == .remote, remote.latestSeenCreatedAt != nil {
            AppLogger.auth.warning("Latest followed-drivers snapshot is not decodable; preserving local driver state")
        } else if resolution.shouldPublishLocal || shouldSeedLegacyLocal {
            if shouldSeedLegacyLocal { syncStore.markDirty(.followedDrivers) }
            do {
                let event = try await service.publishFollowedDriversList(repo.drivers)
                syncStore.markPublished(.followedDrivers, at: event.createdAt)
                AppLogger.auth.info("Published followed drivers list to Nostr")
            } catch {
                AppLogger.auth.info("Failed to publish followed drivers list: \(error)")
            }
        }
    }

    private func applyProfileBackupResolution(
        remote: RoadflareDomainService.StartupRemoteDomain<ProfileBackupContent>
    ) async {
        guard roadflareDomainService != nil else { return }
        guard let syncStore = roadflareSyncStore else { return }
        if let snapshot = remote.snapshot {
            preserveProfileBackupSettingsTemplate(snapshot.value.settings)
        }
        let metadata = syncStore.metadata(for: .profileBackup)
        let resolution = RoadflareDomainService.resolve(
            domain: .profileBackup, metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt
        )
        let shouldSeedLegacyLocal = RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: metadata, remoteCreatedAt: remote.latestSeenCreatedAt,
            hasLocalState: !settings.roadflarePaymentMethods.isEmpty
                || !savedLocations.locations.isEmpty
        )

        if resolution.source == .remote,
           let snapshot = remote.snapshot,
           snapshot.createdAt == remote.latestSeenCreatedAt {
            applyRemoteProfileBackup(snapshot.value)
            syncStore.markPublished(.profileBackup, at: snapshot.createdAt)
        } else if resolution.source == .remote, remote.latestSeenCreatedAt != nil {
            AppLogger.auth.warning("Latest profile backup is not decodable; preserving local backup state")
        } else if resolution.shouldPublishLocal || shouldSeedLegacyLocal {
            if shouldSeedLegacyLocal { syncStore.markDirty(.profileBackup) }
            await publishProfileBackup()
        }
    }

    private func applyRemoteProfileBackup(_ backup: ProfileBackupContent) {
        preserveProfileBackupSettingsTemplate(backup.settings)
        settings.performWithoutChangeTracking {
            settings.setRoadflarePaymentMethods(backup.settings.roadflarePaymentMethods)
        }

        savedLocations.restoreFromBackup(backup.savedLocations.map { loc in
            SavedLocation(
                latitude: loc.lat,
                longitude: loc.lon,
                displayName: loc.displayName,
                addressLine: loc.addressLine ?? loc.displayName,
                isPinned: loc.isPinned,
                nickname: loc.nickname,
                timestampMs: loc.timestampMs ?? Int(Date.now.timeIntervalSince1970 * 1000)
            )
        })

        if !backup.savedLocations.isEmpty {
            AppLogger.auth.info("Restored \(backup.savedLocations.count) saved locations")
        }
    }

    private func applyRideHistoryResolution(
        remote: RoadflareDomainService.StartupRemoteDomain<RideHistoryBackupContent>
    ) async {
        guard let service = roadflareDomainService else { return }
        guard let syncStore = roadflareSyncStore else { return }
        let metadata = syncStore.metadata(for: .rideHistory)
        let resolution = RoadflareDomainService.resolve(
            domain: .rideHistory, metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt
        )
        let shouldSeedLegacyLocal = RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: metadata, remoteCreatedAt: remote.latestSeenCreatedAt,
            hasLocalState: !rideHistory.rides.isEmpty
        )

        if resolution.source == .remote,
           let snapshot = remote.snapshot,
           snapshot.createdAt == remote.latestSeenCreatedAt {
            rideHistory.restoreFromBackup(snapshot.value.rides)
            syncStore.markPublished(.rideHistory, at: snapshot.createdAt)
            if !snapshot.value.rides.isEmpty {
                AppLogger.auth.info("Restored \(snapshot.value.rides.count) ride(s) from Nostr")
            }
        } else if (resolution.shouldPublishLocal || shouldSeedLegacyLocal), !rideHistory.rides.isEmpty {
            if shouldSeedLegacyLocal { syncStore.markDirty(.rideHistory) }
            do {
                let content = RideHistoryBackupContent(rides: rideHistory.rides)
                let event = try await service.publishRideHistoryBackup(content)
                syncStore.markPublished(.rideHistory, at: event.createdAt)
                AppLogger.auth.info("Published ride history backup to Nostr")
            } catch {
                AppLogger.auth.info("Failed to publish ride history backup: \(error)")
            }
        }
    }
}
