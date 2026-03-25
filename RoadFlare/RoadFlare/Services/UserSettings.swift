import Foundation
import RidestrSDK

/// Persistent user settings backed by UserDefaults.
@Observable @MainActor
final class UserSettings {
    private let defaults: UserDefaults
    private static let paymentMethodsKey = "user_payment_methods"
    private static let customPaymentMethodsKey = "user_custom_payment_methods"
    private static let profileNameKey = "user_profile_name"
    private static let profileCompletedKey = "user_profile_completed"

    /// Active payment methods the user has, ordered by preference.
    var paymentMethods: [PaymentMethod] {
        didSet { savePaymentMethods() }
    }

    /// Custom payment method names added by the user.
    var customPaymentMethods: [String] {
        didSet { defaults.set(customPaymentMethods, forKey: Self.customPaymentMethodsKey) }
    }

    /// User's display name. Never persisted as empty — reverts to previous value.
    var profileName: String {
        didSet {
            let trimmed = profileName.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && !oldValue.trimmingCharacters(in: .whitespaces).isEmpty {
                profileName = oldValue
            } else {
                defaults.set(profileName, forKey: Self.profileNameKey)
            }
        }
    }

    /// Whether onboarding is complete.
    var profileCompleted: Bool {
        didSet { defaults.set(profileCompleted, forKey: Self.profileCompletedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.stringArray(forKey: Self.paymentMethodsKey) {
            self.paymentMethods = raw.compactMap { PaymentMethod(rawValue: $0) }
        } else {
            self.paymentMethods = []
        }

        self.customPaymentMethods = defaults.stringArray(forKey: Self.customPaymentMethodsKey) ?? []
        self.profileName = defaults.string(forKey: Self.profileNameKey) ?? ""
        self.profileCompleted = defaults.bool(forKey: Self.profileCompletedKey)
    }

    func togglePaymentMethod(_ method: PaymentMethod) {
        if paymentMethods.contains(method) {
            paymentMethods.removeAll { $0 == method }
            if paymentMethods.isEmpty {
                paymentMethods = [.cash]
            }
        } else {
            paymentMethods.append(method)
        }
    }

    func isEnabled(_ method: PaymentMethod) -> Bool {
        paymentMethods.contains(method)
    }

    var isCashForced: Bool {
        paymentMethods == [.cash]
    }

    func addCustomPaymentMethod(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !customPaymentMethods.contains(trimmed) else { return }
        customPaymentMethods.append(trimmed)
    }

    func removeCustomPaymentMethod(_ name: String) {
        customPaymentMethods.removeAll { $0 == name }
    }

    /// All payment method display names (built-in + custom) for the ride offer.
    var allPaymentMethodNames: [String] {
        paymentMethods.map(\.displayName) + customPaymentMethods
    }

    func clearAll() {
        paymentMethods = []
        customPaymentMethods = []
        profileName = ""
        profileCompleted = false
        defaults.removeObject(forKey: Self.paymentMethodsKey)
        defaults.removeObject(forKey: Self.customPaymentMethodsKey)
        defaults.removeObject(forKey: Self.profileNameKey)
        defaults.removeObject(forKey: Self.profileCompletedKey)
    }

    private func savePaymentMethods() {
        defaults.set(paymentMethods.map(\.rawValue), forKey: Self.paymentMethodsKey)
    }
}
