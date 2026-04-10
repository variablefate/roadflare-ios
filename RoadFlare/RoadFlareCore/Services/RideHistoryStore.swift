import Foundation
import RidestrSDK

/// UserDefaults-backed persistence for RideHistoryRepository.
public final class UserDefaultsRideHistoryPersistence: RideHistoryPersistence, @unchecked Sendable {
    private static let key = "roadflare_ride_history"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadRides() -> [RideHistoryEntry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([RideHistoryEntry].self, from: data)) ?? []
    }

    public func saveRides(_ rides: [RideHistoryEntry]) {
        if let data = try? JSONEncoder().encode(rides) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
