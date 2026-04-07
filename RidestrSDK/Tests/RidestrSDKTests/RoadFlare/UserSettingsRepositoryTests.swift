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

    @Test func setRoadflarePaymentMethodsDeduplicatesAndTrims() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle", " Zelle ", "venmo"])
        #expect(repo.roadflarePaymentMethods == ["zelle", "venmo"])
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

    @Test func moveRoadflarePaymentMethodsClampsOffset() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle", "venmo", "cash"])
        // toOffset 99 exceeds array size after removal — implementation clamps via min()
        repo.moveRoadflarePaymentMethods(fromOffsets: IndexSet(integer: 0), toOffset: 99)
        #expect(repo.roadflarePaymentMethods == ["venmo", "cash", "zelle"])
    }

    @Test func toggleRoadflarePaymentMethodCaseInsensitive() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["custom-method"])
        repo.toggleRoadflarePaymentMethod("Custom-Method")
        #expect(!repo.roadflarePaymentMethods.contains("custom-method"))
    }

    @Test func toggleRoadflarePaymentMethodAddsWhenAbsent() {
        let repo = makeRepo()
        repo.toggleRoadflarePaymentMethod("zelle")
        #expect(repo.roadflarePaymentMethods.contains("zelle"))
    }

    @Test func toggleRoadflarePaymentMethodCanonicalizesKnownName() {
        let repo = makeRepo()
        repo.toggleRoadflarePaymentMethod("Zelle")
        #expect(repo.roadflarePaymentMethods == ["zelle"])
    }

    @Test func toggleRoadflarePaymentMethodIgnoresEmptyInput() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle"])
        repo.toggleRoadflarePaymentMethod("   ")
        #expect(repo.roadflarePaymentMethods == ["zelle"])
    }

    @Test func toggleRoadflarePaymentMethodForcesCashOnLastRemoval() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle"])
        repo.toggleRoadflarePaymentMethod("Zelle")
        #expect(repo.roadflarePaymentMethods == ["cash"])
        #expect(repo.isCashForced)
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

    @Test func paymentMethodsFiltersToKnownOnly() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle", "venmo-business", "cash"])
        #expect(repo.paymentMethods == [.zelle, .cash])
    }

    @Test func customPaymentMethodsFiltersToUnknownOnly() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle", "venmo-business", "cash"])
        #expect(repo.customPaymentMethods == ["venmo-business"])
    }

    @Test func roadflarePrimaryPaymentMethodReturnsFirstOrNil() {
        let repo = makeRepo()
        #expect(repo.roadflarePrimaryPaymentMethod == nil)
        repo.setRoadflarePaymentMethods(["venmo", "zelle"])
        #expect(repo.roadflarePrimaryPaymentMethod == "venmo")
    }

    @Test func roadflareMethodChoicesIncludesKnownAndCustom() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["zelle", "venmo-business"])
        let choices = repo.roadflareMethodChoices
        #expect(choices == ["zelle", "paypal", "cash_app", "venmo", "strike", "bitcoin", "cash", "venmo-business"])
    }

    @Test func isEnabledReflectsCurrentMethods() {
        let repo = makeRepo()
        #expect(!repo.isEnabled(.zelle))
        repo.togglePaymentMethod(.zelle)
        #expect(repo.isEnabled(.zelle))
    }

    @Test func isRoadflareMethodEnabledCaseInsensitive() {
        let repo = makeRepo()
        repo.setRoadflarePaymentMethods(["venmo-business"])
        #expect(repo.isRoadflareMethodEnabled("Venmo-Business"))
        #expect(repo.isRoadflareMethodEnabled("venmo-business"))
        #expect(!repo.isRoadflareMethodEnabled("zelle"))
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

    @Test func performWithoutChangeTrackingCallbacksResumeAfter() {
        let repo = makeRepo()
        let profileChanged = CallbackCounter()
        repo.onProfileChanged = { profileChanged.increment() }
        repo.performWithoutChangeTracking {
            _ = repo.setProfileName("Suppressed")
        }
        #expect(profileChanged.count == 0)
        // After block, callbacks should fire normally
        _ = repo.setProfileName("NotSuppressed")
        #expect(profileChanged.count == 1)
    }

    @Test func performWithoutChangeTrackingNestedCallbacksResumeAfter() {
        let repo = makeRepo()
        let profileChanged = CallbackCounter()
        repo.onProfileChanged = { profileChanged.increment() }
        repo.performWithoutChangeTracking {
            repo.performWithoutChangeTracking {
                _ = repo.setProfileName("Inner")
            }
        }
        #expect(profileChanged.count == 0)
        // After both blocks complete, callbacks should resume
        _ = repo.setProfileName("ResumedAfterNesting")
        #expect(profileChanged.count == 1)
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

    // MARK: - Persistence round-trips

    @Test func setProfileNamePersists() {
        let persistence = InMemoryUserSettingsPersistence()
        let repo = UserSettingsRepository(persistence: persistence)
        _ = repo.setProfileName("Alice")
        #expect(persistence.load().profileName == "Alice")
    }

    @Test func togglePaymentMethodPersists() {
        let persistence = InMemoryUserSettingsPersistence()
        let repo = UserSettingsRepository(persistence: persistence)
        repo.togglePaymentMethod(.zelle)
        #expect(persistence.load().roadflarePaymentMethods.contains("zelle"))
    }
}
