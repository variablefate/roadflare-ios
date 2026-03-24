import Foundation

// MARK: - RoadFlare Key

/// A RoadFlare encryption keypair. Separate from identity key.
/// The private key is shared with approved followers so they can decrypt location broadcasts.
public struct RoadflareKey: Codable, Sendable, Equatable, Hashable {
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

    // Custom Equatable/Hashable: compare by public identity only (never compare private keys).
    public static func == (lhs: RoadflareKey, rhs: RoadflareKey) -> Bool {
        lhs.publicKeyHex == rhs.publicKeyHex && lhs.version == rhs.version
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(publicKeyHex)
        hasher.combine(version)
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
public struct FollowedDriver: Codable, Identifiable, Sendable, Hashable {
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

    /// Equality by pubkey identity — two entries for the same driver are equal.
    public static func == (lhs: FollowedDriver, rhs: FollowedDriver) -> Bool {
        lhs.pubkey == rhs.pubkey
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pubkey)
    }
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
    /// Schema version for migration support. Nil if decoded from pre-versioned data (treated as v1).
    public let schemaVersion: Int?

    enum CodingKeys: String, CodingKey {
        case drivers
        case updatedAt = "updated_at"
        case schemaVersion
    }

    public init(drivers: [FollowedDriverEntry], updatedAt: Int, schemaVersion: Int = 1) {
        self.drivers = drivers
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
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

// MARK: - User Profile / Metadata (Kind 0)

/// NIP-01 user profile metadata (Kind 0 content).
/// All fields optional — only non-nil/non-empty values are serialized.
/// Uses snake_case JSON keys for cross-platform compatibility with Android.
public struct UserProfileContent: Sendable, Equatable {
    public var name: String?
    public var displayName: String?
    public var about: String?
    public var picture: String?
    public var banner: String?
    public var website: String?
    public var nip05: String?
    public var lud16: String?
    public var lud06: String?
    // Vehicle info (driver profiles)
    public var carMake: String?
    public var carModel: String?
    public var carColor: String?
    public var carYear: String?

    public init(
        name: String? = nil, displayName: String? = nil, about: String? = nil,
        picture: String? = nil, banner: String? = nil, website: String? = nil,
        nip05: String? = nil, lud16: String? = nil, lud06: String? = nil,
        carMake: String? = nil, carModel: String? = nil, carColor: String? = nil, carYear: String? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.about = about
        self.picture = picture
        self.banner = banner
        self.website = website
        self.nip05 = nip05
        self.lud16 = lud16
        self.lud06 = lud06
        self.carMake = carMake
        self.carModel = carModel
        self.carColor = carColor
        self.carYear = carYear
    }

    /// Vehicle description string (e.g., "Black Tesla Model S").
    /// Returns nil if no vehicle info is available.
    public var vehicleDescription: String? {
        let parts = [carColor, carMake, carModel].compactMap { $0?.nilIfEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Encode to JSON string, skipping nil/empty values.
    public func toJSON() -> String {
        var dict: [String: String] = [:]
        if let v = name, !v.isEmpty { dict["name"] = v }
        if let v = displayName, !v.isEmpty { dict["display_name"] = v }
        if let v = about, !v.isEmpty { dict["about"] = v }
        if let v = picture, !v.isEmpty { dict["picture"] = v }
        if let v = banner, !v.isEmpty { dict["banner"] = v }
        if let v = website, !v.isEmpty { dict["website"] = v }
        if let v = nip05, !v.isEmpty { dict["nip05"] = v }
        if let v = lud16, !v.isEmpty { dict["lud16"] = v }
        if let v = lud06, !v.isEmpty { dict["lud06"] = v }
        if let v = carMake, !v.isEmpty { dict["car_make"] = v }
        if let v = carModel, !v.isEmpty { dict["car_model"] = v }
        if let v = carColor, !v.isEmpty { dict["car_color"] = v }
        if let v = carYear, !v.isEmpty { dict["car_year"] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// Decode from Kind 0 event content JSON.
    public static func fromJSON(_ json: String) -> UserProfileContent? {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return UserProfileContent(
            name: dict["name"] as? String,
            displayName: dict["display_name"] as? String,
            about: dict["about"] as? String,
            picture: dict["picture"] as? String,
            banner: dict["banner"] as? String,
            website: dict["website"] as? String,
            nip05: dict["nip05"] as? String,
            lud16: dict["lud16"] as? String,
            lud06: dict["lud06"] as? String,
            carMake: dict["car_make"] as? String,
            carModel: dict["car_model"] as? String,
            carColor: dict["car_color"] as? String,
            carYear: dict["car_year"] as? String
        )
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Profile Backup (Kind 30177)

/// Settings portion of the profile backup, matching Android's SettingsBackup.
/// Encrypted to self in Kind 30177.
public struct SettingsBackupContent: Codable, Sendable {
    public var roadflarePaymentMethods: [String]
    public var displayCurrency: String
    public var distanceUnit: String

    public init(
        roadflarePaymentMethods: [String] = [],
        displayCurrency: String = "USD",
        distanceUnit: String = "MILES"
    ) {
        self.roadflarePaymentMethods = roadflarePaymentMethods
        self.displayCurrency = displayCurrency
        self.distanceUnit = distanceUnit
    }
}

/// Full profile backup content (Kind 30177, encrypted to self).
/// Matches Android's ProfileBackupEvent format.
public struct ProfileBackupContent: Codable, Sendable {
    public var savedLocations: [SavedLocationBackup]
    public var settings: SettingsBackupContent
    public var updatedAt: Int

    enum CodingKeys: String, CodingKey {
        case savedLocations
        case settings
        case updatedAt = "updated_at"
    }

    public init(
        savedLocations: [SavedLocationBackup] = [],
        settings: SettingsBackupContent = SettingsBackupContent(),
        updatedAt: Int = Int(Date.now.timeIntervalSince1970)
    ) {
        self.savedLocations = savedLocations
        self.settings = settings
        self.updatedAt = updatedAt
    }
}

/// Minimal saved location for backup (matching Android format).
public struct SavedLocationBackup: Codable, Sendable {
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let address: String?
    public let isFavorite: Bool

    public init(name: String, latitude: Double, longitude: Double,
                address: String? = nil, isFavorite: Bool = false) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.address = address
        self.isFavorite = isFavorite
    }
}

// MARK: - Ride History

/// A completed or cancelled ride stored in history.
public struct RideHistoryEntry: Codable, Identifiable, Sendable, Hashable {
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
    /// Schema version for migration support. Nil if decoded from pre-versioned data (treated as v1).
    public let schemaVersion: Int?

    public init(
        id: String, date: Date, role: String = "rider", status: String = "completed",
        counterpartyPubkey: String, counterpartyName: String? = nil,
        pickupGeohash: String, dropoffGeohash: String,
        pickup: Location, destination: Location,
        fare: Decimal, paymentMethod: String,
        distance: Double? = nil, duration: Int? = nil,
        vehicleMake: String? = nil, vehicleModel: String? = nil,
        appOrigin: String = "roadflare", schemaVersion: Int = 1
    ) {
        self.id = id; self.date = date; self.role = role; self.status = status
        self.counterpartyPubkey = counterpartyPubkey; self.counterpartyName = counterpartyName
        self.pickupGeohash = pickupGeohash; self.dropoffGeohash = dropoffGeohash
        self.pickup = pickup; self.destination = destination
        self.fare = fare; self.paymentMethod = paymentMethod
        self.distance = distance; self.duration = duration
        self.vehicleMake = vehicleMake; self.vehicleModel = vehicleModel
        self.appOrigin = appOrigin; self.schemaVersion = schemaVersion
    }

    /// Equality by ride ID — same ride is always equal regardless of mutable fields.
    public static func == (lhs: RideHistoryEntry, rhs: RideHistoryEntry) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Saved Location

/// A saved pickup/destination address.
public struct SavedLocation: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let latitude: Double
    public let longitude: Double
    public var displayName: String
    public var addressLine: String
    public var locality: String?
    public var isPinned: Bool
    public var nickname: String?
    public var timestampMs: Int
    /// Schema version for migration support. Nil if decoded from pre-versioned data (treated as v1).
    public let schemaVersion: Int?

    public init(
        id: String = UUID().uuidString,
        latitude: Double, longitude: Double,
        displayName: String, addressLine: String,
        locality: String? = nil, isPinned: Bool = false,
        nickname: String? = nil, timestampMs: Int = Int(Date.now.timeIntervalSince1970 * 1000),
        schemaVersion: Int = 1
    ) {
        self.id = id; self.latitude = latitude; self.longitude = longitude
        self.displayName = displayName; self.addressLine = addressLine
        self.locality = locality; self.isPinned = isPinned
        self.nickname = nickname; self.timestampMs = timestampMs
        self.schemaVersion = schemaVersion
    }

    /// Equality by location ID.
    public static func == (lhs: SavedLocation, rhs: SavedLocation) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public func toLocation() -> Location {
        Location(latitude: latitude, longitude: longitude, address: displayName)
    }
}
