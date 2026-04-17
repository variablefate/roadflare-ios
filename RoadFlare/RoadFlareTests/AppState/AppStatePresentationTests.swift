import Testing
import Foundation
@testable import RoadFlareCore
@testable import RidestrSDK

// MARK: - Shared helpers

private let fakePubkeyA = String(repeating: "a", count: 64)
private let fakePubkeyB = String(repeating: "b", count: 64)
private let fakeKey = RoadflareKey(
    privateKeyHex: String(repeating: "c", count: 64),
    publicKeyHex:  String(repeating: "d", count: 64),
    version: 1, keyUpdatedAt: nil
)

private func makeRepo(drivers: [FollowedDriver] = []) -> FollowedDriversRepository {
    let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
    drivers.forEach { repo.addDriver($0) }
    return repo
}

private func setOnline(_ repo: FollowedDriversRepository, pubkey: String) {
    _ = repo.updateDriverLocation(pubkey: pubkey, latitude: 0, longitude: 0,
                                  status: "online", timestamp: 1_000_000, keyVersion: 1)
}

// MARK: - AppState.driverListItems()

@Suite("AppState.driverListItems")
@MainActor
struct AppStateDriverListItemsTests {

    @Test func returnsEmptyWhenNoRepository() {
        let appState = AppState()
        #expect(appState.driverListItems().isEmpty)
    }

    @Test func mapsEachDriver() {
        let driver = FollowedDriver(pubkey: fakePubkeyA, name: "Alice", roadflareKey: fakeKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        let items = appState.driverListItems()
        #expect(items.count == 1)
        #expect(items[0].pubkey == fakePubkeyA)
        #expect(items[0].displayName == "Alice")
    }

    @Test func sortsByStatusOrder() {
        let online  = FollowedDriver(pubkey: fakePubkeyA, name: "Online",  roadflareKey: fakeKey)
        let offline = FollowedDriver(pubkey: fakePubkeyB, name: "Offline", roadflareKey: fakeKey)
        let repo = makeRepo(drivers: [offline, online])
        setOnline(repo, pubkey: fakePubkeyA)

        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        let items = appState.driverListItems()
        #expect(items.count == 2)
        #expect(items[0].status == .online)
        #expect(items[1].status == .offline)
    }

    @Test func propagatesKeyStale() {
        let driver = FollowedDriver(pubkey: fakePubkeyA, name: "Stale", roadflareKey: fakeKey)
        let repo = makeRepo(drivers: [driver])
        repo.markKeyStale(pubkey: fakePubkeyA)

        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        let items = appState.driverListItems()
        #expect(items[0].status == .keyStale)
        #expect(items[0].canRequestRide == false)
    }
}

// MARK: - AppState.driverDetailViewState(pubkey:)

@Suite("AppState.driverDetailViewState")
@MainActor
struct AppStateDriverDetailViewStateTests {

    @Test func returnsNilForUnknownPubkey() {
        let appState = AppState()
        appState.installDriverPingTestContext(
            driversRepository: makeRepo()
        )
        #expect(appState.driverDetailViewState(pubkey: fakePubkeyA) == nil)
    }

    @Test func returnsNilWhenNoRepository() {
        let appState = AppState()
        #expect(appState.driverDetailViewState(pubkey: fakePubkeyA) == nil)
    }

    @Test func mapsKnownDriver() {
        let driver = FollowedDriver(pubkey: fakePubkeyA, name: "Bob", note: "My driver",
                                     roadflareKey: fakeKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        let state = appState.driverDetailViewState(pubkey: fakePubkeyA)
        #expect(state != nil)
        #expect(state?.pubkey == fakePubkeyA)
        #expect(state?.displayName == "Bob")
        #expect(state?.note == "My driver")
        #expect(state?.hasKey == true)
    }

    @Test func statusLabelOnlineWhenOnline() {
        let driver = FollowedDriver(pubkey: fakePubkeyA, name: "Carol", roadflareKey: fakeKey)
        let repo = makeRepo(drivers: [driver])
        setOnline(repo, pubkey: fakePubkeyA)

        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        let state = appState.driverDetailViewState(pubkey: fakePubkeyA)
        #expect(state?.statusLabel == "Available")
        #expect(state?.canRequestRide == true)
    }
}

// MARK: - AppState.onlineDriverOptions()

@Suite("AppState.onlineDriverOptions")
@MainActor
struct AppStateOnlineDriverOptionsTests {

    @Test func returnsEmptyWhenNoRepository() {
        let appState = AppState()
        #expect(appState.onlineDriverOptions().isEmpty)
    }

    @Test func excludesOfflineDrivers() {
        let driver = FollowedDriver(pubkey: fakePubkeyA, name: "Dave", roadflareKey: fakeKey)
        let repo = makeRepo(drivers: [driver])
        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        #expect(appState.onlineDriverOptions().isEmpty)
    }

    @Test func includesOnlineDrivers() {
        let driver = FollowedDriver(pubkey: fakePubkeyA, name: "Eve", roadflareKey: fakeKey)
        let repo = makeRepo(drivers: [driver])
        setOnline(repo, pubkey: fakePubkeyA)

        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        let options = appState.onlineDriverOptions()
        #expect(options.count == 1)
        #expect(options[0].pubkey == fakePubkeyA)
        #expect(options[0].displayName == "Eve")
    }

    @Test func excludesStaleKeyDrivers() {
        let driver = FollowedDriver(pubkey: fakePubkeyA, name: "Frank", roadflareKey: fakeKey)
        let repo = makeRepo(drivers: [driver])
        setOnline(repo, pubkey: fakePubkeyA)
        repo.markKeyStale(pubkey: fakePubkeyA)

        let appState = AppState()
        appState.installDriverPingTestContext(driversRepository: repo)

        #expect(appState.onlineDriverOptions().isEmpty)
    }
}

// MARK: - AppState.rideHistoryRows

@Suite("AppState.rideHistoryRows")
@MainActor
struct AppStateRideHistoryRowsTests {

    private static let fakeEntry = RideHistoryEntry(
        id: "test-ride-1",
        date: Date(timeIntervalSince1970: 0),
        counterpartyPubkey: fakePubkeyA,
        counterpartyName: "Grace",
        pickupGeohash: "abc", dropoffGeohash: "def",
        pickup: Location(latitude: 0, longitude: 0, address: "123 Main St"),
        destination: Location(latitude: 1, longitude: 1, address: "456 Oak Ave"),
        fare: Decimal(12),
        paymentMethod: "cash"
    )

    @Test func returnsEmptyWhenNoRides() {
        let appState = AppState()
        appState.rideHistory.clearAll()
        defer { appState.rideHistory.clearAll() }

        #expect(appState.rideHistoryRows.isEmpty)
    }

    @Test func mapsEntryToRow() {
        let appState = AppState()
        appState.rideHistory.clearAll()
        defer { appState.rideHistory.clearAll() }

        appState.rideHistory.addRide(Self.fakeEntry)

        let rows = appState.rideHistoryRows
        #expect(rows.count == 1)
        #expect(rows[0].id == "test-ride-1")
        #expect(rows[0].counterpartyName == "Grace")
        #expect(rows[0].fareLabel == "$12.00")
        #expect(rows[0].isCompleted == true)
    }
}

// MARK: - AppState.favoriteLocationRows / recentLocationRows

@Suite("AppState.locationRows")
@MainActor
struct AppStateLocationRowsTests {

    private static let favoriteLocation = SavedLocation(
        id: "fav-1", latitude: 37.7, longitude: -122.4,
        displayName: "Office", addressLine: "1 Market St",
        isPinned: true, nickname: "Work",
        timestampMs: 1_000_000
    )

    private static let recentLocation = SavedLocation(
        id: "rec-1", latitude: 37.8, longitude: -122.5,
        displayName: "Coffee Shop", addressLine: "99 Brew Ave",
        isPinned: false,
        timestampMs: 2_000_000
    )

    @Test func favoriteLocationRowsMapsOnlyPinned() {
        let appState = AppState()
        appState.savedLocations.clearAll()
        defer { appState.savedLocations.clearAll() }

        appState.savedLocations.save(Self.favoriteLocation)
        appState.savedLocations.save(Self.recentLocation)

        let rows = appState.favoriteLocationRows
        #expect(rows.count == 1)
        #expect(rows[0].id == "fav-1")
        #expect(rows[0].label == "Work")
        #expect(rows[0].isFavorite == true)
    }

    @Test func recentLocationRowsMapsOnlyUnpinned() {
        let appState = AppState()
        appState.savedLocations.clearAll()
        defer { appState.savedLocations.clearAll() }

        appState.savedLocations.save(Self.favoriteLocation)
        appState.savedLocations.save(Self.recentLocation)

        let rows = appState.recentLocationRows
        #expect(rows.count == 1)
        #expect(rows[0].id == "rec-1")
        #expect(rows[0].displayName == "Coffee Shop")
        #expect(rows[0].isFavorite == false)
    }

    @Test func recentLocationRowsEmpty() {
        let appState = AppState()
        appState.savedLocations.clearAll()
        defer { appState.savedLocations.clearAll() }

        #expect(appState.recentLocationRows.isEmpty)
    }

    // Pins the contract that `recentLocationRows` routes through
    // SavedLocationsRepository.recents (which filters out recents within
    // ~50m of any favorite) rather than iterating locations directly.
    // A direct `savedLocations.locations.filter { !$0.isPinned }` path would
    // include both entries in this test.
    @Test func recentLocationRowsExcludesRecentsNearFavorites() {
        let appState = AppState()
        appState.savedLocations.clearAll()
        defer { appState.savedLocations.clearAll() }

        // Favorite at lat=37.7, lon=-122.4
        appState.savedLocations.save(SavedLocation(
            id: "fav", latitude: 37.7, longitude: -122.4,
            displayName: "Work", addressLine: "1 Market St",
            isPinned: true, nickname: "Work", timestampMs: 1_000_000
        ))
        // Recent within ~50m of the favorite (dedup threshold)
        appState.savedLocations.save(SavedLocation(
            id: "near", latitude: 37.7, longitude: -122.4,
            displayName: "Same spot", addressLine: "1 Market St",
            isPinned: false, timestampMs: 2_000_000
        ))
        // Recent far from any favorite
        appState.savedLocations.save(SavedLocation(
            id: "far", latitude: 40.0, longitude: -74.0,
            displayName: "Faraway", addressLine: "99 Broad St",
            isPinned: false, timestampMs: 3_000_000
        ))

        let rows = appState.recentLocationRows
        #expect(rows.map(\.id) == ["far"])
    }

}
