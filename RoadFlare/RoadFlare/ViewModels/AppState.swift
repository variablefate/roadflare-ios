import SwiftUI
import os
import RidestrSDK

/// App-level authentication state.
enum AuthState {
    case loading
    case loggedOut
    case syncing  // Restoring data from Nostr after key import
    case profileIncomplete
    case paymentSetup
    case ready
}

/// Central app state coordinator. Owns SDK services and manages auth lifecycle.
@Observable
@MainActor
final class AppState {
    private static let connectionWatchdogInterval: Duration = .seconds(10)

    // MARK: - Auth

    var authState: AuthState = .loading

    // MARK: - Navigation

    /// Set by DriverDetailSheet to navigate to ride tab with driver pre-selected.
    var requestRideDriverPubkey: String?
    /// Set to switch tabs programmatically.
    var selectedTab: Int = 0

    // MARK: - SDK Services

    private(set) var keyManager: KeyManager?
    private(set) var relayManager: RelayManager?
    private(set) var roadflareDomainService: RoadflareDomainService?
    private(set) var driversRepository: FollowedDriversRepository?
    private(set) var rideCoordinator: RideCoordinator?
    private(set) var fareCalculator: FareCalculator?
    private(set) var remoteConfigManager: RemoteConfigManager?
    let rideHistory = RideHistoryRepository(persistence: UserDefaultsRideHistoryPersistence())
    let savedLocations = SavedLocationsRepository(persistence: UserDefaultsSavedLocationsPersistence())
    let bitcoinPrice = BitcoinPriceService()

    // MARK: - User State

    private(set) var keypair: NostrKeypair?
    let settings = UserSettings()

    // MARK: - Sync State (for import flow UI)

    var syncStatus: String = ""
    var syncRestoredDrivers: Int = 0
    var syncRestoredLocations: Int = 0
    var syncRestoredName: Bool = false

    // MARK: - Storage

    private let keychainStorage = KeychainStorage(service: "com.roadflare.keys")
    private let driversPersistence = UserDefaultsDriversPersistence()
    private var roadflareSyncStore: RoadflareSyncStateStore?
    private var connectionWatchdogTask: Task<Void, Never>?
    private var isAutoReconnecting = false
    private var isPublishingProfileBackup = false
    private var profileBackupRepublishRequested = false
    private var profileBackupSettingsTemplate = SettingsBackupContent()

    // MARK: - Init

    init() {
        settings.onProfileChanged = { [weak self] in
            self?.roadflareSyncStore?.markDirty(.profile)
        }
        settings.onProfileBackupChanged = { [weak self] in
            self?.roadflareSyncStore?.markDirty(.profileBackup)
        }
        savedLocations.onChange = { [weak self] in
            self?.roadflareSyncStore?.markDirty(.profileBackup)
        }
    }

    private static let hasLaunchedKey = "roadflare_has_launched"

    /// Initialize on app launch. Checks for existing keys.
    /// Handles Keychain persistence across reinstalls by checking UserDefaults.
    func initialize() async {
        let km = KeyManager(storage: keychainStorage)
        self.keyManager = km

        // Keychain survives app deletion but UserDefaults don't.
        // If UserDefaults are empty but Keychain has a key, this is a reinstall — clear stale key.
        if !UserDefaults.standard.bool(forKey: Self.hasLaunchedKey) {
            try? await km.deleteKeys()
            UserDefaults.standard.set(true, forKey: Self.hasLaunchedKey)
        }

        if let kp = await km.getKeypair() {
            keypair = kp
            await setupServices(keypair: kp)
            authState = resolveLocalAuthState()
        } else {
            authState = .loggedOut
        }
    }

    // MARK: - Auth Actions

    /// Generate a new keypair.
    func generateNewKey() async throws {
        guard let km = keyManager else { return }
        let kp = try await km.generate()
        await prepareForIdentityReplacement(clearPersistedSyncState: false)
        keypair = kp
        await setupServices(keypair: kp)
        authState = .profileIncomplete
    }

    /// Import an existing key from nsec or hex. Shows sync screen during restore.
    func importKey(_ input: String) async throws {
        guard let km = keyManager else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let kp: NostrKeypair
        if trimmed.hasPrefix("nsec1") {
            kp = try await km.importNsec(trimmed)
        } else {
            kp = try await km.importHex(trimmed)
        }
        await prepareForIdentityReplacement(clearPersistedSyncState: false)
        keypair = kp

        // Show sync screen
        syncRestoredDrivers = 0
        syncRestoredLocations = 0
        syncRestoredName = false
        authState = .syncing

        await setupServicesWithSync(keypair: kp)

        // Navigate based on what was restored
        if settings.profileName.isEmpty {
            // No name → go to profile setup
            authState = .profileIncomplete
        } else if settings.roadflarePaymentMethods.isEmpty {
            // Have name but no payment methods → go to payment setup
            authState = .paymentSetup
        } else {
            // Have both → fully ready
            settings.profileCompleted = true
            authState = .ready
        }
    }

    /// Mark profile name as set, publish Kind 0 to Nostr, move to payment setup.
    /// Does NOT publish Kind 30177 yet — payment methods aren't set until next step.
    func completeProfileSetup(name: String) async {
        settings.profileName = name
        roadflareSyncStore?.markDirty(.profile)
        await publishProfile()
        authState = .paymentSetup
    }

    /// Mark payment setup as done, finish onboarding. Publishes profile + settings backup.
    func completePaymentSetup() async {
        settings.profileCompleted = true
        roadflareSyncStore?.markDirty(.profileBackup)
        await saveAndPublishSettings()
        authState = .ready
    }

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

    /// Publish both Kind 0 (public profile) and Kind 30177 (encrypted backup) to Nostr.
    func saveAndPublishSettings() async {
        await publishProfile()
        await publishProfileBackup()
    }

    /// Try to restore a specific driver's key from our Kind 30011 backup on the relay.
    /// Used during mid-session re-add when the key was lost locally but exists in the backup.
    func restoreKeyFromBackup(driverPubkey: String) async {
        guard let service = roadflareDomainService,
              let repo = driversRepository else { return }
        let remote = await service.fetchLatestFollowedDriversState()
        guard let snapshot = remote.snapshot else { return }

        if let latestSeenCreatedAt = remote.latestSeenCreatedAt,
           snapshot.createdAt != latestSeenCreatedAt {
            AppLogger.auth.warning(
                "Skipping key restore for \(driverPubkey.prefix(8)) because the latest followed-drivers backup is not decodable"
            )
            return
        }

        if let entry = snapshot.value.drivers.first(where: { $0.pubkey == driverPubkey }),
           let key = entry.roadflareKey {
            _ = repo.updateDriverKey(
                driverPubkey: driverPubkey,
                roadflareKey: key,
                source: .sync
            )
            rideCoordinator?.startLocationSubscriptions()
            AppLogger.auth.info("Restored key for \(driverPubkey.prefix(8)) from Kind 30011 backup")
        }
    }

    /// Send Kind 3187 follow notification to a driver (real-time nudge).
    /// The rider's Kind 30011 p-tags are the source of truth — this is just a push notification.
    func sendFollowNotification(driverPubkey: String) async {
        guard let kp = keypair, let rm = relayManager,
              !settings.profileName.isEmpty else { return }
        do {
            let event = try await RideshareEventBuilder.followNotification(
                driverPubkey: driverPubkey,
                riderName: settings.profileName,
                keypair: kp
            )
            _ = try await rm.publish(event)
            AppLogger.auth.info("Sent follow notification to \(driverPubkey.prefix(8))")
        } catch {
            // Non-fatal — Kind 30011 p-tags are the real source of truth
        }
    }

    /// Called when app returns to foreground. Reconnects relays and restarts subscriptions if needed.
    func handleForeground() async {
        guard authState == .ready else { return }
        await reconnectAndRestoreSession()
    }

    func resolveLocalAuthState() -> AuthState {
        if settings.profileName.isEmpty {
            return .profileIncomplete
        }
        if settings.roadflarePaymentMethods.isEmpty {
            return .paymentSetup
        }
        return settings.profileCompleted ? .ready : .paymentSetup
    }

    /// Log out: clear all data.
    func logout() async {
        await prepareForIdentityReplacement(clearPersistedSyncState: true)
        try? await keyManager?.deleteKeys()
        keypair = nil
        authState = .loggedOut
    }

    // MARK: - Private

    /// Fetch, resolve, and apply RoadFlare startup state using SDK-owned helpers.
    private func performStartupSync(repo: FollowedDriversRepository, importFlow: Bool) async {
        guard let service = roadflareDomainService else { return }

        let remote = await service.fetchStartupRemoteState()

        if importFlow { syncStatus = "Restoring your profile..." }
        await applyProfileResolution(remote: remote.profile)
        if importFlow { syncRestoredName = !settings.profileName.isEmpty }

        if importFlow { syncStatus = "Restoring your drivers..." }
        await applyFollowedDriversResolution(repo: repo, remote: remote.followedDrivers)
        if importFlow { syncRestoredDrivers = repo.drivers.count }

        if importFlow { syncStatus = "Restoring settings..." }
        await applyProfileBackupResolution(remote: remote.profileBackup)
        if importFlow { syncRestoredLocations = savedLocations.locations.count }

        if importFlow { syncStatus = "Restoring ride history..." }
        await applyRideHistoryResolution(remote: remote.rideHistory)

        if importFlow { syncStatus = "Loading driver info..." }
        let driverProfiles = await service.fetchDriverProfiles(pubkeys: repo.allPubkeys)
        for (pubkey, snapshot) in driverProfiles {
            repo.cacheDriverProfile(pubkey: pubkey, profile: snapshot.value)
        }
        if !driverProfiles.isEmpty {
            AppLogger.auth.info("Fetched profiles for \(driverProfiles.count) driver(s)")
        }

        if importFlow {
            syncStatus = "Done!"
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func applyProfileResolution(
        remote: RoadflareDomainService.StartupRemoteDomain<UserProfileContent>
    ) async {
        guard let syncStore = roadflareSyncStore else { return }
        let metadata = syncStore.metadata(for: .profile)
        let resolution = RoadflareDomainService.resolve(
            domain: .profile,
            metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt
        )
        let shouldSeedLegacyLocal = RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt,
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
            if shouldSeedLegacyLocal {
                syncStore.markDirty(.profile)
            }
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
            domain: .followedDrivers,
            metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt
        )
        let shouldSeedLegacyLocal = RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt,
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
            if shouldSeedLegacyLocal {
                syncStore.markDirty(.followedDrivers)
            }
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
            domain: .profileBackup,
            metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt
        )
        let shouldSeedLegacyLocal = RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt,
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
            if shouldSeedLegacyLocal {
                syncStore.markDirty(.profileBackup)
            }
            await publishProfileBackup()
        }
    }

    private func applyRemoteProfileBackup(_ backup: ProfileBackupContent) {
        preserveProfileBackupSettingsTemplate(backup.settings)
        settings.performWithoutChangeTracking {
            settings.setRoadflarePaymentMethods(backup.settings.roadflarePaymentMethods)
        }

        savedLocations.performWithoutChangeTracking {
            let currentLocations = savedLocations.locations
            for location in currentLocations {
                savedLocations.remove(id: location.id)
            }

            for loc in backup.savedLocations {
                savedLocations.save(SavedLocation(
                    id: UUID().uuidString,
                    latitude: loc.lat,
                    longitude: loc.lon,
                    displayName: loc.displayName,
                    addressLine: loc.addressLine ?? loc.displayName,
                    isPinned: loc.isPinned,
                    nickname: loc.nickname,
                    timestampMs: loc.timestampMs ?? Int(Date.now.timeIntervalSince1970 * 1000)
                ))
            }
        }

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
            domain: .rideHistory,
            metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt
        )
        let shouldSeedLegacyLocal = RoadflareDomainService.shouldSeedLegacyLocalState(
            metadata: metadata,
            remoteCreatedAt: remote.latestSeenCreatedAt,
            hasLocalState: !rideHistory.rides.isEmpty
        )

        if resolution.source == .remote,
           let snapshot = remote.snapshot,
           snapshot.createdAt == remote.latestSeenCreatedAt {
            // Remote is authoritative — full replace (matches other domain patterns)
            rideHistory.restoreFromBackup(snapshot.value.rides)
            syncStore.markPublished(.rideHistory, at: snapshot.createdAt)
            if !snapshot.value.rides.isEmpty {
                AppLogger.auth.info("Restored \(snapshot.value.rides.count) ride(s) from Nostr")
            }
        } else if (resolution.shouldPublishLocal || shouldSeedLegacyLocal), !rideHistory.rides.isEmpty {
            if shouldSeedLegacyLocal {
                syncStore.markDirty(.rideHistory)
            }
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

    /// Setup with sync status updates for the import flow UI.
    private func setupServicesWithSync(keypair: NostrKeypair) async {
        let rm = RelayManager(keypair: keypair)
        self.relayManager = rm
        let syncStore = RoadflareSyncStateStore(namespace: keypair.publicKeyHex)
        self.roadflareSyncStore = syncStore
        let repo = FollowedDriversRepository(persistence: driversPersistence)
        self.driversRepository = repo
        configureDriversRepositoryTracking(repo, syncStore: syncStore)
        configureRideHistoryTracking(syncStore: syncStore)
        let service = RoadflareDomainService(relayManager: rm, keypair: keypair)
        self.roadflareDomainService = service
        self.fareCalculator = FareCalculator()
        self.remoteConfigManager = RemoteConfigManager(relayManager: rm)
        bitcoinPrice.start()

        syncStatus = "Connecting to relays..."
        do {
            try await rm.connect(to: DefaultRelays.all)
        } catch {
            syncStatus = "Connection failed — continuing..."
            try? await Task.sleep(for: .seconds(1))
        }

        await performStartupSync(repo: repo, importFlow: true)

        let coordinator = RideCoordinator(
            relayManager: rm, keypair: keypair,
            driversRepository: repo, settings: settings,
            rideHistory: rideHistory, bitcoinPrice: bitcoinPrice,
            roadflareDomainService: service,
            roadflareSyncStore: syncStore
        )
        self.rideCoordinator = coordinator
        await coordinator.restoreLiveSubscriptions()
        restartConnectionWatchdog()
    }

    private func setupServices(keypair: NostrKeypair) async {
        let rm = RelayManager(keypair: keypair)
        self.relayManager = rm
        let syncStore = RoadflareSyncStateStore(namespace: keypair.publicKeyHex)
        self.roadflareSyncStore = syncStore
        let repo = FollowedDriversRepository(persistence: driversPersistence)
        self.driversRepository = repo
        configureDriversRepositoryTracking(repo, syncStore: syncStore)
        configureRideHistoryTracking(syncStore: syncStore)
        let service = RoadflareDomainService(relayManager: rm, keypair: keypair)
        self.roadflareDomainService = service
        self.fareCalculator = FareCalculator()
        self.remoteConfigManager = RemoteConfigManager(relayManager: rm)
        bitcoinPrice.start()

        do {
            AppLogger.auth.info(" Connecting to \(DefaultRelays.all.count) relays...")
            try await rm.connect(to: DefaultRelays.all)
            let connected = await rm.isConnected
            AppLogger.auth.info(" Relay connection: \(connected ? "SUCCESS" : "FAILED")")
        } catch {
            AppLogger.auth.info(" Relay connection FAILED: \(error)")
        }

        await performStartupSync(repo: repo, importFlow: false)

        let coordinator = RideCoordinator(
            relayManager: rm, keypair: keypair,
            driversRepository: repo, settings: settings,
            rideHistory: rideHistory, bitcoinPrice: bitcoinPrice,
            roadflareDomainService: service,
            roadflareSyncStore: syncStore
        )
        self.rideCoordinator = coordinator
        AppLogger.auth.info("Starting subscriptions... (\(repo.drivers.count) drivers loaded)")
        await coordinator.restoreLiveSubscriptions()
        restartConnectionWatchdog()
    }

    private func configureDriversRepositoryTracking(
        _ repo: FollowedDriversRepository,
        syncStore: RoadflareSyncStateStore?
    ) {
        repo.onDriversChanged = { source in
            guard source == .local else { return }
            syncStore?.markDirty(.followedDrivers)
        }
    }

    private func configureRideHistoryTracking(syncStore: RoadflareSyncStateStore?) {
        rideHistory.onRidesChanged = {
            syncStore?.markDirty(.rideHistory)
        }
    }

    func reconnectAndRestoreSession() async {
        guard let rm = relayManager else { return }
        await rm.reconnectIfNeeded()
        guard await rm.isConnected else { return }
        await flushPendingSyncPublishes()
        await rideCoordinator?.restoreLiveSubscriptions()
    }

    private func flushPendingSyncPublishes() async {
        guard let rm = relayManager,
              let syncStore = roadflareSyncStore,
              await rm.isConnected else { return }

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

    private func prepareForIdentityReplacement(clearPersistedSyncState: Bool) async {
        stopConnectionWatchdog()
        await rideCoordinator?.stopAll()
        await relayManager?.disconnect()

        let syncStore = roadflareSyncStore
        roadflareSyncStore = nil
        if clearPersistedSyncState {
            syncStore?.clearAll()
        }

        driversRepository?.onDriversChanged = nil
        driversRepository?.clearAll()
        if driversRepository == nil {
            driversPersistence.saveDrivers([])
            driversPersistence.saveDriverNames([:])
        }
        rideHistory.clearAll()
        savedLocations.clearAll()
        settings.clearAll()
        profileBackupSettingsTemplate = SettingsBackupContent()
        RideStatePersistence.clear()
        requestRideDriverPubkey = nil
        selectedTab = 0

        rideCoordinator = nil
        relayManager = nil
        roadflareDomainService = nil
        driversRepository = nil
        fareCalculator = nil
        remoteConfigManager = nil
        bitcoinPrice.stop()
    }

    private func restartConnectionWatchdog() {
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.connectionWatchdogInterval)
                guard let self else { return }
                await self.autoReconnectIfNeeded()
            }
        }
    }

    private func stopConnectionWatchdog() {
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        isAutoReconnecting = false
    }

    private func autoReconnectIfNeeded() async {
        guard authState == .ready,
              !isAutoReconnecting,
              let rm = relayManager,
              !(await rm.isConnected) else { return }

        isAutoReconnecting = true
        defer { isAutoReconnecting = false }
        await reconnectAndRestoreSession()
    }
}
