import Foundation
import Testing
@testable import RidestrSDK

@Suite("RoadflareModels Tests")
struct RoadflareModelsTests {
    // MARK: - RoadflareKey

    @Test func roadflareKeyCodable() throws {
        let key = RoadflareKey(privateKeyHex: "aabb", publicKeyHex: "ccdd", version: 3, keyUpdatedAt: 1700000000)
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(RoadflareKey.self, from: data)
        #expect(decoded.privateKeyHex == "aabb")
        #expect(decoded.publicKeyHex == "ccdd")
        #expect(decoded.version == 3)
        #expect(decoded.keyUpdatedAt == 1700000000)
    }

    @Test func roadflareKeyCodingKeysMatchAndroid() throws {
        // Android uses "privateKey" and "publicKey" field names
        let json = """
        {"privateKey":"aabb","publicKey":"ccdd","version":2,"keyUpdatedAt":1700000000}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RoadflareKey.self, from: json)
        #expect(decoded.privateKeyHex == "aabb")
        #expect(decoded.version == 2)
    }

    // MARK: - RoadflareLocation

    @Test func roadflareLocationCodable() throws {
        let json = """
        {"lat":40.7128,"lon":-74.006,"timestamp":1700000000,"status":"online"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RoadflareLocation.self, from: json)
        #expect(decoded.latitude == 40.7128)
        #expect(decoded.longitude == -74.006)
        #expect(decoded.status == .online)
        #expect(decoded.timestamp == 1700000000)
    }

    @Test func roadflareLocationOnRide() throws {
        let json = """
        {"lat":40.0,"lon":-74.0,"timestamp":1700000000,"status":"on_ride","onRide":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RoadflareLocation.self, from: json)
        #expect(decoded.status == .onRide)
        #expect(decoded.onRide == true)
    }

    // MARK: - RoadflareStatus

    @Test func roadflareStatusRawValues() {
        #expect(RoadflareStatus.online.rawValue == "online")
        #expect(RoadflareStatus.onRide.rawValue == "on_ride")
        #expect(RoadflareStatus.offline.rawValue == "offline")
    }

    // MARK: - FollowedDriver

    @Test func followedDriverInit() {
        let driver = FollowedDriver(pubkey: "abc123", name: "Alice", note: "Great driver")
        #expect(driver.id == "abc123")
        #expect(driver.pubkey == "abc123")
        #expect(driver.name == "Alice")
        #expect(driver.note == "Great driver")
        #expect(!driver.hasKey)
    }

    @Test func followedDriverHasKey() {
        var driver = FollowedDriver(pubkey: "abc123")
        #expect(!driver.hasKey)
        driver.roadflareKey = RoadflareKey(privateKeyHex: "priv", publicKeyHex: "pub", version: 1, keyUpdatedAt: 0)
        #expect(driver.hasKey)
    }

    @Test func followedDriverCodable() throws {
        let driver = FollowedDriver(
            pubkey: "abc123",
            name: "Bob",
            roadflareKey: RoadflareKey(privateKeyHex: "pp", publicKeyHex: "qq", version: 1, keyUpdatedAt: 100)
        )
        let data = try JSONEncoder().encode(driver)
        let decoded = try JSONDecoder().decode(FollowedDriver.self, from: data)
        #expect(decoded.pubkey == "abc123")
        #expect(decoded.name == "Bob")
        #expect(decoded.roadflareKey?.version == 1)
    }

    // MARK: - FollowedDriversContent (Kind 30011)

    @Test func followedDriversContentCodable() throws {
        let content = FollowedDriversContent(
            drivers: [
                FollowedDriverEntry(pubkey: "d1", addedAt: 100, note: "test", roadflareKey: nil),
                FollowedDriverEntry(pubkey: "d2", addedAt: 200, note: nil,
                    roadflareKey: RoadflareKey(privateKeyHex: "p", publicKeyHex: "q", version: 1, keyUpdatedAt: 300)),
            ],
            updatedAt: 500
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(FollowedDriversContent.self, from: data)
        #expect(decoded.drivers.count == 2)
        #expect(decoded.drivers[0].pubkey == "d1")
        #expect(decoded.drivers[1].roadflareKey?.version == 1)
        #expect(decoded.updatedAt == 500)
    }

    @Test func followedDriversContentCodingKeys() throws {
        let json = """
        {"drivers":[{"pubkey":"d1","addedAt":100,"note":null,"roadflareKey":null}],"updated_at":500}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(FollowedDriversContent.self, from: json)
        #expect(decoded.updatedAt == 500)
    }

    // MARK: - KeyShareContent (Kind 3186)

    @Test func keyShareContentCodable() throws {
        let content = KeyShareContent(
            roadflareKey: RoadflareKey(privateKeyHex: "aa", publicKeyHex: "bb", version: 3, keyUpdatedAt: 1000),
            keyUpdatedAt: 1000,
            driverPubKey: "driver_hex"
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(KeyShareContent.self, from: data)
        #expect(decoded.roadflareKey.version == 3)
        #expect(decoded.driverPubKey == "driver_hex")
    }

    // MARK: - KeyAckContent (Kind 3188)

    @Test func keyAckContentCodable() throws {
        let content = KeyAckContent(keyVersion: 2, keyUpdatedAt: 1000, status: "received", riderPubKey: "rider_hex")
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(KeyAckContent.self, from: data)
        #expect(decoded.keyVersion == 2)
        #expect(decoded.status == "received")
    }

    @Test func keyAckStaleStatus() throws {
        let content = KeyAckContent(keyVersion: 1, keyUpdatedAt: 500, status: "stale", riderPubKey: "r1")
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(KeyAckContent.self, from: data)
        #expect(decoded.status == "stale")
    }

    // MARK: - UserProfileContent (Kind 0)

    @Test func profileToJSONAllFields() {
        let profile = UserProfileContent(
            name: "alice", displayName: "Alice", about: "Rider",
            picture: "https://example.com/pic.jpg", banner: "https://example.com/banner.jpg",
            website: "https://example.com", nip05: "alice@example.com",
            lud16: "alice@getalby.com", lud06: "lnurl1..."
        )
        let json = profile.toJSON()
        #expect(json.contains("\"name\":\"alice\""))
        #expect(json.contains("\"display_name\":\"Alice\""))
        #expect(json.contains("\"about\":\"Rider\""))
        #expect(json.contains("\"lud16\":\"alice@getalby.com\""))
    }

    @Test func profileToJSONSkipsNilAndEmpty() {
        let profile = UserProfileContent(name: "Bob", displayName: nil, about: "")
        let json = profile.toJSON()
        #expect(json.contains("\"name\":\"Bob\""))
        #expect(!json.contains("display_name"))
        #expect(!json.contains("about"))
    }

    @Test func profileToJSONEmpty() {
        let profile = UserProfileContent()
        #expect(profile.toJSON() == "{}")
    }

    @Test func profileFromJSONFull() {
        let json = """
        {"name":"alice","display_name":"Alice","about":"Bio","picture":"https://pic.jpg","nip05":"a@b.com","lud16":"a@ln.com"}
        """
        let profile = UserProfileContent.fromJSON(json)
        #expect(profile?.name == "alice")
        #expect(profile?.displayName == "Alice")
        #expect(profile?.about == "Bio")
        #expect(profile?.picture == "https://pic.jpg")
        #expect(profile?.nip05 == "a@b.com")
        #expect(profile?.lud16 == "a@ln.com")
    }

    @Test func profileFromJSONPartial() {
        let json = """
        {"display_name":"Bob"}
        """
        let profile = UserProfileContent.fromJSON(json)
        #expect(profile?.displayName == "Bob")
        #expect(profile?.name == nil)
        #expect(profile?.about == nil)
    }

    @Test func profileFromJSONMalformed() {
        #expect(UserProfileContent.fromJSON("not json") == nil)
        #expect(UserProfileContent.fromJSON("") == nil)
    }

    @Test func profileRoundtrip() {
        let original = UserProfileContent(name: "test", displayName: "Test User", about: "Hi")
        let json = original.toJSON()
        let decoded = UserProfileContent.fromJSON(json)
        #expect(decoded?.name == original.name)
        #expect(decoded?.displayName == original.displayName)
        #expect(decoded?.about == original.about)
    }

    @Test func profileAndroidCompatJSON() {
        // Verify JSON from Android client parses correctly (including vehicle fields)
        let androidJSON = """
        {"name":"Driver","display_name":"John Smith","about":"Professional driver","picture":"https://img.com/photo.jpg","lud16":"john@walletofsatoshi.com","car_make":"Toyota","car_model":"Camry","car_color":"Blue","car_year":"2024"}
        """
        let profile = UserProfileContent.fromJSON(androidJSON)
        #expect(profile?.name == "Driver")
        #expect(profile?.displayName == "John Smith")
        #expect(profile?.lud16 == "john@walletofsatoshi.com")
        #expect(profile?.carMake == "Toyota")
        #expect(profile?.carModel == "Camry")
        #expect(profile?.carColor == "Blue")
        #expect(profile?.carYear == "2024")
        #expect(profile?.vehicleDescription == "Blue Toyota Camry")
    }

    @Test func vehicleDescriptionCombinations() {
        #expect(UserProfileContent(carMake: "Tesla", carModel: "Model S", carColor: "Black").vehicleDescription == "Black Tesla Model S")
        #expect(UserProfileContent(carMake: "Toyota", carModel: "Camry").vehicleDescription == "Toyota Camry")
        #expect(UserProfileContent(carMake: "Honda").vehicleDescription == "Honda")
        #expect(UserProfileContent(carColor: "Red").vehicleDescription == "Red")
        #expect(UserProfileContent(carModel: "Civic").vehicleDescription == "Civic")
        #expect(UserProfileContent().vehicleDescription == nil)
        #expect(UserProfileContent(carMake: "", carModel: "").vehicleDescription == nil)
    }

    @Test func vehicleFieldsRoundtrip() {
        let original = UserProfileContent(name: "Driver", carMake: "Ford", carModel: "F-150", carColor: "White", carYear: "2023")
        let json = original.toJSON()
        #expect(json.contains("\"car_make\":\"Ford\""))
        #expect(json.contains("\"car_year\":\"2023\""))
        let decoded = UserProfileContent.fromJSON(json)
        #expect(decoded?.carMake == "Ford")
        #expect(decoded?.carModel == "F-150")
        #expect(decoded?.carColor == "White")
        #expect(decoded?.carYear == "2023")
    }

    // MARK: - ProfileBackupContent (Kind 30177)

    @Test func profileBackupCodableRoundtrip() throws {
        let content = ProfileBackupContent(
            savedLocations: [
                SavedLocationBackup(displayName: "Home", lat: 40.7, lon: -74.0, addressLine: "123 Main St", isPinned: true)
            ],
            settings: SettingsBackupContent(roadflarePaymentMethods: ["venmo", "zelle"])
        )
        let data = try JSONEncoder().encode(content)
        let decoded = try JSONDecoder().decode(ProfileBackupContent.self, from: data)
        #expect(decoded.savedLocations.count == 1)
        #expect(decoded.savedLocations[0].displayName == "Home")
        #expect(decoded.savedLocations[0].lat == 40.7)
        #expect(decoded.savedLocations[0].lon == -74.0)
        #expect(decoded.savedLocations[0].isPinned == true)
        #expect(decoded.settings.roadflarePaymentMethods == ["venmo", "zelle"])
        #expect(decoded.vehicles.isEmpty)
    }

    @Test func profileBackupDecodesAndroidFormat() throws {
        // Simulate JSON from Android with vehicles array
        let androidJSON = """
        {
            "vehicles": [{"id":"v1","make":"Toyota","model":"Camry","year":2022,"color":"Blue","licensePlate":"ABC123","isPrimary":true}],
            "savedLocations": [{"displayName":"Work","lat":37.78,"lon":-122.41,"addressLine":"456 Market St","isPinned":true,"locality":"SF"}],
            "settings": {"roadflarePaymentMethods":["cash_app","venmo"],"displayCurrency":"USD","distanceUnit":"MILES","notificationSoundEnabled":true,"paymentMethods":["cashu","lightning"],"defaultPaymentMethod":"cashu","mintUrl":"https://mint.example"},
            "updated_at": 1700000000
        }
        """
        let decoded = try JSONDecoder().decode(ProfileBackupContent.self, from: androidJSON.data(using: .utf8)!)
        #expect(decoded.vehicles.count == 1)
        #expect(decoded.vehicles[0].make == "Toyota")
        #expect(decoded.vehicles[0].isPrimary == true)
        #expect(decoded.savedLocations.count == 1)
        #expect(decoded.savedLocations[0].displayName == "Work")
        #expect(decoded.savedLocations[0].locality == "SF")
        #expect(decoded.settings.roadflarePaymentMethods == ["cash_app", "venmo"])
        #expect(decoded.settings.notificationSoundEnabled == true)
        #expect(decoded.settings.paymentMethods == ["cashu", "lightning"])
        #expect(decoded.settings.defaultPaymentMethod == "cashu")
        #expect(decoded.settings.mintUrl == "https://mint.example")
        #expect(decoded.updatedAt == 1700000000)
    }

    @Test func profileBackupDecodesWithoutCustomPaymentMethods() throws {
        let androidJSON = """
        {
            "vehicles": [],
            "savedLocations": [],
            "settings": {"roadflarePaymentMethods":["cash_app"],"displayCurrency":"USD","distanceUnit":"MILES"},
            "updated_at": 1700000000
        }
        """
        let decoded = try JSONDecoder().decode(ProfileBackupContent.self, from: androidJSON.data(using: .utf8)!)
        #expect(decoded.settings.roadflarePaymentMethods == ["cash_app"])
        #expect(decoded.settings.customPaymentMethods.isEmpty)
    }

    @Test func settingsBackupMergesLegacyCustomPaymentMethodsIntoOrderedList() throws {
        let legacyJSON = """
        {
            "roadflarePaymentMethods":["zelle","cash"],
            "customPaymentMethods":["venmo-business","sat transfer"],
            "displayCurrency":"USD",
            "distanceUnit":"MILES"
        }
        """
        let decoded = try JSONDecoder().decode(
            SettingsBackupContent.self,
            from: Data(legacyJSON.utf8)
        )

        #expect(decoded.roadflarePaymentMethods == ["zelle", "cash", "venmo-business", "sat transfer"])
        #expect(decoded.customPaymentMethods == ["venmo-business", "sat transfer"])
    }

    @Test func settingsBackupEncodesSingleOrderedRoadflareList() throws {
        let settings = SettingsBackupContent(
            roadflarePaymentMethods: ["venmo-business", "zelle", "cash"]
        )

        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(settings)
        ) as? [String: Any]

        #expect(object?["customPaymentMethods"] == nil)
        #expect(object?["roadflarePaymentMethods"] as? [String] == ["venmo-business", "zelle", "cash"])
    }

    @Test func settingsBackupPreservesAndroidPaymentFieldsOnReencode() throws {
        let androidJSON = """
        {
            "roadflarePaymentMethods":["venmo-business","cash"],
            "displayCurrency":"USD",
            "distanceUnit":"MILES",
            "notificationSoundEnabled":false,
            "notificationVibrationEnabled":true,
            "autoOpenNavigation":false,
            "alwaysAskVehicle":false,
            "customRelays":["wss://relay.example"],
            "paymentMethods":["cashu","lightning"],
            "defaultPaymentMethod":"cashu",
            "mintUrl":"https://mint.example"
        }
        """
        let decoded = try JSONDecoder().decode(
            SettingsBackupContent.self,
            from: Data(androidJSON.utf8)
        )
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(decoded)
        ) as? [String: Any]

        #expect(object?["notificationSoundEnabled"] as? Bool == false)
        #expect(object?["notificationVibrationEnabled"] as? Bool == true)
        #expect(object?["autoOpenNavigation"] as? Bool == false)
        #expect(object?["alwaysAskVehicle"] as? Bool == false)
        #expect(object?["customRelays"] as? [String] == ["wss://relay.example"])
        #expect(object?["paymentMethods"] as? [String] == ["cashu", "lightning"])
        #expect(object?["defaultPaymentMethod"] as? String == "cashu")
        #expect(object?["mintUrl"] as? String == "https://mint.example")
    }

    @Test func settingsBackupPreservesBitcoinInRoadflareMethods() {
        let settings = SettingsBackupContent(
            roadflarePaymentMethods: ["bitcoin", "zelle", "cash"]
        )

        #expect(settings.roadflarePaymentMethods == ["bitcoin", "zelle", "cash"])
    }

    @Test func profileBackupEmptyArrays() throws {
        let json = """
        {"vehicles":[],"savedLocations":[],"settings":{"roadflarePaymentMethods":[],"displayCurrency":"USD","distanceUnit":"MILES"},"updated_at":0}
        """
        let decoded = try JSONDecoder().decode(ProfileBackupContent.self, from: json.data(using: .utf8)!)
        #expect(decoded.vehicles.isEmpty)
        #expect(decoded.savedLocations.isEmpty)
        #expect(decoded.settings.roadflarePaymentMethods.isEmpty)
    }

    @Test func settingsBackupContentDefaults() {
        let settings = SettingsBackupContent()
        #expect(settings.roadflarePaymentMethods.isEmpty)
        #expect(settings.customPaymentMethods.isEmpty)
        #expect(settings.displayCurrency == "USD")
        #expect(settings.distanceUnit == "MILES")
        #expect(settings.paymentMethods == ["cashu"])
        #expect(settings.defaultPaymentMethod == "cashu")
    }

    // MARK: - RideHistoryEntry

    @Test func rideHistoryEntryCodable() throws {
        let entry = RideHistoryEntry(
            id: "ride1", date: Date(timeIntervalSince1970: 1700000000),
            counterpartyPubkey: "driver_pub", counterpartyName: "Alice",
            pickupGeohash: "dr5ru1", dropoffGeohash: "dr5rv2",
            pickup: Location(latitude: 40.71, longitude: -74.01),
            destination: Location(latitude: 40.76, longitude: -73.98),
            fare: 12.50, paymentMethod: "zelle",
            distance: 5.5, duration: 18,
            vehicleMake: "Toyota", vehicleModel: "Camry"
        )
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(RideHistoryEntry.self, from: data)
        #expect(decoded.id == "ride1")
        #expect(decoded.counterpartyName == "Alice")
        #expect(decoded.fare == 12.50)
        #expect(decoded.appOrigin == "roadflare")
    }

    // MARK: - SavedLocation

    @Test func savedLocationInit() {
        let loc = SavedLocation(
            latitude: 40.7128, longitude: -74.006,
            displayName: "Home", addressLine: "123 Main St",
            isPinned: true, nickname: "Home"
        )
        #expect(loc.isPinned)
        #expect(loc.nickname == "Home")
    }

    @Test func savedLocationToLocation() {
        let saved = SavedLocation(
            latitude: 40.7128, longitude: -74.006,
            displayName: "Office", addressLine: "456 Work Ave"
        )
        let loc = saved.toLocation()
        #expect(loc.latitude == 40.7128)
        #expect(loc.address == "Office")
    }

    @Test func savedLocationCodable() throws {
        let saved = SavedLocation(latitude: 40.0, longitude: -74.0, displayName: "Test", addressLine: "Addr")
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(SavedLocation.self, from: data)
        #expect(decoded.displayName == "Test")
    }
}
