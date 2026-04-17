import Foundation
import RidestrSDK

/// Display-ready representation of a saved location for list rows.
///
/// Covers both favorites (isPinned = true) and recents.
public struct SavedLocationRow: Equatable, Sendable, Identifiable {

    // MARK: - Identity

    /// Stable ID matching `SavedLocation.id` — used for delete actions.
    public let id: String

    // MARK: - Display

    /// Primary label: nickname if set (e.g. "Home"), otherwise `displayName`.
    public let label: String

    /// The raw display name from the location (place name or searched text).
    public let displayName: String

    /// Street-level address string for the subtitle row.
    public let addressLine: String

    // MARK: - Category

    /// Whether this is a pinned favorite vs. a recent.
    public let isFavorite: Bool

    /// SF Symbol name appropriate for the location label.
    public var iconSystemName: String {
        switch label.lowercased() {
        case "home": return "house.fill"
        case "work": return "briefcase.fill"
        default:     return isFavorite ? "star.fill" : "clock"
        }
    }

    // MARK: - Coordinates (for address-fill actions)

    public let latitude: Double
    public let longitude: Double

    // MARK: - Factory

    /// Project a `SavedLocation` into a display-ready row.
    public static func from(_ location: SavedLocation) -> SavedLocationRow {
        SavedLocationRow(
            id: location.id,
            label: location.nickname ?? location.displayName,
            displayName: location.displayName,
            addressLine: location.addressLine,
            isFavorite: location.isPinned,
            latitude: location.latitude,
            longitude: location.longitude
        )
    }

    /// Build rows for the favorites section.
    public static func favorites(from locations: [SavedLocation]) -> [SavedLocationRow] {
        locations.filter(\.isPinned).map { from($0) }
    }

    /// Build rows for the recents section (up to `limit` items).
    public static func recents(from locations: [SavedLocation], limit: Int = 5) -> [SavedLocationRow] {
        locations
            .filter { !$0.isPinned }
            .prefix(limit)
            .map { from($0) }
    }
}
