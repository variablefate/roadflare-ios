import Foundation

/// Manages saved locations (favorites, recents) for the rider.
///
/// Stores locations locally via a persistence delegate and syncs to Nostr
/// via Kind 30177 (profile backup). Favorites are pinned locations with nicknames.
/// Recents are auto-saved pickup/destination addresses.
///
/// Thread safety: All mutations are protected by an internal lock. Safe to call from
/// any thread, including concurrent background tasks processing sync events.
@Observable
public final class SavedLocationsRepository: @unchecked Sendable {
    /// All saved locations (favorites + recents).
    public private(set) var locations: [SavedLocation] = []

    /// Persistence delegate (UserDefaults-based or injected for testing).
    private let persistence: SavedLocationsPersistence

    /// Internal lock protecting all mutable state.
    private let lock = NSLock()

    /// Suppresses change notifications during sync restore.
    private var suppressChangeNotifications = false

    /// Called after location mutations so app code can persist sync metadata.
    public var onChange: (@Sendable () -> Void)?

    /// Called when the set of pinned favorites changes (add/remove/rename).
    public var onFavoritesChanged: (@Sendable () -> Void)?

    public init(persistence: SavedLocationsPersistence) {
        self.persistence = persistence
        self.locations = persistence.loadLocations()
    }

    // MARK: - Computed Properties

    /// Pinned favorites (Home, Work, etc.).
    public var favorites: [SavedLocation] {
        lock.withLock { locations.filter(\.isPinned) }
    }

    /// Recent (non-pinned) locations, newest first. Excludes locations near any favorite.
    public var recents: [SavedLocation] {
        lock.withLock {
            let favs = locations.filter(\.isPinned)
            return locations.filter { loc in
                guard !loc.isPinned else { return false }
                return !favs.contains { fav in
                    let dist = sqrt(pow(fav.latitude - loc.latitude, 2) + pow(fav.longitude - loc.longitude, 2)) * 111_000
                    return dist < StorageConstants.duplicateLocationThresholdMeters
                }
            }
            .sorted { $0.timestampMs > $1.timestampMs }
        }
    }

    // MARK: - Mutations

    /// Suppress change notifications during a block (used during sync restore).
    public func performWithoutChangeTracking(_ updates: () -> Void) {
        let previous = suppressChangeNotifications
        suppressChangeNotifications = true
        updates()
        suppressChangeNotifications = previous
    }

    /// Add or update a saved location. Deduplicates by proximity (~50m).
    public func save(_ location: SavedLocation) {
        let previousFavorites = favoriteSignaturesLocked()
        lock.withLock {
            if let existingIndex = locations.firstIndex(where: { existing in
                let dist = sqrt(
                    pow(existing.latitude - location.latitude, 2) +
                    pow(existing.longitude - location.longitude, 2)
                ) * 111_000
                return dist < StorageConstants.duplicateLocationThresholdMeters
                    && existing.isPinned == location.isPinned
            }) {
                locations[existingIndex] = location
            } else {
                locations.append(location)
            }
            enforceMaxRecentsLocked()
        }
        persistAndNotify(previousFavorites: previousFavorites)
    }

    /// Add a recent location (convenience for ride completions).
    public func addRecent(latitude: Double, longitude: Double, displayName: String, addressLine: String) {
        save(SavedLocation(
            latitude: latitude, longitude: longitude,
            displayName: displayName, addressLine: addressLine,
            isPinned: false
        ))
    }

    /// Pin a location as a favorite with a nickname.
    public func pin(id: String, nickname: String) {
        let previousFavorites = favoriteSignaturesLocked()
        lock.withLock {
            guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
            locations[index].isPinned = true
            locations[index].nickname = nickname
        }
        persistAndNotify(previousFavorites: previousFavorites)
    }

    /// Unpin a favorite back to recents.
    public func unpin(id: String) {
        let previousFavorites = favoriteSignaturesLocked()
        lock.withLock {
            guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
            locations[index].isPinned = false
            locations[index].nickname = nil
        }
        persistAndNotify(previousFavorites: previousFavorites)
    }

    /// Remove a location.
    public func remove(id: String) {
        let previousFavorites = favoriteSignaturesLocked()
        lock.withLock {
            locations.removeAll { $0.id == id }
        }
        persistAndNotify(previousFavorites: previousFavorites)
    }

    // MARK: - Sync

    /// Replace all locations with a Nostr backup (full restore).
    public func restoreFromBackup(_ incoming: [SavedLocation]) {
        let previousFavorites = favoriteSignaturesLocked()
        lock.withLock {
            locations = incoming
        }
        persistAndNotify(previousFavorites: previousFavorites)
    }

    // MARK: - Cleanup

    /// Clear all locations.
    public func clearAll() {
        let previousFavorites = favoriteSignaturesLocked()
        lock.withLock { locations = [] }
        persistence.saveLocations([])
        notifyChanged()
        notifyFavoritesChangedIfNeeded(previousFavorites)
    }

    // MARK: - Private Helpers

    private func enforceMaxRecentsLocked() {
        let pinnedCount = locations.filter(\.isPinned).count
        let recentCount = locations.count - pinnedCount
        if recentCount > StorageConstants.maxRecentLocations {
            let sortedRecents = locations.filter { !$0.isPinned }
                .sorted { $0.timestampMs > $1.timestampMs }
            let toKeep = Set(sortedRecents.prefix(StorageConstants.maxRecentLocations).map(\.id))
            locations.removeAll { !$0.isPinned && !toKeep.contains($0.id) }
        }
    }

    private func persistAndNotify(previousFavorites: [FavoriteSignature]) {
        let snapshot = lock.withLock { locations }
        persistence.saveLocations(snapshot)
        notifyChanged()
        notifyFavoritesChangedIfNeeded(previousFavorites)
    }

    private func notifyChanged() {
        guard !suppressChangeNotifications else { return }
        onChange?()
    }

    private func notifyFavoritesChangedIfNeeded(_ previousFavorites: [FavoriteSignature]) {
        guard !suppressChangeNotifications else { return }
        guard previousFavorites != favoriteSignaturesLocked() else { return }
        onFavoritesChanged?()
    }

    private func favoriteSignaturesLocked() -> [FavoriteSignature] {
        lock.withLock {
            locations
                .filter(\.isPinned)
                .map {
                    FavoriteSignature(
                        id: $0.id, latitude: $0.latitude, longitude: $0.longitude,
                        displayName: $0.displayName, addressLine: $0.addressLine,
                        nickname: $0.nickname, timestampMs: $0.timestampMs
                    )
                }
                .sorted { $0.id < $1.id }
        }
    }
}

private struct FavoriteSignature: Equatable {
    let id: String
    let latitude: Double
    let longitude: Double
    let displayName: String
    let addressLine: String
    let nickname: String?
    let timestampMs: Int
}

// MARK: - Persistence Protocol

/// Abstraction for saved locations storage. Inject for testability.
public protocol SavedLocationsPersistence: Sendable {
    func loadLocations() -> [SavedLocation]
    func saveLocations(_ locations: [SavedLocation])
}

/// In-memory persistence for testing.
public final class InMemorySavedLocationsPersistence: SavedLocationsPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var storedLocations: [SavedLocation] = []

    public init() {}

    public func loadLocations() -> [SavedLocation] {
        lock.withLock { storedLocations }
    }

    public func saveLocations(_ locations: [SavedLocation]) {
        lock.withLock { storedLocations = locations }
    }
}
