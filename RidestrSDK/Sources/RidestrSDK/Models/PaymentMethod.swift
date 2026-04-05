import Foundation

/// Known payment method labels used by the iOS RoadFlare client.
public enum PaymentMethod: String, Codable, Sendable, CaseIterable {
    case zelle
    case paypal
    case cashApp = "cash_app"
    case venmo
    case strike
    case bitcoin
    case cash

    public var displayName: String {
        switch self {
        case .zelle: "Zelle"
        case .paypal: "PayPal"
        case .cashApp: "Cash App"
        case .venmo: "Venmo"
        case .strike: "Strike"
        case .bitcoin: "Bitcoin"
        case .cash: "Cash"
        }
    }

    /// Known RoadFlare alternate payment rails shown in iOS configuration UI.
    public static let roadflareAlternates: [PaymentMethod] = [
        .zelle, .paypal, .cashApp, .venmo, .strike, .bitcoin, .cash,
    ]

    public static func displayName(for rawValue: String) -> String {
        if let canonical = canonicalRoadflareRawValue(for: rawValue),
           let method = PaymentMethod(rawValue: canonical) {
            return method.displayName
        }
        return rawValue
    }

    public static func canonicalRoadflareRawValue(for input: String) -> String? {
        let lookupKey = normalizedLookupKey(for: input)
        guard !lookupKey.isEmpty else { return nil }

        return roadflareAlternates.first(where: {
            normalizedLookupKey(for: $0.rawValue) == lookupKey
                || normalizedLookupKey(for: $0.displayName) == lookupKey
        })?.rawValue
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

    private static func normalizedLookupKey(for input: String) -> String {
        String(
            input.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { character in
                    character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
                }
        )
    }
}

/// Result of attempting to add a custom payment method.
public enum CustomPaymentMethodAddResult: Equatable, Sendable {
    case added
    case empty
    case duplicate
}
