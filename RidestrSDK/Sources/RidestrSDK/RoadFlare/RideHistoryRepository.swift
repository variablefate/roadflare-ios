import Foundation

/// Manages the rider's ride history.
///
/// Stores rides locally via a persistence delegate and syncs to Nostr via Kind 30174.
///
/// Thread safety: All mutations are protected by an internal lock. Safe to call from
/// any thread, including concurrent background tasks processing relay events.
@Observable
public final class RideHistoryRepository: @unchecked Sendable {
    /// All rides, newest first.
    public private(set) var rides: [RideHistoryEntry] = []

    /// Persistence delegate (UserDefaults-based or injected for testing).
    private let persistence: RideHistoryPersistence

    /// Internal lock protecting all mutable state.
    private let lock = NSLock()

    /// Called after ride-list mutations so app code can persist sync metadata.
    public var onRidesChanged: (@Sendable () -> Void)?

    public init(persistence: RideHistoryPersistence) {
        self.persistence = persistence
        self.rides = persistence.loadRides()
    }

    // MARK: - Ride Management

    /// Add a completed or cancelled ride to history.
    public func addRide(_ entry: RideHistoryEntry) {
        var snapshot: [RideHistoryEntry]?
        lock.withLock {
            guard !rides.contains(where: { $0.id == entry.id }) else { return }
            rides.insert(entry, at: 0)
            if rides.count > StorageConstants.maxRideHistory {
                rides = Array(rides.prefix(StorageConstants.maxRideHistory))
            }
            snapshot = rides
        }
        guard let snapshot else { return }
        persistence.saveRides(snapshot)
        onRidesChanged?()
    }

    /// Remove a ride from history.
    public func removeRide(id: String) {
        var snapshot: [RideHistoryEntry]?
        lock.withLock {
            rides.removeAll { $0.id == id }
            snapshot = rides
        }
        guard let snapshot else { return }
        persistence.saveRides(snapshot)
        onRidesChanged?()
    }

    // MARK: - Sync

    /// Merge rides from a Nostr backup. Adds entries not already present locally.
    /// Returns true if any new rides were added.
    @discardableResult
    public func mergeFromBackup(_ incoming: [RideHistoryEntry]) -> Bool {
        var snapshot: [RideHistoryEntry]?
        var didMerge = false
        lock.withLock {
            let existingIds = Set(rides.map(\.id))
            let newRides = incoming.filter { !existingIds.contains($0.id) }
            guard !newRides.isEmpty else { didMerge = false; return }
            rides = (rides + newRides)
                .sorted { $0.date > $1.date }
                .prefix(StorageConstants.maxRideHistory)
                .map { $0 }
            snapshot = rides
            didMerge = true
        }
        if let snapshot {
            persistence.saveRides(snapshot)
            onRidesChanged?()
        }
        return didMerge
    }

    /// Replace all rides with a Nostr backup (full restore on new device).
    public func restoreFromBackup(_ incoming: [RideHistoryEntry]) {
        let snapshot: [RideHistoryEntry] = lock.withLock {
            rides = incoming
                .sorted { $0.date > $1.date }
                .prefix(StorageConstants.maxRideHistory)
                .map { $0 }
            return rides
        }
        persistence.saveRides(snapshot)
        onRidesChanged?()
    }

    // MARK: - Cleanup

    /// Clear all ride history.
    public func clearAll() {
        lock.withLock { rides = [] }
        persistence.saveRides([])
        onRidesChanged?()
    }
}

// MARK: - Persistence Protocol

/// Abstraction for ride history storage. Inject for testability.
public protocol RideHistoryPersistence: Sendable {
    func loadRides() -> [RideHistoryEntry]
    func saveRides(_ rides: [RideHistoryEntry])
}

/// In-memory persistence for testing.
public final class InMemoryRideHistoryPersistence: RideHistoryPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRides: [RideHistoryEntry] = []

    public init() {}

    public func loadRides() -> [RideHistoryEntry] {
        lock.withLock { storedRides }
    }

    public func saveRides(_ rides: [RideHistoryEntry]) {
        lock.withLock { storedRides = rides }
    }
}
