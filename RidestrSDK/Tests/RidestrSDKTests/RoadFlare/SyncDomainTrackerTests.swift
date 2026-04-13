import Foundation
import Testing
@testable import RidestrSDK

@Suite("SyncDomainTracker Tests")
@MainActor
struct SyncDomainTrackerTests {

    // MARK: - Helpers

    private func makeSyncStore() -> RoadflareSyncStateStore {
        RoadflareSyncStateStore(
            defaults: UserDefaults(suiteName: "tracker_test_\(UUID().uuidString)")!,
            namespace: UUID().uuidString
        )
    }

    private func makeSettings() -> UserSettingsRepository {
        UserSettingsRepository(persistence: InMemoryUserSettingsPersistence())
    }

    private func makeDriversRepo() -> FollowedDriversRepository {
        FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
    }

    private func makeRideHistory() -> RideHistoryRepository {
        RideHistoryRepository(persistence: InMemoryRideHistoryPersistence())
    }

    private func makeSavedLocations() -> SavedLocationsRepository {
        SavedLocationsRepository(persistence: InMemorySavedLocationsPersistence())
    }

    private func makeEntry(id: String = UUID().uuidString) -> RideHistoryEntry {
        RideHistoryEntry(
            id: id, date: .now, counterpartyPubkey: "driver",
            pickupGeohash: "abc", dropoffGeohash: "def",
            pickup: Location(latitude: 40, longitude: -74),
            destination: Location(latitude: 41, longitude: -73),
            fare: 10.0, paymentMethod: "zelle"
        )
    }

    private func makeSavedLocation(id: String = UUID().uuidString) -> SavedLocation {
        SavedLocation(
            id: id, latitude: 36.17, longitude: -115.14,
            displayName: "Home", addressLine: "123 Main St",
            isPinned: true, nickname: "Home"
        )
    }

    // MARK: - Wiring Tests

    @Test func onProfileChanged_marksProfileDirty() {
        let store = makeSyncStore()
        let settings = makeSettings()
        let tracker = SyncDomainTracker(
            store: store,
            settings: settings,
            driversRepo: makeDriversRepo(),
            rideHistory: makeRideHistory(),
            savedLocations: makeSavedLocations()
        )
        _ = tracker  // keep alive

        #expect(!store.metadata(for: .profile).isDirty)
        _ = settings.setProfileName("Alice")
        #expect(store.metadata(for: .profile).isDirty)
    }

    @Test func onProfileBackupChanged_marksProfileBackupDirty_viaSettings() {
        let store = makeSyncStore()
        let settings = makeSettings()
        let tracker = SyncDomainTracker(
            store: store,
            settings: settings,
            driversRepo: makeDriversRepo(),
            rideHistory: makeRideHistory(),
            savedLocations: makeSavedLocations()
        )
        _ = tracker

        #expect(!store.metadata(for: .profileBackup).isDirty)
        settings.setRoadflarePaymentMethods(["cash", "zelle"])
        #expect(store.metadata(for: .profileBackup).isDirty)
    }

    @Test func onDriversChanged_local_marksFollowedDriversDirty() {
        let store = makeSyncStore()
        let driversRepo = makeDriversRepo()
        let tracker = SyncDomainTracker(
            store: store,
            settings: makeSettings(),
            driversRepo: driversRepo,
            rideHistory: makeRideHistory(),
            savedLocations: makeSavedLocations()
        )
        _ = tracker

        #expect(!store.metadata(for: .followedDrivers).isDirty)
        driversRepo.addDriver(FollowedDriver(pubkey: "pk1"), source: .local)
        #expect(store.metadata(for: .followedDrivers).isDirty)
    }

    @Test func onDriversChanged_sync_doesNotMarkFollowedDriversDirty() {
        let store = makeSyncStore()
        let driversRepo = makeDriversRepo()
        let tracker = SyncDomainTracker(
            store: store,
            settings: makeSettings(),
            driversRepo: driversRepo,
            rideHistory: makeRideHistory(),
            savedLocations: makeSavedLocations()
        )
        _ = tracker

        #expect(!store.metadata(for: .followedDrivers).isDirty)
        driversRepo.addDriver(FollowedDriver(pubkey: "pk1"), source: .sync)
        #expect(!store.metadata(for: .followedDrivers).isDirty)
    }

    @Test func onRidesChanged_marksRideHistoryDirty() {
        let store = makeSyncStore()
        let rideHistory = makeRideHistory()
        let tracker = SyncDomainTracker(
            store: store,
            settings: makeSettings(),
            driversRepo: makeDriversRepo(),
            rideHistory: rideHistory,
            savedLocations: makeSavedLocations()
        )
        _ = tracker

        #expect(!store.metadata(for: .rideHistory).isDirty)
        rideHistory.addRide(makeEntry())
        #expect(store.metadata(for: .rideHistory).isDirty)
    }

    @Test func savedLocationsOnChange_marksProfileBackupDirty() {
        let store = makeSyncStore()
        let savedLocations = makeSavedLocations()
        let tracker = SyncDomainTracker(
            store: store,
            settings: makeSettings(),
            driversRepo: makeDriversRepo(),
            rideHistory: makeRideHistory(),
            savedLocations: savedLocations
        )
        _ = tracker

        #expect(!store.metadata(for: .profileBackup).isDirty)
        savedLocations.save(makeSavedLocation())
        #expect(store.metadata(for: .profileBackup).isDirty)
    }

    // MARK: - Detach Tests

    @Test func detach_nilsAllCallbacksSoSubsequentMutationsDoNotDirtyStore() {
        let store = makeSyncStore()
        let settings = makeSettings()
        let driversRepo = makeDriversRepo()
        let rideHistory = makeRideHistory()
        let savedLocations = makeSavedLocations()

        let tracker = SyncDomainTracker(
            store: store,
            settings: settings,
            driversRepo: driversRepo,
            rideHistory: rideHistory,
            savedLocations: savedLocations
        )

        tracker.detach()

        // After detach, mutations must not dirty the store
        _ = settings.setProfileName("Bob")
        settings.setRoadflarePaymentMethods(["cash"])
        driversRepo.addDriver(FollowedDriver(pubkey: "pk2"), source: .local)
        rideHistory.addRide(makeEntry())
        savedLocations.save(makeSavedLocation())

        #expect(!store.metadata(for: .profile).isDirty)
        #expect(!store.metadata(for: .profileBackup).isDirty)
        #expect(!store.metadata(for: .followedDrivers).isDirty)
        #expect(!store.metadata(for: .rideHistory).isDirty)
    }

    /// Regression: commit bef926b fixed a bug where `clearAll()` fired repository
    /// callbacks that still held a reference to the old sync store, writing stale
    /// dirty flags after logout. Detach must nil callbacks before `clearAll()`.
    @Test func detach_preventsStaleCallbacksWhenRepositoriesAreClearedAll() {
        let store = makeSyncStore()
        let rideHistory = makeRideHistory()
        let savedLocations = makeSavedLocations()

        let tracker = SyncDomainTracker(
            store: store,
            settings: makeSettings(),
            driversRepo: makeDriversRepo(),
            rideHistory: rideHistory,
            savedLocations: savedLocations
        )

        tracker.detach()

        // clearAll() fires onRidesChanged?() and onChange?() internally —
        // these must be nil after detach so no dirty flags are written.
        rideHistory.clearAll()
        savedLocations.clearAll()

        #expect(!store.metadata(for: .rideHistory).isDirty)
        #expect(!store.metadata(for: .profileBackup).isDirty)
    }

    @Test func deinit_nilsCallbacksWhenTrackerGoesOutOfScope() {
        let store = makeSyncStore()
        let settings = makeSettings()
        let driversRepo = makeDriversRepo()
        let rideHistory = makeRideHistory()
        let savedLocations = makeSavedLocations()

        do {
            let tracker = SyncDomainTracker(
                store: store,
                settings: settings,
                driversRepo: driversRepo,
                rideHistory: rideHistory,
                savedLocations: savedLocations
            )
            _ = tracker
            // tracker goes out of scope here
        }

        // After deinit, mutations must not dirty the store
        _ = settings.setProfileName("Carol")
        driversRepo.addDriver(FollowedDriver(pubkey: "pk3"), source: .local)
        rideHistory.addRide(makeEntry())
        savedLocations.save(makeSavedLocation())

        #expect(!store.metadata(for: .profile).isDirty)
        #expect(!store.metadata(for: .followedDrivers).isDirty)
        #expect(!store.metadata(for: .rideHistory).isDirty)
        #expect(!store.metadata(for: .profileBackup).isDirty)
    }
}
