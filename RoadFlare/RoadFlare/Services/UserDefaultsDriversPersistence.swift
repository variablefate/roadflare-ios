import Foundation
import RidestrSDK

/// UserDefaults-backed persistence for followed drivers. Survives app restarts.
public final class UserDefaultsDriversPersistence: FollowedDriversPersistence, @unchecked Sendable {
    private let defaults: UserDefaults
    private let driversKey = "roadflare_followed_drivers"
    private let namesKey = "roadflare_driver_names"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadDrivers() -> [FollowedDriver] {
        guard let data = defaults.data(forKey: driversKey) else { return [] }
        return (try? JSONDecoder().decode([FollowedDriver].self, from: data)) ?? []
    }

    public func saveDrivers(_ drivers: [FollowedDriver]) {
        if let data = try? JSONEncoder().encode(drivers) {
            defaults.set(data, forKey: driversKey)
        }
    }

    public func loadDriverNames() -> [String: String] {
        defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
    }

    public func saveDriverNames(_ names: [String: String]) {
        defaults.set(names, forKey: namesKey)
    }
}
