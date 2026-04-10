import Foundation
import RidestrSDK

/// UserDefaults-backed persistence for `UserSettingsRepository`.
///
/// Owns iOS-specific legacy key migration (from `user_payment_methods` +
/// `user_custom_payment_methods` to the unified `user_roadflare_payment_methods`).
final class UserDefaultsUserSettingsPersistence: UserSettingsPersistence, @unchecked Sendable {
    private let defaults: UserDefaults

    private static let roadflarePaymentMethodsKey = "user_roadflare_payment_methods"
    private static let profileNameKey = "user_profile_name"
    private static let profileCompletedKey = "user_profile_completed"

    // Legacy keys — migrated on first load.
    private static let legacyPaymentMethodsKey = "user_payment_methods"
    private static let legacyCustomPaymentMethodsKey = "user_custom_payment_methods"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> UserSettingsSnapshot {
        UserSettingsSnapshot(
            profileName: defaults.string(forKey: Self.profileNameKey) ?? "",
            roadflarePaymentMethods: loadRoadflarePaymentMethods(),
            profileCompleted: defaults.bool(forKey: Self.profileCompletedKey)
        )
    }

    func save(_ snapshot: UserSettingsSnapshot) {
        defaults.set(snapshot.profileName, forKey: Self.profileNameKey)
        defaults.set(snapshot.profileCompleted, forKey: Self.profileCompletedKey)
        if snapshot.roadflarePaymentMethods.isEmpty {
            defaults.removeObject(forKey: Self.roadflarePaymentMethodsKey)
        } else {
            defaults.set(snapshot.roadflarePaymentMethods, forKey: Self.roadflarePaymentMethodsKey)
        }
    }

    func clearAll() {
        [Self.roadflarePaymentMethodsKey,
         Self.legacyPaymentMethodsKey,
         Self.legacyCustomPaymentMethodsKey,
         Self.profileNameKey,
         Self.profileCompletedKey].forEach {
            defaults.removeObject(forKey: $0)
        }
    }

    private func loadRoadflarePaymentMethods() -> [String] {
        if let stored = defaults.stringArray(forKey: Self.roadflarePaymentMethodsKey) {
            return RoadflarePaymentPreferences.normalize(stored)
        }
        // Legacy migration (iOS-specific keys from before unified storage).
        let legacyKnown = (defaults.stringArray(forKey: Self.legacyPaymentMethodsKey) ?? [])
            .compactMap { PaymentMethod(rawValue: $0)?.rawValue }
        let legacyCustom = defaults.stringArray(forKey: Self.legacyCustomPaymentMethodsKey) ?? []
        let merged = RoadflarePaymentPreferences.merge(
            knownMethods: legacyKnown.compactMap(PaymentMethod.init(rawValue:)),
            customMethods: legacyCustom
        ).methods
        // Write-through on both paths (matches former UserSettings.init behavior).
        if merged.isEmpty {
            defaults.removeObject(forKey: Self.roadflarePaymentMethodsKey)
        } else {
            defaults.set(merged, forKey: Self.roadflarePaymentMethodsKey)
        }
        return merged
    }
}
