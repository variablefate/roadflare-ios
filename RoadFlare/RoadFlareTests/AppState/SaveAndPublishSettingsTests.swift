import Testing
import Foundation
@testable import RoadFlareCore

// Direct unit tests for `AppState.saveAndPublishSettings` "always run both"
// invariant introduced in PR #99. The eager-error path tests in
// `OnboardingPublishWatchdogTests` use the coarser
// `onboardingPublishHookForTesting`, which short-circuits before
// `saveAndPublishSettings` runs. Without these tests a regression to
// `try await publishProfile(); try await publishProfileBackup()` (the
// original short-circuit version) would silently pass CI while leaving
// the Kind 30177 backup unattempted whenever the Kind 0 publish fails.

@Suite("AppState saveAndPublishSettings")
@MainActor
struct SaveAndPublishSettingsTests {

    private struct ProfileFailure: Error {}
    private struct BackupFailure: Error {}

    @Test func bothPublishesRunWhenProfileSucceeds() async throws {
        let appState = AppState()
        var profileCalls = 0
        var backupCalls = 0
        appState.publishProfileSDKHookForTesting = { profileCalls += 1 }
        appState.publishProfileBackupSDKHookForTesting = { backupCalls += 1 }

        try await appState.saveAndPublishSettings()

        #expect(profileCalls == 1)
        #expect(backupCalls == 1)
    }

    @Test func backupRunsEvenWhenProfileThrows() async {
        let appState = AppState()
        var profileCalls = 0
        var backupCalls = 0
        appState.publishProfileSDKHookForTesting = {
            profileCalls += 1
            throw ProfileFailure()
        }
        appState.publishProfileBackupSDKHookForTesting = { backupCalls += 1 }

        do {
            try await appState.saveAndPublishSettings()
            Issue.record("Expected saveAndPublishSettings to throw the profile error")
        } catch is ProfileFailure {
            // expected
        } catch {
            Issue.record("Expected ProfileFailure, got \(error)")
        }

        #expect(profileCalls == 1)
        // The key invariant: backup must run even though profile threw.
        // This guards against a regression to the original short-circuit
        // chain `try await publishProfile(); try await publishProfileBackup()`.
        #expect(backupCalls == 1)
    }

    @Test func profileRunsEvenWhenBackupWillThrow() async {
        let appState = AppState()
        var profileCalls = 0
        var backupCalls = 0
        appState.publishProfileSDKHookForTesting = { profileCalls += 1 }
        appState.publishProfileBackupSDKHookForTesting = {
            backupCalls += 1
            throw BackupFailure()
        }

        do {
            try await appState.saveAndPublishSettings()
            Issue.record("Expected saveAndPublishSettings to throw the backup error")
        } catch is BackupFailure {
            // expected
        } catch {
            Issue.record("Expected BackupFailure, got \(error)")
        }

        #expect(profileCalls == 1)
        #expect(backupCalls == 1)
    }

    @Test func firstErrorWins_whenBothFail() async {
        let appState = AppState()
        appState.publishProfileSDKHookForTesting = { throw ProfileFailure() }
        appState.publishProfileBackupSDKHookForTesting = { throw BackupFailure() }

        do {
            try await appState.saveAndPublishSettings()
            Issue.record("Expected saveAndPublishSettings to throw")
        } catch is ProfileFailure {
            // expected — profile failed first; saveAndPublishSettings rethrows
            // the first error per ADR-0017.
        } catch {
            Issue.record("Expected ProfileFailure (first error), got \(error)")
        }
    }
}
