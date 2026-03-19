import Foundation
import RidestrSDK

/// Persistent user settings backed by UserDefaults.
@Observable @MainActor
final class UserSettings {
    private let defaults: UserDefaults
    private static let paymentMethodsKey = "user_payment_methods"
    private static let profileNameKey = "user_profile_name"
    private static let profileCompletedKey = "user_profile_completed"

    /// Active payment methods the user has, ordered by preference.
    var paymentMethods: [PaymentMethod] {
        didSet { savePaymentMethods() }
    }

    /// User's display name. Never persisted as empty — reverts to previous value.
    var profileName: String {
        didSet {
            let trimmed = profileName.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty && !oldValue.trimmingCharacters(in: .whitespaces).isEmpty {
                profileName = oldValue  // Revert — don't persist empty
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

        // Load payment methods
        if let raw = defaults.stringArray(forKey: Self.paymentMethodsKey) {
            self.paymentMethods = raw.compactMap { PaymentMethod(rawValue: $0) }
        } else {
            self.paymentMethods = []  // Empty until user configures during onboarding
        }

        self.profileName = defaults.string(forKey: Self.profileNameKey) ?? ""
        self.profileCompleted = defaults.bool(forKey: Self.profileCompletedKey)
    }

    /// Toggle a payment method on/off. Enforces cash as fallback if all others are removed.
    func togglePaymentMethod(_ method: PaymentMethod) {
        if paymentMethods.contains(method) {
            paymentMethods.removeAll { $0 == method }
            // If nothing left, force cash on
            if paymentMethods.isEmpty && method != .cash {
                paymentMethods = [.cash]
            } else if paymentMethods.isEmpty {
                paymentMethods = [.cash]
            }
        } else {
            paymentMethods.append(method)
        }
    }

    /// Whether a specific method is enabled.
    func isEnabled(_ method: PaymentMethod) -> Bool {
        paymentMethods.contains(method)
    }

    /// Whether cash is forced on (it's the only method and user tried to remove others).
    var isCashForced: Bool {
        paymentMethods == [.cash]
    }

    /// Clear all settings (for logout).
    func clearAll() {
        paymentMethods = []
        profileName = ""
        profileCompleted = false
        defaults.removeObject(forKey: Self.paymentMethodsKey)
        defaults.removeObject(forKey: Self.profileNameKey)
        defaults.removeObject(forKey: Self.profileCompletedKey)
    }

    private func savePaymentMethods() {
        defaults.set(paymentMethods.map(\.rawValue), forKey: Self.paymentMethodsKey)
    }
}
