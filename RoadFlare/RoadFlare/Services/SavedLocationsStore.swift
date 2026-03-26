import Foundation
import RidestrSDK

/// Manages saved locations (Home, Work, favorites, recents).
@Observable @MainActor
final class SavedLocationsStore {
    private static let key = "roadflare_saved_locations"
    private let defaults: UserDefaults
    private var suppressChangeNotifications = false

    var locations: [SavedLocation] = []
    var onChange: (@MainActor () -> Void)?
    var onFavoritesChanged: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.locations = Self.load(from: defaults)
    }

    /// Pinned favorites (Home, Work, etc.).
    var favorites: [SavedLocation] {
        locations.filter(\.isPinned)
    }

    /// Recent (non-pinned) locations, newest first. Excludes locations near any favorite.
    var recents: [SavedLocation] {
        let favs = favorites
        return locations.filter { loc in
            guard !loc.isPinned else { return false }
            // Exclude if within 50m of any favorite
            return !favs.contains { fav in
                let dist = sqrt(pow(fav.latitude - loc.latitude, 2) + pow(fav.longitude - loc.longitude, 2)) * 111_000
                return dist < StorageConstants.duplicateLocationThresholdMeters
            }
        }
        .sorted { $0.timestampMs > $1.timestampMs }
    }

    func performWithoutChangeTracking(_ updates: () -> Void) {
        let previous = suppressChangeNotifications
        suppressChangeNotifications = true
        updates()
        suppressChangeNotifications = previous
    }

    /// Add or update a saved location.
    func save(_ location: SavedLocation) {
        let previousFavorites = favoriteSignatures()

        // Check for duplicate within 50m
        if let existingIndex = locations.firstIndex(where: { existing in
            let dist = sqrt(
                pow(existing.latitude - location.latitude, 2) +
                pow(existing.longitude - location.longitude, 2)
            ) * 111_000  // Rough meters per degree
            return dist < StorageConstants.duplicateLocationThresholdMeters
                && existing.isPinned == location.isPinned
        }) {
            // Update existing
            locations[existingIndex] = location
        } else {
            locations.append(location)
        }

        // Enforce max recents
        let pinnedCount = locations.filter(\.isPinned).count
        let recentCount = locations.count - pinnedCount
        if recentCount > StorageConstants.maxRecentLocations {
            let sortedRecents = locations.filter { !$0.isPinned }
                .sorted { $0.timestampMs > $1.timestampMs }
            let toKeep = Set(sortedRecents.prefix(StorageConstants.maxRecentLocations).map(\.id))
            locations.removeAll { !$0.isPinned && !toKeep.contains($0.id) }
        }

        persist()
        notifyChanged()
        notifyFavoritesChangedIfNeeded(previousFavorites)
    }

    /// Add a recent location (convenience for ride completions).
    func addRecent(latitude: Double, longitude: Double, displayName: String, addressLine: String) {
        let loc = SavedLocation(
            latitude: latitude, longitude: longitude,
            displayName: displayName, addressLine: addressLine,
            isPinned: false
        )
        save(loc)
    }

    /// Pin a location as a favorite with a nickname.
    func pin(id: String, nickname: String) {
        let previousFavorites = favoriteSignatures()
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
        locations[index].isPinned = true
        locations[index].nickname = nickname
        persist()
        notifyChanged()
        notifyFavoritesChangedIfNeeded(previousFavorites)
    }

    /// Unpin a favorite back to recents.
    func unpin(id: String) {
        let previousFavorites = favoriteSignatures()
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
        locations[index].isPinned = false
        locations[index].nickname = nil
        persist()
        notifyChanged()
        notifyFavoritesChangedIfNeeded(previousFavorites)
    }

    /// Remove a location.
    func remove(id: String) {
        let previousFavorites = favoriteSignatures()
        locations.removeAll { $0.id == id }
        persist()
        notifyChanged()
        notifyFavoritesChangedIfNeeded(previousFavorites)
    }

    /// Clear all locations.
    func clearAll() {
        let previousFavorites = favoriteSignatures()
        locations = []
        defaults.removeObject(forKey: Self.key)
        notifyChanged()
        notifyFavoritesChangedIfNeeded(previousFavorites)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(locations) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private static func load(from defaults: UserDefaults) -> [SavedLocation] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([SavedLocation].self, from: data)) ?? []
    }

    private func notifyChanged() {
        guard !suppressChangeNotifications else { return }
        onChange?()
    }

    private func notifyFavoritesChangedIfNeeded(_ previousFavorites: [FavoriteSignature]) {
        guard !suppressChangeNotifications else { return }
        guard previousFavorites != favoriteSignatures() else { return }
        onFavoritesChanged?()
    }

    private func favoriteSignatures() -> [FavoriteSignature] {
        locations
            .filter(\.isPinned)
            .map {
                FavoriteSignature(
                    id: $0.id,
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    displayName: $0.displayName,
                    addressLine: $0.addressLine,
                    nickname: $0.nickname,
                    timestampMs: $0.timestampMs
                )
            }
            .sorted { $0.id < $1.id }
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
