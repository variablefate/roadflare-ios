import SwiftUI
import os
import RidestrSDK

/// App-level authentication state.
enum AuthState {
    case loading
    case loggedOut
    case profileIncomplete
    case paymentSetup
    case ready
}

/// Central app state coordinator. Owns SDK services and manages auth lifecycle.
@Observable
@MainActor
final class AppState {
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
    private(set) var driversRepository: FollowedDriversRepository?
    private(set) var rideCoordinator: RideCoordinator?
    private(set) var fareCalculator: FareCalculator?
    private(set) var remoteConfigManager: RemoteConfigManager?
    let rideHistory = RideHistoryStore()
    let savedLocations = SavedLocationsStore()
    let bitcoinPrice = BitcoinPriceService()

    // MARK: - User State

    private(set) var keypair: NostrKeypair?
    let settings = UserSettings()

    // MARK: - Storage

    private let keychainStorage = KeychainStorage(service: "com.roadflare.keys")
    private let driversPersistence = UserDefaultsDriversPersistence()

    // MARK: - Init

    init() {}

    /// Initialize on app launch. Checks for existing keys.
    func initialize() async {
        let km = KeyManager(storage: keychainStorage)
        self.keyManager = km

        if let kp = await km.getKeypair() {
            keypair = kp
            await setupServices(keypair: kp)
            if settings.profileCompleted {
                authState = .ready
            } else {
                authState = .profileIncomplete
            }
        } else {
            authState = .loggedOut
        }
    }

    // MARK: - Auth Actions

    /// Generate a new keypair.
    func generateNewKey() async throws {
        guard let km = keyManager else { return }
        let kp = try await km.generate()
        keypair = kp
        await setupServices(keypair: kp)
        authState = .profileIncomplete
    }

    /// Import an existing key from nsec or hex.
    func importKey(_ input: String) async throws {
        guard let km = keyManager else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let kp: NostrKeypair
        if trimmed.hasPrefix("nsec1") {
            kp = try await km.importNsec(trimmed)
        } else {
            kp = try await km.importHex(trimmed)
        }
        keypair = kp
        await setupServices(keypair: kp)
        // Imported keys — check if they already completed setup
        if settings.profileCompleted {
            authState = .ready
        } else {
            authState = .profileIncomplete
        }
    }

    /// Mark profile name as set, publish Kind 0 to Nostr, move to payment setup.
    /// Does NOT publish Kind 30177 yet — payment methods aren't set until next step.
    func completeProfileSetup(name: String) async {
        settings.profileName = name
        await publishProfile()
        authState = .paymentSetup
    }

    /// Mark payment setup as done, finish onboarding. Publishes profile + settings backup.
    func completePaymentSetup() async {
        settings.profileCompleted = true
        await saveAndPublishSettings()
        authState = .ready
    }

    /// Publish Kind 0 metadata to Nostr.
    func publishProfile() async {
        guard let kp = keypair, let rm = relayManager else { return }
        let profile = UserProfileContent(
            name: settings.profileName,
            displayName: settings.profileName
        )
        do {
            let event = try await RideshareEventBuilder.metadata(profile: profile, keypair: kp)
            _ = try await rm.publish(event)
            AppLogger.auth.info("Published profile to Nostr")
        } catch {
            AppLogger.auth.info("Failed to publish profile: \(error)")
        }
    }

    /// Publish Kind 30177 encrypted profile backup (settings + saved locations) to Nostr.
    func publishProfileBackup() async {
        guard let kp = keypair, let rm = relayManager else { return }
        let backup = ProfileBackupContent(
            savedLocations: savedLocations.favorites.map { loc in
                SavedLocationBackup(
                    displayName: loc.displayName, lat: loc.latitude, lon: loc.longitude,
                    addressLine: loc.addressLine, isPinned: true
                )
            },
            settings: SettingsBackupContent(
                roadflarePaymentMethods: settings.paymentMethods.map(\.rawValue)
            )
        )
        do {
            let event = try await RideshareEventBuilder.profileBackup(content: backup, keypair: kp)
            _ = try await rm.publish(event)
            AppLogger.auth.info("Published profile backup to Nostr")
        } catch {
            AppLogger.auth.info("Failed to publish profile backup: \(error)")
        }
    }

    /// Publish both Kind 0 (public profile) and Kind 30177 (encrypted backup) to Nostr.
    func saveAndPublishSettings() async {
        await publishProfile()
        await publishProfileBackup()
    }

    /// Try to restore a specific driver's key from our Kind 30011 backup on the relay.
    /// Used during mid-session re-add when the key was lost locally but exists in the backup.
    func restoreKeyFromBackup(driverPubkey: String) async {
        guard let kp = keypair, let rm = relayManager, let repo = driversRepository else { return }
        do {
            let filter = NostrFilter.followedDriversList(myPubkey: kp.publicKeyHex)
            let events = try await rm.fetchEvents(filter: filter, timeout: 5)
            if let event = events.sorted(by: { $0.createdAt > $1.createdAt }).first {
                let content = try RideshareEventParser.parseFollowedDriversList(event: event, keypair: kp)
                if let entry = content.drivers.first(where: { $0.pubkey == driverPubkey }),
                   let key = entry.roadflareKey {
                    repo.updateDriverKey(driverPubkey: driverPubkey, roadflareKey: key)
                    AppLogger.auth.info("Restored key for \(driverPubkey.prefix(8)) from Kind 30011 backup")
                }
            }
        } catch {
            // Non-fatal — will fall through to stale ack
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
        guard authState == .ready, let rm = relayManager, let coordinator = rideCoordinator else { return }
        await rm.reconnectIfNeeded()
        // Restart subscriptions (they terminate when relay disconnects)
        coordinator.startLocationSubscriptions()
        coordinator.startKeyShareSubscription()
    }

    /// Log out: clear all data.
    func logout() async {
        await rideCoordinator?.stopAll()
        await relayManager?.disconnect()
        try? await keyManager?.deleteKeys()
        driversRepository?.clearAll()
        rideHistory.clearAll()
        savedLocations.clearAll()
        settings.clearAll()
        RideStatePersistence.clear()
        keypair = nil
        rideCoordinator = nil
        relayManager = nil
        driversRepository = nil
        fareCalculator = nil
        remoteConfigManager = nil
        bitcoinPrice.stop()
        authState = .loggedOut
    }

    // MARK: - Private

    /// Fetch profile (Kind 0) and followed drivers (Kind 30011) from Nostr.
    private func syncFromNostr(
        relayManager rm: RelayManager,
        keypair: NostrKeypair,
        driversRepository repo: FollowedDriversRepository
    ) async {
        // Fetch profile, followed drivers, and profile backup concurrently
        async let profileResult = fetchOwnProfile(rm: rm, keypair: keypair)
        async let driversResult = fetchFollowedDrivers(rm: rm, keypair: keypair, repo: repo)
        async let backupResult = fetchProfileBackup(rm: rm, keypair: keypair)
        _ = await (profileResult, driversResult, backupResult)
    }

    private func fetchOwnProfile(rm: RelayManager, keypair: NostrKeypair) async {
        do {
            let filter = NostrFilter.metadata(pubkeys: [keypair.publicKeyHex])
            let events = try await rm.fetchEvents(filter: filter, timeout: 5)
            if let event = events.sorted(by: { $0.createdAt > $1.createdAt }).first,
               let profile = RideshareEventParser.parseMetadata(event: event) {
                let name = profile.displayName ?? profile.name
                if let name, !name.isEmpty, settings.profileName.isEmpty {
                    settings.profileName = name
                    AppLogger.auth.info("Restored profile name from Nostr: \(name)")
                }
            }
        } catch {
            AppLogger.auth.info("Profile fetch failed (non-fatal): \(error)")
        }
    }

    private func fetchFollowedDrivers(
        rm: RelayManager, keypair: NostrKeypair, repo: FollowedDriversRepository
    ) async {
        do {
            let filter = NostrFilter.followedDriversList(myPubkey: keypair.publicKeyHex)
            let events = try await rm.fetchEvents(filter: filter, timeout: 5)
            if let event = events.sorted(by: { $0.createdAt > $1.createdAt }).first {
                let content = try RideshareEventParser.parseFollowedDriversList(
                    event: event, keypair: keypair
                )
                if repo.drivers.isEmpty && !content.drivers.isEmpty {
                    repo.restoreFromNostr(content: content)
                    AppLogger.auth.info("Restored \(content.drivers.count) drivers from Nostr")
                }
            }
        } catch {
            AppLogger.auth.info("Followed drivers fetch failed (non-fatal): \(error)")
        }
    }

    private func fetchProfileBackup(rm: RelayManager, keypair: NostrKeypair) async {
        do {
            let filter = NostrFilter.profileBackup(myPubkey: keypair.publicKeyHex)
            let events = try await rm.fetchEvents(filter: filter, timeout: 5)
            if let event = events.sorted(by: { $0.createdAt > $1.createdAt }).first {
                let backup = try RideshareEventParser.parseProfileBackup(event: event, keypair: keypair)
                // Restore payment methods if local is at default (empty or just cash)
                let remotePaymentMethods = backup.settings.roadflarePaymentMethods
                    .compactMap { PaymentMethod(rawValue: $0) }
                if !remotePaymentMethods.isEmpty && settings.paymentMethods == [.cash] {
                    settings.paymentMethods = remotePaymentMethods
                    AppLogger.auth.info("Restored \(remotePaymentMethods.count) payment methods from Nostr backup")
                }
            }
        } catch {
            AppLogger.auth.info("Profile backup fetch failed (non-fatal): \(error)")
        }
    }

    /// Fetch Kind 0 profiles for all followed drivers to get display names and vehicle info.
    private func fetchDriverProfiles(
        relayManager rm: RelayManager,
        driversRepository repo: FollowedDriversRepository
    ) async {
        let pubkeys = repo.allPubkeys
        guard !pubkeys.isEmpty else { return }

        do {
            let filter = NostrFilter.metadata(pubkeys: pubkeys)
            let events = try await rm.fetchEvents(filter: filter, timeout: 8)
            // Dedup: group by pubkey, take latest by createdAt
            let grouped = Dictionary(grouping: events, by: \.pubkey)
            for (pubkey, driverEvents) in grouped {
                if let latest = driverEvents.max(by: { $0.createdAt < $1.createdAt }),
                   let profile = RideshareEventParser.parseMetadata(event: latest) {
                    repo.cacheDriverProfile(pubkey: pubkey, profile: profile)
                }
            }
            if !grouped.isEmpty {
                AppLogger.auth.info("Fetched profiles for \(grouped.count) driver(s)")
            }
        } catch {
            AppLogger.auth.info("Driver profile fetch failed (non-fatal): \(error)")
        }
    }

    private func setupServices(keypair: NostrKeypair) async {
        let rm = RelayManager(keypair: keypair)
        self.relayManager = rm
        let repo = FollowedDriversRepository(persistence: driversPersistence)
        self.driversRepository = repo
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

        // Sync profile and followed drivers from Nostr (on import or app restart)
        await syncFromNostr(relayManager: rm, keypair: keypair, driversRepository: repo)

        // Set up ride coordinator and start background subscriptions
        let coordinator = RideCoordinator(
            relayManager: rm, keypair: keypair,
            driversRepository: repo, settings: settings,
            rideHistory: rideHistory, bitcoinPrice: bitcoinPrice
        )
        self.rideCoordinator = coordinator
        AppLogger.auth.info("Starting subscriptions... (\(repo.drivers.count) drivers loaded)")
        coordinator.startLocationSubscriptions()
        coordinator.startKeyShareSubscription()

        // Publish followed drivers, fetch driver profiles, and check stale keys concurrently
        if repo.hasDrivers {
            async let _publish: () = coordinator.publishFollowedDriversList()
            async let _profiles: () = fetchDriverProfiles(relayManager: rm, driversRepository: repo)
            async let _staleCheck: () = coordinator.checkForStaleKeys()
            _ = await (_publish, _profiles, _staleCheck)
        }
    }
}
