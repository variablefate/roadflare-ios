import Foundation

/// Owns profile-backup publish state: Android-originated template field that
/// round-trips, plus the republish-on-dirty loop machine that coalesces
/// concurrent publish requests.
///
/// Thread safety: NSLock-protected state. The publish state machine is
/// stricter than the sibling SDK repo pattern — atomic loop-exit and a
/// generation counter protect against (a) the lost-update race between loop
/// exit and `defer`, and (b) `clearAll()` firing while a publish is awaiting,
/// allowing a new session to claim `isPublishing` without conflict. The
/// `settingsTemplate` field matches sibling pattern (last-writer-wins under
/// concurrent writers). `applyRemote` / `buildContent` assume
/// `@MainActor`-serialized callers for multi-step consistency — they snapshot
/// across multiple repos without holding a single lock.
public final class ProfileBackupCoordinator: @unchecked Sendable {
    private let domainService: RoadflareDomainService
    private weak var syncStoreRef: RoadflareSyncStateStore?

    private let lock = NSLock()
    private var _settingsTemplate = SettingsBackupContent()
    private var isPublishing = false
    private var republishRequested = false
    /// Bumped by `clearAll()` to invalidate in-flight publish sessions that
    /// crossed a teardown boundary.
    private var generation: UInt64 = 0

    /// Current template state. Internal visibility — only needed by tests.
    /// External callers mutate via `preserveSettingsTemplate` and read via
    /// `buildContent`.
    var settingsTemplate: SettingsBackupContent {
        lock.withLock { _settingsTemplate }
    }

    public init(domainService: RoadflareDomainService, syncStore: RoadflareSyncStateStore) {
        self.domainService = domainService
        self.syncStoreRef = syncStore
    }

    // MARK: - Template

    /// Preserve Android-originated template fields to round-trip on next publish.
    public func preserveSettingsTemplate(_ template: SettingsBackupContent) {
        lock.withLock { _settingsTemplate = template }
    }

    // MARK: - Apply Remote

    /// Apply a remote backup: update template, restore payment methods via the
    /// settings repo, restore saved locations. Caller provides repos.
    public func applyRemote(
        _ backup: ProfileBackupContent,
        settings: UserSettingsRepository,
        savedLocations: SavedLocationsRepository
    ) {
        preserveSettingsTemplate(backup.settings)
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
            RidestrLogger.info("[ProfileBackupCoordinator] Restored \(backup.savedLocations.count) saved locations")
        }
    }

    // MARK: - Build Content

    /// Build `ProfileBackupContent` from local state merged with the preserved
    /// template. Android-originated fields round-trip untouched.
    public func buildContent(
        settings: UserSettingsRepository,
        savedLocations: SavedLocationsRepository
    ) -> ProfileBackupContent {
        var settingsBackup = lock.withLock { _settingsTemplate }
        settingsBackup.roadflarePaymentMethods = settings.roadflarePaymentMethods
        return ProfileBackupContent(
            savedLocations: savedLocations.locations.map { loc in
                SavedLocationBackup(
                    displayName: loc.displayName,
                    lat: loc.latitude,
                    lon: loc.longitude,
                    addressLine: loc.addressLine,
                    isPinned: loc.isPinned,
                    nickname: loc.nickname,
                    timestampMs: loc.timestampMs
                )
            },
            settings: settingsBackup
        )
    }

    // MARK: - Publish

    /// Publish with republish-on-dirty loop: if state changes during publish,
    /// republish with fresh content before returning.
    ///
    /// Correctness notes:
    /// - Loop exit is atomic: "keep looping" vs "release isPublishing" happens
    ///   in a single lock critical section.
    /// - Generation counter invalidates sessions that crossed a `clearAll()`
    ///   boundary: if `clearAll()` fired mid-await, our entry generation no
    ///   longer matches, and we exit WITHOUT touching shared state (a new
    ///   publish session may own it) and WITHOUT calling `markPublished`
    ///   (identity has changed).
    /// - Error semantic (ADR-0017): rethrows the *terminal* iteration's error
    ///   if and only if no successful publish landed during the call window.
    ///   A coalesced republish that succeeds rescues an earlier failed
    ///   iteration — the call returns without throw. Coalesced calls (the
    ///   ones that hit the `shouldQueue` short-circuit) never throw; they
    ///   have no awaitable publish of their own to fail. A session
    ///   invalidated by `clearAll()` returns without throw — the caller's
    ///   identity has been replaced and the error is meaningless.
    public func publishAndMark(
        settings: UserSettingsRepository,
        savedLocations: SavedLocationsRepository
    ) async throws {
        var entryGeneration: UInt64 = 0
        let shouldQueue: Bool = lock.withLock {
            if isPublishing {
                republishRequested = true
                return true
            }
            isPublishing = true
            republishRequested = false
            entryGeneration = generation
            return false
        }
        guard !shouldQueue else { return }

        var lastIterationError: (any Error)?
        while true {
            let content = buildContent(settings: settings, savedLocations: savedLocations)
            do {
                let event = try await domainService.publishProfileBackup(content)
                let stillValid: Bool = lock.withLock { generation == entryGeneration }
                if stillValid {
                    syncStoreRef?.markPublished(.profileBackup, at: event.createdAt)
                    RidestrLogger.info("[ProfileBackupCoordinator] Published profile backup")
                }
                lastIterationError = nil
            } catch {
                RidestrLogger.info("[ProfileBackupCoordinator] Failed to publish profile backup: \(error.localizedDescription)")
                lastIterationError = error
            }

            // Atomic exit: either continue with a fresh iteration (consuming
            // the republish request) OR release isPublishing. If generation
            // changed, bail without touching shared state.
            let shouldContinue: Bool = lock.withLock {
                guard generation == entryGeneration else { return false }
                if republishRequested {
                    republishRequested = false
                    return true
                }
                isPublishing = false
                return false
            }
            if !shouldContinue {
                if let error = lastIterationError,
                   lock.withLock({ generation == entryGeneration }) {
                    throw error
                }
                return
            }
        }
    }

    // MARK: - Cleanup

    /// Reset all state (identity replacement). Bumps `generation` to invalidate
    /// any in-flight `publishAndMark` session whose await is still pending.
    public func clearAll() {
        lock.withLock {
            _settingsTemplate = SettingsBackupContent()
            isPublishing = false
            republishRequested = false
            generation &+= 1
        }
    }
}
