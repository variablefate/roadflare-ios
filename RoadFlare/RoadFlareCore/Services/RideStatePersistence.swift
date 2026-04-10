import Foundation
import os
import RidestrSDK

/// iOS-specific UserDefaults implementation of ride state persistence.
/// Domain logic (expiration, migration, stage filtering) lives in the SDK's
/// RideStateRepository. This class only handles storage.
public final class UserDefaultsRideStatePersistence: RideStatePersistence, @unchecked Sendable {
    private static let key = "roadflare_active_ride_state"

    public init() {}

    public func saveRaw(_ state: PersistedRideState) {
        do {
            let data = try JSONEncoder().encode(state)
            UserDefaults.standard.set(data, forKey: Self.key)
        } catch {
            AppLogger.ride.error("Failed to encode persisted ride state: \(error)")
        }
    }

    public func loadRaw() -> PersistedRideState? {
        guard let data = UserDefaults.standard.data(forKey: Self.key) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(PersistedRideState.self, from: data)
        } catch {
            AppLogger.ride.error("Failed to decode persisted ride state: \(error)")
            return nil
        }
    }

    public func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
