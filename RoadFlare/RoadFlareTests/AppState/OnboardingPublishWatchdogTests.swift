import Testing
import Foundation
@testable import RoadFlareCore
@testable import RidestrSDK

// Behavior tests for the onboarding-publish failure-surface watchdog.
//
// The watchdog observes whether a publish kicked off by `completeProfileSetup`
// or `completePaymentSetup` cleared the sync-store dirty flag within the
// timeout window. If it didn't, AND the relay is reachable, the banner
// status flips to `.failed` so RootView can surface a retry CTA.
//
// Tests use `setOnboardingPublishHooksForTesting(...)` to:
//   - replace the publish call (so dirty stays set without hitting a relay)
//   - drive connectivity (online vs offline)
//   - fake the dirty check (since wiring a full SyncCoordinator is out of
//     scope for unit tests)
//   - shorten the watchdog timing so tests run in milliseconds rather than
//     a minute per case
//
// The full integration path (real publish → real syncStore → watchdog
// observes real dirty flag) is exercised manually on-device.

@Suite("AppState onboarding-publish watchdog")
@MainActor
struct OnboardingPublishWatchdogTests {

    /// Helper: spin until `condition()` is true or `timeout` elapses.
    /// Returns true if the condition was satisfied. Avoids an unconditional
    /// fixed sleep that either flakes (too short) or wastes time (too long).
    private func waitFor(
        timeout: TimeInterval,
        pollIntervalMs: UInt64 = 5,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
        }
        return condition()
    }

    @Test func staysIdleWhenPublishClearsDirtyBeforeTimeout() async {
        let appState = AppState()
        var isDirty = true
        appState.setOnboardingPublishHooksForTesting(
            publish: { _ in isDirty = false },         // simulates markPublished
            connectivity: { true },
            isDirty: { _ in isDirty },
            timeout: 0.05,
            rearmInterval: 0.05
        )

        await appState.completeProfileSetup(name: "Alice")

        // Sleep well past `timeout + rearm` so the watchdog has run its full
        // cycle. Status must remain `.idle` because by the time the watchdog
        // checks `isDirty`, the publish hook has already flipped it false.
        try? await Task.sleep(nanoseconds: 250_000_000)  // 250ms = 5x timeout
        #expect(appState.onboardingPublishStatus == .idle)
    }

    @Test func surfacesFailureWhenStillDirtyAtTimeoutAndOnline() async {
        let appState = AppState()
        appState.setOnboardingPublishHooksForTesting(
            publish: { _ in /* never clears dirty */ },
            connectivity: { true },
            isDirty: { _ in true },
            timeout: 0.05,
            rearmInterval: 0.05
        )

        await appState.completeProfileSetup(name: "Alice")

        let surfaced = await waitFor(timeout: 1.0) {
            appState.onboardingPublishStatus == .failed(domain: .profile)
        }
        #expect(surfaced)
    }

    @Test func staysIdleWhenStillDirtyAtTimeoutButOffline() async {
        let appState = AppState()
        appState.setOnboardingPublishHooksForTesting(
            publish: { _ in /* never clears dirty */ },
            connectivity: { false },                    // user offline
            isDirty: { _ in true },
            timeout: 0.05,
            rearmInterval: 0.05
        )

        await appState.completeProfileSetup(name: "Alice")

        // Watchdog should park silently on rearm-poll. Wait long enough that
        // we'd have fired several rearms — and confirm we stay idle.
        try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms ~= 6 rearms
        #expect(appState.onboardingPublishStatus == .idle)
    }

    @Test func parkedWatchdogSurfacesFailureOnceConnectivityReturns() async {
        let appState = AppState()
        var online = false
        appState.setOnboardingPublishHooksForTesting(
            publish: { _ in /* never clears dirty */ },
            connectivity: { online },
            isDirty: { _ in true },
            timeout: 0.05,
            rearmInterval: 0.05
        )

        await appState.completeProfileSetup(name: "Alice")

        // Confirm parked.
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(appState.onboardingPublishStatus == .idle)

        // Now bring the user online; next rearm tick must surface failure.
        online = true
        let surfaced = await waitFor(timeout: 1.0) {
            appState.onboardingPublishStatus == .failed(domain: .profile)
        }
        #expect(surfaced)
    }

    @Test func paymentSetupSurfacesSettingsBackupDomain() async {
        let appState = AppState()
        appState.setOnboardingPublishHooksForTesting(
            publish: { _ in /* never clears */ },
            connectivity: { true },
            isDirty: { _ in true },
            timeout: 0.05,
            rearmInterval: 0.05
        )

        await appState.completePaymentSetup()

        let surfaced = await waitFor(timeout: 1.0) {
            appState.onboardingPublishStatus == .failed(domain: .settingsBackup)
        }
        #expect(surfaced)
    }

    /// Verifies retry kicks off a fresh publish + watchdog cycle after a
    /// failure has surfaced. Note: this asserts the new cycle runs and
    /// reaches `.idle` after success — it does NOT prove the prior
    /// publish Task was actually cancelled before its relay write
    /// (cancellation in our impl is cooperative; the SDK publish path
    /// doesn't observe `Task.isCancelled` once started). The early-bail
    /// in `runOnboardingPublishImpl` is what prevents a duplicate publish
    /// when the cancel lands before the impl Task is scheduled.
    @Test func retryStartsFreshPublishAfterFailure() async {
        let appState = AppState()
        var publishCalls = 0
        var clearOnNextPublish = false
        appState.setOnboardingPublishHooksForTesting(
            publish: { _ in publishCalls += 1 },
            connectivity: { true },
            isDirty: { _ in !clearOnNextPublish },
            timeout: 0.05,
            rearmInterval: 0.05
        )

        // First attempt fails.
        await appState.completeProfileSetup(name: "Alice")
        let firstFailed = await waitFor(timeout: 1.0) {
            appState.onboardingPublishStatus == .failed(domain: .profile)
        }
        #expect(firstFailed)
        let callsAfterFirst = publishCalls

        // User taps Retry; flip dirty so the next watchdog cycle sees clean.
        clearOnNextPublish = true
        appState.retryOnboardingPublish()

        // Status returns to .idle (set synchronously by startOnboardingPublish)
        // and stays idle through the next watchdog cycle.
        #expect(appState.onboardingPublishStatus == .idle)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(appState.onboardingPublishStatus == .idle)
        #expect(publishCalls > callsAfterFirst)
    }

    @Test func retryIsNoOpWhenStatusIsIdle() {
        let appState = AppState()
        appState.setOnboardingPublishHooksForTesting(
            publish: { _ in },
            connectivity: { true },
            isDirty: { _ in false },
            timeout: 0.05,
            rearmInterval: 0.05
        )

        // Retry without a prior failure → no-op.
        appState.retryOnboardingPublish()
        #expect(appState.onboardingPublishStatus == .idle)
    }

    @Test func reconnectAndRestoreSessionClearsBannerWhenDomainsClean() async {
        let appState = AppState()
        var isDirty = true
        appState.setOnboardingPublishHooksForTesting(
            publish: { _ in /* doesn't clear dirty itself */ },
            connectivity: { true },
            isDirty: { _ in isDirty },
            timeout: 0.05,
            rearmInterval: 0.05
        )

        // Drive into .failed state.
        await appState.completeProfileSetup(name: "Alice")
        let surfaced = await waitFor(timeout: 1.0) {
            appState.onboardingPublishStatus == .failed(domain: .profile)
        }
        #expect(surfaced)

        // Background flush succeeds (sync coordinator clears the dirty flag).
        // `reconnectAndRestoreSession` short-circuits because relayManager is
        // nil in this test context — exercise the helper directly to confirm
        // the dismissal logic runs once domains are clean.
        isDirty = false
        appState.clearOnboardingPublishStatusIfDomainsCleanForTesting()
        #expect(appState.onboardingPublishStatus == .idle)
    }

    @Test func paymentSetupCancelsStaleProfileWatchdog() async {
        let appState = AppState()
        appState.setOnboardingPublishHooksForTesting(
            publish: { _ in /* never clears */ },
            connectivity: { true },
            isDirty: { _ in true },
            timeout: 0.05,
            rearmInterval: 0.05
        )

        // Kick off profile publish. Watchdog will fire eventually, but we
        // chain payment setup before it does.
        await appState.completeProfileSetup(name: "Alice")
        await appState.completePaymentSetup()

        // Only the second (settingsBackup) watchdog should surface — the
        // first profile watchdog was cancelled and replaced.
        let surfaced = await waitFor(timeout: 1.0) {
            if case .failed(let d) = appState.onboardingPublishStatus { return d == .settingsBackup }
            return false
        }
        #expect(surfaced)
        if case .failed(let d) = appState.onboardingPublishStatus {
            #expect(d == .settingsBackup)
        } else {
            Issue.record("Expected .failed(settingsBackup), got \(appState.onboardingPublishStatus)")
        }
    }
}
