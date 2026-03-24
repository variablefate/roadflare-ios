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

    /// Mark profile name as set, publish to Nostr, move to payment setup.
    func completeProfileSetup(name: String) async {
        settings.profileName = name
        await publishProfile()
        authState = .paymentSetup
    }

    /// Mark payment setup as done, finish onboarding.
    func completePaymentSetup() async {
        settings.profileCompleted = true
        await publishProfile()
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
        authState = .loggedOut
    }

    // MARK: - Private

    /// Fetch profile (Kind 0) and followed drivers (Kind 30011) from Nostr.
    private func syncFromNostr(
        relayManager rm: RelayManager,
        keypair: NostrKeypair,
        driversRepository repo: FollowedDriversRepository
    ) async {
        // Fetch profile (Kind 0) and followed drivers (Kind 30011) concurrently
        async let profileResult = fetchOwnProfile(rm: rm, keypair: keypair)
        async let driversResult = fetchFollowedDrivers(rm: rm, keypair: keypair, repo: repo)
        _ = await (profileResult, driversResult)
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
            rideHistory: rideHistory
        )
        self.rideCoordinator = coordinator
        AppLogger.auth.info("Starting subscriptions... (\(repo.drivers.count) drivers loaded)")
        coordinator.startLocationSubscriptions()
        coordinator.startKeyShareSubscription()

        // Publish followed drivers + fetch driver profiles concurrently (non-blocking)
        if repo.hasDrivers {
            async let _publish: () = coordinator.publishFollowedDriversList()
            async let _profiles: () = fetchDriverProfiles(relayManager: rm, driversRepository: repo)
            _ = await (_publish, _profiles)
        }
    }
}
