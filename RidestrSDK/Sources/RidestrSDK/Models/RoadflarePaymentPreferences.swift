import Foundation

/// Ordered RoadFlare payment preferences shared across backup and ride-offer wiring.
///
/// The first method is the rider's highest-priority alternate rail and becomes the
/// `payment_method` in RoadFlare ride offers. The full ordered list is published as
/// `fiat_payment_methods`.
public struct RoadflarePaymentPreferences: Equatable, Sendable {
    public let methods: [String]

    public init(methods: [String] = []) {
        self.methods = Self.normalize(methods)
    }

    public var primaryMethod: String? {
        methods.first
    }

    public static func normalize(_ methods: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for method in methods {
            let trimmed = method.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let canonical = PaymentMethod.canonicalRoadflareRawValue(for: trimmed) ?? trimmed

            let dedupKey = canonical.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seen.insert(dedupKey).inserted else { continue }
            normalized.append(canonical)
        }

        return normalized
    }

    public static func merge(
        knownMethods: [PaymentMethod],
        customMethods: [String]
    ) -> RoadflarePaymentPreferences {
        RoadflarePaymentPreferences(
            methods: knownMethods.map(\.rawValue) + customMethods
        )
    }

    public static func displayName(for method: String) -> String {
        PaymentMethod.displayName(for: method)
    }
}
