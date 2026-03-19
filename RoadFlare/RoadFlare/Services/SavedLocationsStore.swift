import Foundation
import RidestrSDK

/// Manages saved locations (Home, Work, favorites, recents).
@Observable @MainActor
final class SavedLocationsStore {
    private static let key = "roadflare_saved_locations"
    private let defaults: UserDefaults

    var locations: [SavedLocation] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.locations = Self.load(from: defaults)
    }

    /// Pinned favorites (Home, Work, etc.).
    var favorites: [SavedLocation] {
        locations.filter(\.isPinned)
    }

    /// Recent (non-pinned) locations, newest first.
    var recents: [SavedLocation] {
        locations.filter { !$0.isPinned }
            .sorted { $0.timestampMs > $1.timestampMs }
    }

    /// Add or update a saved location.
    func save(_ location: SavedLocation) {
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
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
        locations[index].isPinned = true
        locations[index].nickname = nickname
        persist()
    }

    /// Unpin a favorite back to recents.
    func unpin(id: String) {
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
        locations[index].isPinned = false
        locations[index].nickname = nil
        persist()
    }

    /// Remove a location.
    func remove(id: String) {
        locations.removeAll { $0.id == id }
        persist()
    }

    /// Clear all locations.
    func clearAll() {
        locations = []
        defaults.removeObject(forKey: Self.key)
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
}
