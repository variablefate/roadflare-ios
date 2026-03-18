import Foundation
import RidestrSDK

/// Simple ride history persistence backed by UserDefaults.
@Observable @MainActor
final class RideHistoryStore {
    private static let key = "roadflare_ride_history"
    private let defaults: UserDefaults

    var rides: [RideHistoryEntry] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rides = Self.load(from: defaults)
    }

    /// Add a completed or cancelled ride to history.
    func addRide(_ entry: RideHistoryEntry) {
        // Deduplicate by ID
        guard !rides.contains(where: { $0.id == entry.id }) else { return }
        rides.insert(entry, at: 0)  // Newest first
        // Enforce max
        if rides.count > StorageConstants.maxRideHistory {
            rides = Array(rides.prefix(StorageConstants.maxRideHistory))
        }
        save()
    }

    /// Remove a ride from history.
    func removeRide(id: String) {
        rides.removeAll { $0.id == id }
        save()
    }

    /// Clear all history.
    func clearAll() {
        rides = []
        defaults.removeObject(forKey: Self.key)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rides) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private static func load(from defaults: UserDefaults) -> [RideHistoryEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RideHistoryEntry].self, from: data)) ?? []
    }
}
