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

// MARK: - RideHistoryRepository Tests

@Suite("RideHistoryRepository Tests")
struct RideHistoryRepositoryTests {
    private func makeRepo() -> RideHistoryRepository {
        RideHistoryRepository(persistence: InMemoryRideHistoryPersistence())
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

    @Test func emptyOnInit() {
        let repo = makeRepo()
        #expect(repo.rides.isEmpty)
    }

    @Test func addRide() {
        let repo = makeRepo()
        repo.addRide(makeEntry(id: "ride1"))
        #expect(repo.rides.count == 1)
    }

    @Test func addRideDeduplicatesById() {
        let repo = makeRepo()
        repo.addRide(makeEntry(id: "ride1"))
        repo.addRide(makeEntry(id: "ride1"))
        #expect(repo.rides.count == 1)
    }

    @Test func addRideNewestFirst() {
        let repo = makeRepo()
        repo.addRide(makeEntry(id: "old"))
        repo.addRide(makeEntry(id: "new"))
        #expect(repo.rides.first?.id == "new")
    }

    @Test func removeRide() {
        let repo = makeRepo()
        repo.addRide(makeEntry(id: "ride1"))
        repo.addRide(makeEntry(id: "ride2"))
        repo.removeRide(id: "ride1")
        #expect(repo.rides.count == 1)
    }

    @Test func clearAll() {
        let repo = makeRepo()
        repo.addRide(makeEntry(id: "ride1"))
        repo.clearAll()
        #expect(repo.rides.isEmpty)
    }

    @Test func mergeFromBackupAddsNew() {
        let repo = makeRepo()
        repo.addRide(makeEntry(id: "local"))
        let merged = repo.mergeFromBackup([makeEntry(id: "remote")])
        #expect(merged)
        #expect(repo.rides.count == 2)
    }

    @Test func mergeFromBackupSkipsDuplicates() {
        let repo = makeRepo()
        repo.addRide(makeEntry(id: "ride1"))
        let merged = repo.mergeFromBackup([makeEntry(id: "ride1")])
        #expect(!merged)
        #expect(repo.rides.count == 1)
    }

    @Test func restoreFromBackupReplacesAll() {
        let repo = makeRepo()
        repo.addRide(makeEntry(id: "local"))
        repo.restoreFromBackup([makeEntry(id: "remote1"), makeEntry(id: "remote2")])
        #expect(repo.rides.count == 2)
        #expect(!repo.rides.contains { $0.id == "local" })
    }

    @Test func persistsViaPersistence() {
        let persistence = InMemoryRideHistoryPersistence()
        let repo1 = RideHistoryRepository(persistence: persistence)
        repo1.addRide(makeEntry(id: "ride1", fare: 15.50))
        let repo2 = RideHistoryRepository(persistence: persistence)
        #expect(repo2.rides.count == 1)
        #expect(repo2.rides.first?.fare == 15.50)
    }
}

// MARK: - SavedLocationsRepository Tests

@Suite("SavedLocationsRepository Tests")
struct SavedLocationsRepositoryTests {
    private func makeRepo() -> SavedLocationsRepository {
        SavedLocationsRepository(persistence: InMemorySavedLocationsPersistence())
    }

    @Test func recentsDoNotTriggerFavoritesChanged() {
        let repo = makeRepo()
        var changeCount = 0
        var favoritesChangeCount = 0

        repo.onChange = { changeCount += 1 }
        repo.onFavoritesChanged = { favoritesChangeCount += 1 }

        repo.addRecent(
            latitude: 36.17,
            longitude: -115.14,
            displayName: "Airport",
            addressLine: "Harry Reid Intl"
        )

        #expect(changeCount == 1)
        #expect(favoritesChangeCount == 0)
    }

    @Test func pinningFavoriteTriggersFavoritesChanged() {
        let repo = makeRepo()
        var favoritesChangeCount = 0

        repo.onFavoritesChanged = { favoritesChangeCount += 1 }

        let recent = SavedLocation(
            id: "home",
            latitude: 36.17,
            longitude: -115.14,
            displayName: "Home",
            addressLine: "123 Main St",
            isPinned: false
        )
        repo.save(recent)
        repo.pin(id: "home", nickname: "Home")

        #expect(favoritesChangeCount == 1)
        #expect(repo.favorites.count == 1)
    }

    @Test func restoreFromBackupReplacesAll() {
        let repo = makeRepo()
        repo.addRecent(latitude: 1, longitude: 2, displayName: "Old", addressLine: "Old St")
        repo.restoreFromBackup([
            SavedLocation(latitude: 3, longitude: 4, displayName: "New", addressLine: "New Ave", isPinned: true, nickname: "Work")
        ])
        #expect(repo.locations.count == 1)
        #expect(repo.favorites.count == 1)
    }

    @Test func persistsViaPersistence() {
        let persistence = InMemorySavedLocationsPersistence()
        let repo1 = SavedLocationsRepository(persistence: persistence)
        repo1.save(SavedLocation(latitude: 40, longitude: -74, displayName: "NYC", addressLine: "Broadway", isPinned: true, nickname: "Office"))
        let repo2 = SavedLocationsRepository(persistence: persistence)
        #expect(repo2.locations.count == 1)
        #expect(repo2.favorites.first?.nickname == "Office")
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
        // SyncCoordinator owns buildProfileBackupContent, so test it directly
        let settings = UserSettings(defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!)
        let savedLocations = SavedLocationsRepository(persistence: InMemorySavedLocationsPersistence())
        let rideHistory = RideHistoryRepository(persistence: InMemoryRideHistoryPersistence())
        let sync = SyncCoordinator(settings: settings, savedLocations: savedLocations, rideHistory: rideHistory)

        settings.setRoadflarePaymentMethods(["zelle", "venmo-business"])
        savedLocations.save(SavedLocation(
            id: "fav", latitude: 36.17, longitude: -115.14,
            displayName: "Home", addressLine: "123 Main St",
            isPinned: true, nickname: "Home", timestampMs: 100
        ))
        savedLocations.save(SavedLocation(
            id: "recent", latitude: 36.12, longitude: -115.17,
            displayName: "Airport", addressLine: "Harry Reid Intl",
            isPinned: false, timestampMs: 200
        ))

        let backup = sync.buildProfileBackupContent()

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
        let settings = UserSettings(defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!)
        let savedLocations = SavedLocationsRepository(persistence: InMemorySavedLocationsPersistence())
        let rideHistory = RideHistoryRepository(persistence: InMemoryRideHistoryPersistence())
        let sync = SyncCoordinator(settings: settings, savedLocations: savedLocations, rideHistory: rideHistory)

        sync.preserveProfileBackupSettingsTemplate(
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
        settings.setRoadflarePaymentMethods(["zelle", "venmo-business"])

        let backup = sync.buildProfileBackupContent()

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

    @MainActor
    @Test func syncCoordinatorTeardownDetachesCallbacksBeforeClearAll() async {
        let settings = UserSettings(defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!)
        let savedLocations = SavedLocationsRepository(persistence: InMemorySavedLocationsPersistence())
        let rideHistory = RideHistoryRepository(persistence: InMemoryRideHistoryPersistence())
        let sync = SyncCoordinator(settings: settings, savedLocations: savedLocations, rideHistory: rideHistory)

        let testDefaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let syncStore = RoadflareSyncStateStore(defaults: testDefaults, namespace: UUID().uuidString)
        let relay = FakeRelayManager()
        try? await relay.connect(to: DefaultRelays.all)
        let keypair = try! NostrKeypair.generate()
        let domainService = RoadflareDomainService(relayManager: relay, keypair: keypair)
        sync.configure(syncStore: syncStore, domainService: domainService)

        let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
        sync.wireTrackingCallbacks(driversRepo: repo)

        // Add data that would trigger callbacks on clearAll
        rideHistory.addRide(
            RideHistoryEntry(
                id: "ride-1", date: .now, counterpartyPubkey: "driver",
                pickupGeohash: "abc", dropoffGeohash: "def",
                pickup: Location(latitude: 40, longitude: -74),
                destination: Location(latitude: 41, longitude: -73),
                fare: 12.50, paymentMethod: "zelle"
            )
        )
        savedLocations.save(
            SavedLocation(
                id: "home", latitude: 36.17, longitude: -115.14,
                displayName: "Home", addressLine: "123 Main St",
                isPinned: true, nickname: "Home"
            )
        )

        // Clear the syncStore to reset dirty flags, then teardown + clearAll
        syncStore.clearAll()
        sync.teardown(clearPersistedState: true)
        rideHistory.clearAll()
        savedLocations.clearAll()

        // Callbacks were nil'd before clearAll, so no dirty flags should be set
        #expect(syncStore.metadata(for: .rideHistory).isDirty == false)
        #expect(syncStore.metadata(for: .profileBackup).isDirty == false)
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
        p.saveDrivers([FollowedDriver(pubkey: "d1"), FollowedDriver(pubkey: "d2")])
        p.saveDriverNames(["d1": "Alice", "d2": "Bob"])
        let loaded = p.loadDriverNames()
        #expect(loaded["d1"] == "Alice")
        #expect(loaded["d2"] == "Bob")
    }

    @Test func loadDriverNamesDropsOrphans() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let p = UserDefaultsDriversPersistence(defaults: defaults)
        p.saveDrivers([FollowedDriver(pubkey: "d1")])
        p.saveDriverNames(["d1": "Alice", "d2": "Bob"])

        let loaded = p.loadDriverNames()

        #expect(loaded == ["d1": "Alice"])
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

@MainActor
@Suite("RideStatePersistence Tests", .serialized)
struct RideStatePersistenceTests {
    init() { RideStatePersistence.clear() }

    private func makeRestoredSession(
        stage: RiderStage,
        pin: String? = "1234",
        confirmationId: String? = "conf1",
        pinAttempts: Int = 0,
        paymentMethod: String? = "zelle",
        fiatPaymentMethods: [String] = ["zelle", "venmo"],
        lastDriverStatus: String? = nil,
        lastDriverStateTimestamp: Int = 0,
        lastDriverActionCount: Int = 0
    ) throws -> RiderRideSession {
        let keypair = try NostrKeypair.generate()
        let session = RiderRideSession(relayManager: FakeRelayManager(), keypair: keypair)
        session.restore(
            stage: stage,
            offerEventId: "o1",
            acceptanceEventId: "a1",
            confirmationEventId: confirmationId,
            driverPubkey: "d1",
            pin: pin,
            pinAttempts: pinAttempts,
            pinVerified: false,
            paymentMethod: paymentMethod,
            fiatPaymentMethods: fiatPaymentMethods,
            lastDriverStatus: lastDriverStatus,
            lastDriverStateTimestamp: lastDriverStateTimestamp,
            lastDriverActionCount: lastDriverActionCount
        )
        return session
    }

    private func setupAndSave(
        stage: RiderStage,
        pin: String? = "1234",
        confirmationId: String? = "conf1",
        pinAttempts: Int = 0
    ) throws {
        let session = try makeRestoredSession(
            stage: stage,
            pin: pin,
            confirmationId: confirmationId,
            pinAttempts: pinAttempts
        )
        RideStatePersistence.save(
            session: session,
            pickup: Location(latitude: 40.71, longitude: -74.01, address: "Penn Station"),
            destination: Location(latitude: 40.76, longitude: -73.98, address: "Central Park"),
            fare: FareEstimate(distanceMiles: 5.5, durationMinutes: 18, fareUSD: 12.50)
        )
    }

    @Test func saveAndLoad() throws {
        try setupAndSave(stage: .rideConfirmed)
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

    @Test func savePersistsDriverStateCursorFromSession() throws {
        let session = try makeRestoredSession(
            stage: .driverArrived,
            paymentMethod: "zelle",
            fiatPaymentMethods: ["zelle"],
            lastDriverStatus: "arrived",
            lastDriverStateTimestamp: 1_700_000_100,
            lastDriverActionCount: 1
        )
        RideStatePersistence.save(session: session, pickup: nil, destination: nil, fare: nil)

        let loaded = RideStatePersistence.load()
        #expect(loaded?.lastDriverStatus == "arrived")
        #expect(loaded?.lastDriverStateTimestamp == 1_700_000_100)
        #expect(loaded?.lastDriverActionCount == 1)
        RideStatePersistence.clear()
    }

    @Test func loadReturnsNilWhenEmpty() {
        RideStatePersistence.clear()
        #expect(RideStatePersistence.load() == nil)
    }

    @Test func loadIgnoresIdle() throws {
        try setupAndSave(stage: .idle)
        #expect(RideStatePersistence.load() == nil)
        RideStatePersistence.clear()
    }

    @Test func loadIgnoresCompleted() throws {
        try setupAndSave(stage: .completed)
        #expect(RideStatePersistence.load() == nil)
        RideStatePersistence.clear()
    }

    @Test func loadAcceptsWaitingForAcceptance() throws {
        try setupAndSave(stage: .waitingForAcceptance)
        #expect(RideStatePersistence.load()?.stage == "waitingForAcceptance")
        RideStatePersistence.clear()
    }

    @Test func waitingForAcceptanceSurvivesShortRelaunchWithinOfferLifetime() throws {
        try setupAndSave(stage: .waitingForAcceptance)
        let stillLiveAt = Date.now.addingTimeInterval(60)
        #expect(RideStatePersistence.load(now: stillLiveAt)?.stage == "waitingForAcceptance")
        RideStatePersistence.clear()
    }

    @Test func waitingForAcceptanceExpiresWithDriverOfferVisibilityWindow() throws {
        try setupAndSave(stage: .waitingForAcceptance)
        let expiredAt = Date.now.addingTimeInterval(TimeInterval(RideStatePersistence.interopOfferVisibilitySeconds + 1))
        #expect(RideStatePersistence.load(now: expiredAt) == nil)
        RideStatePersistence.clear()
    }

    @Test func loadAcceptsDriverAccepted() throws {
        try setupAndSave(stage: .driverAccepted)
        #expect(RideStatePersistence.load()?.stage == "driverAccepted")
        RideStatePersistence.clear()
    }

    @Test func driverAcceptedExpiresWithDriverConfirmationTimeout() throws {
        try setupAndSave(stage: .driverAccepted)
        let expiredAt = Date.now.addingTimeInterval(RideConstants.confirmationTimeoutSeconds + 1)
        #expect(RideStatePersistence.load(now: expiredAt) == nil)
        RideStatePersistence.clear()
    }

    @Test func loadAcceptsDriverArrived() throws {
        try setupAndSave(stage: .driverArrived)
        #expect(RideStatePersistence.load()?.stage == "driverArrived")
        RideStatePersistence.clear()
    }

    @Test func loadAcceptsInProgress() throws {
        try setupAndSave(stage: .inProgress)
        #expect(RideStatePersistence.load()?.stage == "inProgress")
        RideStatePersistence.clear()
    }

    @Test func clearRemovesData() throws {
        try setupAndSave(stage: .rideConfirmed)
        #expect(RideStatePersistence.load() != nil)
        RideStatePersistence.clear()
        #expect(RideStatePersistence.load() == nil)
    }

    @Test func saveWithoutLocations() throws {
        let session = try makeRestoredSession(
            stage: .waitingForAcceptance,
            pin: nil,
            confirmationId: nil,
            paymentMethod: nil,
            fiatPaymentMethods: []
        )
        RideStatePersistence.save(session: session, pickup: nil, destination: nil, fare: nil)
        let loaded = RideStatePersistence.load()
        #expect(loaded?.pickupLat == nil)
        #expect(loaded?.destLat == nil)
        #expect(loaded?.fareUSD == nil)
        RideStatePersistence.clear()
    }

    @Test func pinSurvivesPersistence() throws {
        try setupAndSave(stage: .driverArrived, pin: "5678")
        let loaded = RideStatePersistence.load()
        #expect(loaded?.pin == "5678")
        RideStatePersistence.clear()
    }

    @Test func pinAttemptsSurvivePersistence() throws {
        try setupAndSave(stage: .driverArrived, pinAttempts: 3)
        let loaded = RideStatePersistence.load()
        #expect(loaded?.pinAttempts == 3)
        RideStatePersistence.clear()
    }
}
