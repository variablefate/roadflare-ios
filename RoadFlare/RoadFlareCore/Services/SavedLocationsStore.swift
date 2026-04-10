import Foundation
import RidestrSDK

/// UserDefaults-backed persistence for SavedLocationsRepository.
final class UserDefaultsSavedLocationsPersistence: SavedLocationsPersistence, @unchecked Sendable {
    private static let key = "roadflare_saved_locations"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadLocations() -> [SavedLocation] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([SavedLocation].self, from: data)) ?? []
    }

    func saveLocations(_ locations: [SavedLocation]) {
        if let data = try? JSONEncoder().encode(locations) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
