import Foundation
import RidestrSDK

/// iOS-specific UserDefaults implementation of ride state persistence.
/// Domain logic (expiration, migration, stage filtering) lives in the SDK's
/// RideStateRepository. This class only handles storage.
final class UserDefaultsRideStatePersistence: RideStatePersistence, @unchecked Sendable {
    private static let key = "roadflare_active_ride_state"

    func saveRaw(_ state: PersistedRideState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func loadRaw() -> PersistedRideState? {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(PersistedRideState.self, from: data) else {
            return nil
        }
        return state
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
