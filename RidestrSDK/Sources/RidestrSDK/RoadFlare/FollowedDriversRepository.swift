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

    /// Persistence delegate (UserDefaults-based or injected for testing).
    private let persistence: FollowedDriversPersistence

    /// Internal lock protecting all mutable state.
    private let lock = NSLock()

    public init(persistence: FollowedDriversPersistence) {
        self.persistence = persistence
        self.drivers = persistence.loadDrivers()
        self.driverNames = persistence.loadDriverNames()
    }

    // MARK: - Driver Management

    /// Add or update a followed driver.
    public func addDriver(_ driver: FollowedDriver) {
        lock.withLock {
            if let index = drivers.firstIndex(where: { $0.pubkey == driver.pubkey }) {
                drivers[index] = driver
            } else {
                drivers.append(driver)
            }
        }
        persistence.saveDrivers(drivers)
    }

    /// Remove a followed driver.
    public func removeDriver(pubkey: String) {
        lock.withLock {
            drivers.removeAll { $0.pubkey == pubkey }
            driverNames.removeValue(forKey: pubkey)
            driverLocations.removeValue(forKey: pubkey)
        }
        persistence.saveDrivers(drivers)
        persistence.saveDriverNames(driverNames)
    }

    /// Update a driver's RoadFlare key (when receiving Kind 3186).
    public func updateDriverKey(driverPubkey: String, roadflareKey: RoadflareKey) {
        lock.withLock {
            guard let index = drivers.firstIndex(where: { $0.pubkey == driverPubkey }) else { return }
            drivers[index].roadflareKey = roadflareKey
        }
        persistence.saveDrivers(drivers)
    }

    /// Update a driver's personal note.
    public func updateDriverNote(driverPubkey: String, note: String) {
        lock.withLock {
            guard let index = drivers.firstIndex(where: { $0.pubkey == driverPubkey }) else { return }
            drivers[index].note = note
        }
        persistence.saveDrivers(drivers)
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
        lock.withLock {
            guard drivers.contains(where: { $0.pubkey == pubkey }) else { return }
            driverNames[pubkey] = name
        }
        persistence.saveDriverNames(driverNames)
    }

    /// Get the cached display name for a driver.
    public func cachedDriverName(pubkey: String) -> String? {
        lock.withLock { driverNames[pubkey] }
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

    /// Get a driver's RoadFlare key for decrypting their location broadcasts.
    public func getRoadflareKey(driverPubkey: String) -> RoadflareKey? {
        getDriver(pubkey: driverPubkey)?.roadflareKey
    }

    // MARK: - Sync

    /// Replace all drivers (for sync restore from Nostr).
    public func replaceAll(drivers: [FollowedDriver]) {
        lock.withLock { self.drivers = drivers }
        persistence.saveDrivers(drivers)
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
        replaceAll(drivers: restored)
    }

    // MARK: - Cleanup

    /// Clear all data (for logout).
    public func clearAll() {
        lock.withLock {
            drivers = []
            driverNames = [:]
            driverLocations = [:]
        }
        persistence.saveDrivers([])
        persistence.saveDriverNames([:])
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
