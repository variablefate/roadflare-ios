import SwiftUI
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

    /// Mark profile name as set, move to payment setup.
    func completeProfileSetup(name: String) {
        settings.profileName = name
        authState = .paymentSetup
    }

    /// Mark payment setup as done, finish onboarding.
    func completePaymentSetup() {
        settings.profileCompleted = true
        authState = .ready
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

    private func setupServices(keypair: NostrKeypair) async {
        let rm = RelayManager(keypair: keypair)
        self.relayManager = rm
        let repo = FollowedDriversRepository(persistence: driversPersistence)
        self.driversRepository = repo
        self.fareCalculator = FareCalculator()
        self.remoteConfigManager = RemoteConfigManager(relayManager: rm)

        do {
            print("[AppState] Connecting to \(DefaultRelays.all.count) relays...")
            try await rm.connect(to: DefaultRelays.all)
            let connected = await rm.isConnected
            print("[AppState] Relay connection: \(connected ? "SUCCESS" : "FAILED")")
        } catch {
            print("[AppState] Relay connection FAILED: \(error)")
        }

        // Set up ride coordinator and start background subscriptions
        let coordinator = RideCoordinator(
            relayManager: rm, keypair: keypair,
            driversRepository: repo, settings: settings,
            rideHistory: rideHistory
        )
        self.rideCoordinator = coordinator
        print("[AppState] Starting subscriptions... (\(repo.drivers.count) drivers loaded)")
        coordinator.startLocationSubscriptions()
        coordinator.startKeyShareSubscription()

        // Publish followed drivers list so drivers can discover followers
        if repo.hasDrivers {
            await coordinator.publishFollowedDriversList()
        }
    }
}
