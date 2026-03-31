import Foundation
import RidestrSDK

/// Persists active ride state to UserDefaults so it can be restored after app kill.
struct RideStatePersistence {
    private static let key = "roadflare_active_ride_state"
    nonisolated static let interopOfferVisibilitySeconds = 2 * 60
    nonisolated static let interopConfirmationWaitSeconds = Int(RideConstants.confirmationTimeoutSeconds)

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

    struct RestorePolicy: Sendable, Equatable {
        let waitingForAcceptance: Int
        let driverAccepted: Int
        let postConfirmation: Int

        static let interopDefault = RestorePolicy(
            waitingForAcceptance: interopOfferVisibilitySeconds,
            driverAccepted: interopConfirmationWaitSeconds,
            postConfirmation: Int(EventExpiration.rideConfirmationHours * 3600)
        )
    }

    static func save(
        session: RiderRideSession,
        pickup: Location?,
        destination: Location?,
        fare: FareEstimate?,
        savedAt: Int? = nil
    ) {
        save(
            stage: session.stage.rawValue,
            offerEventId: session.offerEventId,
            acceptanceEventId: session.acceptanceEventId,
            confirmationEventId: session.confirmationEventId,
            driverPubkey: session.driverPubkey,
            pin: session.pin,
            pinVerified: session.pinVerified,
            paymentMethodRaw: session.paymentMethod,
            fiatPaymentMethodsRaw: session.fiatPaymentMethods,
            pickupLocation: pickup ?? session.precisePickup,
            destinationLocation: destination ?? session.preciseDestination,
            fareEstimate: fare,
            processedPinActionKeys: session.processedPinActionKeys,
            pinAttempts: session.pinAttempts,
            precisePickupShared: session.precisePickupShared,
            preciseDestinationShared: session.preciseDestinationShared,
            lastDriverStatus: session.lastDriverStatus,
            lastDriverStateTimestamp: session.lastDriverStateTimestamp,
            lastDriverActionCount: session.lastDriverActionCount,
            riderStateHistory: session.riderStateHistory,
            savedAt: savedAt
        )
    }

    static func load(
        now: Date = .now,
        restorePolicy: RestorePolicy = .interopDefault
    ) -> PersistedRideState? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let state = try? JSONDecoder().decode(PersistedRideState.self, from: data) else {
            return nil
        }
        // Match restore windows to the latest event the app still needs for that stage.
        let age = Int(now.timeIntervalSince1970) - state.savedAt
        guard age < maxRestoreAge(for: state.stage, restorePolicy: restorePolicy) else {
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

    private static func maxRestoreAge(for stage: String, restorePolicy: RestorePolicy) -> Int {
        switch stage {
        case RiderStage.waitingForAcceptance.rawValue:
            restorePolicy.waitingForAcceptance
        case RiderStage.driverAccepted.rawValue:
            restorePolicy.driverAccepted
        default:
            restorePolicy.postConfirmation
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(
        stage: String,
        offerEventId: String?,
        acceptanceEventId: String?,
        confirmationEventId: String?,
        driverPubkey: String?,
        pin: String?,
        pinVerified: Bool,
        paymentMethodRaw: String?,
        fiatPaymentMethodsRaw: [String],
        pickupLocation: Location?,
        destinationLocation: Location?,
        fareEstimate: FareEstimate?,
        processedPinActionKeys: Set<String>,
        pinAttempts: Int,
        precisePickupShared: Bool,
        preciseDestinationShared: Bool,
        lastDriverStatus: String?,
        lastDriverStateTimestamp: Int,
        lastDriverActionCount: Int,
        riderStateHistory: [RiderRideAction],
        savedAt: Int?
    ) {
        let state = PersistedRideState(
            stage: stage,
            offerEventId: offerEventId,
            acceptanceEventId: acceptanceEventId,
            confirmationEventId: confirmationEventId,
            driverPubkey: driverPubkey,
            pin: pin,
            pinVerified: pinVerified,
            paymentMethodRaw: paymentMethodRaw,
            fiatPaymentMethodsRaw: fiatPaymentMethodsRaw,
            pickupLat: pickupLocation?.latitude,
            pickupLon: pickupLocation?.longitude,
            pickupAddress: pickupLocation?.address,
            destLat: destinationLocation?.latitude,
            destLon: destinationLocation?.longitude,
            destAddress: destinationLocation?.address,
            fareUSD: fareEstimate.map { "\($0.fareUSD)" },
            fareDistanceMiles: fareEstimate.map(\.distanceMiles),
            fareDurationMinutes: fareEstimate.map(\.durationMinutes),
            savedAt: savedAt ?? Int(Date.now.timeIntervalSince1970),
            processedPinActionKeys: processedPinActionKeys.isEmpty ? nil : Array(processedPinActionKeys),
            processedPinTimestamps: nil,
            pinAttempts: pinAttempts > 0 ? pinAttempts : nil,
            precisePickupShared: precisePickupShared ? true : nil,
            preciseDestinationShared: preciseDestinationShared ? true : nil,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp > 0 ? lastDriverStateTimestamp : nil,
            lastDriverActionCount: lastDriverActionCount > 0 ? lastDriverActionCount : nil,
            riderStateHistory: riderStateHistory.isEmpty ? nil : riderStateHistory
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
