import Testing
import Foundation
@testable import RoadFlareCore
@testable import RidestrSDK

/// `AppState.handleIncomingURL(_:)` is the entry point for custom URL scheme
/// dispatch (`.onOpenURL` in `RoadFlareApp`). Recognized URLs populate
/// `pendingDriverDeepLink` and switch to the drivers tab so `DriversTab` can
/// observe and present `AddDriverSheet` pre-filled.
@Suite("AppState.handleIncomingURL")
struct HandleIncomingURLTests {
    private func makeNpub(hex: String = String(repeating: "a", count: 64)) throws -> String {
        try NIP19.npubEncode(publicKeyHex: hex)
    }

    @MainActor
    @Test func roadflaredURLPopulatesPendingDriverDeepLink() throws {
        let appState = AppState()
        let npub = try makeNpub(hex: String(repeating: "1a", count: 32))
        let url = URL(string: "roadflared:\(npub)")!

        appState.handleIncomingURL(url)

        #expect(appState.pendingDriverDeepLink == ParsedDriverQRCode(pubkeyInput: npub, scannedName: nil))
    }

    @MainActor
    @Test func roadflaredURLWithNameParsesDisplayName() throws {
        let appState = AppState()
        let npub = try makeNpub(hex: String(repeating: "2b", count: 32))
        let url = URL(string: "roadflared:\(npub)?name=Road%20Runner")!

        appState.handleIncomingURL(url)

        #expect(appState.pendingDriverDeepLink == ParsedDriverQRCode(pubkeyInput: npub, scannedName: "Road Runner"))
    }

    @MainActor
    @Test func roadflaredURLSwitchesToDriversTab() throws {
        let appState = AppState()
        appState.selectedTab = 0  // Start on ride tab
        let npub = try makeNpub(hex: String(repeating: "3c", count: 32))
        let url = URL(string: "roadflared:\(npub)")!

        appState.handleIncomingURL(url)

        #expect(appState.selectedTab == 1)
    }

    @MainActor
    @Test func unknownSchemeIsDropped() throws {
        let appState = AppState()
        appState.selectedTab = 0
        let url = URL(string: "https://example.com/whatever")!

        appState.handleIncomingURL(url)

        #expect(appState.pendingDriverDeepLink == nil)
        #expect(appState.selectedTab == 0)  // Tab unchanged
    }

    @MainActor
    @Test func roadflaredWithGarbagePayloadIsDropped() {
        let appState = AppState()
        appState.selectedTab = 0
        let url = URL(string: "roadflared:not-a-real-key")!

        appState.handleIncomingURL(url)

        #expect(appState.pendingDriverDeepLink == nil)
        #expect(appState.selectedTab == 0)
    }

    @MainActor
    @Test func nostrSchemeAlsoSupported() throws {
        // The parser already accepts nostr: URIs (via QR codes pasted as text).
        // For consistency, .onOpenURL routes them too — useful if a future
        // share surface emits nostr: instead of roadflared:.
        let appState = AppState()
        let npub = try makeNpub(hex: String(repeating: "4d", count: 32))
        let url = URL(string: "nostr:\(npub)?name=Driver%20Dan")!

        appState.handleIncomingURL(url)

        #expect(appState.pendingDriverDeepLink == ParsedDriverQRCode(pubkeyInput: npub, scannedName: "Driver Dan"))
    }

    @MainActor
    @Test func navigationIntentSurvivesIdentityReplacementWhenNoKeypair() async throws {
        // Cold-start regression: when a `roadflared:` URL arrives before the
        // user has created an account (keypair is nil), the conditional in
        // `prepareForIdentityReplacement` must preserve ALL the navigation
        // intent state set by `handleIncomingURL` — both `pendingDriverDeepLink`
        // AND `selectedTab` (= 1, drivers tab). Without this guard, a
        // first-time user who tapped a share link before onboarding would
        // lose the intent the moment they tap "Generate Key" / "Create with
        // Passkey" — both of which call `prepareForIdentityReplacement`
        // internally before establishing the new identity. See ADR-0012.
        //
        // The keypair-SET branch (cross-user leak protection on logout)
        // cannot be unit-tested here: the RoadFlareTests target lacks
        // Keychain entitlement, so initialize/generateNewKey/createWithPasskey
        // all fail with errSecMissingEntitlement (-34018). That branch is
        // verified via the manual test checklist in PR #66.
        let appState = AppState()
        let npub = try makeNpub(hex: String(repeating: "5e", count: 32))
        appState.handleIncomingURL(URL(string: "roadflared:\(npub)")!)
        #expect(appState.pendingDriverDeepLink != nil)
        #expect(appState.selectedTab == 1)
        #expect(appState.keypair == nil)

        // `logout()` exercises `prepareForIdentityReplacement` with the same
        // keypair-conditional gate; with no prior keypair, ALL navigation
        // intents must survive (otherwise post-onboarding the user lands on
        // the wrong tab and never sees the AddDriverSheet for the deep-linked
        // driver).
        await appState.logout()

        #expect(appState.pendingDriverDeepLink != nil, "Deep link must survive identity replacement when no prior keypair existed")
        #expect(appState.selectedTab == 1, "Tab selection must survive identity replacement when no prior keypair existed")
    }
}
