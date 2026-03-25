import Foundation

/// Payment methods supported by the Ridestr protocol.
/// v1 supports fiat-only methods. Cashu/Lightning are defined for protocol compatibility
/// but not implemented.
public enum PaymentMethod: String, Codable, Sendable, CaseIterable {
    case zelle
    case paypal
    case cashApp = "cash_app"
    case venmo
    case strike
    case cash
    case bitcoin

    public var displayName: String {
        switch self {
        case .zelle: "Zelle"
        case .paypal: "PayPal"
        case .cashApp: "Cash App"
        case .venmo: "Venmo"
        case .strike: "Strike"
        case .cash: "Cash"
        case .bitcoin: "Bitcoin"
        }
    }

    /// Find the first common payment method between rider preferences and driver's accepted methods.
    /// Returns nil if no common method exists.
    public static func findCommon(
        riderPreferences: [PaymentMethod],
        driverAccepted: [PaymentMethod]
    ) -> PaymentMethod? {
        let driverSet = Set(driverAccepted)
        return riderPreferences.first { driverSet.contains($0) }
    }
}
