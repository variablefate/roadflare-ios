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
    public var notificationSoundEnabled: Bool
    public var notificationVibrationEnabled: Bool
    public var autoOpenNavigation: Bool
    public var alwaysAskVehicle: Bool
    public var customRelays: [String]
    public var paymentMethods: [String]
    public var defaultPaymentMethod: String
    public var mintUrl: String?

    enum CodingKeys: String, CodingKey {
        case roadflarePaymentMethods
        case customPaymentMethods
        case displayCurrency
        case distanceUnit
        case notificationSoundEnabled
        case notificationVibrationEnabled
        case autoOpenNavigation
        case alwaysAskVehicle
        case customRelays
        case paymentMethods
        case defaultPaymentMethod
        case mintUrl
    }

    public init(
        roadflarePaymentMethods: [String] = [],
        customPaymentMethods: [String] = [],
        displayCurrency: String = "USD",
        distanceUnit: String = "MILES",
        notificationSoundEnabled: Bool = true,
        notificationVibrationEnabled: Bool = true,
        autoOpenNavigation: Bool = true,
        alwaysAskVehicle: Bool = true,
        customRelays: [String] = [],
        paymentMethods: [String] = ["cashu"],
        defaultPaymentMethod: String = "cashu",
        mintUrl: String? = nil
    ) {
        self.roadflarePaymentMethods = RoadflarePaymentPreferences(
            methods: roadflarePaymentMethods + customPaymentMethods
        ).methods
        self.displayCurrency = displayCurrency
        self.distanceUnit = distanceUnit
        self.notificationSoundEnabled = notificationSoundEnabled
        self.notificationVibrationEnabled = notificationVibrationEnabled
        self.autoOpenNavigation = autoOpenNavigation
        self.alwaysAskVehicle = alwaysAskVehicle
        self.customRelays = customRelays.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.paymentMethods = paymentMethods.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.defaultPaymentMethod = defaultPaymentMethod
        self.mintUrl = mintUrl
    }

    public var customPaymentMethods: [String] {
        roadflarePaymentMethods.filter { PaymentMethod(rawValue: $0) == nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let roadflarePaymentMethods = try container.decodeIfPresent(
            [String].self,
            forKey: .roadflarePaymentMethods
        ) ?? []
        let legacyCustomPaymentMethods = try container.decodeIfPresent(
            [String].self,
            forKey: .customPaymentMethods
        ) ?? []
        self.roadflarePaymentMethods = RoadflarePaymentPreferences(
            methods: roadflarePaymentMethods + legacyCustomPaymentMethods
        ).methods
        displayCurrency = try container.decodeIfPresent(
            String.self,
            forKey: .displayCurrency
        ) ?? "USD"
        distanceUnit = try container.decodeIfPresent(
            String.self,
            forKey: .distanceUnit
        ) ?? "MILES"
        notificationSoundEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .notificationSoundEnabled
        ) ?? true
        notificationVibrationEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .notificationVibrationEnabled
        ) ?? true
        autoOpenNavigation = try container.decodeIfPresent(
            Bool.self,
            forKey: .autoOpenNavigation
        ) ?? true
        alwaysAskVehicle = try container.decodeIfPresent(
            Bool.self,
            forKey: .alwaysAskVehicle
        ) ?? true
        customRelays = try container.decodeIfPresent(
            [String].self,
            forKey: .customRelays
        ) ?? []
        self.paymentMethods = (try container.decodeIfPresent(
            [String].self,
            forKey: .paymentMethods
        ) ?? ["cashu"]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        defaultPaymentMethod = try container.decodeIfPresent(
            String.self,
            forKey: .defaultPaymentMethod
        ) ?? "cashu"
        mintUrl = try container.decodeIfPresent(
            String.self,
            forKey: .mintUrl
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            RoadflarePaymentPreferences(methods: roadflarePaymentMethods).methods,
            forKey: .roadflarePaymentMethods
        )
        try container.encode(displayCurrency, forKey: .displayCurrency)
        try container.encode(distanceUnit, forKey: .distanceUnit)
        try container.encode(notificationSoundEnabled, forKey: .notificationSoundEnabled)
        try container.encode(notificationVibrationEnabled, forKey: .notificationVibrationEnabled)
        try container.encode(autoOpenNavigation, forKey: .autoOpenNavigation)
        try container.encode(alwaysAskVehicle, forKey: .alwaysAskVehicle)
        try container.encode(customRelays, forKey: .customRelays)
        try container.encode(paymentMethods, forKey: .paymentMethods)
        try container.encode(defaultPaymentMethod, forKey: .defaultPaymentMethod)
        try container.encodeIfPresent(mintUrl, forKey: .mintUrl)
    }
}

/// Full profile backup content (Kind 30177, encrypted to self).
/// Matches Android's ProfileBackupEvent format.
/// The `vehicles` field is present for Android compat but unused by iOS (rider-only).
public struct ProfileBackupContent: Codable, Sendable {
    public var vehicles: [VehicleBackup]
    public var savedLocations: [SavedLocationBackup]
    public var settings: SettingsBackupContent
    public var updatedAt: Int

    enum CodingKeys: String, CodingKey {
        case vehicles
        case savedLocations
        case settings
        case updatedAt = "updated_at"
    }

    public init(
        vehicles: [VehicleBackup] = [],
        savedLocations: [SavedLocationBackup] = [],
        settings: SettingsBackupContent = SettingsBackupContent(),
        updatedAt: Int = Int(Date.now.timeIntervalSince1970)
    ) {
        self.vehicles = vehicles
        self.savedLocations = savedLocations
        self.settings = settings
        self.updatedAt = updatedAt
    }
}

/// Minimal vehicle struct for backup compat with Android.
/// iOS rider app doesn't use vehicles, but must decode them to avoid parse failures.
public struct VehicleBackup: Codable, Sendable {
    public let id: String?
    public let make: String?
    public let model: String?
    public let year: Int?
    public let color: String?
    public let licensePlate: String?
    public let isPrimary: Bool?

    public init(id: String? = nil, make: String? = nil, model: String? = nil,
                year: Int? = nil, color: String? = nil, licensePlate: String? = nil, isPrimary: Bool? = nil) {
        self.id = id; self.make = make; self.model = model
        self.year = year; self.color = color; self.licensePlate = licensePlate; self.isPrimary = isPrimary
    }
}

/// Saved location for backup. Field names match Android's SavedLocation JSON format.
public struct SavedLocationBackup: Codable, Sendable {
    public let displayName: String
    public let lat: Double
    public let lon: Double
    public let addressLine: String?
    public let isPinned: Bool
    public let locality: String?
    public let nickname: String?
    public let timestampMs: Int?

    public init(displayName: String, lat: Double, lon: Double,
                addressLine: String? = nil, isPinned: Bool = false,
                locality: String? = nil, nickname: String? = nil, timestampMs: Int? = nil) {
        self.displayName = displayName
        self.lat = lat
        self.lon = lon
        self.addressLine = addressLine
        self.isPinned = isPinned
        self.locality = locality
        self.nickname = nickname
        self.timestampMs = timestampMs
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

public extension RideHistoryEntry {
    /// Type-safe projection of `status`. Two known cases; unrecognized
    /// values fail-open to `.completed` so a future cross-platform status
    /// addition (e.g. `"ended_early"`) doesn't redact fare data on old clients.
    enum Status: String, Sendable {
        case completed
        case cancelled
    }

    /// Typed projection of the raw `status` string. Fails open to `.completed`.
    var statusEnum: Status { Status(rawValue: status) ?? .completed }
}

// MARK: - Ride History Backup (Kind 30174)

/// Content of a ride history backup event (Kind 30174, encrypted to self).
/// Matches Android's RideHistoryEvent JSON structure for cross-platform sync.
public struct RideHistoryBackupContent: Codable, Sendable {
    public let rides: [RideHistoryEntry]
    public let updatedAt: Int

    enum CodingKeys: String, CodingKey {
        case rides
        case updatedAt = "updated_at"
    }

    public init(rides: [RideHistoryEntry], updatedAt: Int = Int(Date.now.timeIntervalSince1970)) {
        self.rides = rides
        self.updatedAt = updatedAt
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
