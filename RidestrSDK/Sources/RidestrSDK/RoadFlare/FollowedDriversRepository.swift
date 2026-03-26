import Foundation

/// Manages the rider's list of followed (trusted) drivers.
///
/// Stores drivers locally via a persistence delegate and syncs to Nostr via Kind 30011.
/// Driver locations are cached in-memory only (ephemeral 5-min broadcast data).
///
/// Thread safety: All mutations are protected by an internal lock. Safe to call from
/// any thread, including concurrent background tasks processing relay events.
@Observable
public final class FollowedDriversRepository: @unchecked Sendable {
    /// All followed drivers.
    public private(set) var drivers: [FollowedDriver] = []

    /// Cached driver display names (from Nostr profile lookups).
    public private(set) var driverNames: [String: String] = [:]

    /// In-memory driver location cache (from Kind 30014 decryption).
    public private(set) var driverLocations: [String: CachedDriverLocation] = [:]

    /// In-memory driver profile cache (from Kind 0 fetches). Not persisted.
    public private(set) var driverProfiles: [String: UserProfileContent] = [:]

    /// Drivers with stale keys (detected via Kind 30012 comparison). In-memory only.
    public private(set) var staleKeyPubkeys: Set<String> = []

    /// Persistence delegate (UserDefaults-based or injected for testing).
    private let persistence: FollowedDriversPersistence

    /// Internal lock protecting all mutable state.
    private let lock = NSLock()

    /// Called after driver-list mutations so app code can persist sync metadata.
    public var onDriversChanged: (@Sendable (FollowedDriversMutationSource) -> Void)?

    public init(persistence: FollowedDriversPersistence) {
        self.persistence = persistence
        self.drivers = persistence.loadDrivers()
        self.driverNames = persistence.loadDriverNames()
    }

    // MARK: - Driver Management

    /// Add or update a followed driver.
    public func addDriver(_ driver: FollowedDriver, source: FollowedDriversMutationSource = .local) {
        var snapshot = drivers
        lock.withLock {
            if let index = drivers.firstIndex(where: { $0.pubkey == driver.pubkey }) {
                let existing = drivers[index]
                let merged = mergeForLocalMutation(existing: existing, incoming: driver)
                drivers[index] = merged
                if shouldClearStaleFlag(existing: existing.roadflareKey, merged: merged.roadflareKey) {
                    staleKeyPubkeys.remove(existing.pubkey)
                }
            } else {
                drivers.append(driver)
            }
            snapshot = drivers
        }
        persistence.saveDrivers(snapshot)
        onDriversChanged?(source)
    }

    /// Remove a followed driver.
    public func removeDriver(pubkey: String, source: FollowedDriversMutationSource = .local) {
        var driversSnapshot = drivers
        var namesSnapshot = driverNames
        lock.withLock {
            drivers.removeAll { $0.pubkey == pubkey }
            driverNames.removeValue(forKey: pubkey)
            driverLocations.removeValue(forKey: pubkey)
            driverProfiles.removeValue(forKey: pubkey)
            staleKeyPubkeys.remove(pubkey)
            driversSnapshot = drivers
            namesSnapshot = driverNames
        }
        persistence.saveDrivers(driversSnapshot)
        persistence.saveDriverNames(namesSnapshot)
        onDriversChanged?(source)
    }

    /// Update a driver's RoadFlare key (when receiving Kind 3186).
    public func updateDriverKey(
        driverPubkey: String,
        roadflareKey: RoadflareKey,
        source: FollowedDriversMutationSource = .local
    ) -> DriverKeyUpdateOutcome {
        var snapshot: [FollowedDriver]?
        var outcome: DriverKeyUpdateOutcome = .unknownDriver
        lock.withLock {
            guard let index = drivers.firstIndex(where: { $0.pubkey == driverPubkey }) else { return }
            let existingKey = drivers[index].roadflareKey
            outcome = compareKeyUpdate(existing: existingKey, incoming: roadflareKey)
            guard outcome.shouldPersist else { return }
            drivers[index].roadflareKey = roadflareKey
            staleKeyPubkeys.remove(driverPubkey)
            snapshot = drivers
        }
        guard let snapshot else { return outcome }
        persistence.saveDrivers(snapshot)
        onDriversChanged?(source)
        return outcome
    }

    public func currentKeyUpdateOutcome(
        driverPubkey: String,
        incoming roadflareKey: RoadflareKey
    ) -> DriverKeyUpdateOutcome {
        lock.withLock {
            guard let existing = drivers.first(where: { $0.pubkey == driverPubkey }) else {
                return .unknownDriver
            }
            return compareKeyUpdate(existing: existing.roadflareKey, incoming: roadflareKey)
        }
    }

    /// Update a driver's personal note.
    public func updateDriverNote(
        driverPubkey: String,
        note: String,
        source: FollowedDriversMutationSource = .local
    ) {
        var snapshot: [FollowedDriver]?
        lock.withLock {
            guard let index = drivers.firstIndex(where: { $0.pubkey == driverPubkey }) else { return }
            drivers[index].note = note
            snapshot = drivers
        }
        guard let snapshot else { return }
        persistence.saveDrivers(snapshot)
        onDriversChanged?(source)
    }

    /// Get a specific driver by pubkey.
    public func getDriver(pubkey: String) -> FollowedDriver? {
        lock.withLock { drivers.first { $0.pubkey == pubkey } }
    }

    /// All followed driver pubkeys.
    public var allPubkeys: [String] {
        lock.withLock { drivers.map(\.pubkey) }
    }

    /// Whether a driver is followed.
    public func isFollowing(pubkey: String) -> Bool {
        lock.withLock { drivers.contains { $0.pubkey == pubkey } }
    }

    /// Whether there are any followed drivers.
    public var hasDrivers: Bool { lock.withLock { !drivers.isEmpty } }

    // MARK: - Driver Names

    /// Cache a driver's display name from their Nostr profile.
    public func cacheDriverName(pubkey: String, name: String) {
        var snapshot: [String: String]?
        lock.withLock {
            guard drivers.contains(where: { $0.pubkey == pubkey }) else { return }
            driverNames[pubkey] = name
            snapshot = driverNames
        }
        guard let snapshot else { return }
        persistence.saveDriverNames(snapshot)
    }

    /// Get the cached display name for a driver.
    public func cachedDriverName(pubkey: String) -> String? {
        lock.withLock { driverNames[pubkey] }
    }

    /// Cache a driver's full profile from their Kind 0 event.
    public func cacheDriverProfile(pubkey: String, profile: UserProfileContent) {
        var snapshot: [String: String]?
        lock.withLock {
            guard drivers.contains(where: { $0.pubkey == pubkey }) else { return }
            driverProfiles[pubkey] = profile
            // Also update the name cache
            if let name = profile.displayName ?? profile.name, !name.isEmpty {
                driverNames[pubkey] = name
            }
            snapshot = driverNames
        }
        guard let snapshot else { return }
        persistence.saveDriverNames(snapshot)
    }

    /// Get the cached profile for a driver.
    public func cachedDriverProfile(pubkey: String) -> UserProfileContent? {
        lock.withLock { driverProfiles[pubkey] }
    }

    // MARK: - Driver Locations (in-memory only)

    /// Update a driver's cached location from a decrypted Kind 30014 broadcast.
    /// Returns false if the event is stale (older than current cached location).
    @discardableResult
    public func updateDriverLocation(
        pubkey: String,
        latitude: Double,
        longitude: Double,
        status: String,
        timestamp: Int,
        keyVersion: Int
    ) -> Bool {
        lock.withLock {
            if let existing = driverLocations[pubkey], existing.timestamp >= timestamp {
                return false
            }
            driverLocations[pubkey] = CachedDriverLocation(
                latitude: latitude, longitude: longitude,
                status: status, timestamp: timestamp, keyVersion: keyVersion
            )
            return true
        }
    }

    /// Remove a driver's cached location.
    public func removeDriverLocation(pubkey: String) {
        lock.withLock { _ = driverLocations.removeValue(forKey: pubkey) }
    }

    /// Clear all cached locations.
    public func clearDriverLocations() {
        lock.withLock { driverLocations.removeAll() }
    }

    /// Mark a driver's key as stale (needs refresh from driver).
    public func markKeyStale(pubkey: String) {
        _ = lock.withLock { staleKeyPubkeys.insert(pubkey) }
    }

    /// Clear the stale key flag for a driver (key was refreshed).
    public func clearKeyStale(pubkey: String) {
        _ = lock.withLock { staleKeyPubkeys.remove(pubkey) }
    }

    /// Get a driver's RoadFlare key for decrypting their location broadcasts.
    public func getRoadflareKey(driverPubkey: String) -> RoadflareKey? {
        getDriver(pubkey: driverPubkey)?.roadflareKey
    }

    // MARK: - Sync

    /// Replace all drivers (for sync restore from Nostr).
    public func replaceAll(
        drivers: [FollowedDriver],
        source: FollowedDriversMutationSource = .sync
    ) {
        var driversSnapshot = self.drivers
        var namesSnapshot = driverNames
        lock.withLock {
            let existingByPubkey = Dictionary(
                self.drivers.map { ($0.pubkey, $0) },
                uniquingKeysWith: { _, new in new }
            )
            var seenPubkeys: Set<String> = []
            let newDrivers = drivers.compactMap { incoming -> FollowedDriver? in
                guard seenPubkeys.insert(incoming.pubkey).inserted else { return nil }
                if let existing = existingByPubkey[incoming.pubkey] {
                    let merged = mergeForSyncRestore(existing: existing, incoming: incoming)
                    if shouldClearStaleFlag(existing: existing.roadflareKey, merged: merged.roadflareKey) {
                        staleKeyPubkeys.remove(existing.pubkey)
                    }
                    return merged
                }
                return incoming
            }
            let removedPubkeys = Set(self.drivers.map(\.pubkey)).subtracting(Set(newDrivers.map(\.pubkey)))
            self.drivers = newDrivers
            reconcileRemovedDriversLocked(pubkeys: removedPubkeys)
            driversSnapshot = self.drivers
            namesSnapshot = self.driverNames
        }
        persistence.saveDrivers(driversSnapshot)
        persistence.saveDriverNames(namesSnapshot)
        onDriversChanged?(source)
    }

    /// Build FollowedDriver entries from a parsed Kind 30011 content.
    public func restoreFromNostr(content: FollowedDriversContent) {
        let restored = content.drivers.map { entry in
            FollowedDriver(
                pubkey: entry.pubkey,
                addedAt: entry.addedAt,
                note: entry.note,
                roadflareKey: entry.roadflareKey
            )
        }
        replaceAll(drivers: restored, source: .sync)
    }

    // MARK: - Cleanup

    /// Clear all data (for logout).
    public func clearAll(source: FollowedDriversMutationSource = .reset) {
        var driversSnapshot: [FollowedDriver] = []
        var namesSnapshot: [String: String] = [:]
        lock.withLock {
            drivers = []
            driverNames = [:]
            driverLocations = [:]
            driverProfiles = [:]
            staleKeyPubkeys = []
            driversSnapshot = drivers
            namesSnapshot = driverNames
        }
        persistence.saveDrivers(driversSnapshot)
        persistence.saveDriverNames(namesSnapshot)
        onDriversChanged?(source)
    }

    // MARK: - Merge Helpers

    private func mergeForLocalMutation(existing: FollowedDriver, incoming: FollowedDriver) -> FollowedDriver {
        FollowedDriver(
            pubkey: existing.pubkey,
            addedAt: existing.addedAt,
            name: resolveStringReplacement(existing: existing.name, incoming: incoming.name),
            note: resolveStringReplacement(existing: existing.note, incoming: incoming.note),
            roadflareKey: resolveRoadflareKeyReplacement(
                existing: existing.roadflareKey,
                incoming: incoming.roadflareKey
            )
        )
    }

    private func mergeForSyncRestore(existing: FollowedDriver, incoming: FollowedDriver) -> FollowedDriver {
        FollowedDriver(
            pubkey: incoming.pubkey,
            addedAt: incoming.addedAt,
            name: resolveStringReplacement(existing: existing.name, incoming: incoming.name),
            note: normalizeOptionalString(incoming.note),
            roadflareKey: resolveRoadflareKeyReplacement(
                existing: existing.roadflareKey,
                incoming: incoming.roadflareKey
            )
        )
    }

    private func resolveStringReplacement(existing: String?, incoming: String?) -> String? {
        if let normalized = normalizeOptionalString(incoming) { return normalized }
        return existing
    }

    private func normalizeOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolveRoadflareKeyReplacement(
        existing: RoadflareKey?,
        incoming: RoadflareKey?
    ) -> RoadflareKey? {
        guard let incoming else { return existing }
        guard let existing else { return incoming }
        if incoming.version != existing.version {
            return incoming.version > existing.version ? incoming : existing
        }
        switch (incoming.keyUpdatedAt, existing.keyUpdatedAt) {
        case let (incomingUpdatedAt?, existingUpdatedAt?):
            return incomingUpdatedAt > existingUpdatedAt ? incoming : existing
        case (.some, nil):
            return incoming
        case (nil, .some):
            return existing
        case (nil, nil):
            return existing
        }
    }

    private func shouldClearStaleFlag(existing: RoadflareKey?, merged: RoadflareKey?) -> Bool {
        guard let merged else { return false }
        guard let existing else { return true }
        if merged.publicKeyHex != existing.publicKeyHex || merged.version != existing.version {
            return true
        }
        return (merged.keyUpdatedAt ?? 0) > (existing.keyUpdatedAt ?? 0)
    }

    private func reconcileRemovedDriversLocked(pubkeys: Set<String>) {
        guard !pubkeys.isEmpty else { return }
        for pubkey in pubkeys {
            driverNames.removeValue(forKey: pubkey)
            driverLocations.removeValue(forKey: pubkey)
            driverProfiles.removeValue(forKey: pubkey)
            staleKeyPubkeys.remove(pubkey)
        }
    }

    private func compareKeyUpdate(existing: RoadflareKey?, incoming: RoadflareKey) -> DriverKeyUpdateOutcome {
        guard let existing else { return .appliedNewer }
        if incoming == existing { return .duplicateCurrent }

        let incomingUpdatedAt = incoming.keyUpdatedAt ?? 0
        let existingUpdatedAt = existing.keyUpdatedAt ?? 0
        if incomingUpdatedAt != existingUpdatedAt {
            return incomingUpdatedAt > existingUpdatedAt ? .appliedNewer : .ignoredOlder
        }
        if incoming.version != existing.version {
            return incoming.version > existing.version ? .appliedNewer : .ignoredOlder
        }
        return .ignoredOlder
    }
}

/// Origin of a followed-driver repository mutation.
public enum FollowedDriversMutationSource: Sendable {
    case local
    case sync
    case reset
}

public enum DriverKeyUpdateOutcome: Sendable, Equatable {
    case appliedNewer
    case duplicateCurrent
    case ignoredOlder
    case unknownDriver

    var shouldPersist: Bool {
        switch self {
        case .appliedNewer:
            return true
        case .duplicateCurrent, .ignoredOlder, .unknownDriver:
            return false
        }
    }
}

// MARK: - Cached Location

/// In-memory cached driver location from RoadFlare broadcasts.
public struct CachedDriverLocation: Sendable {
    public let latitude: Double
    public let longitude: Double
    public let status: String
    public let timestamp: Int
    public let keyVersion: Int
}

// MARK: - Persistence Protocol

/// Abstraction for followed drivers storage. Inject for testability.
public protocol FollowedDriversPersistence: Sendable {
    func loadDrivers() -> [FollowedDriver]
    func saveDrivers(_ drivers: [FollowedDriver])
    func loadDriverNames() -> [String: String]
    func saveDriverNames(_ names: [String: String])
}

/// In-memory persistence for testing.
public final class InMemoryFollowedDriversPersistence: FollowedDriversPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDrivers: [FollowedDriver] = []
    private var storedNames: [String: String] = [:]

    public init() {}

    public func loadDrivers() -> [FollowedDriver] {
        lock.withLock { storedDrivers }
    }

    public func saveDrivers(_ drivers: [FollowedDriver]) {
        lock.withLock { storedDrivers = drivers }
    }

    public func loadDriverNames() -> [String: String] {
        lock.withLock { storedNames }
    }

    public func saveDriverNames(_ names: [String: String]) {
        lock.withLock { storedNames = names }
    }
}
