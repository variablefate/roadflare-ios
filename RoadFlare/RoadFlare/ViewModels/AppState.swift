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
///
/// Views access this via `@Environment(AppState.self)`. All sync orchestration
/// is delegated to `SyncCoordinator`; connection watchdog to `ConnectionCoordinator`.
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

    // MARK: - Private Coordinators & Storage

    private let keychainStorage = KeychainStorage(service: "com.roadflare.keys")
    private let driversPersistence = UserDefaultsDriversPersistence()
    private var syncCoordinator: SyncCoordinator?
    private let connectionCoordinator = ConnectionCoordinator()

    // MARK: - Init

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
            authState = .profileIncomplete
        } else if settings.roadflarePaymentMethods.isEmpty {
            authState = .paymentSetup
        } else {
            settings.profileCompleted = true
            authState = .ready
        }
    }

    /// Mark profile name as set, publish Kind 0 to Nostr, move to payment setup.
    func completeProfileSetup(name: String) async {
        settings.profileName = name
        syncCoordinator?.markDirty(.profile)
        await syncCoordinator?.publishProfile()
        authState = .paymentSetup
    }

    /// Mark payment setup as done, finish onboarding. Publishes profile + settings backup.
    func completePaymentSetup() async {
        settings.profileCompleted = true
        syncCoordinator?.markDirty(.profileBackup)
        await syncCoordinator?.saveAndPublishSettings()
        authState = .ready
    }

    // MARK: - Forwarding to SyncCoordinator

    func publishProfile() async { await syncCoordinator?.publishProfile() }
    func publishProfileBackup() async { await syncCoordinator?.publishProfileBackup() }
    func saveAndPublishSettings() async { await syncCoordinator?.saveAndPublishSettings() }

    func buildProfileBackupContent() -> ProfileBackupContent {
        syncCoordinator?.buildProfileBackupContent()
            ?? ProfileBackupContent(savedLocations: [], settings: SettingsBackupContent())
    }

    func preserveProfileBackupSettingsTemplate(_ s: SettingsBackupContent) {
        syncCoordinator?.preserveProfileBackupSettingsTemplate(s)
    }

    // MARK: - Driver Key Management

    /// Try to restore a specific driver's key from our Kind 30011 backup on the relay.
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

    // MARK: - Connection & Foreground

    /// Called when app returns to foreground. Reconnects relays and restarts subscriptions if needed.
    func handleForeground() async {
        guard authState == .ready else { return }
        await reconnectAndRestoreSession()
    }

    func reconnectAndRestoreSession() async {
        guard let rm = relayManager else { return }
        await rm.reconnectIfNeeded()
        guard await rm.isConnected else { return }
        await syncCoordinator?.flushPendingSyncPublishes(rideCoordinator: rideCoordinator)
        await rideCoordinator?.restoreLiveSubscriptions()
    }

    // MARK: - Auth Helpers

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

    // MARK: - Service Setup

    /// Setup with sync status updates for the import flow UI.
    private func setupServicesWithSync(keypair: NostrKeypair) async {
        let rm = RelayManager(keypair: keypair)
        self.relayManager = rm

        let sync = SyncCoordinator(settings: settings, savedLocations: savedLocations, rideHistory: rideHistory)
        let syncStore = RoadflareSyncStateStore(namespace: keypair.publicKeyHex)
        let service = RoadflareDomainService(relayManager: rm, keypair: keypair)
        sync.configure(syncStore: syncStore, domainService: service)
        self.syncCoordinator = sync
        self.roadflareDomainService = service

        let repo = FollowedDriversRepository(persistence: driversPersistence)
        self.driversRepository = repo
        sync.wireTrackingCallbacks(driversRepo: repo)

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

        await sync.performStartupSync(repo: repo, importFlow: true) { [weak self] progress in
            switch progress {
            case .status(let msg): self?.syncStatus = msg
            case .profileRestored(let found): self?.syncRestoredName = found
            case .driversRestored(let count): self?.syncRestoredDrivers = count
            case .locationsRestored(let count): self?.syncRestoredLocations = count
            }
        }

        let coordinator = RideCoordinator(
            relayManager: rm, keypair: keypair,
            driversRepository: repo, settings: settings,
            rideHistory: rideHistory, bitcoinPrice: bitcoinPrice,
            roadflareDomainService: service,
            roadflareSyncStore: sync.roadflareSyncStore
        )
        self.rideCoordinator = coordinator
        await coordinator.restoreLiveSubscriptions()
        connectionCoordinator.start(
            interval: Self.connectionWatchdogInterval,
            shouldReconnect: { [weak self] in self?.authState == .ready },
            isConnected: { [weak self] in await self?.relayManager?.isConnected ?? false },
            reconnect: { [weak self] in await self?.reconnectAndRestoreSession() }
        )
    }

    private func setupServices(keypair: NostrKeypair) async {
        let rm = RelayManager(keypair: keypair)
        self.relayManager = rm

        let sync = SyncCoordinator(settings: settings, savedLocations: savedLocations, rideHistory: rideHistory)
        let syncStore = RoadflareSyncStateStore(namespace: keypair.publicKeyHex)
        let service = RoadflareDomainService(relayManager: rm, keypair: keypair)
        sync.configure(syncStore: syncStore, domainService: service)
        self.syncCoordinator = sync
        self.roadflareDomainService = service

        let repo = FollowedDriversRepository(persistence: driversPersistence)
        self.driversRepository = repo
        sync.wireTrackingCallbacks(driversRepo: repo)

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

        await sync.performStartupSync(repo: repo, importFlow: false)

        let coordinator = RideCoordinator(
            relayManager: rm, keypair: keypair,
            driversRepository: repo, settings: settings,
            rideHistory: rideHistory, bitcoinPrice: bitcoinPrice,
            roadflareDomainService: service,
            roadflareSyncStore: sync.roadflareSyncStore
        )
        self.rideCoordinator = coordinator
        AppLogger.auth.info("Starting subscriptions... (\(repo.drivers.count) drivers loaded)")
        await coordinator.restoreLiveSubscriptions()
        connectionCoordinator.start(
            interval: Self.connectionWatchdogInterval,
            shouldReconnect: { [weak self] in self?.authState == .ready },
            isConnected: { [weak self] in await self?.relayManager?.isConnected ?? false },
            reconnect: { [weak self] in await self?.reconnectAndRestoreSession() }
        )
    }

    // MARK: - Identity Replacement

    private func prepareForIdentityReplacement(clearPersistedSyncState: Bool) async {
        // 1. Connection
        connectionCoordinator.stop()

        // 2. Ride + relay
        await rideCoordinator?.stopAll()
        await relayManager?.disconnect()

        // 3. Sync (detaches ALL callbacks before any clearAll)
        syncCoordinator?.teardown(clearPersistedState: clearPersistedSyncState)
        syncCoordinator = nil

        // 4. Repository data (callbacks already nil'd by teardown)
        driversRepository?.clearAll()
        if driversRepository == nil {
            driversPersistence.saveDrivers([])
            driversPersistence.saveDriverNames([:])
        }
        rideHistory.clearAll()
        savedLocations.clearAll()
        settings.clearAll()
        RideStatePersistence.clear()

        // 5. UI state
        requestRideDriverPubkey = nil
        selectedTab = 0

        // 6. Nil service refs
        rideCoordinator = nil
        relayManager = nil
        roadflareDomainService = nil
        driversRepository = nil
        fareCalculator = nil
        remoteConfigManager = nil
        bitcoinPrice.stop()
    }
}
