import Testing
import Foundation
@testable import RoadFlareCore
@testable import RidestrSDK

// MARK: - Shared test helpers

private let fakePubkey = String(repeating: "a", count: 64)
private let fakeKey = RoadflareKey(
    privateKeyHex: String(repeating: "b", count: 64),
    publicKeyHex:  String(repeating: "c", count: 64),
    version: 3, keyUpdatedAt: nil
)

private func makeDriver(
    pubkey: String = fakePubkey,
    name: String? = nil,
    note: String? = nil,
    key: RoadflareKey? = fakeKey
) -> FollowedDriver {
    FollowedDriver(pubkey: pubkey, name: name, note: note, roadflareKey: key)
}

/// Create a `CachedDriverLocation` via the repository's `updateDriverLocation` method,
/// then extract it, since `CachedDriverLocation.init` is internal to the SDK.
private func makeLocation(
    pubkey: String = fakePubkey,
    status: String,
    timestamp: Int = 1_000_000
) -> CachedDriverLocation {
    let repo = FollowedDriversRepository(persistence: InMemoryFollowedDriversPersistence())
    let driver = FollowedDriver(pubkey: pubkey)
    repo.addDriver(driver)
    _ = repo.updateDriverLocation(
        pubkey: pubkey, latitude: 37.7, longitude: -122.4,
        status: status, timestamp: timestamp, keyVersion: 1
    )
    return repo.driverLocations[pubkey]!
}

// MARK: - DriverListItem

@Suite("DriverListItem")
struct DriverListItemTests {

    @Test func mapsDisplayNameFromExplicitOverride() {
        let driver = makeDriver(name: "Alice")
        let item = DriverListItem.from(driver, displayName: "Alice (cached)", location: nil,
                                       profile: nil, isKeyStale: false, canPing: false)
        #expect(item.displayName == "Alice (cached)")
    }

    @Test func fallsBackToDriverNameWhenNoOverride() {
        let driver = makeDriver(name: "Bob")
        let item = DriverListItem.from(driver, displayName: nil, location: nil,
                                       profile: nil, isKeyStale: false, canPing: false)
        #expect(item.displayName == "Bob")
    }

    @Test func fallsBackToShortPubkeyWhenNoName() {
        let driver = makeDriver(name: nil)
        let item = DriverListItem.from(driver, displayName: nil, location: nil,
                                       profile: nil, isKeyStale: false, canPing: false)
        #expect(item.displayName == String(fakePubkey.prefix(8)) + "...")
    }

    @Test func onlineStatus() {
        let driver = makeDriver()
        let loc = makeLocation(status: "online")
        let item = DriverListItem.from(driver, displayName: nil, location: loc,
                                       profile: nil, isKeyStale: false, canPing: false)
        #expect(item.status == .online)
        #expect(item.canRequestRide == true)
    }

    @Test func onRideStatus() {
        let driver = makeDriver()
        let loc = makeLocation(status: "on_ride")
        let item = DriverListItem.from(driver, displayName: nil, location: loc,
                                       profile: nil, isKeyStale: false, canPing: false)
        #expect(item.status == .onRide)
        #expect(item.canRequestRide == false)
    }

    @Test func offlineWhenNoLocation() {
        let driver = makeDriver()
        let item = DriverListItem.from(driver, displayName: nil, location: nil,
                                       profile: nil, isKeyStale: false, canPing: false)
        #expect(item.status == .offline)
    }

    @Test func pendingApprovalWhenNoKey() {
        let driver = makeDriver(key: nil)
        let item = DriverListItem.from(driver, displayName: nil, location: nil,
                                       profile: nil, isKeyStale: false, canPing: false)
        #expect(item.status == .pendingApproval)
        #expect(item.canRequestRide == false)
    }

    @Test func keyStaleStatusTakesPrecedenceOverLocation() {
        let driver = makeDriver()
        let loc = makeLocation(status: "online")
        let item = DriverListItem.from(driver, displayName: nil, location: loc,
                                       profile: nil, isKeyStale: true, canPing: false)
        #expect(item.status == .keyStale)
        #expect(item.canRequestRide == false)
    }

    @Test func vehicleDescriptionFromProfile() {
        let driver = makeDriver()
        let profile = UserProfileContent(carMake: "Tesla", carModel: "Model 3", carColor: "Black")
        let item = DriverListItem.from(driver, displayName: nil, location: nil,
                                       profile: profile, isKeyStale: false, canPing: false)
        #expect(item.vehicleDescription == "Black Tesla Model 3")
    }

    @Test func canPingPropagated() {
        let driver = makeDriver()
        let item = DriverListItem.from(driver, displayName: nil, location: nil,
                                       profile: nil, isKeyStale: false, canPing: true)
        #expect(item.canPing == true)
    }

    @Test func sortOrderOnlineFirst() {
        let online = DriverListItem.from(makeDriver(), displayName: nil,
                                          location: makeLocation(status: "online"),
                                          profile: nil, isKeyStale: false, canPing: false)
        let onRide = DriverListItem.from(makeDriver(), displayName: nil,
                                          location: makeLocation(status: "on_ride"),
                                          profile: nil, isKeyStale: false, canPing: false)
        let keyStale = DriverListItem.from(makeDriver(), displayName: nil,
                                            location: makeLocation(status: "online"),
                                            profile: nil, isKeyStale: true, canPing: false)
        let pending = DriverListItem.from(makeDriver(key: nil), displayName: nil,
                                           location: nil,
                                           profile: nil, isKeyStale: false, canPing: false)
        let offline = DriverListItem.from(makeDriver(), displayName: nil,
                                           location: nil,
                                           profile: nil, isKeyStale: false, canPing: false)
        #expect(online.sortOrder < onRide.sortOrder)
        #expect(onRide.sortOrder < keyStale.sortOrder)
        #expect(keyStale.sortOrder < pending.sortOrder)
        #expect(pending.sortOrder < offline.sortOrder)
    }
}

// MARK: - DriverDetailViewState

@Suite("DriverDetailViewState")
struct DriverDetailViewStateTests {

    @Test func displayNameResolution() {
        let driver = makeDriver(name: "Carol")
        let state = DriverDetailViewState.from(driver, displayName: "Carol (repo)",
                                               location: nil, profile: nil, isKeyStale: false)
        #expect(state.displayName == "Carol (repo)")
    }

    @Test func statusLabelAvailableWhenOnline() {
        let driver = makeDriver()
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: makeLocation(status: "online"),
                                               profile: nil, isKeyStale: false)
        #expect(state.statusLabel == "Available")
        #expect(state.canRequestRide == true)
    }

    @Test func statusLabelOnRide() {
        let driver = makeDriver()
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: makeLocation(status: "on_ride"),
                                               profile: nil, isKeyStale: false)
        #expect(state.statusLabel == "On a ride")
        #expect(state.canRequestRide == false)
    }

    @Test func statusLabelOfflineWhenNoLocation() {
        let driver = makeDriver()
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: nil, profile: nil, isKeyStale: false)
        #expect(state.statusLabel == "Offline")
        #expect(state.canRequestRide == false)
    }

    @Test func statusLabelPendingWhenNoKey() {
        let driver = makeDriver(key: nil)
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: nil, profile: nil, isKeyStale: false)
        #expect(state.statusLabel == "Pending approval")
        #expect(state.hasKey == false)
    }

    @Test func keyStaleStatusLabelAndBlocksRequest() {
        let driver = makeDriver()
        let online = makeLocation(status: "online")
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: online, profile: nil, isKeyStale: true)
        #expect(state.statusLabel == "Key outdated")
        #expect(state.canRequestRide == false)
    }

    @Test func keyVersionExposesSdkVersion() {
        let driver = makeDriver()  // fakeKey has version 3
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: nil, profile: nil, isKeyStale: false)
        #expect(state.hasKey == true)
        #expect(state.keyVersion == 3)
    }

    @Test func noKeyVersionWhenNoKey() {
        let driver = makeDriver(key: nil)
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: nil, profile: nil, isKeyStale: false)
        #expect(state.keyVersion == nil)
    }

    @Test func lastLocationTimestampLabelIsNilWhenNoLocation() {
        let driver = makeDriver()
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: nil, profile: nil, isKeyStale: false)
        #expect(state.lastLocationTimestampLabel == nil)
        #expect(state.lastLocationStatus == nil)
    }

    @Test func lastLocationTimestampLabelIsRelativeString() throws {
        let driver = makeDriver()
        let referenceDate = Date(timeIntervalSince1970: 1_000_000 + 180)  // 3 min after timestamp
        let loc = makeLocation(status: "online", timestamp: 1_000_000)
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: loc, profile: nil,
                                               isKeyStale: false, referenceDate: referenceDate)
        // Relative formatter should produce something non-empty
        let label = try #require(state.lastLocationTimestampLabel)
        #expect(!label.isEmpty)
    }

    @Test func noteDefaultsToEmptyString() {
        let driver = makeDriver(note: nil)
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: nil, profile: nil, isKeyStale: false)
        #expect(state.note == "")
    }

    @Test func notePreserved() {
        let driver = makeDriver(note: "Great driver!")
        let state = DriverDetailViewState.from(driver, displayName: nil,
                                               location: nil, profile: nil, isKeyStale: false)
        #expect(state.note == "Great driver!")
    }
}

// MARK: - RideRequestDriverOption

@Suite("RideRequestDriverOption")
struct RideRequestDriverOptionTests {

    @Test func returnsNilWhenNoKey() {
        let driver = makeDriver(key: nil)
        let result = RideRequestDriverOption.from(driver, displayName: nil,
                                                   location: makeLocation(status: "online"),
                                                   isKeyStale: false)
        #expect(result == nil)
    }

    @Test func returnsNilWhenOffline() {
        let driver = makeDriver()
        let result = RideRequestDriverOption.from(driver, displayName: nil,
                                                   location: makeLocation(status: "offline"),
                                                   isKeyStale: false)
        #expect(result == nil)
    }

    @Test func returnsNilWhenNoLocation() {
        let driver = makeDriver()
        let result = RideRequestDriverOption.from(driver, displayName: nil,
                                                   location: nil, isKeyStale: false)
        #expect(result == nil)
    }

    @Test func returnsNilWhenKeyIsStale() {
        let driver = makeDriver()
        let result = RideRequestDriverOption.from(driver, displayName: nil,
                                                   location: makeLocation(status: "online"),
                                                   isKeyStale: true)
        #expect(result == nil)
    }

    @Test func returnsOptionWhenOnline() throws {
        let driver = makeDriver(name: "Dave")
        let result = RideRequestDriverOption.from(driver, displayName: "Dave (cached)",
                                                   location: makeLocation(status: "online"),
                                                   isKeyStale: false)
        let option = try #require(result)
        #expect(option.pubkey == fakePubkey)
        #expect(option.displayName == "Dave (cached)")
    }

    @Test func idMatchesPubkey() throws {
        let driver = makeDriver()
        let option = try #require(
            RideRequestDriverOption.from(driver, displayName: nil,
                                          location: makeLocation(status: "online"),
                                          isKeyStale: false)
        )
        #expect(option.id == option.pubkey)
    }

    @Test func onlineOptionsFiltersOfflineDrivers() {
        let pubkey2 = String(repeating: "d", count: 64)
        let onlineDriver  = makeDriver(pubkey: fakePubkey)
        let offlineDriver = makeDriver(pubkey: pubkey2)
        let names: [String: String] = [:]
        let locations: [String: CachedDriverLocation] = [
            fakePubkey: makeLocation(pubkey: fakePubkey, status: "online"),
            pubkey2:    makeLocation(pubkey: pubkey2, status: "offline"),
        ]
        let options = RideRequestDriverOption.onlineOptions(
            from: [onlineDriver, offlineDriver],
            driverNames: names,
            driverLocations: locations
        )
        #expect(options.count == 1)
        #expect(options.first?.pubkey == fakePubkey)
    }

    @Test func onlineOptionsFiltersStaleKeyDrivers() {
        let pubkey2 = String(repeating: "d", count: 64)
        let freshDriver = makeDriver(pubkey: fakePubkey)
        let staleDriver = makeDriver(pubkey: pubkey2)
        let locations: [String: CachedDriverLocation] = [
            fakePubkey: makeLocation(pubkey: fakePubkey, status: "online"),
            pubkey2:    makeLocation(pubkey: pubkey2, status: "online"),
        ]
        let options = RideRequestDriverOption.onlineOptions(
            from: [freshDriver, staleDriver],
            driverNames: [:],
            driverLocations: locations,
            staleKeyPubkeys: [pubkey2]
        )
        #expect(options.count == 1)
        #expect(options.first?.pubkey == fakePubkey)
    }
}

// MARK: - RideHistoryRow

@Suite("RideHistoryRow")
struct RideHistoryRowTests {

    private func makeEntry(
        id: String = "ride-1",
        date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        status: String = "completed",
        counterpartyName: String? = "Eve",
        pickupAddress: String? = "123 Main St",
        destAddress: String? = "456 Oak Ave",
        fare: Decimal = Decimal(string: "14.50")!,
        paymentMethod: String = "cash_app",
        distance: Double? = 4.2,
        duration: Int? = 18
    ) -> RideHistoryEntry {
        let pickup = Location(latitude: 37.7, longitude: -122.4, address: pickupAddress)
        let dest   = Location(latitude: 37.8, longitude: -122.5, address: destAddress)
        return RideHistoryEntry(
            id: id, date: date, status: status,
            counterpartyPubkey: fakePubkey, counterpartyName: counterpartyName,
            pickupGeohash: "9q8yy", dropoffGeohash: "9q8yz",
            pickup: pickup, destination: dest,
            fare: fare, paymentMethod: paymentMethod,
            distance: distance, duration: duration
        )
    }

    @Test func idPreserved() {
        let row = RideHistoryRow.from(makeEntry(id: "ride-42"))
        #expect(row.id == "ride-42")
    }

    @Test func datePreserved() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let row = RideHistoryRow.from(makeEntry(date: date))
        #expect(row.date == date)
    }

    @Test func fareLabelFormattedCorrectly() {
        let row = RideHistoryRow.from(makeEntry(fare: Decimal(string: "14.50")!))
        #expect(row.fareLabel == "$14.50")
    }

    @Test func fareLabelZeroShowsDash() {
        let row = RideHistoryRow.from(makeEntry(fare: 0))
        #expect(row.fareLabel == "–")
    }

    @Test func distanceLabelFormatted() {
        let row = RideHistoryRow.from(makeEntry(distance: 4.2))
        #expect(row.distanceLabel == "4.2 mi")
    }

    @Test func distanceLabelNilWhenAbsent() {
        let row = RideHistoryRow.from(makeEntry(distance: nil))
        #expect(row.distanceLabel == nil)
    }

    @Test func durationLabelFormatted() {
        let row = RideHistoryRow.from(makeEntry(duration: 18))
        #expect(row.durationLabel == "18 min")
    }

    @Test func durationLabelNilWhenAbsent() {
        let row = RideHistoryRow.from(makeEntry(duration: nil))
        #expect(row.durationLabel == nil)
    }

    @Test func paymentMethodLabelResolvesKnownMethod() {
        let row = RideHistoryRow.from(makeEntry(paymentMethod: "cash_app"))
        #expect(row.paymentMethodLabel == "Cash App")
    }

    @Test func paymentMethodLabelPassesThroughUnknown() {
        let row = RideHistoryRow.from(makeEntry(paymentMethod: "custom_rail"))
        #expect(row.paymentMethodLabel == "custom_rail")
    }

    @Test func isCompletedTrueForCompletedStatus() {
        let row = RideHistoryRow.from(makeEntry(status: "completed"))
        #expect(row.isCompleted == true)
    }

    @Test func isCompletedFalseForCancelledStatus() {
        let row = RideHistoryRow.from(makeEntry(status: "cancelled"))
        #expect(row.isCompleted == false)
    }

    @Test func counterpartyNamePreserved() {
        let row = RideHistoryRow.from(makeEntry(counterpartyName: "Eve"))
        #expect(row.counterpartyName == "Eve")
    }

    @Test func nilCounterpartyNamePreserved() {
        let row = RideHistoryRow.from(makeEntry(counterpartyName: nil))
        #expect(row.counterpartyName == nil)
    }

    @Test func addressesPreserved() {
        let row = RideHistoryRow.from(makeEntry(pickupAddress: "123 Main St",
                                                destAddress: "456 Oak Ave"))
        #expect(row.pickupAddress == "123 Main St")
        #expect(row.destinationAddress == "456 Oak Ave")
    }
}

// MARK: - SavedLocationRow

@Suite("SavedLocationRow")
struct SavedLocationRowTests {

    private func makeLocation(
        id: String = "loc-1",
        displayName: String = "Home",
        addressLine: String = "100 Maple Ave",
        isPinned: Bool = true,
        nickname: String? = "Home",
        lat: Double = 37.7,
        lon: Double = -122.4
    ) -> SavedLocation {
        SavedLocation(
            id: id, latitude: lat, longitude: lon,
            displayName: displayName, addressLine: addressLine,
            isPinned: isPinned, nickname: nickname
        )
    }

    @Test func idPreserved() {
        let row = SavedLocationRow.from(makeLocation(id: "loc-99"))
        #expect(row.id == "loc-99")
    }

    @Test func labelUsesNicknameWhenPresent() {
        let row = SavedLocationRow.from(makeLocation(displayName: "123 Main", nickname: "Home"))
        #expect(row.label == "Home")
    }

    @Test func labelFallsBackToDisplayNameWhenNoNickname() {
        let row = SavedLocationRow.from(makeLocation(displayName: "Coffee Shop", nickname: nil))
        #expect(row.label == "Coffee Shop")
    }

    @Test func isFavoriteMatchesPinned() {
        let pinned = SavedLocationRow.from(makeLocation(isPinned: true))
        let recent  = SavedLocationRow.from(makeLocation(isPinned: false, nickname: nil))
        #expect(pinned.isFavorite == true)
        #expect(recent.isFavorite == false)
    }

    @Test func iconForHome() {
        let row = SavedLocationRow.from(makeLocation(nickname: "Home"))
        #expect(row.iconSystemName == "house.fill")
    }

    @Test func iconForWork() {
        let row = SavedLocationRow.from(makeLocation(displayName: "Work HQ", nickname: "Work"))
        #expect(row.iconSystemName == "briefcase.fill")
    }

    @Test func iconForFavoriteFallback() {
        let row = SavedLocationRow.from(makeLocation(displayName: "Gym", nickname: "Gym"))
        #expect(row.iconSystemName == "star.fill")
    }

    @Test func iconForRecentFallback() {
        let row = SavedLocationRow.from(makeLocation(displayName: "Airport", isPinned: false, nickname: nil))
        #expect(row.iconSystemName == "clock")
    }

    @Test func coordinatesPreserved() {
        let row = SavedLocationRow.from(makeLocation(lat: 40.7128, lon: -74.0060))
        #expect(row.latitude == 40.7128)
        #expect(row.longitude == -74.0060)
    }

    @Test func addressLinePreserved() {
        let row = SavedLocationRow.from(makeLocation(addressLine: "100 Maple Ave"))
        #expect(row.addressLine == "100 Maple Ave")
    }

    @Test func favoritesFilterFunction() {
        let fav = makeLocation(id: "f1", isPinned: true)
        let rec = makeLocation(id: "r1", isPinned: false, nickname: nil)
        let rows = SavedLocationRow.favorites(from: [fav, rec])
        #expect(rows.count == 1)
        #expect(rows.first?.id == "f1")
    }

    @Test func recentsFilterFunction() {
        let fav = makeLocation(id: "f1", isPinned: true)
        let rec = makeLocation(id: "r1", isPinned: false, nickname: nil)
        let rows = SavedLocationRow.recents(from: [fav, rec])
        #expect(rows.count == 1)
        #expect(rows.first?.id == "r1")
    }

    @Test func recentsLimitRespected() {
        let locs = (1...10).map { i in
            makeLocation(id: "r\(i)", isPinned: false, nickname: nil)
        }
        let rows = SavedLocationRow.recents(from: locs, limit: 3)
        #expect(rows.count == 3)
    }
}
