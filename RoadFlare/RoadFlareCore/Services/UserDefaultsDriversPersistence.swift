import Foundation
import RidestrSDK

/// UserDefaults-backed persistence for followed drivers. Survives app restarts.
final class UserDefaultsDriversPersistence: FollowedDriversPersistence, @unchecked Sendable {
    private let defaults: UserDefaults
    private let driversKey = "roadflare_followed_drivers"
    private let namesKey = "roadflare_driver_names"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadDrivers() -> [FollowedDriver] {
        guard let data = defaults.data(forKey: driversKey) else { return [] }
        return (try? JSONDecoder().decode([FollowedDriver].self, from: data)) ?? []
    }

    func saveDrivers(_ drivers: [FollowedDriver]) {
        if let data = try? JSONEncoder().encode(drivers) {
            defaults.set(data, forKey: driversKey)
        }
    }

    func loadDriverNames() -> [String: String] {
        let names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        // Clean up orphaned names for drivers that no longer exist
        let driverPubkeys = Set(loadDrivers().map(\.pubkey))
        let cleaned = names.filter { driverPubkeys.contains($0.key) }
        if cleaned.count != names.count {
            defaults.set(cleaned, forKey: namesKey)  // Persist cleanup
        }
        return cleaned
    }

    func saveDriverNames(_ names: [String: String]) {
        defaults.set(names, forKey: namesKey)
    }
}
