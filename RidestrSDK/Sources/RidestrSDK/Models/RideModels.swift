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
    public let fareEstimate: Decimal
    public let destination: Location
    public let approxPickup: Location
    public let pickupRouteKm: Double?
    public let pickupRouteMin: Double?
    public let rideRouteKm: Double?
    public let rideRouteMin: Double?
    public let destinationGeohash: String?
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
        case paymentMethod = "payment_method"
        case fiatPaymentMethods = "fiat_payment_methods"
    }

    public init(
        fareEstimate: Decimal,
        destination: Location,
        approxPickup: Location,
        pickupRouteKm: Double? = nil,
        pickupRouteMin: Double? = nil,
        rideRouteKm: Double? = nil,
        rideRouteMin: Double? = nil,
        destinationGeohash: String? = nil,
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
        self.paymentMethod = paymentMethod
        self.fiatPaymentMethods = fiatPaymentMethods
    }
}

/// Content of a ride acceptance (Kind 3174, NIP-44 encrypted to rider).
public struct RideAcceptanceContent: Codable, Sendable {
    public let status: String
    public let walletPubkey: String?
    public let paymentMethod: String?
    public let mintUrl: String?

    enum CodingKeys: String, CodingKey {
        case status
        case walletPubkey = "wallet_pubkey"
        case paymentMethod = "payment_method"
        case mintUrl = "mint_url"
    }
}

/// Content of a ride confirmation (Kind 3175, NIP-44 encrypted to driver).
public struct RideConfirmationContent: Codable, Sendable {
    public let precisePickup: Location?

    enum CodingKeys: String, CodingKey {
        case precisePickup = "precise_pickup"
        // Future Cashu fields: payment_hash, escrow_token
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

    enum CodingKeys: String, CodingKey {
        case type = "action"
        case at, status, invoice
        case approxLocation = "approx_location"
        case finalFare = "final_fare"
        case pinEncrypted = "pin_encrypted"
    }

    public var isStatusAction: Bool { type == "status" }
    public var isPinSubmitAction: Bool { type == "pin_submit" }
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

    enum CodingKeys: String, CodingKey {
        case type = "action"
        case at, status, attempt
        case locationType = "location_type"
        case locationEncrypted = "location_encrypted"
    }

    public init(type: String, at: Int, locationType: String?, locationEncrypted: String?,
                status: String?, attempt: Int?) {
        self.type = type; self.at = at; self.locationType = locationType
        self.locationEncrypted = locationEncrypted; self.status = status; self.attempt = attempt
    }

    public var isLocationReveal: Bool { type == "location_reveal" }
    public var isPinVerify: Bool { type == "pin_verify" }
    public var isPinVerified: Bool { isPinVerify && status == "verified" }
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
