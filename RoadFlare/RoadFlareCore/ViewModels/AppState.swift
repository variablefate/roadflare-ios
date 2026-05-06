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

/// Reasons account deletion can fail before contacting relays.
public enum AccountDeletionError: Error, Equatable {
    case servicesNotReady
    case activeRideInProgress
}

/// Outcome of a user-initiated key refresh request.
///
/// `requestKeyRefresh(pubkey:)` enforces a per-driver cooldown so a frustrated
/// rider tapping the button repeatedly doesn't spam the driver with stale
/// acks; `.rateLimited` carries the next-eligible timestamp so callers can
/// surface a precise countdown. `.publishFailed` distinguishes a relay
/// publish failure (e.g. all relays disconnected) so the caller can show
/// an actionable error rather than a misleading "sent" toast — and AppState
/// rolls back the cooldown slot in that case so the rider can retry.
public enum KeyRefreshOutcome: Sendable, Equatable {
    case sent
    case rateLimited(retryAt: Date)
    case publishFailed
}

/// Which onboarding publish a `OnboardingPublishStatus.failed` refers to.
public enum OnboardingPublishDomain: Sendable, Equatable {
    /// Profile-only publish kicked off by `completeProfileSetup`.
    case profile
    /// Profile + settings backup kicked off by `completePaymentSetup`.
    case settingsBackup
}

/// State of the onboarding-publish failure surface.
///
/// `.idle` is the default. `.failed` triggers the in-app banner. The
/// transition is gated on relay connectivity: a publish that stays dirty
/// for 60s while the user is reachable surfaces as failed; a publish that
/// stays dirty while the user is offline does not (offline ≠ relay
/// failure). The banner clears (status returns to `.idle`) on:
///   - retry success — `retryOnboardingPublish` re-spawns the publish, the
///     watchdog finds the dirty flag cleared, no failure is re-raised;
///   - background reconnect success — `reconnectAndRestoreSession` calls
///     `flushPendingSyncPublishes` and clears the banner if the dirty flag
///     is now clean (see `clearOnboardingPublishStatusIfDomainsClean`);
///   - identity replacement — `prepareForIdentityReplacement` cancels the
///     watchdog and resets status alongside other per-identity state.
public enum OnboardingPublishStatus: Sendable, Equatable {
    case idle
    case failed(domain: OnboardingPublishDomain)
}

/// Outcome of `restoreKeyFromBackup(driverPubkey:)`.
///
/// Distinguishes "no key was in the backup" from "couldn't reach the relay
/// or decode it" so the caller can react differently — important on the
/// add-driver re-handshake path, where falling through to the new-follow
/// branch on a transient relay failure would re-trigger the issue #72
/// Bug 3 over-rotation symptom.
public enum RestoreKeyFromBackupOutcome: Sendable, Equatable {
    /// Backup was reachable, the driver was in it, and a key was applied to
    /// the local repo.
    case restored
    /// Backup was reachable but the driver entry has no key (e.g. driver
    /// was followed before any Kind 3186 was received). Treat as a genuine
    /// new follow — Kind 3187 + Kind 3188 are appropriate.
    case notInBackup
    /// Couldn't fetch the backup, snapshot was missing, or the latest
    /// remote event was undecodable. The caller cannot tell from the
    /// signal alone whether this is a re-add or a new follow.
    case backupUnavailable
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

    // MARK: - Onboarding Publish Surface

    /// Current state of the onboarding-publish failure banner. See
    /// `OnboardingPublishStatus` and ADR-0016.
    public var onboardingPublishStatus: OnboardingPublishStatus = .idle

    /// Time the user must be online with the publish still dirty before the
    /// failure surface fires. 60s matches the App Store push deadline UX bar
    /// — long enough to absorb a slow first-time relay handshake, short
    /// enough that a user stranded in a relay-broken state finds out before
    /// they've moved on to using the app for real.
    static let onboardingPublishTimeoutSeconds: TimeInterval = 60

    /// Poll interval used while the watchdog is parked waiting for
    /// connectivity (the user was offline at the timeout). Re-checks online
    /// + dirty every 10s; once online, surfaces failure or returns to idle.
    static let onboardingPublishRearmIntervalSeconds: TimeInterval = 10

    // MARK: - Navigation

    /// Set by DriverDetailSheet to navigate to ride tab with driver pre-selected.
    public var requestRideDriverPubkey: String?
    /// Set to switch tabs programmatically.
    public var selectedTab: Int = 0
    /// Pending Add-Driver intent from a custom URL scheme (`roadflared:`) or
    /// other deep-link source. `DriversTab` observes this and presents
    /// `AddDriverSheet` pre-filled; the consumer is responsible for clearing
    /// it back to `nil` after the sheet is dismissed. See `handleIncomingURL`.
    public var pendingDriverDeepLink: ParsedDriverQRCode?

    // MARK: - SDK Services

    public private(set) var keyManager: KeyManager?
    public private(set) var relayManager: RelayManager?
    public private(set) var roadflareDomainService: RoadflareDomainService?
    public private(set) var driversRepository: FollowedDriversRepository?
    public private(set) var rideCoordinator: RideCoordinator?
    public private(set) var fareCalculator: FareCalculator?
    public private(set) var remoteConfigManager: RemoteConfigManager?
    public private(set) var rideHistory = RideHistoryRepository(persistence: UserDefaultsRideHistoryPersistence())
    public private(set) var savedLocations = SavedLocationsRepository(persistence: UserDefaultsSavedLocationsPersistence())
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

    /// Persist a freshly-generated keypair from a passkey ceremony and finish
    /// onboarding without going through the sync/restore screen.
    ///
    /// This is the passkey analog of `generateNewKey()`: a brand-new account
    /// is being established (the seed comes from the passkey, but there is no
    /// pre-existing identity on relays to restore), so we transition directly
    /// to `.profileIncomplete` and skip the `.syncing` detour that
    /// `importKey()` uses for the recover-existing-account flow.
    ///
    /// The "Log In with Passkey" flow (recovering an existing account from
    /// the passkey-derived seed) should continue to use `importKey(_:)` —
    /// that's where the sync screen / "Restoring Your Data" copy is correct.
    /// Closes #70.
    public func createWithPasskey(_ nsec: String) async throws {
        guard let km = keyManager else { return }
        let kp = try await km.importNsec(nsec)
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
    /// Optimistic: advances `authState` immediately, publishes in the background.
    /// `markDirty` persists the dirty flag synchronously. If publish fails,
    /// `completePaymentSetup` republishes profile via `saveAndPublishSettings`,
    /// and once the user reaches `.ready` any still-dirty domain is retried by
    /// `SyncCoordinator.flushPendingSyncPublishes` on the next relay reconnect.
    /// (Reconnect-flush is gated by `authState == .ready`, so it does not fire
    /// during the `.paymentSetup` window.)
    public func completeProfileSetup(name: String) async {
        settings.setProfileName(name)
        syncCoordinator?.markDirty(.profile)
        authState = .paymentSetup
        startOnboardingPublish(domain: .profile)
    }

    /// Mark payment setup as done, finish onboarding. Publishes profile +
    /// settings backup in the background. Once `authState == .ready`, any
    /// domain still dirty is retried on the next relay reconnect via
    /// `SyncCoordinator.flushPendingSyncPublishes`.
    public func completePaymentSetup() async {
        settings.setProfileCompleted(true)
        syncCoordinator?.markDirty(.profileBackup)
        authState = .ready
        startOnboardingPublish(domain: .settingsBackup)
    }

    /// Spawn the publish + watchdog for an onboarding domain. Cancels any
    /// in-flight watchdog and clears prior failure state, so a fast user
    /// chaining ProfileSetup → PaymentSetup doesn't surface a stale
    /// `.failed` from the first publish while the second is still in
    /// flight. The publish itself is unsupervised (matches pre-watchdog
    /// optimistic-transition contract from ADR-0014); the watchdog is the
    /// only signal we need to cancel-and-restart.
    private func startOnboardingPublish(domain: OnboardingPublishDomain) {
        onboardingPublishWatchdogTask?.cancel()
        onboardingPublishTask?.cancel()
        onboardingPublishStatus = .idle
        onboardingPublishTask = Task {
            await self.runOnboardingPublishImpl(domain: domain)
        }
        onboardingPublishWatchdogTask = Task {
            await self.runOnboardingPublishWatchdog(domain: domain)
        }
    }

    /// Re-invoke the publish that previously failed and re-arm the watchdog.
    /// No-op if `onboardingPublishStatus` isn't `.failed` (banner already
    /// dismissed, or nothing has been started).
    public func retryOnboardingPublish() {
        guard case .failed(let domain) = onboardingPublishStatus else { return }
        startOnboardingPublish(domain: domain)
    }

    private func runOnboardingPublishImpl(domain: OnboardingPublishDomain) async {
        // Early-bail when a retry/chain cancel landed before this Task was
        // scheduled. Once the SDK publish below has been awaited, the relay
        // round-trip completes regardless — `publishProfileAndMark` doesn't
        // observe cooperative cancellation.
        guard !Task.isCancelled else { return }
        do {
            #if DEBUG
            if let hook = onboardingPublishHookForTesting {
                try await hook(domain)
                return
            }
            #endif
            switch domain {
            case .profile:
                try await publishProfile()
            case .settingsBackup:
                try await saveAndPublishSettings()
            }
        } catch {
            // Eager-error surface (ADR-0017): an SDK throw is a faster signal
            // than the dirty-flag watchdog. If the relay is reachable, fire
            // the banner immediately and cancel the watchdog (its +60s
            // `.failed(domain:)` write would be a redundant idempotent set).
            // If offline, do nothing — the watchdog's offline-park loop is
            // the right place to wait for connectivity to come back.
            guard !Task.isCancelled else { return }
            AppLogger.auth.warning(
                "Onboarding publish (\(String(describing: domain))) failed: \(error.localizedDescription)"
            )
            let online = await isOnboardingPublishOnline()
            guard !Task.isCancelled else { return }
            if online {
                onboardingPublishStatus = .failed(domain: domain)
                onboardingPublishWatchdogTask?.cancel()
            }
        }
    }

    /// Sleep for the timeout window. If the publish hasn't cleared the
    /// dirty flag AND the relay is reachable, surface the failure banner.
    /// If the user is offline at the timeout, park (poll the rearm
    /// interval) until either the publish clears or connectivity returns.
    private func runOnboardingPublishWatchdog(domain: OnboardingPublishDomain) async {
        let timeout = onboardingPublishTimeoutSeconds()
        do {
            try await Task.sleep(for: .seconds(timeout))
        } catch {
            return  // cancelled (retry, identity replacement, etc.)
        }
        guard !Task.isCancelled else { return }
        await checkOnboardingPublishOutcome(domain: domain)
    }

    private func checkOnboardingPublishOutcome(domain: OnboardingPublishDomain) async {
        guard !Task.isCancelled else { return }
        if !isOnboardingDomainDirty(domain) { return }   // publish succeeded
        let online = await isOnboardingPublishOnline()
        // Re-check cancellation after the connectivity await so a retry that
        // landed during the await doesn't get clobbered by a stale `.failed`
        // write here.
        guard !Task.isCancelled else { return }
        if online {
            onboardingPublishStatus = .failed(domain: domain)
            return
        }
        // Offline: park and re-check after the rearm interval.
        let rearm = onboardingPublishRearmIntervalSeconds()
        do {
            try await Task.sleep(for: .seconds(rearm))
        } catch {
            return
        }
        await checkOnboardingPublishOutcome(domain: domain)
    }

    private func onboardingPublishTimeoutSeconds() -> TimeInterval {
        #if DEBUG
        if let override = onboardingPublishTimeoutOverrideForTesting {
            return override
        }
        #endif
        return Self.onboardingPublishTimeoutSeconds
    }

    private func onboardingPublishRearmIntervalSeconds() -> TimeInterval {
        #if DEBUG
        if let override = onboardingPublishRearmOverrideForTesting {
            return override
        }
        #endif
        return Self.onboardingPublishRearmIntervalSeconds
    }

    private func isOnboardingDomainDirty(_ domain: OnboardingPublishDomain) -> Bool {
        #if DEBUG
        if let hook = onboardingPublishIsDirtyHookForTesting {
            return hook(domain)
        }
        #endif
        guard let store = syncCoordinator?.roadflareSyncStore else { return false }
        switch domain {
        case .profile:
            return store.metadata(for: .profile).isDirty
        case .settingsBackup:
            // The settings-backup window covers BOTH the Kind 0 profile
            // republish and the Kind 30177 backup publish — surface failure
            // if either is still dirty after the window.
            return store.metadata(for: .profile).isDirty
                || store.metadata(for: .profileBackup).isDirty
        }
    }

    private func isOnboardingPublishOnline() async -> Bool {
        #if DEBUG
        if let hook = onboardingPublishConnectivityHookForTesting {
            return await hook()
        }
        #endif
        return await isRelayConnected()
    }

    // MARK: - Forwarding to SDK (through SyncCoordinator)

    func publishProfile() async throws {
        guard let service = roadflareDomainService,
              let syncStore = syncCoordinator?.roadflareSyncStore else { return }
        try await service.publishProfileAndMark(from: settings, syncStore: syncStore)
    }

    public func publishProfileBackup() async throws {
        guard let coordinator = syncCoordinator?.profileBackupCoordinator else { return }
        try await coordinator.publishAndMark(settings: settings, savedLocations: savedLocations)
    }

    public func saveAndPublishSettings() async throws {
        // Always attempt both publishes — they target independent Nostr kinds
        // (Kind 0 profile vs Kind 30177 backup) and a transient failure of one
        // shouldn't suppress the other. Capture the first error and rethrow so
        // the onboarding eager-error path (ADR-0017) still fires the banner.
        var firstError: (any Error)?
        do { try await publishProfile() } catch { firstError = error }
        do { try await publishProfileBackup() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
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

    /// Try to restore a specific driver's key from our Kind 30011 backup on
    /// the relay.
    ///
    /// The returned outcome lets callers distinguish "the backup said this
    /// driver has no key" from "we couldn't reach or decode the backup" —
    /// critical on the add-driver re-handshake path where a transient
    /// failure should NOT silently fall through to Kind 3187, since Kind
    /// 3187 triggers driver-side key rotation for all followers (issue #72
    /// Bug 3).
    @discardableResult
    public func restoreKeyFromBackup(driverPubkey: String) async -> RestoreKeyFromBackupOutcome {
        guard let service = roadflareDomainService,
              let repo = driversRepository else { return .backupUnavailable }
        let remote = await service.fetchLatestFollowedDriversState()
        guard let snapshot = remote.snapshot else { return .backupUnavailable }

        if let latestSeenCreatedAt = remote.latestSeenCreatedAt,
           snapshot.createdAt != latestSeenCreatedAt {
            AppLogger.auth.warning(
                "Skipping key restore for \(driverPubkey.prefix(8)) because the latest followed-drivers backup is not decodable"
            )
            return .backupUnavailable
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
            return .restored
        }

        return .notInBackup
    }

    /// Restart the key-share subscription. Surfaced so the add-driver
    /// re-handshake can preserve the side effect from `sendFollowNotification`
    /// (PR #54) when the new flow skips the Kind 3187 publish: a fresh
    /// subscription forces relay re-delivery of any subsequent Kind 3186
    /// rotations within the 12-hour window, even if the long-lived
    /// subscription from app launch dropped events.
    public func restartKeyShareSubscription() {
        rideCoordinator?.startKeyShareSubscription()
    }

    /// Restart the Kind 30173 driver-availability subscription. Sibling of
    /// `restartKeyShareSubscription`; called whenever the followed-drivers list
    /// changes so the author filter is rebuilt against the new set. See issue #91.
    public func restartDriverAvailabilitySubscription() {
        rideCoordinator?.startDriverAvailabilitySubscription()
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
        // Restart the key share subscription so the relay re-delivers any Kind 3186
        // the driver sends in response to this follow notification. The long-lived
        // subscription from app launch may miss new events on some relays; a fresh
        // subscription forces re-delivery of both historical (12-hour window) and
        // future key share events. See issue #54.
        rideCoordinator?.startKeyShareSubscription()
        // Same reasoning for Kind 30173: rebuild the author filter to include the
        // newly added driver so the rider sees their active vehicle. See issue #91.
        rideCoordinator?.startDriverAvailabilitySubscription()
    }

    // MARK: - Driver Ping

    /// Per-driver last-ping timestamps for sender-side rate limiting.
    /// Lives in memory for the lifetime of the process (survives backgrounding).
    /// Cleared on logout / identity replacement via `prepareForIdentityReplacement()`,
    /// so rider B cannot inherit rider A's cooldowns in the same session.
    /// Intentionally not persisted — resets on app restart to avoid stale state.
    private var pingCooldowns: [String: Date] = [:]
    private static let pingCooldownSeconds: TimeInterval = 600  // 10 minutes

    /// Per-driver last user-initiated key-refresh timestamps. Cleared on
    /// identity replacement alongside `pingCooldowns`. Mirrors Android's
    /// `keyRefreshRequests` map (rider-app/.../RoadflareTab.kt) — a 60s window
    /// is enough that a tap-spam rider still gets actionable feedback ("wait
    /// 30s before requesting again") rather than queueing a flood of stale acks.
    private var keyRefreshCooldowns: [String: Date] = [:]
    static let keyRefreshCooldownSeconds: TimeInterval = 60  // matches Android rider

    #if DEBUG
    /// Test-only override for the SDK call inside `requestKeyRefresh(pubkey:)`.
    /// Set via `setKeyRefreshSDKHookForTesting(_:)`. See that method's docs.
    var keyRefreshSDKHookForTesting: ((String) async throws -> Void)?

    /// Test-only overrides for the onboarding-publish failure surface. See
    /// `setOnboardingPublishHooksForTesting(...)` for usage.
    var onboardingPublishHookForTesting: ((OnboardingPublishDomain) async throws -> Void)?
    var onboardingPublishConnectivityHookForTesting: (() async -> Bool)?
    var onboardingPublishIsDirtyHookForTesting: ((OnboardingPublishDomain) -> Bool)?
    var onboardingPublishTimeoutOverrideForTesting: TimeInterval?
    var onboardingPublishRearmOverrideForTesting: TimeInterval?
    #endif

    /// In-flight watchdog Task. Cancelled and replaced when the user retries
    /// or starts a fresh onboarding-publish (e.g. tapping Continue on
    /// PaymentSetup after Continue on ProfileSetup).
    private var onboardingPublishWatchdogTask: Task<Void, Never>?

    /// In-flight publish Task spawned alongside the watchdog. Tracked so a
    /// retry / chained Continue can mark it cancelled before the publish
    /// switch runs (`runOnboardingPublishImpl` early-bails on
    /// `Task.isCancelled`). Note: the underlying SDK call
    /// (`publishProfileAndMark`) doesn't check cancellation itself, so a
    /// publish whose `await publishProfile()` has already started completes
    /// regardless. Cancellation only avoids the duplicate when the cancel
    /// lands before the spawned Task is scheduled — which is the common
    /// case for back-to-back Continue taps and rapid retries.
    private var onboardingPublishTask: Task<Void, Never>?

    /// Returns `true` when `driver` is a valid ping target.
    ///
    /// Checks: has a current RoadFlare key, key is not stale, driver is not online,
    /// driver is not on a ride. Independent of the per-driver cooldown — use
    /// `sendDriverPing` for the full send-with-cooldown flow.
    public func canPingDriver(_ driver: FollowedDriver) -> Bool {
        guard let repo = driversRepository else { return false }
        return repo.canPingDriver(driver)
    }

    /// Returns `true` when `driver` is a valid target for a ride request.
    ///
    /// Checks: driver exists in the repo, has a current RoadFlare key, key is not
    /// stale, and is currently broadcasting status `online`. Used to gate the
    /// Request-Ride button and online-drivers list. Returns `false` when services
    /// are not yet configured.
    public func canRequestRide(_ driver: FollowedDriver) -> Bool {
        guard let repo = driversRepository else { return false }
        return repo.canRequestRide(driver)
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

    // MARK: - Deep Links

    /// Route an incoming custom-scheme URL into the app.
    ///
    /// Recognized URLs (`roadflared:npub1...?name=...` and friends — see
    /// `DriverQRCodeParser.parse` for the full set) populate
    /// `pendingDriverDeepLink` and switch `selectedTab` to the drivers tab.
    /// `DriversTab` observes `pendingDriverDeepLink` and presents
    /// `AddDriverSheet` pre-filled with the parsed npub + display name.
    ///
    /// Unrecognized URLs are dropped silently — the URL scheme registration
    /// in Info.plist is the gate, but we defend against any unexpected payload
    /// (e.g. a future scheme we don't yet handle, or a malformed link).
    public func handleIncomingURL(_ url: URL) {
        guard let parsed = DriverQRCodeParser.parse(url.absoluteString) else { return }
        pendingDriverDeepLink = parsed
        selectedTab = 1  // Drivers tab — see MainTabView.swift
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
        clearOnboardingPublishStatusIfDomainsClean()
        await rideCoordinator?.restoreLiveSubscriptions()
    }

    /// If the failure banner was up but the post-flush dirty flags are now
    /// clear (background reconnect-flush succeeded), dismiss the banner.
    /// Without this, a user who had the banner up could fix connectivity,
    /// have their publish silently succeed via the sync-coordinator's
    /// retry path, and still see the banner until they tapped Retry.
    private func clearOnboardingPublishStatusIfDomainsClean() {
        guard case .failed(let domain) = onboardingPublishStatus else { return }
        if !isOnboardingDomainDirty(domain) {
            onboardingPublishWatchdogTask?.cancel()
            onboardingPublishWatchdogTask = nil
            onboardingPublishTask?.cancel()
            onboardingPublishTask = nil
            onboardingPublishStatus = .idle
        }
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

    // MARK: - Account Deletion

    /// Scan relays for all rider-authored events. Returns categorised results.
    /// Call while still logged in (relay + keypair are live).
    ///
    /// Defensively reconnects the relay manager if its notification handler died
    /// (e.g. after backgrounding) so the scan doesn't silently return 0 events
    /// because the WebSocket is dead. Restores live ride subscriptions (so they
    /// survive the user cancelling the sheet) but deliberately skips
    /// `flushPendingSyncPublishes`: flushing here would push dirty profile/drivers/
    /// history state to relays right before the user asks to delete everything,
    /// wasting relay traffic and risking a race where freshly-flushed events
    /// aren't indexed in time for the scan query — orphaning them on relays
    /// after the keypair is destroyed.
    public func scanRelaysForDeletion() async throws -> RelayScanResult {
        guard let keypair, let relayManager else {
            throw AccountDeletionError.servicesNotReady
        }
        guard !(rideCoordinator?.session.stage.isActiveRide ?? false) else {
            throw AccountDeletionError.activeRideInProgress
        }
        await relayManager.reconnectIfNeeded()
        if await relayManager.isConnected {
            await rideCoordinator?.restoreLiveSubscriptions()
        }
        let service = AccountDeletionService(relayManager: relayManager, keypair: keypair)
        return await service.scanRelays()
    }

    /// Delete only RoadFlare events from relays, then clear local data and log out.
    /// Logs publish failures via `AppLogger.auth.error` so they're visible in Console.app.
    /// Re-checks active-ride state: the user could have started a ride between scan
    /// and confirm (e.g. accepted an offer in another tab), and `logout()` → `clearAll()`
    /// would otherwise tear down an active ride mid-flight.
    ///
    /// Only calls `logout()` when the Kind 5 publish succeeds — logging out on
    /// publish failure would destroy the keypair before the user sees the error,
    /// leaving their events stranded on relays with no way to retry from this
    /// device. On failure the caller must surface the error and let the user retry
    /// or abandon the flow; the local session stays intact until then.
    public func deleteRoadflareEvents(from scan: RelayScanResult) async -> RelayDeletionResult {
        guard let keypair, let relayManager else {
            return RelayDeletionResult(
                deletedEventIds: [], targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: false, publishError: "Services not ready"
            )
        }
        guard !(rideCoordinator?.session.stage.isActiveRide ?? false) else {
            return RelayDeletionResult(
                deletedEventIds: [], targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: false,
                publishError: "An active ride started during deletion — cancel it and try again."
            )
        }
        let service = AccountDeletionService(relayManager: relayManager, keypair: keypair)
        let result = await service.deleteRoadflareEvents(from: scan)
        if result.publishedSuccessfully {
            await logout()
        } else {
            AppLogger.auth.error(
                "RoadFlare event deletion publish failed: \(result.publishError ?? "unknown", privacy: .public)"
            )
        }
        return result
    }

    /// Delete all Ridestr events (including Kind 0 metadata) from relays,
    /// then clear local data and log out. Re-checks active-ride state for the same
    /// reason as `deleteRoadflareEvents`, and only logs out on publish success —
    /// see `deleteRoadflareEvents` for the keypair-preservation rationale.
    public func deleteAllRidestrEvents(from scan: RelayScanResult) async -> RelayDeletionResult {
        guard let keypair, let relayManager else {
            return RelayDeletionResult(
                deletedEventIds: [], targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: false, publishError: "Services not ready"
            )
        }
        guard !(rideCoordinator?.session.stage.isActiveRide ?? false) else {
            return RelayDeletionResult(
                deletedEventIds: [], targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: false,
                publishError: "An active ride started during deletion — cancel it and try again."
            )
        }
        let service = AccountDeletionService(relayManager: relayManager, keypair: keypair)
        let result = await service.deleteAllRidestrEvents(from: scan)
        if result.publishedSuccessfully {
            await logout()
        } else {
            AppLogger.auth.error(
                "Full Ridestr event deletion publish failed: \(result.publishError ?? "unknown", privacy: .public)"
            )
        }
        return result
    }

    /// Publish the Kind 5 account deletion event for all Ridestr events + Kind 0.
    /// Unlike `deleteAllRidestrEvents`, this DOES NOT call `logout()` on success —
    /// the caller is responsible for invoking `logout()` after the user confirms
    /// a post-publish verification step. This lets the UI show a verification
    /// screen (re-scans relays to confirm deletion was honoured) before the
    /// keypair is destroyed.
    public func publishAccountDeletion(from scan: RelayScanResult) async -> RelayDeletionResult {
        guard let keypair, let relayManager else {
            return RelayDeletionResult(
                deletedEventIds: [], targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: false, publishError: "Services not ready"
            )
        }
        guard !(rideCoordinator?.session.stage.isActiveRide ?? false) else {
            return RelayDeletionResult(
                deletedEventIds: [], targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: false,
                publishError: "An active ride started during deletion — cancel it and try again."
            )
        }
        let service = AccountDeletionService(relayManager: relayManager, keypair: keypair)
        let result = await service.deleteAllRidestrEvents(from: scan)
        if !result.publishedSuccessfully {
            AppLogger.auth.error(
                "Account deletion publish failed: \(result.publishError ?? "unknown", privacy: .public)"
            )
        }
        return result
    }

    /// Re-scan relays for the given event IDs to verify how many were honoured.
    /// Intended to run after `publishAccountDeletion` returns successfully and
    /// before the user confirms the final logout. The keypair + relay manager
    /// must still be live when this is called.
    public func verifyAccountDeletion(eventIds: [String]) async -> DeletionVerificationResult {
        guard let keypair, let relayManager else {
            return DeletionVerificationResult(
                requestedCount: eventIds.count,
                remainingCount: eventIds.count,
                scanErrors: ["Services not ready"]
            )
        }
        let service = AccountDeletionService(relayManager: relayManager, keypair: keypair)
        return await service.verifyDeletion(targetEventIds: eventIds)
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

        // 4. Repository data (callbacks already nil'd by teardown).
        //    `clearAll()` zeroes drivers, names, locations, profiles, vehicles
        //    (Kind 30173 cache), and the stale-key set — see
        //    FollowedDriversRepository.clearAll().
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
        // Navigation intents (`selectedTab`, `requestRideDriverPubkey`,
        // `pendingDriverDeepLink`) are only cleared on actual REPLACEMENT
        // of a prior identity (logout, key import/regen with a prior
        // keypair). On first-time setup (`keypair == nil`), preserve them
        // so cold-start state — e.g. a `roadflared:` URL tapped before
        // onboarding sets `selectedTab = 1` and `pendingDriverDeepLink` —
        // survives the user's first `generateNewKey` / `createWithPasskey`
        // / `importKey` call (each of which routes through this function
        // BEFORE establishing the new identity) and is consumed by
        // `DriversTab` once the user reaches the main tab view post-`.ready`.
        // See ADR-0012.
        if keypair != nil {
            requestRideDriverPubkey = nil
            selectedTab = 0
            pendingDriverDeepLink = nil
        }
        pingCooldowns = [:]
        keyRefreshCooldowns = [:]
        onboardingPublishWatchdogTask?.cancel()
        onboardingPublishWatchdogTask = nil
        onboardingPublishTask?.cancel()
        onboardingPublishTask = nil
        onboardingPublishStatus = .idle

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

// MARK: - Façade: Connectivity

extension AppState {
    /// Async connectivity check for views that need to poll relay status.
    public func isRelayConnected() async -> Bool {
        await relayManager?.isConnected ?? false
    }
}

// MARK: - Façade: Drivers

extension AppState {
    /// Whether the rider has any followed drivers.
    public var hasFollowedDrivers: Bool {
        driversRepository?.hasDrivers ?? false
    }

    /// The current list of followed drivers.
    public var followedDrivers: [FollowedDriver] {
        driversRepository?.drivers ?? []
    }

    /// Cached location broadcast for a driver. Nil if no broadcast has been received.
    public func driverLocation(pubkey: String) -> CachedDriverLocation? {
        driversRepository?.driverLocations[pubkey]
    }

    /// Best available display name for a driver: cached Kind 0 profile name, then
    /// stored follow-list name.
    public func driverDisplayName(pubkey: String) -> String? {
        driversRepository?.cachedDriverName(pubkey: pubkey)
    }

    /// Cached Kind 0 profile for a driver. Nil until a profile fetch has run.
    public func driverProfile(pubkey: String) -> UserProfileContent? {
        driversRepository?.driverProfiles[pubkey]
    }

    /// Whether the driver's current key is flagged as stale.
    public func isDriverKeyStale(pubkey: String) -> Bool {
        driversRepository?.staleKeyPubkeys.contains(pubkey) ?? false
    }

    /// Whether the rider is already following this pubkey.
    public func isFollowingDriver(pubkey: String) -> Bool {
        driversRepository?.isFollowing(pubkey: pubkey) ?? false
    }

    /// Whether the rider has a RoadFlare key for this driver.
    public func hasKeyForDriver(pubkey: String) -> Bool {
        driversRepository?.getRoadflareKey(driverPubkey: pubkey) != nil
    }

    /// Get the current `FollowedDriver` struct for a pubkey (re-fetches live state).
    public func getDriver(pubkey: String) -> FollowedDriver? {
        driversRepository?.getDriver(pubkey: pubkey)
    }

    /// Add a driver and cache their profile and name if available.
    /// Note: unlike `removeDriver` and `updateDriverNote`, this does NOT auto-publish the
    /// updated list. Call `publishDriversList()` and `sendFollowNotification(driverPubkey:)`
    /// separately after adding (see `AddDriverSheet.addDriver()`).
    public func addDriver(_ driver: FollowedDriver, profile: UserProfileContent? = nil, name: String? = nil) {
        driversRepository?.addDriver(driver)
        if let profile {
            driversRepository?.cacheDriverProfile(pubkey: driver.pubkey, profile: profile)
        } else if let name, !name.isEmpty {
            driversRepository?.cacheDriverName(pubkey: driver.pubkey, name: name)
        }
    }

    /// Remove a driver and republish the updated list.
    public func removeDriver(pubkey: String) {
        driversRepository?.removeDriver(pubkey: pubkey)
        Task {
            await rideCoordinator?.publishFollowedDriversList()
            rideCoordinator?.startLocationSubscriptions()
            rideCoordinator?.startDriverAvailabilitySubscription()
        }
    }

    /// Update the personal note for a driver and republish.
    public func updateDriverNote(pubkey: String, note: String) {
        driversRepository?.updateDriverNote(driverPubkey: pubkey, note: note)
        Task {
            await rideCoordinator?.publishFollowedDriversList()
        }
    }

    /// Clear all cached driver locations and restart location subscriptions.
    /// Also restarts the Kind 30173 availability subscription so the rider's
    /// pull-to-refresh re-pulls active vehicles, not just locations.
    public func refreshDriverLocations() {
        driversRepository?.clearDriverLocations()
        rideCoordinator?.startLocationSubscriptions()
        rideCoordinator?.startDriverAvailabilitySubscription()
    }

    /// Fetch a driver's Kind 0 profile from Nostr. Returns nil if the service
    /// is not yet initialized or the fetch yields no result.
    public func fetchDriverProfile(pubkey: String) async -> UserProfileContent? {
        guard let service = roadflareDomainService else { return nil }
        let profiles = await service.fetchDriverProfiles(pubkeys: [pubkey])
        return profiles[pubkey]?.value
    }

    /// Publish the current followed-drivers list (Kind 30011) to the relay.
    public func publishDriversList() async {
        await rideCoordinator?.publishFollowedDriversList()
    }

    /// Request a fresh share key from a driver. Internal flows (e.g. add-driver
    /// re-handshake) — does not enforce the user-facing rate limit. Best-effort:
    /// publish failures are swallowed because internal callers have no UI to
    /// surface them and the periodic `checkForStaleKeys` sweep will retry.
    public func requestDriverKeyRefresh(driverPubkey: String) async {
        try? await rideCoordinator?.requestKeyRefresh(driverPubkey: driverPubkey)
    }

    /// User-initiated key refresh for a driver whose key is flagged stale.
    ///
    /// Enforces a per-pubkey cooldown (`keyRefreshCooldownSeconds`) so that a
    /// rider hammering the button doesn't spam the driver. Returns
    /// `.rateLimited(retryAt:)` when the cooldown is still active so the
    /// caller can show a precise wait time. Returns `.publishFailed` if no
    /// coordinator is wired (logout/identity-replacement window — the
    /// cooldown is never claimed) or the SDK publish throws (the cooldown
    /// is rolled back); either way the rider can retry immediately.
    /// Otherwise returns `.sent` after the publish lands.
    @discardableResult
    public func requestKeyRefresh(pubkey: String) async -> KeyRefreshOutcome {
        if let last = keyRefreshCooldowns[pubkey] {
            let retryAt = last.addingTimeInterval(Self.keyRefreshCooldownSeconds)
            if Date.now < retryAt {
                return .rateLimited(retryAt: retryAt)
            }
        }
        // Resolve the dispatch closure: in production it's the SDK call, in
        // tests it can be overridden via `keyRefreshSDKHookForTesting` so we
        // can drive both `.sent` and `.publishFailed` paths without standing
        // up a full RideCoordinator. Returns nil when no coordinator is wired
        // (logout/identity-replacement window) — bail before claiming the
        // cooldown slot so the rider can retry immediately rather than burn
        // 60s on a publish that never happened. The optional-chain
        // `try await rideCoordinator?...` would otherwise silently return nil,
        // the catch wouldn't fire, and `.sent` would be returned with the
        // slot claimed.
        guard let dispatch = keyRefreshDispatch() else { return .publishFailed }
        // Claim the slot before awaiting — `sendDriverPing` follows the same
        // eager-claim-then-rollback pattern. Without the eager claim, two
        // rapid taps both pass the cooldown check because the await is a
        // suspension point. Without the rollback, a publish failure would
        // burn 60s with nothing actually sent.
        keyRefreshCooldowns[pubkey] = Date.now
        do {
            try await dispatch(pubkey)
            return .sent
        } catch {
            keyRefreshCooldowns[pubkey] = nil
            AppLogger.auth.info("requestKeyRefresh failed for \(pubkey.prefix(8)): \(error.localizedDescription)")
            return .publishFailed
        }
    }

    private func keyRefreshDispatch() -> ((String) async throws -> Void)? {
        #if DEBUG
        if let hook = keyRefreshSDKHookForTesting { return hook }
        #endif
        guard let coordinator = rideCoordinator else { return nil }
        return { pubkey in try await coordinator.requestKeyRefresh(driverPubkey: pubkey) }
    }

    /// Pubkeys of all followed drivers whose key is currently flagged stale,
    /// returned in deterministic (lexicographic) order. Empty when no
    /// repository has been installed.
    ///
    /// Sorting matters because callers and tests compare arrays directly;
    /// `Set.Iterator` does not guarantee a stable order across reads.
    public var staleKeyDriverPubkeys: [String] {
        guard let repo = driversRepository else { return [] }
        return repo.staleKeyPubkeys.sorted()
    }

    /// Fan-out user-initiated key refresh for every stale-key driver.
    /// Each pubkey goes through the same cooldown as `requestKeyRefresh(pubkey:)`,
    /// so a banner-tap spammer still hits the per-pubkey limit. Returns the
    /// number of `.sent` outcomes for caller-side toast feedback.
    @discardableResult
    public func refreshAllStaleDriverKeys() async -> Int {
        var sentCount = 0
        for pubkey in staleKeyDriverPubkeys {
            if case .sent = await requestKeyRefresh(pubkey: pubkey) {
                sentCount += 1
            }
        }
        return sentCount
    }

    /// Check all followed drivers for stale keys and request refreshes.
    public func checkForStaleDriverKeys() async {
        await rideCoordinator?.checkForStaleKeys()
    }
}

// MARK: - Façade: Ride History

extension AppState {
    /// The rider's completed ride history entries.
    public var rideHistoryEntries: [RideHistoryEntry] {
        rideHistory.rides
    }

    /// Remove a ride history entry by ID and trigger a backup.
    public func removeRideHistoryEntry(id: String) {
        rideHistory.removeRide(id: id)
        rideCoordinator?.backupRideHistory()
    }
}

// MARK: - Façade: Saved Locations

extension AppState {
    /// Favorite saved locations.
    public var favoriteLocations: [SavedLocation] {
        savedLocations.favorites
    }

    /// Recent (non-pinned) saved locations.
    public var recentLocations: [SavedLocation] {
        savedLocations.recents
    }

    /// All saved locations (favorites + recents).
    public var allSavedLocations: [SavedLocation] {
        savedLocations.locations
    }

    /// Save a location to the recent list.
    public func saveLocation(_ location: SavedLocation) {
        savedLocations.save(location)
    }

    /// Save a geocoded location as a recent entry (called after fare calculation).
    ///
    /// Thin wrapper around `SavedLocationsRepository.addRecent` so callers in
    /// the view layer don't have to construct `SavedLocation` directly.
    public func saveGeocodedLocation(latitude: Double, longitude: Double,
                                     displayName: String, addressLine: String) {
        savedLocations.addRecent(
            latitude: latitude, longitude: longitude,
            displayName: displayName, addressLine: addressLine
        )
    }

    /// Pin a recent location as a favorite.
    public func pinLocation(id: String, nickname: String) {
        savedLocations.pin(id: id, nickname: nickname)
    }

    /// Remove a saved location by ID.
    public func removeLocation(id: String) {
        savedLocations.remove(id: id)
    }

    /// Clear all saved locations and publish the profile backup.
    public func clearAllLocations() async {
        savedLocations.clearAll()
        try? await publishProfileBackup()
    }
}

// MARK: - Façade: Settings (read-only badge and display helpers; writes still use appState.settings directly)

extension AppState {
    /// The rider's display name.
    public var profileName: String {
        settings.profileName
    }

    /// The rider's configured payment method count (for settings badge).
    public var paymentMethodCount: Int {
        settings.roadflarePaymentMethods.count
    }

    /// Number of followed drivers (for settings badge).
    public var followedDriverCount: Int {
        driversRepository?.drivers.count ?? 0
    }

    /// Number of pinned (favorite) locations.
    public var favoritesCount: Int {
        savedLocations.favorites.count
    }

    /// Display names for all configured payment methods.
    public var allPaymentMethodNames: [String] {
        settings.allPaymentMethodNames
    }
}

#if DEBUG
extension AppState {
    /// Test seam for unit tests that exercise ping behavior without running full service setup.
    func installDriverPingTestContext(
        keypair: NostrKeypair? = nil,
        relayManager: RelayManager? = nil,
        driversRepository: FollowedDriversRepository? = nil
    ) {
        self.keypair = keypair
        self.relayManager = relayManager
        self.driversRepository = driversRepository
    }

    func primePingCooldownForTesting(driverPubkey: String, lastPing: Date) {
        pingCooldowns[driverPubkey] = lastPing
    }

    func primeKeyRefreshCooldownForTesting(pubkey: String, lastRequest: Date) {
        keyRefreshCooldowns[pubkey] = lastRequest
    }

    /// Test-only override for the SDK call inside `requestKeyRefresh(pubkey:)`.
    /// When set, this closure is invoked with the target pubkey instead of
    /// `rideCoordinator?.requestKeyRefresh(...)`. Lets tests drive the
    /// `.sent` path (closure returns) and the `.publishFailed` path (closure
    /// throws) without wiring a full RideCoordinator.
    func setKeyRefreshSDKHookForTesting(_ hook: ((String) async throws -> Void)?) {
        keyRefreshSDKHookForTesting = hook
    }

    /// Test-only overrides for the onboarding-publish failure surface.
    /// Lets tests substitute the publish call (so dirty stays set without
    /// hitting a relay), drive connectivity, fake the dirty check, and
    /// shorten the watchdog timing so tests run in milliseconds rather
    /// than minutes. Pass `nil` for any parameter to keep the production
    /// behavior; pass a value to override.
    func setOnboardingPublishHooksForTesting(
        publish: ((OnboardingPublishDomain) async throws -> Void)? = nil,
        connectivity: (() async -> Bool)? = nil,
        isDirty: ((OnboardingPublishDomain) -> Bool)? = nil,
        timeout: TimeInterval? = nil,
        rearmInterval: TimeInterval? = nil
    ) {
        onboardingPublishHookForTesting = publish
        onboardingPublishConnectivityHookForTesting = connectivity
        onboardingPublishIsDirtyHookForTesting = isDirty
        onboardingPublishTimeoutOverrideForTesting = timeout
        onboardingPublishRearmOverrideForTesting = rearmInterval
    }

    /// Test seam exposing the post-flush banner-dismissal logic so unit
    /// tests can exercise it without standing up a full RelayManager +
    /// SyncCoordinator.
    func clearOnboardingPublishStatusIfDomainsCleanForTesting() {
        clearOnboardingPublishStatusIfDomainsClean()
    }

    /// Replace the persistence-backed `rideHistory` / `savedLocations` repos so
    /// presentation-façade tests don't mutate `UserDefaults.standard` on the
    /// simulator (which would wipe any saved state from a concurrently-running
    /// instance of the app).
    func installPresentationTestContext(
        rideHistory: RideHistoryRepository? = nil,
        savedLocations: SavedLocationsRepository? = nil
    ) {
        if let rideHistory { self.rideHistory = rideHistory }
        if let savedLocations { self.savedLocations = savedLocations }
    }
}
#endif
