import Foundation
import RidestrSDK

/// Shared resolver for the driver-status priority ladder used by both
/// `DriverListItem` and `DriverDetailViewState`.
///
/// Keeping the logic in one place means a new status string or precondition
/// only needs to be added in one spot.
func resolveDriverPresentationStatus(
    hasKey: Bool,
    isKeyStale: Bool,
    location: CachedDriverLocation?
) -> DriverListItem.Status {
    if isKeyStale {
        return .keyStale
    }
    if !hasKey {
        return .pendingApproval
    }
    guard let loc = location else {
        return .offline
    }
    switch loc.status {
    case "online":  return .online
    case "on_ride": return .onRide
    default:        return .offline
    }
}

extension DriverListItem.Status {
    /// Human-readable label used by the driver detail sheet.
    var detailLabel: String {
        switch self {
        case .online:          return "Available"
        case .onRide:          return "On a ride"
        case .offline:         return "Offline"
        case .pendingApproval: return "Pending approval"
        case .keyStale:        return "Key outdated"
        }
    }
}
