import Foundation
import RidestrSDK

/// Persistent user settings backed by UserDefaults.
@Observable @MainActor
final class UserSettings {
    enum CustomPaymentMethodAddResult: Equatable {
        case added
        case empty
        case duplicate
    }

    private let defaults: UserDefaults
    private static let roadflarePaymentMethodsKey = "user_roadflare_payment_methods"
    private static let legacyPaymentMethodsKey = "user_payment_methods"
    private static let legacyCustomPaymentMethodsKey = "user_custom_payment_methods"
    private static let profileNameKey = "user_profile_name"
    private static let profileCompletedKey = "user_profile_completed"
    private var suppressChangeNotifications = false
    private var allowEmptyProfileName = false

    var onProfileChanged: (@MainActor () -> Void)?
    var onProfileBackupChanged: (@MainActor () -> Void)?

    /// Ordered RoadFlare payment methods shared with backup + ride offers.
    var roadflarePaymentMethods: [String] {
        didSet {
            let normalized = RoadflarePaymentPreferences.normalize(roadflarePaymentMethods)
            if roadflarePaymentMethods != normalized {
                roadflarePaymentMethods = normalized
                return
            }
            defaults.set(roadflarePaymentMethods, forKey: Self.roadflarePaymentMethodsKey)
            notifyProfileBackupChanged()
        }
    }

    /// Known built-in payment methods enabled by the user, in current order.
    var paymentMethods: [PaymentMethod] {
        get { roadflarePaymentMethods.compactMap { PaymentMethod(rawValue: $0) } }
        set {
            roadflarePaymentMethods = RoadflarePaymentPreferences.merge(
                knownMethods: newValue,
                customMethods: customPaymentMethods
            ).methods
        }
    }

    /// Custom/unknown payment method names added by the user, in current order.
    var customPaymentMethods: [String] {
        get { roadflarePaymentMethods.filter { PaymentMethod(rawValue: $0) == nil } }
        set {
            roadflarePaymentMethods = RoadflarePaymentPreferences.merge(
                knownMethods: paymentMethods,
                customMethods: newValue
            ).methods
        }
    }

    /// User's display name. Never persisted as empty — reverts to previous value.
    var profileName: String {
        didSet {
            let trimmed = profileName.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && !oldValue.trimmingCharacters(in: .whitespaces).isEmpty && !allowEmptyProfileName {
                profileName = oldValue
            } else {
                defaults.set(profileName, forKey: Self.profileNameKey)
                if profileName != oldValue {
                    notifyProfileChanged()
                }
            }
        }
    }

    /// Whether onboarding is complete.
    var profileCompleted: Bool {
        didSet { defaults.set(profileCompleted, forKey: Self.profileCompletedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let initialRoadflarePaymentMethods: [String]
        if let stored = defaults.stringArray(forKey: Self.roadflarePaymentMethodsKey) {
            initialRoadflarePaymentMethods = RoadflarePaymentPreferences.normalize(stored)
        } else {
            let legacyKnown = (defaults.stringArray(forKey: Self.legacyPaymentMethodsKey) ?? [])
                .compactMap { PaymentMethod(rawValue: $0)?.rawValue }
            let legacyCustom = defaults.stringArray(forKey: Self.legacyCustomPaymentMethodsKey) ?? []
            initialRoadflarePaymentMethods = RoadflarePaymentPreferences.merge(
                knownMethods: legacyKnown.compactMap(PaymentMethod.init(rawValue:)),
                customMethods: legacyCustom
            ).methods
        }
        if initialRoadflarePaymentMethods.isEmpty {
            defaults.removeObject(forKey: Self.roadflarePaymentMethodsKey)
        } else {
            defaults.set(initialRoadflarePaymentMethods, forKey: Self.roadflarePaymentMethodsKey)
        }
        self.roadflarePaymentMethods = initialRoadflarePaymentMethods
        self.profileName = defaults.string(forKey: Self.profileNameKey) ?? ""
        self.profileCompleted = defaults.bool(forKey: Self.profileCompletedKey)
    }

    func togglePaymentMethod(_ method: PaymentMethod) {
        if isEnabled(method) {
            roadflarePaymentMethods.removeAll { $0 == method.rawValue }
            if roadflarePaymentMethods.isEmpty {
                roadflarePaymentMethods = [PaymentMethod.cash.rawValue]
            }
        } else {
            roadflarePaymentMethods.append(method.rawValue)
        }
    }

    func isEnabled(_ method: PaymentMethod) -> Bool {
        roadflarePaymentMethods.contains(method.rawValue)
    }

    var isCashForced: Bool {
        roadflarePaymentMethods == [PaymentMethod.cash.rawValue]
    }

    func addCustomPaymentMethod(_ name: String) -> CustomPaymentMethodAddResult {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }
        let canonical = PaymentMethod.canonicalRoadflareRawValue(for: trimmed) ?? trimmed
        let key = normalizedMethodKey(canonical)
        guard !roadflarePaymentMethods.contains(where: { normalizedMethodKey($0) == key }) else {
            return .duplicate
        }
        roadflarePaymentMethods.append(canonical)
        return .added
    }

    func removeCustomPaymentMethod(_ name: String) {
        let key = normalizedMethodKey(name)
        roadflarePaymentMethods.removeAll {
            PaymentMethod(rawValue: $0) == nil && normalizedMethodKey($0) == key
        }
    }

    func setRoadflarePaymentMethods(_ methods: [String]) {
        roadflarePaymentMethods = methods
    }

    func moveRoadflarePaymentMethods(fromOffsets: IndexSet, toOffset: Int) {
        var methods = roadflarePaymentMethods
        let moving = fromOffsets.map { methods[$0] }
        for index in fromOffsets.sorted(by: >) {
            methods.remove(at: index)
        }
        let adjustedOffset = min(toOffset, methods.count)
        methods.insert(contentsOf: moving, at: adjustedOffset)
        roadflarePaymentMethods = methods
    }

    func toggleRoadflarePaymentMethod(_ method: String) {
        let normalized = PaymentMethod.canonicalRoadflareRawValue(for: method)
            ?? method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let key = normalizedMethodKey(normalized)
        if roadflarePaymentMethods.contains(where: { normalizedMethodKey($0) == key }) {
            roadflarePaymentMethods.removeAll { normalizedMethodKey($0) == key }
            if roadflarePaymentMethods.isEmpty {
                roadflarePaymentMethods = [PaymentMethod.cash.rawValue]
            }
        } else {
            roadflarePaymentMethods.append(normalized)
        }
    }

    func isRoadflareMethodEnabled(_ method: String) -> Bool {
        let key = normalizedMethodKey(method)
        return roadflarePaymentMethods.contains { normalizedMethodKey($0) == key }
    }

    var roadflarePrimaryPaymentMethod: String? {
        RoadflarePaymentPreferences(methods: roadflarePaymentMethods).primaryMethod
    }

    var roadflareMethodChoices: [String] {
        let known = PaymentMethod.roadflareAlternates.map(\.rawValue)
        return RoadflarePaymentPreferences.normalize(
            known + roadflarePaymentMethods.filter { PaymentMethod(rawValue: $0) == nil }
        )
    }

    /// All payment method display names (built-in + custom) for the ride offer.
    var allPaymentMethodNames: [String] {
        roadflarePaymentMethods.map(RoadflarePaymentPreferences.displayName(for:))
    }

    func performWithoutChangeTracking(_ updates: () -> Void) {
        let previous = suppressChangeNotifications
        suppressChangeNotifications = true
        updates()
        suppressChangeNotifications = previous
    }

    func clearAll() {
        performWithoutChangeTracking {
            let previousAllowEmpty = allowEmptyProfileName
            allowEmptyProfileName = true
            roadflarePaymentMethods = []
            profileName = ""
            profileCompleted = false
            allowEmptyProfileName = previousAllowEmpty
        }
        defaults.removeObject(forKey: Self.roadflarePaymentMethodsKey)
        defaults.removeObject(forKey: Self.legacyPaymentMethodsKey)
        defaults.removeObject(forKey: Self.legacyCustomPaymentMethodsKey)
        defaults.removeObject(forKey: Self.profileNameKey)
        defaults.removeObject(forKey: Self.profileCompletedKey)
    }

    private func notifyProfileChanged() {
        guard !suppressChangeNotifications else { return }
        onProfileChanged?()
    }

    private func notifyProfileBackupChanged() {
        guard !suppressChangeNotifications else { return }
        onProfileBackupChanged?()
    }

    private func normalizedMethodKey(_ method: String) -> String {
        method.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
