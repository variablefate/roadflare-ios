import Foundation
import RidestrSDK

/// Persists active ride state to UserDefaults so it can be restored after app kill.
struct RideStatePersistence {
    private static let key = "roadflare_active_ride_state"
    static let interopOfferVisibilitySeconds = 2 * 60
    static let interopConfirmationWaitSeconds = Int(RideConstants.confirmationTimeoutSeconds)

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
        let fareDistanceMiles: Double?
        let fareDurationMinutes: Double?
        let savedAt: Int
        let processedPinActionKeys: [String]?
        let processedPinTimestamps: [Int]?  // Legacy timestamp-only dedup set
        let pinAttempts: Int?
        let precisePickupShared: Bool?
        let preciseDestinationShared: Bool?
        let lastDriverStatus: String?
        let lastDriverStateTimestamp: Int?
        let lastDriverActionCount: Int?
        let riderStateHistory: [RiderRideAction]?
    }

    static func save(
        stateMachine: RideStateMachine,
        pickupLocation: Location?,
        destinationLocation: Location?,
        fareEstimate: FareEstimate?,
        paymentMethod: String?,
        processedPinActionKeys: Set<String> = [],
        persistDriverStateCursor: Bool = true
    ) {
        let state = PersistedRideState(
            stage: stateMachine.stage.rawValue,
            offerEventId: stateMachine.offerEventId,
            acceptanceEventId: stateMachine.acceptanceEventId,
            confirmationEventId: stateMachine.confirmationEventId,
            driverPubkey: stateMachine.driverPubkey,
            pin: stateMachine.pin,
            pinVerified: stateMachine.pinVerified,
            paymentMethodRaw: paymentMethod,
            fiatPaymentMethodsRaw: stateMachine.fiatPaymentMethods,
            pickupLat: pickupLocation?.latitude,
            pickupLon: pickupLocation?.longitude,
            pickupAddress: pickupLocation?.address,
            destLat: destinationLocation?.latitude,
            destLon: destinationLocation?.longitude,
            destAddress: destinationLocation?.address,
            fareUSD: fareEstimate.map { "\($0.fareUSD)" },
            fareDistanceMiles: fareEstimate.map(\.distanceMiles),
            fareDurationMinutes: fareEstimate.map(\.durationMinutes),
            savedAt: Int(Date.now.timeIntervalSince1970),
            processedPinActionKeys: processedPinActionKeys.isEmpty ? nil : Array(processedPinActionKeys),
            processedPinTimestamps: nil,
            pinAttempts: stateMachine.pinAttempts > 0 ? stateMachine.pinAttempts : nil,
            precisePickupShared: stateMachine.precisePickupShared ? true : nil,
            preciseDestinationShared: stateMachine.preciseDestinationShared ? true : nil,
            lastDriverStatus: stateMachine.lastDriverStatus,
            lastDriverStateTimestamp: persistDriverStateCursor && stateMachine.context.lastDriverStateTimestamp > 0
                ? stateMachine.context.lastDriverStateTimestamp
                : nil,
            lastDriverActionCount: persistDriverStateCursor && stateMachine.lastDriverActionCount > 0
                ? stateMachine.lastDriverActionCount
                : nil,
            riderStateHistory: stateMachine.riderStateHistory.isEmpty ? nil : stateMachine.riderStateHistory
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load(now: Date = .now) -> PersistedRideState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(PersistedRideState.self, from: data) else {
            return nil
        }
        // Match restore windows to the latest event the app still needs for that stage.
        let age = Int(now.timeIntervalSince1970) - state.savedAt
        guard age < maxRestoreAge(for: state.stage) else {
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

    private static func maxRestoreAge(for stage: String) -> Int {
        switch stage {
        case RiderStage.waitingForAcceptance.rawValue:
            interopOfferVisibilitySeconds
        case RiderStage.driverAccepted.rawValue:
            interopConfirmationWaitSeconds
        default:
            Int(EventExpiration.rideConfirmationHours * 3600)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
