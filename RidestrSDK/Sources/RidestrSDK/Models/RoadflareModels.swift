import Foundation

// MARK: - RoadFlare Key

/// A RoadFlare encryption keypair. Separate from identity key.
/// The private key is shared with approved followers so they can decrypt location broadcasts.
public struct RoadflareKey: Codable, Sendable {
    public let privateKeyHex: String
    public let publicKeyHex: String
    public let version: Int
    public let keyUpdatedAt: Int?  // unix timestamp, optional (Android omits if <= 0)

    enum CodingKeys: String, CodingKey {
        case privateKeyHex = "privateKey"
        case publicKeyHex = "publicKey"
        case version
        case keyUpdatedAt
    }

    public init(privateKeyHex: String, publicKeyHex: String, version: Int, keyUpdatedAt: Int? = nil) {
        self.privateKeyHex = privateKeyHex
        self.publicKeyHex = publicKeyHex
        self.version = version
        self.keyUpdatedAt = keyUpdatedAt
    }
}

// MARK: - RoadFlare Location

/// Decrypted RoadFlare location broadcast data.
public struct RoadflareLocation: Codable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let timestamp: Int
    public let status: RoadflareStatus
    public let onRide: Bool?

    enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lon"
        case timestamp, status, onRide
    }
}

/// RoadFlare driver availability status.
public enum RoadflareStatus: String, Codable, Sendable {
    case online
    case onRide = "on_ride"
    case offline
}

/// A parsed RoadFlare location event with metadata.
public struct RoadflareLocationEvent: Sendable {
    public let eventId: String
    public let driverPubkey: String
    public let location: RoadflareLocation
    public let keyVersion: Int
    public let tagStatus: String?
    public let createdAt: Int
}

// MARK: - Followed Driver

/// A driver in the rider's trusted network.
public struct FollowedDriver: Codable, Identifiable, Sendable {
    public let id: String  // pubkey
    public let pubkey: String
    public var addedAt: Int  // unix timestamp
    public var name: String?
    public var note: String?
    public var roadflareKey: RoadflareKey?

    public init(pubkey: String, addedAt: Int = Int(Date.now.timeIntervalSince1970),
                name: String? = nil, note: String? = nil, roadflareKey: RoadflareKey? = nil) {
        self.id = pubkey
        self.pubkey = pubkey
        self.addedAt = addedAt
        self.name = name
        self.note = note
        self.roadflareKey = roadflareKey
    }

    /// Whether this driver has shared their RoadFlare key (follower approved).
    public var hasKey: Bool { roadflareKey != nil }
}

// MARK: - Key Share Data

/// Parsed content of a Kind 3186 key share event.
public struct RoadflareKeyShareData: Sendable {
    public let eventId: String
    public let driverPubkey: String
    public let roadflareKey: RoadflareKey
    public let keyUpdatedAt: Int
    public let createdAt: Int
}

// MARK: - Key Ack Data

/// Parsed content of a Kind 3188 key acknowledgement event.
public struct RoadflareKeyAckData: Sendable {
    public let eventId: String
    public let riderPubkey: String
    public let keyVersion: Int
    public let keyUpdatedAt: Int
    public let status: String  // "received" or "stale"
    public let createdAt: Int
}

// MARK: - Followed Drivers List Content (Kind 30011)

/// Content of the followed drivers list event (Kind 30011, encrypted to self).
public struct FollowedDriversContent: Codable, Sendable {
    public let drivers: [FollowedDriverEntry]
    public let updatedAt: Int

    enum CodingKeys: String, CodingKey {
        case drivers
        case updatedAt = "updated_at"
    }
}

/// A single entry in the followed drivers list.
public struct FollowedDriverEntry: Codable, Sendable {
    public let pubkey: String
    public let addedAt: Int
    public let note: String?
    public let roadflareKey: RoadflareKey?
}

// MARK: - Key Share Content (Kind 3186)

/// Content of a key share event (Kind 3186, encrypted to follower).
public struct KeyShareContent: Codable, Sendable {
    public let roadflareKey: RoadflareKey
    public let keyUpdatedAt: Int
    public let driverPubKey: String
}

// MARK: - Key Ack Content (Kind 3188)

/// Content of a key ack event (Kind 3188, encrypted to driver).
public struct KeyAckContent: Codable, Sendable {
    public let keyVersion: Int
    public let keyUpdatedAt: Int
    public let status: String
    public let riderPubKey: String
}

// MARK: - Ride History

/// A completed or cancelled ride stored in history.
public struct RideHistoryEntry: Codable, Identifiable, Sendable {
    public let id: String
    public let date: Date
    public let role: String
    public let status: String
    public let counterpartyPubkey: String
    public var counterpartyName: String?
    public let pickupGeohash: String
    public let dropoffGeohash: String
    public let pickup: Location
    public let destination: Location
    public let fare: Decimal
    public let paymentMethod: String
    public let distance: Double?
    public let duration: Int?  // minutes
    public var vehicleMake: String?
    public var vehicleModel: String?
    public let appOrigin: String

    public init(
        id: String, date: Date, role: String = "rider", status: String = "completed",
        counterpartyPubkey: String, counterpartyName: String? = nil,
        pickupGeohash: String, dropoffGeohash: String,
        pickup: Location, destination: Location,
        fare: Decimal, paymentMethod: String,
        distance: Double? = nil, duration: Int? = nil,
        vehicleMake: String? = nil, vehicleModel: String? = nil,
        appOrigin: String = "roadflare"
    ) {
        self.id = id; self.date = date; self.role = role; self.status = status
        self.counterpartyPubkey = counterpartyPubkey; self.counterpartyName = counterpartyName
        self.pickupGeohash = pickupGeohash; self.dropoffGeohash = dropoffGeohash
        self.pickup = pickup; self.destination = destination
        self.fare = fare; self.paymentMethod = paymentMethod
        self.distance = distance; self.duration = duration
        self.vehicleMake = vehicleMake; self.vehicleModel = vehicleModel
        self.appOrigin = appOrigin
    }
}

// MARK: - Saved Location

/// A saved pickup/destination address.
public struct SavedLocation: Codable, Identifiable, Sendable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    public var displayName: String
    public var addressLine: String
    public var locality: String?
    public var isPinned: Bool
    public var nickname: String?
    public var timestampMs: Int

    public init(
        id: String = UUID().uuidString,
        latitude: Double, longitude: Double,
        displayName: String, addressLine: String,
        locality: String? = nil, isPinned: Bool = false,
        nickname: String? = nil, timestampMs: Int = Int(Date.now.timeIntervalSince1970 * 1000)
    ) {
        self.id = id; self.latitude = latitude; self.longitude = longitude
        self.displayName = displayName; self.addressLine = addressLine
        self.locality = locality; self.isPinned = isPinned
        self.nickname = nickname; self.timestampMs = timestampMs
    }

    public func toLocation() -> Location {
        Location(latitude: latitude, longitude: longitude, address: displayName)
    }
}
