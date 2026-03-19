import Foundation
import RidestrSDK

/// Persists active ride state to UserDefaults so it can be restored after app kill.
struct RideStatePersistence {
    private static let key = "roadflare_active_ride_state"

    struct PersistedRideState: Codable {
        let stage: String
        let offerEventId: String?
        let acceptanceEventId: String?
        let confirmationEventId: String?
        let driverPubkey: String?
        let pin: String?
        let pinVerified: Bool
        let paymentMethodRaw: String?
        let fiatPaymentMethodsRaw: [String]
        let pickupLat: Double?
        let pickupLon: Double?
        let pickupAddress: String?
        let destLat: Double?
        let destLon: Double?
        let destAddress: String?
        let fareUSD: String?  // Decimal as string
        let savedAt: Int
        let processedPinTimestamps: [Int]?  // Persisted dedup set
        let pinAttempts: Int?
    }

    static func save(
        stateMachine: RideStateMachine,
        pickupLocation: Location?,
        destinationLocation: Location?,
        fareEstimate: FareEstimate?,
        paymentMethod: PaymentMethod?,
        processedPinTimestamps: Set<Int> = []
    ) {
        let state = PersistedRideState(
            stage: stateMachine.stage.rawValue,
            offerEventId: stateMachine.offerEventId,
            acceptanceEventId: stateMachine.acceptanceEventId,
            confirmationEventId: stateMachine.confirmationEventId,
            driverPubkey: stateMachine.driverPubkey,
            pin: stateMachine.pin,
            pinVerified: stateMachine.pinVerified,
            paymentMethodRaw: paymentMethod?.rawValue,
            fiatPaymentMethodsRaw: stateMachine.fiatPaymentMethods.map(\.rawValue),
            pickupLat: pickupLocation?.latitude,
            pickupLon: pickupLocation?.longitude,
            pickupAddress: pickupLocation?.address,
            destLat: destinationLocation?.latitude,
            destLon: destinationLocation?.longitude,
            destAddress: destinationLocation?.address,
            fareUSD: fareEstimate.map { "\($0.fareUSD)" },
            savedAt: Int(Date.now.timeIntervalSince1970),
            processedPinTimestamps: processedPinTimestamps.isEmpty ? nil : Array(processedPinTimestamps),
            pinAttempts: stateMachine.pinAttempts > 0 ? stateMachine.pinAttempts : nil
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> PersistedRideState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(PersistedRideState.self, from: data) else {
            return nil
        }
        // Don't restore if saved more than 8 hours ago (ride events expire)
        let age = Int(Date.now.timeIntervalSince1970) - state.savedAt
        guard age < 8 * 3600 else {
            clear()
            return nil
        }
        // Don't restore idle or completed
        guard state.stage != "idle" && state.stage != "completed" else {
            clear()
            return nil
        }
        return state
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
