import Foundation
import Testing
@testable import RidestrSDK

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}

@Suite("UserSettingsRepository Tests")
struct UserSettingsRepositoryTests {
    private func makeRepo() -> UserSettingsRepository {
        UserSettingsRepository(persistence: InMemoryUserSettingsPersistence())
    }

    // MARK: - Fresh state

    @Test func defaultsEmpty() {
        let repo = makeRepo()
        #expect(repo.profileName.isEmpty)
        #expect(repo.roadflarePaymentMethods.isEmpty)
        #expect(!repo.profileCompleted)
    }

    @Test func initializesFromPersistence() {
        let persistence = InMemoryUserSettingsPersistence(
            initial: UserSettingsSnapshot(
                profileName: "Alice",
                roadflarePaymentMethods: ["zelle", "venmo"],
                profileCompleted: true
            )
        )
        let repo = UserSettingsRepository(persistence: persistence)
        #expect(repo.profileName == "Alice")
        #expect(repo.roadflarePaymentMethods == ["zelle", "venmo"])
        #expect(repo.profileCompleted)
    }

    // MARK: - setProfileName

    @Test func setProfileNameHappyPath() {
        let repo = makeRepo()
        let changedCount = CallbackCounter()
        repo.onProfileChanged = { changedCount.increment() }
        #expect(repo.setProfileName("Alice"))
        #expect(repo.profileName == "Alice")
        #expect(changedCount.count == 1)
    }

    @Test func setProfileNameRejectsEmptyOverNonEmpty() {
        let repo = makeRepo()
        _ = repo.setProfileName("Alice")
        let changedCount = CallbackCounter()
        repo.onProfileChanged = { changedCount.increment() }
        #expect(!repo.setProfileName(""))
        #expect(repo.profileName == "Alice")
        #expect(changedCount.count == 0)
    }

    @Test func setProfileNameAllowEmptyBypassesGuard() {
        let repo = makeRepo()
        _ = repo.setProfileName("Alice")
        let changedCount = CallbackCounter()
        repo.onProfileChanged = { changedCount.increment() }
        #expect(repo.setProfileName("", allowEmpty: true))
        #expect(repo.profileName.isEmpty)
        #expect(changedCount.count == 1)
    }

    @Test func setProfileNameUnchangedNoNotify() {
        let repo = makeRepo()
        _ = repo.setProfileName("Alice")
        let changedCount = CallbackCounter()
        repo.onProfileChanged = { changedCount.increment() }
        #expect(repo.setProfileName("Alice"))
        #expect(changedCount.count == 0)
    }

    @Test func setProfileNameWhitespaceRejectedOverNonEmpty() {
        let repo = makeRepo()
        _ = repo.setProfileName("Alice")
        #expect(!repo.setProfileName("   "))
        #expect(repo.profileName == "Alice")
    }

    @Test func setProfileNameEmptyOverEmptyIsUnchanged() {
        let repo = makeRepo()
        let changedCount = CallbackCounter()
        repo.onProfileChanged = { changedCount.increment() }
        // Default is empty; setting empty should be unchanged
        #expect(repo.setProfileName(""))
        #expect(changedCount.count == 0)
    }

    // MARK: - Notification isolation

    @Test func setProfileNameDoesNotFireBackupChanged() {
        let repo = makeRepo()
        let backupChanged = CallbackCounter()
        repo.onProfileBackupChanged = { backupChanged.increment() }
        _ = repo.setProfileName("Alice")
        #expect(backupChanged.count == 0)
    }

    @Test func togglePaymentMethodFiresBackupChanged() {
        let repo = makeRepo()
        let backupChanged = CallbackCounter()
        repo.onProfileBackupChanged = { backupChanged.increment() }
        repo.togglePaymentMethod(.zelle)
        #expect(backupChanged.count == 1)
    }

    @Test func togglePaymentMethodDoesNotFireProfileChanged() {
        let repo = makeRepo()
        let profileChanged = CallbackCounter()
        repo.onProfileChanged = { profileChanged.increment() }
        repo.togglePaymentMethod(.zelle)
        #expect(profileChanged.count == 0)
    }

    @Test func addCustomPaymentMethodFiresBackupChanged() {
        let repo = makeRepo()
        let backupChanged = CallbackCounter()
        repo.onProfileBackupChanged = { backupChanged.increment() }
        let result = repo.addCustomPaymentMethod("litecoin")
        #expect(result == .added)
        #expect(backupChanged.count == 1)
    }

    @Test func removeCustomPaymentMethodFiresBackupChanged() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["venmo-business", "cash"])
        let backupChanged = CallbackCounter()
        repo.onProfileBackupChanged = { backupChanged.increment() }
        repo.removeCustomPaymentMethod("venmo-business")
        #expect(backupChanged.count == 1)
    }

    @Test func moveRoadflarePaymentMethodsFiresBackupChanged() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle", "venmo", "cash"])
        let backupChanged = CallbackCounter()
        repo.onProfileBackupChanged = { backupChanged.increment() }
        repo.moveRoadflarePaymentMethods(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(backupChanged.count == 1)
    }

    // MARK: - setProfileCompleted

    @Test func setProfileCompletedPersistsNoNotify() {
        let repo = makeRepo()
        let profileChanged = CallbackCounter()
        let backupChanged = CallbackCounter()
        repo.onProfileChanged = { profileChanged.increment() }
        repo.onProfileBackupChanged = { backupChanged.increment() }
        repo.setProfileCompleted(true)
        #expect(repo.profileCompleted)
        #expect(profileChanged.count == 0)
        #expect(backupChanged.count == 0)
    }

    @Test func setProfileCompletedIdempotent() {
        let repo = makeRepo()
        repo.setProfileCompleted(true)
        repo.setProfileCompleted(true)
        #expect(repo.profileCompleted)
    }

    // MARK: - Payment methods

    @Test func togglePaymentMethod() {
        let repo = makeRepo()
        repo.togglePaymentMethod(.zelle)
        #expect(repo.isEnabled(.zelle))
        repo.togglePaymentMethod(.zelle)
        #expect(!repo.isEnabled(.zelle))
        #expect(repo.isEnabled(.cash))  // Cash forced as fallback
    }

    @Test func cashForcedWhenAllRemoved() {
        let repo = makeRepo()
        repo.togglePaymentMethod(.venmo)
        repo.togglePaymentMethod(.venmo)
        #expect(repo.isCashForced)
        #expect(repo.paymentMethods == [.cash])
    }

    @Test func setRoadflarePaymentMethodsNormalizes() {
        let repo = makeRepo()
        let backupChanged = CallbackCounter()
        repo.onProfileBackupChanged = { backupChanged.increment() }
        repo.setRoadflarePaymentMethods(["zelle", "venmo"])
        #expect(repo.roadflarePaymentMethods == ["zelle", "venmo"])
        #expect(backupChanged.count == 1)
    }

    @Test func setRoadflarePaymentMethodsUnchangedNoNotify() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle"])
        let backupChanged = CallbackCounter()
        repo.onProfileBackupChanged = { backupChanged.increment() }
        repo.setRoadflarePaymentMethods(["zelle"])
        #expect(backupChanged.count == 0)
    }

    @Test func addCustomPaymentMethodAdds() {
        let repo = makeRepo()
        let result = repo.addCustomPaymentMethod("Bitcoin")
        #expect(result == .added)
        #expect(repo.roadflarePaymentMethods == ["bitcoin"])
    }

    @Test func addCustomPaymentMethodEmpty() {
        let repo = makeRepo()
        let result = repo.addCustomPaymentMethod("   ")
        #expect(result == .empty)
        #expect(repo.roadflarePaymentMethods.isEmpty)
    }

    @Test func addCustomPaymentMethodRejectsDuplicate() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["bitcoin"])
        let result = repo.addCustomPaymentMethod("Bitcoin")
        #expect(result == .duplicate)
        #expect(repo.roadflarePaymentMethods == ["bitcoin"])
    }

    @Test func removeCustomPaymentMethod() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["venmo-business", "cash"])
        repo.removeCustomPaymentMethod("venmo-business")
        #expect(!repo.roadflarePaymentMethods.contains("venmo-business"))
        #expect(repo.roadflarePaymentMethods.contains("cash"))
    }

    @Test func removeCustomPaymentMethodLeavesKnownMethodsAlone() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle", "cash"])
        repo.removeCustomPaymentMethod("zelle")
        #expect(repo.roadflarePaymentMethods == ["zelle", "cash"])
    }

    @Test func moveRoadflarePaymentMethods() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle", "venmo", "cash"])
        repo.moveRoadflarePaymentMethods(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(repo.roadflarePaymentMethods == ["cash", "zelle", "venmo"])
    }

    @Test func toggleRoadflarePaymentMethodCaseInsensitive() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["custom-method"])
        repo.toggleRoadflarePaymentMethod("Custom-Method")
        #expect(!repo.roadflarePaymentMethods.contains("custom-method"))
    }

    // MARK: - Computed helpers

    @Test func isCashForcedTrueOnlyForSingletonCash() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["cash"])
        #expect(repo.isCashForced)
        repo.setRoadflarePaymentMethods(["cash", "zelle"])
        #expect(!repo.isCashForced)
    }

    @Test func allPaymentMethodNames() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle", "custom-method"])
        #expect(repo.allPaymentMethodNames.contains("Zelle"))
        #expect(repo.allPaymentMethodNames.contains("custom-method"))
    }

    // MARK: - performWithoutChangeTracking

    @Test func performWithoutChangeTrackingSuppressesCallbacks() {
        let repo = makeRepo()
        let profileChanged = CallbackCounter()
        let backupChanged = CallbackCounter()
        repo.onProfileChanged = { profileChanged.increment() }
        repo.onProfileBackupChanged = { backupChanged.increment() }
        repo.performWithoutChangeTracking {
            _ = repo.setProfileName("Alice")
            repo.setRoadflarePaymentMethods(["zelle"])
        }
        #expect(repo.profileName == "Alice")
        #expect(repo.roadflarePaymentMethods == ["zelle"])
        #expect(profileChanged.count == 0)
        #expect(backupChanged.count == 0)
    }

    @Test func performWithoutChangeTrackingNesting() {
        let repo = makeRepo()
        let profileChanged = CallbackCounter()
        repo.onProfileChanged = { profileChanged.increment() }
        repo.performWithoutChangeTracking {
            repo.performWithoutChangeTracking {
                _ = repo.setProfileName("Inner")
            }
            // After inner block, still suppressed
            _ = repo.setProfileName("Outer")
        }
        #expect(repo.profileName == "Outer")
        #expect(profileChanged.count == 0)
    }

    // MARK: - clearAll

    @Test func clearAll() {
        let repo = makeRepo()
        repo.togglePaymentMethod(.zelle)
        _ = repo.setProfileName("Bob")
        repo.setProfileCompleted(true)
        let profileChanged = CallbackCounter()
        let backupChanged = CallbackCounter()
        repo.onProfileChanged = { profileChanged.increment() }
        repo.onProfileBackupChanged = { backupChanged.increment() }
        repo.clearAll()
        #expect(repo.profileName.isEmpty)
        #expect(repo.roadflarePaymentMethods.isEmpty)
        #expect(!repo.profileCompleted)
        #expect(profileChanged.count == 0)
        #expect(backupChanged.count == 0)
    }

    @Test func clearAllPersists() {
        let persistence = InMemoryUserSettingsPersistence()
        let repo = UserSettingsRepository(persistence: persistence)
        _ = repo.setProfileName("Alice")
        repo.clearAll()
        let snapshot = persistence.load()
        #expect(snapshot.profileName.isEmpty)
        #expect(snapshot.roadflarePaymentMethods.isEmpty)
        #expect(!snapshot.profileCompleted)
    }
}
