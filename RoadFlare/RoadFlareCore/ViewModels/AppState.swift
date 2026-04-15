import SwiftUI
import os
import RidestrSDK

/// App-level authentication state.
public enum AuthState {
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
public final class AppState {
    private static let connectionWatchdogInterval: Duration = .seconds(10)

    // MARK: - Auth

    public var authState: AuthState = .loading

    // MARK: - Navigation

    /// Set by DriverDetailSheet to navigate to ride tab with driver pre-selected.
    public var requestRideDriverPubkey: String?
    /// Set to switch tabs programmatically.
    public var selectedTab: Int = 0

    // MARK: - SDK Services

    public private(set) var keyManager: KeyManager?
    public private(set) var relayManager: RelayManager?
    public private(set) var roadflareDomainService: RoadflareDomainService?
    public private(set) var driversRepository: FollowedDriversRepository?
    public private(set) var rideCoordinator: RideCoordinator?
    public private(set) var fareCalculator: FareCalculator?
    public private(set) var remoteConfigManager: RemoteConfigManager?
    public let rideHistory = RideHistoryRepository(persistence: UserDefaultsRideHistoryPersistence())
    public let savedLocations = SavedLocationsRepository(persistence: UserDefaultsSavedLocationsPersistence())
    public let bitcoinPrice = BitcoinPriceService()

    // MARK: - User State

    public private(set) var keypair: NostrKeypair?
    public let settings = UserSettingsRepository(persistence: UserDefaultsUserSettingsPersistence())

    // MARK: - Sync State (for import flow UI)

    public var syncStatus: String = ""
    public var syncRestoredDrivers: Int = 0
    public var syncRestoredLocations: Int = 0
    public var syncRestoredName: Bool = false

    // MARK: - Private Coordinators & Storage

    private let keychainStorage = KeychainStorage(service: "com.roadflare.keys")
    private let driversPersistence = UserDefaultsDriversPersistence()
    private let rideStatePersistence = UserDefaultsRideStatePersistence()
    private var syncCoordinator: SyncCoordinator?
    private let connectionCoordinator = ConnectionCoordinator()

    // MARK: - Init

    private static let hasLaunchedKey = "roadflare_has_launched"

    public init() {}

    /// Initialize on app launch. Checks for existing keys.
    /// Handles Keychain persistence across reinstalls by checking UserDefaults.
    public func initialize() async {
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
    public func generateNewKey() async throws {
        guard let km = keyManager else { return }
        let kp = try await km.generate()
        await prepareForIdentityReplacement(clearPersistedSyncState: false)
        keypair = kp
        await setupServices(keypair: kp)
        authState = .profileIncomplete
    }

    /// Import an existing key from nsec or hex. Shows sync screen during restore.
    public func importKey(_ input: String) async throws {
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
            settings.setProfileCompleted(true)
            authState = .ready
        }
    }

    /// Mark profile name as set, publish Kind 0 to Nostr, move to payment setup.
    public func completeProfileSetup(name: String) async {
        settings.setProfileName(name)
        syncCoordinator?.markDirty(.profile)
        await publishProfile()
        authState = .paymentSetup
    }

    /// Mark payment setup as done, finish onboarding. Publishes profile + settings backup.
    public func completePaymentSetup() async {
        settings.setProfileCompleted(true)
        syncCoordinator?.markDirty(.profileBackup)
        await saveAndPublishSettings()
        authState = .ready
    }

    // MARK: - Forwarding to SDK (through SyncCoordinator)

    func publishProfile() async {
        guard let service = roadflareDomainService,
              let syncStore = syncCoordinator?.roadflareSyncStore else { return }
        await service.publishProfileAndMark(from: settings, syncStore: syncStore)
    }

    public func publishProfileBackup() async {
        await syncCoordinator?.profileBackupCoordinator?.publishAndMark(
            settings: settings, savedLocations: savedLocations
        )
    }

    public func saveAndPublishSettings() async {
        await publishProfile()
        await publishProfileBackup()
    }

    func buildProfileBackupContent() -> ProfileBackupContent {
        syncCoordinator?.profileBackupCoordinator?.buildContent(
            settings: settings, savedLocations: savedLocations
        ) ?? ProfileBackupContent(savedLocations: [], settings: SettingsBackupContent())
    }

    func preserveProfileBackupSettingsTemplate(_ s: SettingsBackupContent) {
        syncCoordinator?.profileBackupCoordinator?.preserveSettingsTemplate(s)
    }

    // MARK: - Driver Key Management

    /// Try to restore a specific driver's key from our Kind 30011 backup on the relay.
    public func restoreKeyFromBackup(driverPubkey: String) async {
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
    public func sendFollowNotification(driverPubkey: String) async {
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

    // MARK: - Driver Ping

    /// Per-driver last-ping timestamps for sender-side rate limiting.
    /// Lives in memory for the lifetime of the process (survives backgrounding).
    /// Cleared on logout / identity replacement via `prepareForIdentityReplacement()`,
    /// so rider B cannot inherit rider A's cooldowns in the same session.
    /// Intentionally not persisted — resets on app restart to avoid stale state.
    private var pingCooldowns: [String: Date] = [:]
    private static let pingCooldownSeconds: TimeInterval = 600  // 10 minutes

    /// Returns `true` when `driver` is a valid ping target.
    ///
    /// Checks: has a current RoadFlare key, key is not stale, driver is not online,
    /// driver is not on a ride. Independent of the per-driver cooldown — use
    /// `sendDriverPing` for the full send-with-cooldown flow.
    public func canPingDriver(_ driver: FollowedDriver) -> Bool {
        guard let repo = driversRepository else { return false }
        return repo.canPingDriver(driver)
    }

    /// Send Kind 3189 driver ping request to an offline driver.
    ///
    /// Enforces a 10-minute per-driver cooldown locally. Returns `.rateLimited` if the
    /// cooldown has not elapsed. Returns `.missingKey` if the driver has not shared their
    /// RoadFlare key (ping cannot be authenticated without it). Returns `.ineligible` if
    /// the driver exists but is no longer pingable (for example stale key, online, or on a ride).
    /// Returns `.sent` on success.
    ///
    /// Non-fatal publish failures return `.publishFailed` — the rider is informed but the app
    /// continues normally.
    @discardableResult
    public func sendDriverPing(driverPubkey: String) async -> DriverPingResult {
        // 1. Check cooldown
        if let lastPing = pingCooldowns[driverPubkey] {
            let retryAt = lastPing.addingTimeInterval(Self.pingCooldownSeconds)
            if Date.now < retryAt {
                return .rateLimited(retryAfter: retryAt)
            }
        }

        // 2. Recheck structural eligibility at send time. The bell can remain visible briefly
        // while async location or stale-key updates arrive; this keeps the actual send path
        // aligned with the same source of truth the UI uses.
        guard let repo = driversRepository else {
            return .ineligible
        }
        if let preflightFailure = repo.driverPingPreflight(driverPubkey: driverPubkey) {
            return preflightFailure
        }
        guard let roadflareKey = repo.getRoadflareKey(driverPubkey: driverPubkey) else {
            return .ineligible
        }

        // 3. Require rider identity
        guard let kp = keypair, let rm = relayManager,
              !settings.profileName.isEmpty else {
            return .publishFailed("Not logged in")
        }

        // 4. Build and publish
        // Claim the cooldown slot BEFORE any await. sendDriverPing runs on @MainActor,
        // but each `await` is a suspension point — a second tap during the async call
        // would see an empty pingCooldowns and launch a duplicate publish. Claiming
        // eagerly prevents that. Roll back on failure so the user can retry.
        pingCooldowns[driverPubkey] = Date.now
        do {
            let event = try await RideshareEventBuilder.driverPingRequest(
                driverPubkey: driverPubkey,
                riderName: settings.profileName,
                roadflareKey: roadflareKey,
                keypair: kp
            )
            _ = try await rm.publish(event)
            AppLogger.auth.info("Sent driver ping to \(driverPubkey.prefix(8))")
            return .sent
        } catch {
            pingCooldowns[driverPubkey] = nil  // rollback so user can retry
            return .publishFailed(error.localizedDescription)
        }
    }

    // MARK: - Connection & Foreground

    /// Called when app returns to foreground. Reconnects relays and restarts subscriptions if needed.
    public func handleForeground() async {
        guard authState == .ready else { return }
        await reconnectAndRestoreSession()
    }

    public func reconnectAndRestoreSession() async {
        guard let rm = relayManager else { return }
        await rm.reconnectIfNeeded()
        guard await rm.isConnected else { return }
        await syncCoordinator?.flushPendingSyncPublishes(rideCoordinator: rideCoordinator)
        await rideCoordinator?.restoreLiveSubscriptions()
    }

    // MARK: - Auth Helpers

    public func resolveLocalAuthState() -> AuthState {
        if settings.profileName.isEmpty {
            return .profileIncomplete
        }
        if settings.roadflarePaymentMethods.isEmpty {
            return .paymentSetup
        }
        return settings.profileCompleted ? .ready : .paymentSetup
    }

    /// Log out: clear all data.
    public func logout() async {
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
            roadflareSyncStore: sync.roadflareSyncStore,
            rideStatePersistence: rideStatePersistence
        )
        self.rideCoordinator = coordinator
        coordinator.rideHistorySyncCoordinator = sync.rideHistorySyncCoordinator
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
            roadflareSyncStore: sync.roadflareSyncStore,
            rideStatePersistence: rideStatePersistence
        )
        self.rideCoordinator = coordinator
        coordinator.rideHistorySyncCoordinator = sync.rideHistorySyncCoordinator
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
        rideStatePersistence.clear()

        // 5. UI state
        requestRideDriverPubkey = nil
        selectedTab = 0
        pingCooldowns = [:]

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
