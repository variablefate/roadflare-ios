import Testing
import Foundation
@testable import RoadFlare
@testable import RidestrSDK

// MARK: - UserSettings Tests

@Suite("UserSettings Tests")
struct UserSettingsTests {
    @MainActor
    @Test func defaultsEmpty() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let settings = UserSettings(defaults: defaults)
        #expect(settings.paymentMethods.isEmpty)
        #expect(settings.profileName.isEmpty)
        #expect(!settings.profileCompleted)
    }

    @MainActor
    @Test func togglePaymentMethod() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let settings = UserSettings(defaults: defaults)
        settings.togglePaymentMethod(.zelle)
        #expect(settings.isEnabled(.zelle))
        settings.togglePaymentMethod(.zelle)
        #expect(!settings.isEnabled(.zelle))
        #expect(settings.isEnabled(.cash))  // Cash forced as fallback
    }

    @MainActor
    @Test func cashForcedWhenAllRemoved() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let settings = UserSettings(defaults: defaults)
        settings.togglePaymentMethod(.venmo)
        settings.togglePaymentMethod(.venmo)
        #expect(settings.isCashForced)
        #expect(settings.paymentMethods == [.cash])
    }

    @MainActor
    @Test func paymentMethodsPersist() {
        let suiteName = "test_\(UUID().uuidString)"
        let s1 = UserSettings(defaults: UserDefaults(suiteName: suiteName)!)
        s1.togglePaymentMethod(.zelle)
        s1.togglePaymentMethod(.venmo)

        let s2 = UserSettings(defaults: UserDefaults(suiteName: suiteName)!)
        #expect(s2.isEnabled(.zelle))
        #expect(s2.isEnabled(.venmo))
    }

    @MainActor
    @Test func legacyPaymentSettingsMigrateIntoUnifiedRoadflareOrder() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(["zelle", "cash"], forKey: "user_payment_methods")
        defaults.set(["venmo-business"], forKey: "user_custom_payment_methods")

        let settings = UserSettings(defaults: defaults)

        #expect(settings.roadflarePaymentMethods == ["zelle", "cash", "venmo-business"])
        #expect(settings.customPaymentMethods == ["venmo-business"])
    }

    @MainActor
    @Test func roadflareSettingsPreserveBitcoinDuringMigration() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(["bitcoin", "cash"], forKey: "user_payment_methods")

        let settings = UserSettings(defaults: defaults)

        #expect(settings.roadflarePaymentMethods == ["bitcoin", "cash"])
    }

    @MainActor
    @Test func roadflareSettingsKeepStoredBitcoinUnifiedMethods() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        defaults.set(["bitcoin"], forKey: "user_roadflare_payment_methods")

        let settings = UserSettings(defaults: defaults)

        #expect(settings.roadflarePaymentMethods == ["bitcoin"])
        #expect(defaults.stringArray(forKey: "user_roadflare_payment_methods") == ["bitcoin"])
    }

    @MainActor
    @Test func addCustomPaymentMethodCanonicalizesKnownBitcoinLabel() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let settings = UserSettings(defaults: defaults)

        let result = settings.addCustomPaymentMethod("Bitcoin")

        #expect(result == .added)
        #expect(settings.roadflarePaymentMethods == ["bitcoin"])
    }

    @MainActor
    @Test func addCustomPaymentMethodRejectsDuplicateKnownLabel() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let settings = UserSettings(defaults: defaults)
        settings.setRoadflarePaymentMethods(["bitcoin"])

        let result = settings.addCustomPaymentMethod("Bitcoin")

        #expect(result == .duplicate)
        #expect(settings.roadflarePaymentMethods == ["bitcoin"])
    }

    @MainActor
    @Test func profileNamePersists() {
        let suiteName = "test_\(UUID().uuidString)"
        let s1 = UserSettings(defaults: UserDefaults(suiteName: suiteName)!)
        s1.profileName = "Alice"
        let s2 = UserSettings(defaults: UserDefaults(suiteName: suiteName)!)
        #expect(s2.profileName == "Alice")
    }

    @MainActor
    @Test func clearAll() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let settings = UserSettings(defaults: defaults)
        settings.togglePaymentMethod(.zelle)
        settings.profileName = "Bob"
        settings.profileCompleted = true
        settings.clearAll()
        #expect(settings.paymentMethods.isEmpty)
        #expect(settings.profileName.isEmpty)
        #expect(!settings.profileCompleted)
    }
}

// MARK: - RideHistoryStore Tests

@Suite("RideHistoryStore Tests")
struct RideHistoryStoreTests {
    @MainActor
    private func makeStore() -> RideHistoryStore {
        RideHistoryStore(defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!)
    }

    private func makeEntry(id: String = UUID().uuidString, fare: Decimal = 10.0) -> RideHistoryEntry {
        RideHistoryEntry(
            id: id, date: .now, counterpartyPubkey: "driver",
            pickupGeohash: "abc", dropoffGeohash: "def",
            pickup: Location(latitude: 40, longitude: -74),
            destination: Location(latitude: 41, longitude: -73),
            fare: fare, paymentMethod: "zelle"
        )
    }

    @MainActor
    @Test func emptyOnInit() {
        let store = makeStore()
        #expect(store.rides.isEmpty)
    }

    @MainActor
    @Test func addRide() {
        let store = makeStore()
        store.addRide(makeEntry(id: "ride1"))
        #expect(store.rides.count == 1)
    }

    @MainActor
    @Test func addRideDeduplicatesById() {
        let store = makeStore()
        store.addRide(makeEntry(id: "ride1"))
        store.addRide(makeEntry(id: "ride1"))
        #expect(store.rides.count == 1)
    }

    @MainActor
    @Test func addRideNewestFirst() {
        let store = makeStore()
        store.addRide(makeEntry(id: "old"))
        store.addRide(makeEntry(id: "new"))
        #expect(store.rides.first?.id == "new")
    }

    @MainActor
    @Test func removeRide() {
        let store = makeStore()
        store.addRide(makeEntry(id: "ride1"))
        store.addRide(makeEntry(id: "ride2"))
        store.removeRide(id: "ride1")
        #expect(store.rides.count == 1)
    }

    @MainActor
    @Test func clearAll() {
        let store = makeStore()
        store.addRide(makeEntry(id: "ride1"))
        store.clearAll()
        #expect(store.rides.isEmpty)
    }

    @MainActor
    @Test func persistsAcrossInit() {
        let suiteName = "test_\(UUID().uuidString)"
        let s1 = RideHistoryStore(defaults: UserDefaults(suiteName: suiteName)!)
        s1.addRide(makeEntry(id: "ride1", fare: 15.50))
        let s2 = RideHistoryStore(defaults: UserDefaults(suiteName: suiteName)!)
        #expect(s2.rides.count == 1)
        #expect(s2.rides.first?.fare == 15.50)
    }
}

// MARK: - SavedLocationsStore Tests

@Suite("SavedLocationsStore Tests")
struct SavedLocationsStoreTests {
    @MainActor
    @Test func recentsDoNotTriggerFavoritesChanged() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let store = SavedLocationsStore(defaults: defaults)
        var changeCount = 0
        var favoritesChangeCount = 0

        store.onChange = { changeCount += 1 }
        store.onFavoritesChanged = { favoritesChangeCount += 1 }

        store.addRecent(
            latitude: 36.17,
            longitude: -115.14,
            displayName: "Airport",
            addressLine: "Harry Reid Intl"
        )

        #expect(changeCount == 1)
        #expect(favoritesChangeCount == 0)
    }

    @MainActor
    @Test func pinningFavoriteTriggersFavoritesChanged() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let store = SavedLocationsStore(defaults: defaults)
        var favoritesChangeCount = 0

        store.onFavoritesChanged = { favoritesChangeCount += 1 }

        let recent = SavedLocation(
            id: "home",
            latitude: 36.17,
            longitude: -115.14,
            displayName: "Home",
            addressLine: "123 Main St",
            isPinned: false
        )
        store.save(recent)
        store.pin(id: "home", nickname: "Home")

        #expect(favoritesChangeCount == 1)
        #expect(store.favorites.count == 1)
    }
}

// MARK: - AppState Tests

@Suite("AppState Tests")
struct AppStateTests {
    @MainActor
    @Test func localAuthStateRequiresRoadflareMethodsBeforeReady() {
        let appState = AppState()
        appState.settings.profileName = "Alice"
        appState.settings.profileCompleted = true
        appState.settings.setRoadflarePaymentMethods([])

        #expect(appState.resolveLocalAuthState() == .paymentSetup)
    }

    @MainActor
    @Test func profileBackupContentIncludesPinnedAndRecentLocations() {
        let appState = AppState()
        appState.settings.setRoadflarePaymentMethods(["zelle", "venmo-business"])

        appState.savedLocations.save(SavedLocation(
            id: "fav",
            latitude: 36.17,
            longitude: -115.14,
            displayName: "Home",
            addressLine: "123 Main St",
            isPinned: true,
            nickname: "Home",
            timestampMs: 100
        ))
        appState.savedLocations.save(SavedLocation(
            id: "recent",
            latitude: 36.12,
            longitude: -115.17,
            displayName: "Airport",
            addressLine: "Harry Reid Intl",
            isPinned: false,
            timestampMs: 200
        ))

        let backup = appState.buildProfileBackupContent()

        #expect(backup.savedLocations.count == 2)
        #expect(backup.savedLocations.contains {
            $0.displayName == "Home" && $0.isPinned && $0.nickname == "Home" && $0.timestampMs == 100
        })
        #expect(backup.savedLocations.contains {
            $0.displayName == "Airport" && !$0.isPinned && $0.timestampMs == 200
        })
        #expect(backup.settings.roadflarePaymentMethods == ["zelle", "venmo-business"])
        #expect(backup.settings.customPaymentMethods == ["venmo-business"])
    }

    @MainActor
    @Test func profileBackupContentPreservesImportedAndroidSettingsTemplate() {
        let appState = AppState()
        appState.preserveProfileBackupSettingsTemplate(
            SettingsBackupContent(
                roadflarePaymentMethods: ["cash"],
                notificationSoundEnabled: false,
                notificationVibrationEnabled: false,
                autoOpenNavigation: false,
                alwaysAskVehicle: false,
                customRelays: ["wss://relay.example"],
                paymentMethods: ["cashu", "lightning"],
                defaultPaymentMethod: "cashu",
                mintUrl: "https://mint.example"
            )
        )
        appState.settings.setRoadflarePaymentMethods(["zelle", "venmo-business"])

        let backup = appState.buildProfileBackupContent()

        #expect(backup.settings.roadflarePaymentMethods == ["zelle", "venmo-business"])
        #expect(backup.settings.notificationSoundEnabled == false)
        #expect(backup.settings.notificationVibrationEnabled == false)
        #expect(backup.settings.autoOpenNavigation == false)
        #expect(backup.settings.alwaysAskVehicle == false)
        #expect(backup.settings.customRelays == ["wss://relay.example"])
        #expect(backup.settings.paymentMethods == ["cashu", "lightning"])
        #expect(backup.settings.defaultPaymentMethod == "cashu")
        #expect(backup.settings.mintUrl == "https://mint.example")
    }
}

// MARK: - UserDefaultsDriversPersistence Tests

@Suite("UserDefaultsDriversPersistence Tests")
struct UserDefaultsDriversPersistenceTests {
    @Test func saveAndLoadDrivers() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let p = UserDefaultsDriversPersistence(defaults: defaults)
        let drivers = [
            FollowedDriver(pubkey: "d1", name: "Alice",
                           roadflareKey: RoadflareKey(privateKeyHex: "p", publicKeyHex: "q", version: 1)),
            FollowedDriver(pubkey: "d2", name: "Bob"),
        ]
        p.saveDrivers(drivers)
        let loaded = p.loadDrivers()
        #expect(loaded.count == 2)
        #expect(loaded[0].name == "Alice")
        #expect(loaded[0].roadflareKey?.version == 1)
    }

    @Test func saveAndLoadNames() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let p = UserDefaultsDriversPersistence(defaults: defaults)
        p.saveDriverNames(["d1": "Alice", "d2": "Bob"])
        let loaded = p.loadDriverNames()
        #expect(loaded["d1"] == "Alice")
    }

    @Test func emptyOnInit() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let p = UserDefaultsDriversPersistence(defaults: defaults)
        #expect(p.loadDrivers().isEmpty)
        #expect(p.loadDriverNames().isEmpty)
    }

    @Test func overwriteDrivers() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let p = UserDefaultsDriversPersistence(defaults: defaults)
        p.saveDrivers([FollowedDriver(pubkey: "d1")])
        p.saveDrivers([FollowedDriver(pubkey: "d2"), FollowedDriver(pubkey: "d3")])
        let loaded = p.loadDrivers()
        #expect(loaded.count == 2)
        #expect(loaded[0].pubkey == "d2")
    }

    @Test func driverWithAllFields() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let p = UserDefaultsDriversPersistence(defaults: defaults)
        let driver = FollowedDriver(
            pubkey: "d1", addedAt: 1700000000, name: "Alice", note: "Toyota",
            roadflareKey: RoadflareKey(privateKeyHex: "aa", publicKeyHex: "bb", version: 3, keyUpdatedAt: 1700000000)
        )
        p.saveDrivers([driver])
        let loaded = p.loadDrivers()
        #expect(loaded[0].note == "Toyota")
        #expect(loaded[0].roadflareKey?.version == 3)
        #expect(loaded[0].roadflareKey?.keyUpdatedAt == 1700000000)
    }
}

// MARK: - RideStatePersistence Tests

@Suite("RideStatePersistence Tests", .serialized)
struct RideStatePersistenceTests {
    init() { RideStatePersistence.clear() }

    private func setupAndSave(
        stage: RiderStage,
        pin: String? = "1234",
        confirmationId: String? = "conf1",
        pinAttempts: Int = 0
    ) {
        let sm = RideStateMachine()
        sm.restore(
            stage: stage, offerEventId: "o1", acceptanceEventId: "a1",
            confirmationEventId: confirmationId, driverPubkey: "d1",
            pin: pin, pinAttempts: pinAttempts, pinVerified: false,
            paymentMethod: "zelle", fiatPaymentMethods: ["zelle", "venmo"]
        )
        RideStatePersistence.save(
            stateMachine: sm,
            pickupLocation: Location(latitude: 40.71, longitude: -74.01, address: "Penn Station"),
            destinationLocation: Location(latitude: 40.76, longitude: -73.98, address: "Central Park"),
            fareEstimate: FareEstimate(distanceMiles: 5.5, durationMinutes: 18, fareUSD: 12.50),
            paymentMethod: "zelle"
        )
    }

    @Test func saveAndLoad() {
        setupAndSave(stage: .rideConfirmed)
        let loaded = RideStatePersistence.load()
        #expect(loaded != nil)
        #expect(loaded?.stage == "rideConfirmed")
        #expect(loaded?.pin == "1234")
        #expect(loaded?.driverPubkey == "d1")
        #expect(loaded?.confirmationEventId == "conf1")
        #expect(loaded?.pickupLat == 40.71)
        #expect(loaded?.pickupAddress == "Penn Station")
        #expect(loaded?.destLat == 40.76)
        #expect(loaded?.destAddress == "Central Park")
        #expect(loaded?.fareUSD == "12.5")
        #expect(loaded?.paymentMethodRaw == "zelle")
        #expect(loaded?.fiatPaymentMethodsRaw == ["zelle", "venmo"])
        RideStatePersistence.clear()
    }

    @Test func saveCanOmitDriverStateCursor() {
        let sm = RideStateMachine()
        sm.restore(
            stage: .driverArrived,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: "conf1",
            driverPubkey: "d1",
            pin: "1234",
            pinVerified: false,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"],
            lastDriverStatus: "arrived",
            lastDriverStateTimestamp: 1_700_000_100,
            lastDriverActionCount: 1
        )

        RideStatePersistence.save(
            stateMachine: sm,
            pickupLocation: nil,
            destinationLocation: nil,
            fareEstimate: nil,
            paymentMethod: "zelle",
            persistDriverStateCursor: false
        )

        let loaded = RideStatePersistence.load()
        #expect(loaded?.lastDriverStatus == "arrived")
        #expect(loaded?.lastDriverStateTimestamp == nil)
        #expect(loaded?.lastDriverActionCount == nil)
        RideStatePersistence.clear()
    }

    @Test func loadReturnsNilWhenEmpty() {
        RideStatePersistence.clear()
        #expect(RideStatePersistence.load() == nil)
    }

    @Test func loadIgnoresIdle() {
        setupAndSave(stage: .idle)
        #expect(RideStatePersistence.load() == nil)
        RideStatePersistence.clear()
    }

    @Test func loadIgnoresCompleted() {
        setupAndSave(stage: .completed)
        #expect(RideStatePersistence.load() == nil)
        RideStatePersistence.clear()
    }

    @Test func loadAcceptsWaitingForAcceptance() {
        setupAndSave(stage: .waitingForAcceptance)
        #expect(RideStatePersistence.load()?.stage == "waitingForAcceptance")
        RideStatePersistence.clear()
    }

    @Test func waitingForAcceptanceSurvivesShortRelaunchWithinOfferLifetime() {
        setupAndSave(stage: .waitingForAcceptance)
        let stillLiveAt = Date.now.addingTimeInterval(60)
        #expect(RideStatePersistence.load(now: stillLiveAt)?.stage == "waitingForAcceptance")
        RideStatePersistence.clear()
    }

    @Test func waitingForAcceptanceExpiresWithDriverOfferVisibilityWindow() {
        setupAndSave(stage: .waitingForAcceptance)
        let expiredAt = Date.now.addingTimeInterval(TimeInterval(RideStatePersistence.interopOfferVisibilitySeconds + 1))
        #expect(RideStatePersistence.load(now: expiredAt) == nil)
        RideStatePersistence.clear()
    }

    @Test func loadAcceptsDriverAccepted() {
        setupAndSave(stage: .driverAccepted)
        #expect(RideStatePersistence.load()?.stage == "driverAccepted")
        RideStatePersistence.clear()
    }

    @Test func driverAcceptedExpiresWithDriverConfirmationTimeout() {
        setupAndSave(stage: .driverAccepted)
        let expiredAt = Date.now.addingTimeInterval(RideConstants.confirmationTimeoutSeconds + 1)
        #expect(RideStatePersistence.load(now: expiredAt) == nil)
        RideStatePersistence.clear()
    }

    @Test func loadAcceptsDriverArrived() {
        setupAndSave(stage: .driverArrived)
        #expect(RideStatePersistence.load()?.stage == "driverArrived")
        RideStatePersistence.clear()
    }

    @Test func loadAcceptsInProgress() {
        setupAndSave(stage: .inProgress)
        #expect(RideStatePersistence.load()?.stage == "inProgress")
        RideStatePersistence.clear()
    }

    @Test func clearRemovesData() {
        setupAndSave(stage: .rideConfirmed)
        #expect(RideStatePersistence.load() != nil)
        RideStatePersistence.clear()
        #expect(RideStatePersistence.load() == nil)
    }

    @Test func saveWithoutLocations() {
        let sm = RideStateMachine()
        sm.restore(stage: .waitingForAcceptance, offerEventId: "o1", acceptanceEventId: nil,
                   confirmationEventId: nil, driverPubkey: "d1", pin: nil,
                   pinVerified: false, paymentMethod: nil, fiatPaymentMethods: [])
        RideStatePersistence.save(
            stateMachine: sm,
            pickupLocation: nil, destinationLocation: nil,
            fareEstimate: nil, paymentMethod: nil
        )
        let loaded = RideStatePersistence.load()
        #expect(loaded?.pickupLat == nil)
        #expect(loaded?.destLat == nil)
        #expect(loaded?.fareUSD == nil)
        RideStatePersistence.clear()
    }

    @Test func pinSurvivesPersistence() {
        setupAndSave(stage: .driverArrived, pin: "5678")
        let loaded = RideStatePersistence.load()
        #expect(loaded?.pin == "5678")
        RideStatePersistence.clear()
    }

    @Test func pinAttemptsSurvivePersistence() {
        setupAndSave(stage: .driverArrived, pinAttempts: 3)
        let loaded = RideStatePersistence.load()
        #expect(loaded?.pinAttempts == 3)
        RideStatePersistence.clear()
    }
}
