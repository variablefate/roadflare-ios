import Foundation

/// Canonical persistence contract for active ride state.
/// Both platforms (iOS/Android) agree on this shape.
public struct PersistedRideState: Codable, Sendable {
    public let stage: String
    public let offerEventId: String?
    public let acceptanceEventId: String?
    public let confirmationEventId: String?
    public let driverPubkey: String?
    public let pin: String?
    public let pinVerified: Bool
    public let paymentMethodRaw: String?
    public let fiatPaymentMethodsRaw: [String]
    public let pickupLat: Double?
    public let pickupLon: Double?
    public let pickupAddress: String?
    public let destLat: Double?
    public let destLon: Double?
    public let destAddress: String?
    public let fareUSD: String?
    public let fareDistanceMiles: Double?
    public let fareDurationMinutes: Double?
    public let savedAt: Int
    public let processedPinActionKeys: [String]?
    public let processedPinTimestamps: [Int]?
    public let pinAttempts: Int?
    public let precisePickupShared: Bool?
    public let preciseDestinationShared: Bool?
    public let lastDriverStatus: String?
    public let lastDriverStateTimestamp: Int?
    public let lastDriverActionCount: Int?
    public let riderStateHistory: [RiderRideAction]?

    public init(
        stage: String,
        offerEventId: String? = nil,
        acceptanceEventId: String? = nil,
        confirmationEventId: String? = nil,
        driverPubkey: String? = nil,
        pin: String? = nil,
        pinVerified: Bool = false,
        paymentMethodRaw: String? = nil,
        fiatPaymentMethodsRaw: [String] = [],
        pickupLat: Double? = nil,
        pickupLon: Double? = nil,
        pickupAddress: String? = nil,
        destLat: Double? = nil,
        destLon: Double? = nil,
        destAddress: String? = nil,
        fareUSD: String? = nil,
        fareDistanceMiles: Double? = nil,
        fareDurationMinutes: Double? = nil,
        savedAt: Int = Int(Date.now.timeIntervalSince1970),
        processedPinActionKeys: [String]? = nil,
        processedPinTimestamps: [Int]? = nil,
        pinAttempts: Int? = nil,
        precisePickupShared: Bool? = nil,
        preciseDestinationShared: Bool? = nil,
        lastDriverStatus: String? = nil,
        lastDriverStateTimestamp: Int? = nil,
        lastDriverActionCount: Int? = nil,
        riderStateHistory: [RiderRideAction]? = nil
    ) {
        self.stage = stage
        self.offerEventId = offerEventId
        self.acceptanceEventId = acceptanceEventId
        self.confirmationEventId = confirmationEventId
        self.driverPubkey = driverPubkey
        self.pin = pin
        self.pinVerified = pinVerified
        self.paymentMethodRaw = paymentMethodRaw
        self.fiatPaymentMethodsRaw = fiatPaymentMethodsRaw
        self.pickupLat = pickupLat
        self.pickupLon = pickupLon
        self.pickupAddress = pickupAddress
        self.destLat = destLat
        self.destLon = destLon
        self.destAddress = destAddress
        self.fareUSD = fareUSD
        self.fareDistanceMiles = fareDistanceMiles
        self.fareDurationMinutes = fareDurationMinutes
        self.savedAt = savedAt
        self.processedPinActionKeys = processedPinActionKeys
        self.processedPinTimestamps = processedPinTimestamps
        self.pinAttempts = pinAttempts
        self.precisePickupShared = precisePickupShared
        self.preciseDestinationShared = preciseDestinationShared
        self.lastDriverStatus = lastDriverStatus
        self.lastDriverStateTimestamp = lastDriverStateTimestamp
        self.lastDriverActionCount = lastDriverActionCount
        self.riderStateHistory = riderStateHistory
    }

    /// Normalize legacy fields. Converts old `processedPinTimestamps` to
    /// `processedPinActionKeys` format. Called by `RideStateRepository.load()`.
    public func migrated() -> PersistedRideState {
        guard processedPinActionKeys == nil, let timestamps = processedPinTimestamps else {
            return self
        }
        return PersistedRideState(
            stage: stage, offerEventId: offerEventId,
            acceptanceEventId: acceptanceEventId, confirmationEventId: confirmationEventId,
            driverPubkey: driverPubkey, pin: pin, pinVerified: pinVerified,
            paymentMethodRaw: paymentMethodRaw, fiatPaymentMethodsRaw: fiatPaymentMethodsRaw,
            pickupLat: pickupLat, pickupLon: pickupLon, pickupAddress: pickupAddress,
            destLat: destLat, destLon: destLon, destAddress: destAddress,
            fareUSD: fareUSD, fareDistanceMiles: fareDistanceMiles,
            fareDurationMinutes: fareDurationMinutes, savedAt: savedAt,
            processedPinActionKeys: timestamps.map { "pin_submit:\($0)" },
            processedPinTimestamps: processedPinTimestamps,
            pinAttempts: pinAttempts, precisePickupShared: precisePickupShared,
            preciseDestinationShared: preciseDestinationShared,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount,
            riderStateHistory: riderStateHistory
        )
    }
}
