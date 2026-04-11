import Foundation
import RidestrSDK

/// UserDefaults-backed persistence for RideHistoryRepository.
final class UserDefaultsRideHistoryPersistence: RideHistoryPersistence, @unchecked Sendable {
    private static let key = "roadflare_ride_history"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRides() -> [RideHistoryEntry] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([RideHistoryEntry].self, from: data)) ?? []
    }

    func saveRides(_ rides: [RideHistoryEntry]) {
        if let data = try? JSONEncoder().encode(rides) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
