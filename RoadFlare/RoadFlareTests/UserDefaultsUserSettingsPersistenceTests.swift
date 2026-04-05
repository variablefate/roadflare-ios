import Testing
import Foundation
@testable import RoadFlare
@testable import RidestrSDK

@Suite("UserDefaultsUserSettingsPersistence Tests")
struct UserDefaultsUserSettingsPersistenceTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test_\(UUID().uuidString)")!
    }

    @Test func loadEmptyOnFreshDefaults() {
        let defaults = makeDefaults()
        let persistence = UserDefaultsUserSettingsPersistence(defaults: defaults)
        let snapshot = persistence.load()
        #expect(snapshot.profileName.isEmpty)
        #expect(snapshot.roadflarePaymentMethods.isEmpty)
        #expect(!snapshot.profileCompleted)
    }

    @Test func saveAndReloadRoundTrip() {
        let defaults = makeDefaults()
        let p1 = UserDefaultsUserSettingsPersistence(defaults: defaults)
        p1.save(UserSettingsSnapshot(
            profileName: "Alice",
            roadflarePaymentMethods: ["zelle", "venmo"],
            profileCompleted: true
        ))

        let p2 = UserDefaultsUserSettingsPersistence(defaults: defaults)
        let snapshot = p2.load()
        #expect(snapshot.profileName == "Alice")
        #expect(snapshot.roadflarePaymentMethods == ["zelle", "venmo"])
        #expect(snapshot.profileCompleted)
    }

    @Test func migratesLegacyKeys() {
        let defaults = makeDefaults()
        defaults.set(["zelle", "cash"], forKey: "user_payment_methods")
        defaults.set(["venmo-business"], forKey: "user_custom_payment_methods")

        let persistence = UserDefaultsUserSettingsPersistence(defaults: defaults)
        let snapshot = persistence.load()
        #expect(snapshot.roadflarePaymentMethods == ["zelle", "cash", "venmo-business"])
        // Migration writes through to new key
        #expect(defaults.stringArray(forKey: "user_roadflare_payment_methods") == ["zelle", "cash", "venmo-business"])
    }

    @Test func preservesBitcoinDuringMigration() {
        let defaults = makeDefaults()
        defaults.set(["bitcoin", "cash"], forKey: "user_payment_methods")

        let persistence = UserDefaultsUserSettingsPersistence(defaults: defaults)
        let snapshot = persistence.load()
        #expect(snapshot.roadflarePaymentMethods == ["bitcoin", "cash"])
    }

    @Test func newKeyWinsWhenBothPresent() {
        let defaults = makeDefaults()
        defaults.set(["venmo-business"], forKey: "user_custom_payment_methods")
        defaults.set(["bitcoin"], forKey: "user_roadflare_payment_methods")

        let persistence = UserDefaultsUserSettingsPersistence(defaults: defaults)
        let snapshot = persistence.load()
        #expect(snapshot.roadflarePaymentMethods == ["bitcoin"])
    }

    @Test func clearAllRemovesAllKeys() {
        let defaults = makeDefaults()
        defaults.set("Alice", forKey: "user_profile_name")
        defaults.set(true, forKey: "user_profile_completed")
        defaults.set(["zelle"], forKey: "user_roadflare_payment_methods")
        defaults.set(["zelle"], forKey: "user_payment_methods")
        defaults.set(["custom"], forKey: "user_custom_payment_methods")

        let persistence = UserDefaultsUserSettingsPersistence(defaults: defaults)
        persistence.clearAll()

        #expect(defaults.string(forKey: "user_profile_name") == nil)
        #expect(!defaults.bool(forKey: "user_profile_completed"))
        #expect(defaults.stringArray(forKey: "user_roadflare_payment_methods") == nil)
        #expect(defaults.stringArray(forKey: "user_payment_methods") == nil)
        #expect(defaults.stringArray(forKey: "user_custom_payment_methods") == nil)
    }

    @Test func saveWithEmptyMethodsRemovesNewKey() {
        let defaults = makeDefaults()
        defaults.set(["zelle"], forKey: "user_roadflare_payment_methods")

        let persistence = UserDefaultsUserSettingsPersistence(defaults: defaults)
        persistence.save(UserSettingsSnapshot(
            profileName: "Alice",
            roadflarePaymentMethods: [],
            profileCompleted: false
        ))
        #expect(defaults.stringArray(forKey: "user_roadflare_payment_methods") == nil)
    }
}
