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

    // MARK: - SDK Services

    private(set) var keyManager: KeyManager?
    private(set) var relayManager: RelayManager?
    private(set) var driversRepository: FollowedDriversRepository?
    private(set) var rideCoordinator: RideCoordinator?
    private(set) var fareCalculator: FareCalculator?
    private(set) var remoteConfigManager: RemoteConfigManager?

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
        settings.clearAll()
        keypair = nil
        rideCoordinator = nil
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
            try await rm.connect(to: DefaultRelays.all)
        } catch {
            print("Failed to connect to relays: \(error)")
        }

        // Set up ride coordinator and start background subscriptions
        let coordinator = RideCoordinator(
            relayManager: rm, keypair: keypair,
            driversRepository: repo, settings: settings
        )
        self.rideCoordinator = coordinator
        coordinator.startLocationSubscriptions()
        coordinator.startKeyShareSubscription()

        // Publish followed drivers list so drivers can discover followers
        if repo.hasDrivers {
            await coordinator.publishFollowedDriversList()
        }
    }
}
