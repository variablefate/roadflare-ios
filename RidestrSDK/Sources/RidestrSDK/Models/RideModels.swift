import Foundation

// MARK: - Type Aliases

/// 64-character hex-encoded Nostr public key.
public typealias PublicKeyHex = String

/// 64-character hex-encoded Nostr event ID (SHA-256 hash).
public typealias EventID = String

/// Event ID of a Kind 3175 confirmation — canonical ride identifier.
public typealias ConfirmationEventID = String

// MARK: - Rider Stages

/// Rider ride lifecycle stages.
public enum RiderStage: String, Codable, Sendable {
    case idle
    case waitingForAcceptance
    case driverAccepted
    case rideConfirmed
    case enRoute
    case driverArrived
    case inProgress
    case completed

    /// Whether cancellation is allowed from this stage.
    public var canCancel: Bool {
        self != .completed && self != .idle
    }

    /// Whether this is an active ride (post-confirmation, pre-completion).
    public var isActiveRide: Bool {
        switch self {
        case .rideConfirmed, .enRoute, .driverArrived, .inProgress: true
        default: false
        }
    }
}

// MARK: - Event Content Models

/// Content of a RoadFlare ride offer (Kind 3173, NIP-44 encrypted to driver).
public struct RideOfferContent: Codable, Sendable {
    /// Fare in satoshis (matching Android's Double encoding for JSON compatibility).
    public let fareEstimate: Double
    public let destination: Location
    public let approxPickup: Location
    public let pickupRouteKm: Double?
    public let pickupRouteMin: Double?
    public let rideRouteKm: Double?
    public let rideRouteMin: Double?
    public let destinationGeohash: String?
    public let mintUrl: String?
    public let paymentMethod: String
    public let fiatPaymentMethods: [String]

    enum CodingKeys: String, CodingKey {
        case fareEstimate = "fare_estimate"
        case destination
        case approxPickup = "approx_pickup"
        case pickupRouteKm = "pickup_route_km"
        case pickupRouteMin = "pickup_route_min"
        case rideRouteKm = "ride_route_km"
        case rideRouteMin = "ride_route_min"
        case destinationGeohash = "destination_geohash"
        case mintUrl = "mint_url"
        case paymentMethod = "payment_method"
        case fiatPaymentMethods = "fiat_payment_methods"
    }

    public init(
        fareEstimate: Double,
        destination: Location,
        approxPickup: Location,
        pickupRouteKm: Double? = nil,
        pickupRouteMin: Double? = nil,
        rideRouteKm: Double? = nil,
        rideRouteMin: Double? = nil,
        destinationGeohash: String? = nil,
        mintUrl: String? = nil,
        paymentMethod: String = "zelle",
        fiatPaymentMethods: [String] = []
    ) {
        self.fareEstimate = fareEstimate
        self.destination = destination
        self.approxPickup = approxPickup
        self.pickupRouteKm = pickupRouteKm
        self.pickupRouteMin = pickupRouteMin
        self.rideRouteKm = rideRouteKm
        self.rideRouteMin = rideRouteMin
        self.destinationGeohash = destinationGeohash
        self.mintUrl = mintUrl
        self.paymentMethod = paymentMethod
        self.fiatPaymentMethods = fiatPaymentMethods
    }
}

/// Content of a ride acceptance (Kind 3174, NIP-44 encrypted to rider).
public struct RideAcceptanceContent: Codable, Sendable {
    public let status: String
    public let walletPubkey: String?
    public let escrowType: String?
    public let escrowInvoice: String?
    public let escrowExpiry: Int?
    public let paymentMethod: String?
    public let mintUrl: String?

    enum CodingKeys: String, CodingKey {
        case status
        case walletPubkey = "wallet_pubkey"
        case escrowType = "escrow_type"
        case escrowInvoice = "escrow_invoice"
        case escrowExpiry = "escrow_expiry"
        case paymentMethod = "payment_method"
        case mintUrl = "mint_url"
    }

    public init(
        status: String,
        walletPubkey: String? = nil,
        escrowType: String? = nil,
        escrowInvoice: String? = nil,
        escrowExpiry: Int? = nil,
        paymentMethod: String? = nil,
        mintUrl: String? = nil
    ) {
        self.status = status
        self.walletPubkey = walletPubkey
        self.escrowType = escrowType
        self.escrowInvoice = escrowInvoice
        self.escrowExpiry = escrowExpiry
        self.paymentMethod = paymentMethod
        self.mintUrl = mintUrl
    }
}

/// Parsed acceptance envelope metadata from Kind 3174.
///
/// This lets SDK consumers validate who sent the acceptance and which rider/offer
/// it targets without re-parsing raw tags in app code.
public struct RideAcceptanceEnvelope: Sendable, Equatable {
    public let eventId: String
    public let driverPubkey: String
    public let offerEventId: String
    public let riderPubkey: String
    public let createdAt: Int

    public init(
        eventId: String,
        driverPubkey: String,
        offerEventId: String,
        riderPubkey: String,
        createdAt: Int
    ) {
        self.eventId = eventId
        self.driverPubkey = driverPubkey
        self.offerEventId = offerEventId
        self.riderPubkey = riderPubkey
        self.createdAt = createdAt
    }
}

/// Content of a ride confirmation (Kind 3175, NIP-44 encrypted to driver).
public struct RideConfirmationContent: Codable, Sendable {
    public let precisePickup: Location
    public let paymentHash: String?
    public let escrowToken: String?

    enum CodingKeys: String, CodingKey {
        case precisePickup = "precise_pickup"
        case paymentHash = "payment_hash"
        case escrowToken = "escrow_token"
    }

    public init(
        precisePickup: Location,
        paymentHash: String? = nil,
        escrowToken: String? = nil
    ) {
        self.precisePickup = precisePickup
        self.paymentHash = paymentHash
        self.escrowToken = escrowToken
    }
}

/// Parsed confirmation envelope metadata from Kind 3175.
///
/// This is useful when the caller needs to validate identity and linkage without
/// decrypting the confirmation body.
public struct RideConfirmationEnvelope: Sendable, Equatable {
    public let eventId: String
    public let riderPubkey: String
    public let acceptanceEventId: String
    public let driverPubkey: String
    public let createdAt: Int

    public init(
        eventId: String,
        riderPubkey: String,
        acceptanceEventId: String,
        driverPubkey: String,
        createdAt: Int
    ) {
        self.eventId = eventId
        self.riderPubkey = riderPubkey
        self.acceptanceEventId = acceptanceEventId
        self.driverPubkey = driverPubkey
        self.createdAt = createdAt
    }
}

// MARK: - Driver Ride State (Kind 30180)

/// Content of a driver ride state event (Kind 30180).
public struct DriverRideStateContent: Codable, Sendable {
    public let currentStatus: String
    public let history: [DriverRideAction]

    enum CodingKeys: String, CodingKey {
        case currentStatus = "current_status"
        case history
    }
}

/// An action in the driver's ride state history.
public struct DriverRideAction: Codable, Sendable {
    public let type: String
    public let at: Int

    // Status action fields
    public let status: String?
    public let approxLocation: Location?
    public let finalFare: Decimal?
    public let invoice: String?

    // PinSubmit action fields
    public let pinEncrypted: String?

    // Settlement action fields
    public let settlementProof: String?
    public let settledAmount: Decimal?

    // Cross-mint deposit-invoice-share action fields
    public let amount: Decimal?

    enum CodingKeys: String, CodingKey {
        case type = "action"
        case at, status, invoice
        case approxLocation = "approx_location"
        case finalFare = "final_fare"
        case pinEncrypted = "pin_encrypted"
        case settlementProof = "settlement_proof"
        case settledAmount = "settled_amount"
        case amount
    }

    public init(
        type: String,
        at: Int,
        status: String?,
        approxLocation: Location?,
        finalFare: Decimal?,
        invoice: String?,
        pinEncrypted: String?,
        settlementProof: String? = nil,
        settledAmount: Decimal? = nil,
        amount: Decimal? = nil
    ) {
        self.type = type
        self.at = at
        self.status = status
        self.approxLocation = approxLocation
        self.finalFare = finalFare
        self.invoice = invoice
        self.pinEncrypted = pinEncrypted
        self.settlementProof = settlementProof
        self.settledAmount = settledAmount
        self.amount = amount
    }

    public var isStatusAction: Bool { type == "status" }
    public var isPinSubmitAction: Bool { type == "pin_submit" }
    public var isSettlementAction: Bool { type == "settlement" }
    public var isDepositInvoiceShareAction: Bool { type == "deposit_invoice_share" }
}

// MARK: - Rider Ride State (Kind 30181)

/// Content of a rider ride state event (Kind 30181).
public struct RiderRideStateContent: Codable, Sendable {
    public let currentPhase: String
    public let history: [RiderRideAction]

    enum CodingKeys: String, CodingKey {
        case currentPhase = "current_phase"
        case history
    }
}

/// An action in the rider's ride state history.
public struct RiderRideAction: Codable, Sendable {
    public let type: String
    public let at: Int

    // LocationReveal fields
    public let locationType: String?
    public let locationEncrypted: String?

    // PinVerify fields
    public let status: String?
    public let attempt: Int?

    // PreimageShare / BridgeComplete fields
    public let preimageEncrypted: String?
    public let escrowTokenEncrypted: String?
    public let preimage: String?
    public let amount: Decimal?
    public let fees: Decimal?

    enum CodingKeys: String, CodingKey {
        case type = "action"
        case at, status, attempt
        case locationType = "location_type"
        case locationEncrypted = "location_encrypted"
        case preimageEncrypted = "preimage_encrypted"
        case escrowTokenEncrypted = "escrow_token_encrypted"
        case preimage
        case amount
        case fees
    }

    public init(type: String, at: Int, locationType: String?, locationEncrypted: String?,
                status: String?, attempt: Int?, preimageEncrypted: String? = nil,
                escrowTokenEncrypted: String? = nil, preimage: String? = nil,
                amount: Decimal? = nil, fees: Decimal? = nil) {
        self.type = type
        self.at = at
        self.locationType = locationType
        self.locationEncrypted = locationEncrypted
        self.status = status
        self.attempt = attempt
        self.preimageEncrypted = preimageEncrypted
        self.escrowTokenEncrypted = escrowTokenEncrypted
        self.preimage = preimage
        self.amount = amount
        self.fees = fees
    }

    public var isLocationReveal: Bool { type == "location_reveal" }
    public var isPinVerify: Bool { type == "pin_verify" }
    public var isPinVerified: Bool { isPinVerify && status == "verified" }
    public var isPreimageShare: Bool { type == "preimage_share" }
    public var isBridgeComplete: Bool { type == "bridge_complete" }
}

// MARK: - Chat

/// Content of a chat message (Kind 3178, NIP-44 encrypted).
public struct ChatMessageContent: Codable, Sendable {
    public let message: String
}

// MARK: - Cancellation

/// Content of a cancellation event (Kind 3179).
public struct CancellationContent: Codable, Sendable {
    public let status: String
    public let reason: String?

    public init(reason: String?) {
        self.status = "cancelled"
        self.reason = reason
    }
}

// MARK: - User Profile (Kind 0)

/// Nostr metadata profile (NIP-01 Kind 0).
public struct UserProfile: Codable, Sendable {
    public let name: String?
    public let about: String?
    public let picture: String?

    public init(name: String? = nil, about: String? = nil, picture: String? = nil) {
        self.name = name
        self.about = about
        self.picture = picture
    }
}

// MARK: - Vehicle

/// Vehicle information shared via driver profile.
public struct Vehicle: Codable, Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public var make: String
    public var model: String
    public var year: Int?
    public var color: String?
    public var licensePlate: String?

    public init(id: String = UUID().uuidString, make: String, model: String,
                year: Int? = nil, color: String? = nil, licensePlate: String? = nil) {
        self.id = id
        self.make = make
        self.model = model
        self.year = year
        self.color = color
        self.licensePlate = licensePlate
    }

    public var displayName: String {
        [make, model, year.map(String.init)].compactMap { $0 }.joined(separator: " ")
    }
}
