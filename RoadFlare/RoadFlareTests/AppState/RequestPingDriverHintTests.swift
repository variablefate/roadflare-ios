import Testing
import Foundation
@testable import RoadFlareCore

/// `AppState.requestPingDriverHint()` is the entry point for the "Ping a
/// Driver" CTA in the ride flow (RideRequestView). It must (a) switch to the
/// Drivers tab and (b) raise a one-shot `pendingPingHint` signal that the
/// Drivers tab consumes to pulse the bell icons on driver cards. See
/// issue #92 — the pulse teaches first-time users that the bell is the
/// tappable target for sending a ping. Other code paths that switch to the
/// Drivers tab (Add a Driver, deep link, settings) must NOT raise the hint;
/// the pulse is specifically a "you got here from Ping a Driver" affordance.
@Suite("AppState.requestPingDriverHint")
struct RequestPingDriverHintTests {

    @MainActor
    @Test func setsPendingPingHint() {
        let appState = AppState()
        #expect(appState.pendingPingHint == nil)

        appState.requestPingDriverHint()

        #expect(appState.pendingPingHint != nil)
    }

    @MainActor
    @Test func switchesToDriversTab() {
        let appState = AppState()
        appState.selectedTab = 0

        appState.requestPingDriverHint()

        #expect(appState.selectedTab == 1)
    }

    @MainActor
    @Test func eachCallProducesDistinctHint() {
        // The hint is a UUID? not a Bool — successive calls must mint a new
        // value so DriversTab's `.onChange` observer re-fires when the user
        // taps "Ping a Driver" twice (e.g. went back to ride flow, hit it
        // again). With a Bool, a re-tap while the value is still `true`
        // would not register as a change and the second pulse would be
        // skipped.
        let appState = AppState()
        appState.requestPingDriverHint()
        let first = appState.pendingPingHint
        appState.requestPingDriverHint()
        let second = appState.pendingPingHint

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)
    }

    @MainActor
    @Test func directTabSwitchDoesNotRaiseHint() {
        // Sanity: setting `selectedTab` directly (e.g. the "Add a Driver"
        // empty-state CTA at RideRequestView.swift:60, the deep-link path,
        // SettingsTab quick links) must NOT raise the bell-pulse hint. The
        // pulse is specifically scoped to arrival via "Ping a Driver".
        let appState = AppState()

        appState.selectedTab = 1

        #expect(appState.pendingPingHint == nil)
    }
}
