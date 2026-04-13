import Testing
import Foundation
@testable import RoadFlareCore
@testable import RidestrSDK


// MARK: - AppLogger Tests

@Suite("AppLogger Tests")
struct AppLoggerTests {
    @Test func bootstrapSDKLoggingWiresRidestrLoggerHandler() {
        // Save and restore the global handler so this test doesn't leak state.
        let original = RidestrLogger.handler
        defer { RidestrLogger.handler = original }

        RidestrLogger.handler = nil
        #expect(RidestrLogger.handler == nil)

        AppLogger.bootstrapSDKLogging()

        #expect(RidestrLogger.handler != nil)
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
        appState.settings.setProfileName("Alice")
        appState.settings.setProfileCompleted(true)
        appState.settings.setRoadflarePaymentMethods([])

        #expect(appState.resolveLocalAuthState() == .paymentSetup)
    }

    @MainActor
    @Test func syncCoordinatorTeardownDetachesCallbacksBeforeClearAll() async {
        let settings = UserSettingsRepository(persistence: InMemoryUserSettingsPersistence())
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
        // Both coordinators/tracker should be released
        #expect(sync.profileBackupCoordinator == nil)
        #expect(sync.syncDomainTracker == nil)
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

// MARK: - UserDefaultsRideStatePersistence Tests

@MainActor
@Suite("UserDefaultsRideStatePersistence Tests", .serialized)
struct UserDefaultsRideStatePersistenceTests {
    private let persistence = UserDefaultsRideStatePersistence()

    init() { persistence.clear() }

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

    private func makePersistedState(
        session: RiderRideSession,
        pickup: Location? = nil,
        destination: Location? = nil,
        fare: FareEstimate? = nil,
        savedAt: Int = Int(Date.now.timeIntervalSince1970)
    ) -> PersistedRideState {
        let p = pickup ?? session.precisePickup
        let d = destination ?? session.preciseDestination
        return PersistedRideState(
            stage: session.stage.rawValue,
            offerEventId: session.offerEventId,
            acceptanceEventId: session.acceptanceEventId,
            confirmationEventId: session.confirmationEventId,
            driverPubkey: session.driverPubkey,
            pin: session.pin,
            pinVerified: session.pinVerified,
            paymentMethodRaw: session.paymentMethod,
            fiatPaymentMethodsRaw: session.fiatPaymentMethods,
            pickupLat: p?.latitude, pickupLon: p?.longitude, pickupAddress: p?.address,
            destLat: d?.latitude, destLon: d?.longitude, destAddress: d?.address,
            fareUSD: fare.map { "\($0.fareUSD)" },
            fareDistanceMiles: fare?.distanceMiles,
            fareDurationMinutes: fare?.durationMinutes,
            savedAt: savedAt,
            processedPinActionKeys: session.processedPinActionKeys.isEmpty ? nil : Array(session.processedPinActionKeys),
            processedPinTimestamps: nil,
            pinAttempts: session.pinAttempts > 0 ? session.pinAttempts : nil,
            precisePickupShared: session.precisePickupShared ? true : nil,
            preciseDestinationShared: session.preciseDestinationShared ? true : nil,
            lastDriverStatus: session.lastDriverStatus,
            lastDriverStateTimestamp: session.lastDriverStateTimestamp > 0 ? session.lastDriverStateTimestamp : nil,
            lastDriverActionCount: session.lastDriverActionCount > 0 ? session.lastDriverActionCount : nil,
            riderStateHistory: session.riderStateHistory.isEmpty ? nil : session.riderStateHistory
        )
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
        persistence.saveRaw(makePersistedState(
            session: session,
            pickup: Location(latitude: 40.71, longitude: -74.01, address: "Penn Station"),
            destination: Location(latitude: 40.76, longitude: -73.98, address: "Central Park"),
            fare: FareEstimate(distanceMiles: 5.5, durationMinutes: 18, fareUSD: 12.50)
        ))
    }

    @Test func saveAndLoad() throws {
        try setupAndSave(stage: .rideConfirmed)
        let loaded = persistence.loadRaw()
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
        persistence.clear()
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
        persistence.saveRaw(makePersistedState(session: session))

        let loaded = persistence.loadRaw()
        #expect(loaded?.lastDriverStatus == "arrived")
        #expect(loaded?.lastDriverStateTimestamp == 1_700_000_100)
        #expect(loaded?.lastDriverActionCount == 1)
        persistence.clear()
    }

    @Test func clearRemovesData() throws {
        try setupAndSave(stage: .rideConfirmed)
        #expect(persistence.loadRaw() != nil)
        persistence.clear()
        #expect(persistence.loadRaw() == nil)
    }

    @Test func saveWithoutLocations() throws {
        let session = try makeRestoredSession(
            stage: .waitingForAcceptance,
            pin: nil,
            confirmationId: nil,
            paymentMethod: nil,
            fiatPaymentMethods: []
        )
        persistence.saveRaw(makePersistedState(session: session))
        let loaded = persistence.loadRaw()
        #expect(loaded?.pickupLat == nil)
        #expect(loaded?.destLat == nil)
        #expect(loaded?.fareUSD == nil)
        persistence.clear()
    }

    @Test func pinSurvivesPersistence() throws {
        try setupAndSave(stage: .driverArrived, pin: "5678")
        let loaded = persistence.loadRaw()
        #expect(loaded?.pin == "5678")
        persistence.clear()
    }

    @Test func pinAttemptsSurvivePersistence() throws {
        try setupAndSave(stage: .driverArrived, pinAttempts: 3)
        let loaded = persistence.loadRaw()
        #expect(loaded?.pinAttempts == 3)
        persistence.clear()
    }
}
