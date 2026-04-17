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

    /// Ride history as display-ready rows.
    public var rideHistoryRows: [RideHistoryRow] {
        rideHistory.rides.map { RideHistoryRow.from($0) }
    }

    /// Favorite saved locations as display-ready rows.
    public var favoriteLocationRows: [SavedLocationRow] {
        SavedLocationRow.favorites(from: savedLocations.locations)
    }

    /// Recent (non-pinned) saved locations as display-ready rows, newest first.
    public var recentLocationRows: [SavedLocationRow] {
        SavedLocationRow.recents(from: savedLocations.locations)
    }
}
