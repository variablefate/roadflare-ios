import Foundation
import RidestrSDK

// MARK: - Façade: Presentation Types
//
// These methods project repository state into app-owned presentation types so
// views never need to touch SDK domain models for rendering.

extension AppState {

    /// Sorted driver list items for the Drivers tab.
    ///
    /// Order: online → onRide → keyStale → pendingApproval → offline.
    public func driverListItems() -> [DriverListItem] {
        guard let repo = driversRepository else { return [] }
        return repo.drivers.map { driver in
            DriverListItem.from(
                driver,
                displayName: repo.cachedDriverName(pubkey: driver.pubkey),
                location: repo.driverLocations[driver.pubkey],
                profile: repo.driverProfiles[driver.pubkey],
                vehicle: repo.driverVehicles[driver.pubkey],
                isKeyStale: repo.staleKeyPubkeys.contains(driver.pubkey),
                canPing: repo.canPingDriver(driver)
            )
        }
        .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// Detail view state for a single driver. Returns nil if the driver is not found.
    public func driverDetailViewState(pubkey: String) -> DriverDetailViewState? {
        guard let repo = driversRepository,
              let driver = repo.getDriver(pubkey: pubkey) else { return nil }
        return DriverDetailViewState.from(
            driver,
            displayName: repo.cachedDriverName(pubkey: pubkey),
            location: repo.driverLocations[pubkey],
            profile: repo.driverProfiles[pubkey],
            vehicle: repo.driverVehicles[pubkey],
            isKeyStale: repo.staleKeyPubkeys.contains(pubkey),
            canPing: repo.canPingDriver(driver)
        )
    }

    /// Available driver options for a new ride request (online, non-stale drivers only).
    public func onlineDriverOptions() -> [RideRequestDriverOption] {
        guard let repo = driversRepository else { return [] }
        return RideRequestDriverOption.onlineOptions(
            from: repo.drivers,
            driverNames: repo.driverNames,
            driverLocations: repo.driverLocations,
            staleKeyPubkeys: repo.staleKeyPubkeys
        )
    }

    /// `true` when any followed driver is currently a valid ping target.
    ///
    /// Lets views gate a "Ping a Driver" CTA without materializing the full
    /// `driverListItems()` array (which builds a DriverListItem per driver and
    /// sorts the result) just to check one boolean.
    public var hasPingableDriver: Bool {
        guard let repo = driversRepository else { return false }
        return repo.drivers.contains(where: { repo.canPingDriver($0) })
    }

    /// Ride history as display-ready rows. Filters by `appOrigin == "roadflare"`
    /// so that entries synced from a sibling app (e.g. Ridestr Android on the
    /// same account) are merged into the local store but hidden from this view.
    public var rideHistoryRows: [RideHistoryRow] {
        rideHistory.rides
            .filter { $0.appOrigin == "roadflare" }
            .map { RideHistoryRow.from($0) }
    }

    /// Favorite saved locations as display-ready rows.
    public var favoriteLocationRows: [SavedLocationRow] {
        savedLocations.favorites.map { SavedLocationRow.from($0) }
    }

    /// Recent (non-pinned) saved locations as display-ready rows, newest first.
    ///
    /// Mirrors `SavedLocationsRepository.recents` exactly — including the
    /// proximity filter that drops recents within ~50m of any favorite. Using
    /// `SavedLocationRow.recents(from:)` would skip that filter and show
    /// duplicates that the repo has deliberately suppressed.
    public var recentLocationRows: [SavedLocationRow] {
        savedLocations.recents.map { SavedLocationRow.from($0) }
    }
}
