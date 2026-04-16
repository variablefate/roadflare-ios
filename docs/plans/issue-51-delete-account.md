# Delete Account Feature (Issue #51) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a two-page in-app Delete Account flow: Page 1 scans relays for the user's events, Page 2 shows results and offers two deletion tiers — RoadFlare-only events or all Ridestr events including Kind 0 metadata — each with appropriate confirmation, followed by local data cleanup and logout.

**Architecture:** A new `AccountDeletionService` in RidestrSDK handles relay scanning and Kind 5 deletion publishing via `RelayManagerProtocol`. `AppState` gains orchestration methods for scanning, deleting, and completing logout. The UI is a sheet with a `NavigationStack` — Page 1 scans relays, Page 2 shows results and two delete options — triggered from a "Delete Account" button in Settings.

**Tech Stack:** SwiftUI, RidestrSDK (`NostrFilter`, `RideshareEventBuilder`, `RelayManagerProtocol`, `DefaultRelays`, `EventKind`), `AppState` (`@Observable`, `@MainActor`), `FakeRelayManager` + Swift Testing for unit tests

---

## Background & Codebase Context

### What constitutes "an account"

A RoadFlare account is:
1. **A Nostr keypair** — private key in Keychain at service `"com.roadflare.keys"`, key `"nostr_identity_private_key"`. Cleared by `KeyManager.deleteKeys()`.
2. **Local UserDefaults data** — profile name, payment methods, saved locations, ride history, followed drivers, sync metadata. Cleared by repository `clearAll()` calls in `prepareForIdentityReplacement()`.
3. **Nostr events on relays** — rider-authored events across 13 event kinds. NOT cleared by current `logout()`.

### Rider-authored event kinds (all Ridestr/RoadFlare)

**Non-ephemeral (parameterized replaceable, always on relays):**

| Kind | Name | d-tag |
|------|------|-------|
| 30011 | followedDriversList | `"roadflare-drivers"` |
| 30174 | rideHistoryBackup | `"rideshare-history"` |
| 30177 | unifiedProfile / profileBackup | `"rideshare-profile"` |
| 30181 | riderRideState | dynamic (confirmationEventId) |

**Ephemeral (expire naturally, but may still be on relays):**

| Kind | Name | Expiry |
|------|------|--------|
| 3173 | rideOffer | 15 min |
| 3175 | rideConfirmation | 8 hrs |
| 3178 | chatMessage | 8 hrs |
| 3179 | cancellation | 24 hrs |
| 3186 | keyShare | 12 hrs |
| 3187 | followNotification | 5 min |
| 3188 | keyAcknowledgement | 5 min |
| 3189 | driverPingRequest | 30 min |

**Shared Nostr identity (not RoadFlare-specific):**

| Kind | Name | Note |
|------|------|------|
| 0 | metadata | Profile name — used by all Nostr apps sharing this identity |

Driver-only kinds (30012, 30013, 30014, 30173, 30180, 3174) are not rider-authored and won't appear in scans.

### Two deletion tiers

1. **Delete RoadFlare Events** — the 12 Ridestr kinds above. Simple "are you sure?" confirmation.
2. **Delete All Ridestr Events** — the same 12 + Kind 0 metadata. Heavier confirmation with checkboxes warning about other Nostr apps.

Both tiers end with local data cleanup (same as `logout()`).

### Current logout flow (reused for local cleanup)

`AppState.logout()` at `RoadFlare/RoadFlareCore/ViewModels/AppState.swift:341`:
```swift
public func logout() async {
    await prepareForIdentityReplacement(clearPersistedSyncState: true)
    try? await keyManager?.deleteKeys()
    keypair = nil
    authState = .loggedOut
}
```

### Mid-ride guard

`rideCoordinator?.session.stage.isActiveRide` (defined at `RideModels.swift:33`). Active stages: `.rideConfirmed`, `.enRoute`, `.driverArrived`, `.inProgress`.

### Existing SDK infrastructure

- `RelayManagerProtocol.fetchEvents(filter:timeout:)` — one-shot EOSE query.
- `RelayManagerProtocol.publish(_:)` — publishes to all connected relays.
- `DefaultRelays.all` — `[wss://relay.damus.io, wss://nos.lol, wss://relay.primal.net]`.
- `RideshareEventBuilder.deletion(eventIds:reason:kinds:keypair:)` — Kind 5 builder, already implemented at `RideshareEventBuilder.swift:331`.
- `NostrFilter` — builder with `.authors()`, `.rawKinds()`, `.kinds()` methods.

### UI patterns to follow

- **ConnectivitySheet** (`ConnectivityIndicator.swift:83`): `DisclosureGroup` titled "About Nostr Protocol" with relay list and card-style background.
- **BackupKeySheet** (`ProfileSetupView.swift:153`): `DisclosureGroup` titled "About Your Keys" explaining Nostr identity.
- Both use `.tint(Color.rfOnSurfaceVariant)` + `.padding(16).background(Color.rfSurfaceContainer).clipShape(RoundedRectangle(cornerRadius: 16))`.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `RidestrSDK/Sources/RidestrSDK/RoadFlare/AccountDeletionService.swift` | Scan relays + publish Kind 5 deletion |
| Create | `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/AccountDeletionServiceTests.swift` | Unit tests for the service |
| Create | `RoadFlare/RoadFlare/Views/Settings/DeleteAccountSheet.swift` | Two-page UI (scan + delete options) |
| Modify | `RoadFlare/RoadFlareCore/ViewModels/AppState.swift` | Orchestration methods + `AccountDeletionError` |
| Modify | `RoadFlare/RoadFlare/Views/Settings/SettingsTab.swift` | Add Delete Account button + sheet presentation |

---

## Task 1: AccountDeletionService — SDK scan and deletion service

**Files:**
- Create: `RidestrSDK/Sources/RidestrSDK/RoadFlare/AccountDeletionService.swift`
- Create: `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/AccountDeletionServiceTests.swift`

- [ ] **Step 1.1: Write the failing test file**

```swift
// RidestrSDK/Tests/RidestrSDKTests/RoadFlare/AccountDeletionServiceTests.swift
import Foundation
import Testing
@testable import RidestrSDK

private func stubEvent(id: String, kind: UInt16, pubkey: String) -> NostrEvent {
    let json = """
    {"id":"\(id)","pubkey":"\(pubkey)","created_at":1700000000,"kind":\(kind),\
    "tags":[],"content":"","sig":"fakesig"}
    """
    return try! JSONDecoder().decode(NostrEvent.self, from: json.data(using: .utf8)!)
}

@Suite("AccountDeletionService Tests")
struct AccountDeletionServiceTests {
    private func makeKit() throws -> (sut: AccountDeletionService, relay: FakeRelayManager, pubkey: String) {
        let keypair = try NostrKeypair.generate()
        let relay = FakeRelayManager()
        let sut = AccountDeletionService(relayManager: relay, keypair: keypair)
        return (sut, relay, keypair.publicKeyHex)
    }

    // MARK: - Scan

    @Test func scan_noEvents_returnsEmptyResult() async throws {
        let (sut, relay, _) = try makeKit()
        relay.fetchResults = []

        let result = await sut.scanRelays()

        #expect(result.roadflareEvents.isEmpty)
        #expect(result.metadataEvents.isEmpty)
        #expect(result.targetRelayURLs == DefaultRelays.all)
        // Two queries: roadflare kinds + kind 0
        #expect(relay.fetchCalls.count == 2)
    }

    @Test func scan_withEvents_categorisesCorrectly() async throws {
        let (sut, relay, pubkey) = try makeKit()
        let rfEvent = stubEvent(id: "rf1", kind: EventKind.followedDriversList.rawValue, pubkey: pubkey)
        let metaEvent = stubEvent(id: "meta1", kind: EventKind.metadata.rawValue, pubkey: pubkey)
        relay.fetchResults = [rfEvent, metaEvent]

        let result = await sut.scanRelays()

        // Both queries return both events — but categorisation is by filter, not by kind.
        // The service uses two separate fetches, so fetchResults returns the same array twice.
        // In production, each filter returns only matching events.
        #expect(!result.roadflareEvents.isEmpty)
        #expect(!result.metadataEvents.isEmpty)
    }

    // MARK: - Delete RoadFlare events

    @Test func deleteRoadflare_noEvents_publishesNothing() async throws {
        let (sut, relay, _) = try makeKit()
        let scan = RelayScanResult(
            roadflareEvents: [],
            metadataEvents: [],
            targetRelayURLs: DefaultRelays.all
        )

        let result = await sut.deleteRoadflareEvents(from: scan)

        #expect(result.publishedSuccessfully == true)
        #expect(result.deletedEventIds.isEmpty)
        #expect(relay.publishedEvents.isEmpty)
    }

    @Test func deleteRoadflare_withEvents_publishesKind5ForRoadflareOnly() async throws {
        let (sut, relay, pubkey) = try makeKit()
        let rfEvent = stubEvent(id: "rf1", kind: EventKind.followedDriversList.rawValue, pubkey: pubkey)
        let metaEvent = stubEvent(id: "meta1", kind: EventKind.metadata.rawValue, pubkey: pubkey)
        let scan = RelayScanResult(
            roadflareEvents: [rfEvent],
            metadataEvents: [metaEvent],
            targetRelayURLs: DefaultRelays.all
        )

        let result = await sut.deleteRoadflareEvents(from: scan)

        #expect(result.publishedSuccessfully == true)
        #expect(result.deletedEventIds == ["rf1"])
        #expect(relay.publishedEvents.count == 1)
        let kind5 = relay.publishedEvents[0]
        #expect(kind5.kind == 5)
        let eTagIds = kind5.tagValues("e")
        #expect(eTagIds.contains("rf1"))
        #expect(!eTagIds.contains("meta1"))  // Kind 0 NOT included
    }

    // MARK: - Delete all Ridestr events

    @Test func deleteAll_withEvents_publishesKind5IncludingMetadata() async throws {
        let (sut, relay, pubkey) = try makeKit()
        let rfEvent = stubEvent(id: "rf1", kind: EventKind.followedDriversList.rawValue, pubkey: pubkey)
        let metaEvent = stubEvent(id: "meta1", kind: EventKind.metadata.rawValue, pubkey: pubkey)
        let scan = RelayScanResult(
            roadflareEvents: [rfEvent],
            metadataEvents: [metaEvent],
            targetRelayURLs: DefaultRelays.all
        )

        let result = await sut.deleteAllRidestrEvents(from: scan)

        #expect(result.publishedSuccessfully == true)
        #expect(result.deletedEventIds.contains("rf1"))
        #expect(result.deletedEventIds.contains("meta1"))
        let kind5 = relay.publishedEvents[0]
        let eTagIds = kind5.tagValues("e")
        #expect(eTagIds.contains("rf1"))
        #expect(eTagIds.contains("meta1"))
    }

    // MARK: - Publish failure

    @Test func delete_publishFails_returnsFailureResult() async throws {
        let (sut, relay, pubkey) = try makeKit()
        let rfEvent = stubEvent(id: "rf1", kind: 30011, pubkey: pubkey)
        let scan = RelayScanResult(
            roadflareEvents: [rfEvent],
            metadataEvents: [],
            targetRelayURLs: DefaultRelays.all
        )
        relay.shouldFailPublish = true

        let result = await sut.deleteRoadflareEvents(from: scan)

        #expect(result.publishedSuccessfully == false)
        #expect(result.publishError != nil)
        #expect(result.deletedEventIds == ["rf1"])
    }

    // MARK: - Kind lists

    @Test func roadflareKinds_containsAll12RiderAuthoredKinds() {
        let rawValues = AccountDeletionService.roadflareKinds.map(\.rawValue)
        // Replaceable
        #expect(rawValues.contains(30011))  // followedDriversList
        #expect(rawValues.contains(30174))  // rideHistoryBackup
        #expect(rawValues.contains(30177))  // unifiedProfile
        #expect(rawValues.contains(30181))  // riderRideState
        // Regular/ephemeral
        #expect(rawValues.contains(3173))   // rideOffer
        #expect(rawValues.contains(3175))   // rideConfirmation
        #expect(rawValues.contains(3178))   // chatMessage
        #expect(rawValues.contains(3179))   // cancellation
        #expect(rawValues.contains(3186))   // keyShare
        #expect(rawValues.contains(3187))   // followNotification
        #expect(rawValues.contains(3188))   // keyAcknowledgement
        #expect(rawValues.contains(3189))   // driverPingRequest
    }

    @Test func roadflareKinds_excludesDriverAndNonRidestrKinds() {
        let rawValues = AccountDeletionService.roadflareKinds.map(\.rawValue)
        #expect(!rawValues.contains(0))      // metadata — separate tier
        #expect(!rawValues.contains(3174))   // rideAcceptance — driver-authored
        #expect(!rawValues.contains(30012))  // driverRoadflareState
        #expect(!rawValues.contains(30173))  // driverAvailability
        #expect(!rawValues.contains(30180))  // driverRideState
    }
}
```

- [ ] **Step 1.2: Run test to confirm compile failure**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
xcodebuild test \
  -workspace RoadFlare.xcworkspace \
  -scheme RidestrSDK \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build Succeeded|Build FAILED"
```

Expected: `error: cannot find type 'AccountDeletionService'`

- [ ] **Step 1.3: Create AccountDeletionService.swift**

```swift
// RidestrSDK/Sources/RidestrSDK/RoadFlare/AccountDeletionService.swift
import Foundation

// MARK: - Result Models

/// Result of scanning relays for user-authored events.
public struct RelayScanResult: Sendable {
    /// RoadFlare/Ridestr events found (12 rider-authored kinds, excluding Kind 0).
    public let roadflareEvents: [NostrEvent]
    /// Kind 0 metadata events found (shared Nostr identity, used by all apps).
    public let metadataEvents: [NostrEvent]
    /// Relay URLs that were scanned.
    public let targetRelayURLs: [URL]

    public var roadflareCount: Int { roadflareEvents.count }
    public var metadataCount: Int { metadataEvents.count }
    public var totalCount: Int { roadflareCount + metadataCount }
}

/// Result of a relay-side deletion pass.
public struct RelayDeletionResult: Sendable {
    /// Event IDs included in the Kind 5 deletion request.
    public let deletedEventIds: [String]
    /// Relay URLs the deletion was published to.
    public let targetRelayURLs: [URL]
    /// True if the Kind 5 event was published, or if there was nothing to delete.
    public let publishedSuccessfully: Bool
    /// Human-readable error from the publish step, if any.
    public let publishError: String?
}

// MARK: - Service

/// Scans relays for rider-authored events and publishes NIP-09 Kind 5 deletion requests.
///
/// Create with the app's live `relayManager` (already connected). The service is stateless —
/// create a fresh instance for each deletion flow.
///
/// ## Usage
/// ```swift
/// let service = AccountDeletionService(relayManager: rm, keypair: kp)
/// let scan = await service.scanRelays()
/// // Show results to user, then:
/// let result = await service.deleteRoadflareEvents(from: scan)
/// ```
public final class AccountDeletionService: Sendable {
    private let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair

    /// The 12 rider-authored Ridestr event kinds (excludes Kind 0 metadata).
    public static let roadflareKinds: [EventKind] = [
        // Parameterized replaceable (always on relays)
        .followedDriversList,    // 30011
        .rideHistoryBackup,      // 30174
        .unifiedProfile,         // 30177
        .riderRideState,         // 30181
        // Regular (ephemeral, may still be on relays)
        .rideOffer,              // 3173
        .rideConfirmation,       // 3175
        .chatMessage,            // 3178
        .cancellation,           // 3179
        .keyShare,               // 3186
        .followNotification,     // 3187
        .keyAcknowledgement,     // 3188
        .driverPingRequest,      // 3189
    ]

    public init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair) {
        self.relayManager = relayManager
        self.keypair = keypair
    }

    // MARK: - Scan

    /// Query connected relays for all rider-authored events.
    /// Two queries: one for all 12 RoadFlare kinds, one for Kind 0 metadata.
    public func scanRelays() async -> RelayScanResult {
        let roadflareFilter = NostrFilter()
            .authors([keypair.publicKeyHex])
            .rawKinds(Self.roadflareKinds.map(\.rawValue))

        let metadataFilter = NostrFilter.metadata(pubkeys: [keypair.publicKeyHex])

        async let rfFetch = fetchSafe(filter: roadflareFilter)
        async let metaFetch = fetchSafe(filter: metadataFilter)

        let (rfEvents, metaEvents) = await (rfFetch, metaFetch)

        return RelayScanResult(
            roadflareEvents: rfEvents,
            metadataEvents: metaEvents,
            targetRelayURLs: DefaultRelays.all
        )
    }

    // MARK: - Delete

    /// Delete only RoadFlare events (12 Ridestr kinds). Does NOT delete Kind 0 metadata.
    public func deleteRoadflareEvents(from scan: RelayScanResult) async -> RelayDeletionResult {
        let eventIds = scan.roadflareEvents.map(\.id)
        return await publishDeletion(
            eventIds: eventIds,
            kinds: Self.roadflareKinds
        )
    }

    /// Delete all Ridestr events (12 RoadFlare kinds + Kind 0 metadata).
    public func deleteAllRidestrEvents(from scan: RelayScanResult) async -> RelayDeletionResult {
        let eventIds = scan.roadflareEvents.map(\.id) + scan.metadataEvents.map(\.id)
        return await publishDeletion(
            eventIds: eventIds,
            kinds: Self.roadflareKinds + [.metadata]
        )
    }

    // MARK: - Private

    private func fetchSafe(filter: NostrFilter) async -> [NostrEvent] {
        (try? await relayManager.fetchEvents(
            filter: filter,
            timeout: RelayConstants.eoseTimeoutSeconds
        )) ?? []
    }

    private func publishDeletion(eventIds: [String], kinds: [EventKind]) async -> RelayDeletionResult {
        guard !eventIds.isEmpty else {
            return RelayDeletionResult(
                deletedEventIds: [],
                targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: true,
                publishError: nil
            )
        }

        do {
            let deletionEvent = try await RideshareEventBuilder.deletion(
                eventIds: eventIds,
                reason: "Account deleted by user",
                kinds: kinds,
                keypair: keypair
            )
            _ = try await relayManager.publish(deletionEvent)
            return RelayDeletionResult(
                deletedEventIds: eventIds,
                targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: true,
                publishError: nil
            )
        } catch {
            return RelayDeletionResult(
                deletedEventIds: eventIds,
                targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: false,
                publishError: error.localizedDescription
            )
        }
    }
}
```

- [ ] **Step 1.4: Run the tests**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
xcodebuild test \
  -workspace RoadFlare.xcworkspace \
  -scheme RidestrSDK \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:RidestrSDKTests/AccountDeletionServiceTests \
  2>&1 | grep -E "Test.*passed|Test.*failed|Build Succeeded|Build FAILED|error:"
```

Expected: all 9 tests pass.

- [ ] **Step 1.5: Commit**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
git add \
  RidestrSDK/Sources/RidestrSDK/RoadFlare/AccountDeletionService.swift \
  RidestrSDK/Tests/RidestrSDKTests/RoadFlare/AccountDeletionServiceTests.swift
git commit -m "feat(sdk): add AccountDeletionService with relay scan and two-tier deletion"
```

---

## Task 2: AppState — orchestration methods

**Files:**
- Modify: `RoadFlare/RoadFlareCore/ViewModels/AppState.swift`

- [ ] **Step 2.1: Add top-level error enum and AppState methods**

Add `AccountDeletionError` as a **top-level enum** in `AppState.swift`, above the `AppState` class (next to the existing top-level `AuthState` enum at line 6). This follows the existing `AuthState` pattern and ensures the type is accessible without a prefix in catch clauses:

```swift
/// Reasons account deletion can fail before contacting relays.
public enum AccountDeletionError: Error, Equatable {
    case servicesNotReady
    case activeRideInProgress
}
```

Then add the following methods inside `AppState`, after the closing `}` of `logout()` at line 346:

```swift
// MARK: - Account Deletion

/// Scan relays for all rider-authored events. Returns categorised results.
/// Call while still logged in (relay + keypair are live).
public func scanRelaysForDeletion() async throws -> RelayScanResult {
    guard let keypair, let relayManager else {
        throw AccountDeletionError.servicesNotReady
    }
    guard !(rideCoordinator?.session.stage.isActiveRide ?? false) else {
        throw AccountDeletionError.activeRideInProgress
    }
    let service = AccountDeletionService(relayManager: relayManager, keypair: keypair)
    return await service.scanRelays()
}

/// Delete only RoadFlare events from relays, then clear local data and log out.
public func deleteRoadflareEvents(from scan: RelayScanResult) async -> RelayDeletionResult {
    guard let keypair, let relayManager else {
        return RelayDeletionResult(
            deletedEventIds: [], targetRelayURLs: DefaultRelays.all,
            publishedSuccessfully: false, publishError: "Services not ready"
        )
    }
    let service = AccountDeletionService(relayManager: relayManager, keypair: keypair)
    let result = await service.deleteRoadflareEvents(from: scan)
    await logout()
    return result
}

/// Delete all Ridestr events (including Kind 0 metadata) from relays,
/// then clear local data and log out.
public func deleteAllRidestrEvents(from scan: RelayScanResult) async -> RelayDeletionResult {
    guard let keypair, let relayManager else {
        return RelayDeletionResult(
            deletedEventIds: [], targetRelayURLs: DefaultRelays.all,
            publishedSuccessfully: false, publishError: "Services not ready"
        )
    }
    let service = AccountDeletionService(relayManager: relayManager, keypair: keypair)
    let result = await service.deleteAllRidestrEvents(from: scan)
    await logout()
    return result
}
```

- [ ] **Step 2.2: Build the full project**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
xcodebuild build \
  -workspace RoadFlare.xcworkspace \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build Succeeded|Build FAILED"
```

Expected: `Build Succeeded`

- [ ] **Step 2.3: Commit**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
git add RoadFlare/RoadFlareCore/ViewModels/AppState.swift
git commit -m "feat: add relay scan and two-tier account deletion to AppState"
```

---

## Task 3: DeleteAccountSheet — two-page UI

**Files:**
- Create: `RoadFlare/RoadFlare/Views/Settings/DeleteAccountSheet.swift`

- [ ] **Step 3.1: Create DeleteAccountSheet.swift**

```swift
// RoadFlare/RoadFlare/Views/Settings/DeleteAccountSheet.swift
import SwiftUI
import RidestrSDK
import RoadFlareCore

// MARK: - Container

struct DeleteAccountSheet: View {
    var body: some View {
        NavigationStack {
            DeleteAccountScanView()
        }
    }
}

// MARK: - Page 1: Relay Scan

struct DeleteAccountScanView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum ScanPhase {
        case idle
        case scanning
        case complete(RelayScanResult)
        case failed(String)
    }

    @State private var phase: ScanPhase = .idle

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 52))
                            .foregroundColor(Color.rfError)
                        Text("Delete Account")
                            .font(RFFont.headline(22))
                            .foregroundColor(Color.rfOnSurface)
                        Text("Step 1 of 2 — Relay Scan")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }
                    .padding(.top, 8)

                    // Relay list
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Relays")
                        VStack(spacing: 8) {
                            ForEach(DefaultRelays.all, id: \.absoluteString) { url in
                                HStack {
                                    Circle()
                                        .fill(relayDotColor)
                                        .frame(width: 6, height: 6)
                                    Text(url.absoluteString)
                                        .font(RFFont.mono(12))
                                        .foregroundColor(Color.rfOnSurfaceVariant)
                                    Spacer()
                                    if case .scanning = phase {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                            .tint(Color.rfPrimary)
                                    }
                                }
                                .rfCard(.low)
                            }
                        }
                    }

                    // Error message
                    if case .failed(let msg) = phase {
                        Text(msg)
                            .font(RFFont.body(13))
                            .foregroundColor(Color.rfError)
                            .padding(14)
                            .background(Color.rfSurfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Primary action
                    switch phase {
                    case .idle:
                        Button {
                            Task { await startScan() }
                        } label: {
                            Text("Scan Relays")
                                .font(RFFont.body(16).bold())
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color.rfError)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                    case .scanning:
                        HStack(spacing: 12) {
                            ProgressView().tint(Color.rfOnSurface)
                            Text("Scanning relays…")
                                .font(RFFont.body(15))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.rfSurfaceContainer)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    case .complete(let scan):
                        NavigationLink {
                            DeleteAccountResultsView(scan: scan)
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color.rfOnline)
                                Text("Continue — \(scan.totalCount) event\(scan.totalCount == 1 ? "" : "s") found")
                                    .font(RFFont.body(16).bold())
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.rfError)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }

                    case .failed:
                        Button {
                            phase = .idle
                        } label: {
                            Text("Try Again")
                                .font(RFFont.body(15))
                                .foregroundColor(Color.rfOnSurface)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Color.rfSurfaceContainer)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }

                    // Nostr explainer
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("RoadFlare is built on Nostr, a decentralized protocol. Your data is stored on independent relays — not on RoadFlare's servers.")
                                .font(RFFont.body(14))
                                .foregroundColor(Color.rfOnSurfaceVariant)

                            Text("When you delete your account, RoadFlare sends a deletion request (NIP-09) to each relay. Most relays honour these requests and remove your events, but because relays are independently operated, removal cannot be guaranteed.")
                                .font(RFFont.body(14))
                                .foregroundColor(Color.rfOnSurfaceVariant)

                            Text("Your private key exists only on this device. Once deleted, the key — and your Nostr identity — cannot be recovered.")
                                .font(RFFont.body(14))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("About Nostr & Account Deletion")
                            .font(RFFont.body(15))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }
                    .tint(Color.rfOnSurfaceVariant)
                    .padding(16)
                    .background(Color.rfSurfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.rfSurface, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if case .scanning = phase {
                    // Hide during active scan
                } else {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }
            }
        }
    }

    private var relayDotColor: Color {
        switch phase {
        case .idle: Color.rfOffline
        case .scanning: Color.rfPrimary
        case .complete: Color.rfOnline
        case .failed: Color.rfError
        }
    }

    private func startScan() async {
        phase = .scanning
        do {
            let scan = try await appState.scanRelaysForDeletion()
            phase = .complete(scan)
        } catch AccountDeletionError.activeRideInProgress {
            phase = .failed("You have an active ride. Complete or cancel it before deleting your account.")
        } catch AccountDeletionError.servicesNotReady {
            phase = .failed("Unable to connect — please try again.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Page 2: Scan Results + Delete Options

struct DeleteAccountResultsView: View {
    @Environment(AppState.self) private var appState
    let scan: RelayScanResult

    @State private var showRoadflareConfirm = false
    @State private var showFullDeleteSheet = false
    @State private var isDeleting = false

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 52))
                            .foregroundColor(Color.rfError)
                        Text("Review & Delete")
                            .font(RFFont.headline(22))
                            .foregroundColor(Color.rfOnSurface)
                        Text("Step 2 of 2 — Choose What to Delete")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }
                    .padding(.top, 8)

                    // Scan summary
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(Color.rfPrimary)
                            Text("Scan Results")
                                .font(RFFont.title(15))
                                .foregroundColor(Color.rfOnSurface)
                        }
                        Text("Found **\(scan.roadflareCount)** RoadFlare event\(scan.roadflareCount == 1 ? "" : "s") and **\(scan.metadataCount)** Nostr profile event\(scan.metadataCount == 1 ? "" : "s") across \(scan.targetRelayURLs.count) relays.")
                            .font(RFFont.body(14))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.rfSurfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Option 1: Delete RoadFlare events only
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recommended")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                            .textCase(.uppercase)
                            .tracking(1)

                        Button {
                            showRoadflareConfirm = true
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Delete RoadFlare Events")
                                    .font(RFFont.body(16).bold())
                                    .foregroundColor(.white)
                                Text("Removes ride history, driver list, saved locations, and all protocol events from relays. Keeps your Nostr profile (Kind 0) intact.")
                                    .font(RFFont.caption(12))
                                    .foregroundColor(.white.opacity(0.8))
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.rfError)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(isDeleting)
                    }

                    // Option 2: Delete all Ridestr events including Kind 0
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Full Deletion")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                            .textCase(.uppercase)
                            .tracking(1)

                        Button {
                            showFullDeleteSheet = true
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Delete All Ridestr Events")
                                    .font(RFFont.body(16).bold())
                                    .foregroundColor(Color.rfError)
                                Text("Removes everything above plus your Nostr profile (Kind 0). This may affect other Nostr apps using this identity.")
                                    .font(RFFont.caption(12))
                                    .foregroundColor(Color.rfOnSurfaceVariant)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.rfSurfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(isDeleting)
                    }

                    // Deleting indicator
                    if isDeleting {
                        HStack(spacing: 12) {
                            ProgressView().tint(Color.rfOnSurface)
                            Text("Deleting…")
                                .font(RFFont.body(15))
                                .foregroundColor(Color.rfOnSurfaceVariant)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.rfSurfaceContainer)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Delete Events")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.rfSurface, for: .navigationBar)
        .navigationBarBackButtonHidden(isDeleting)
        .alert("Delete RoadFlare Events?", isPresented: $showRoadflareConfirm) {
            Button("Delete", role: .destructive) {
                Task { await performRoadflareDeletion() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will request deletion of \(scan.roadflareCount) RoadFlare event\(scan.roadflareCount == 1 ? "" : "s") from all relays, then remove all local data and log you out.")
        }
        .sheet(isPresented: $showFullDeleteSheet) {
            FullDeletionConfirmSheet(scan: scan) {
                Task { await performFullDeletion() }
            }
        }
    }

    private func performRoadflareDeletion() async {
        isDeleting = true
        _ = await appState.deleteRoadflareEvents(from: scan)
        // logout() sets authState = .loggedOut → RootView replaces MainTabView → sheet dismissed
    }

    private func performFullDeletion() async {
        isDeleting = true
        _ = await appState.deleteAllRidestrEvents(from: scan)
        // logout() sets authState = .loggedOut → RootView replaces MainTabView → sheet dismissed
    }
}

// MARK: - Full Deletion Confirmation (checkbox sheet)

struct FullDeletionConfirmSheet: View {
    let scan: RelayScanResult
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var checkProfile = false
    @State private var checkOtherApps = false
    @State private var checkBackedUp = false

    private var allChecked: Bool {
        checkProfile && checkOtherApps && checkBackedUp
    }

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()

            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Color.rfError)
                    Text("Full Nostr Deletion")
                        .font(RFFont.headline(20))
                        .foregroundColor(Color.rfOnSurface)
                }
                .padding(.top, 16)

                Text("This deletes all \(scan.totalCount) event\(scan.totalCount == 1 ? "" : "s") including your Nostr profile (Kind 0 metadata). Please confirm you understand:")
                    .font(RFFont.body(14))
                    .foregroundColor(Color.rfOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                // Checkboxes
                VStack(spacing: 0) {
                    confirmRow(
                        isOn: $checkProfile,
                        text: "I understand this deletes my Nostr profile (display name) from relays"
                    )
                    Divider().padding(.leading, 46)
                    confirmRow(
                        isOn: $checkOtherApps,
                        text: "I understand this may affect other Nostr apps that use this identity"
                    )
                    Divider().padding(.leading, 46)
                    confirmRow(
                        isOn: $checkBackedUp,
                        text: "I have backed up my private key, or I no longer need it"
                    )
                }
                .background(Color.rfSurfaceContainer)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                // Delete button
                Button {
                    dismiss()
                    onConfirm()
                } label: {
                    Text("Delete All Ridestr Events")
                        .font(RFFont.body(16).bold())
                        .foregroundColor(allChecked ? .white : Color.rfOffline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(allChecked ? Color.rfError : Color.rfSurfaceContainer)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!allChecked)

                Button("Cancel") { dismiss() }
                    .font(RFFont.body(15))
                    .foregroundColor(Color.rfOnSurfaceVariant)

                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func confirmRow(isOn: Binding<Bool>, text: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundColor(isOn.wrappedValue ? Color.rfError : Color.rfOffline)
                    .frame(width: 24)
                Text(text)
                    .font(RFFont.body(14))
                    .foregroundColor(Color.rfOnSurface)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3.2: Build to confirm no compile errors**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
xcodebuild build \
  -workspace RoadFlare.xcworkspace \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build Succeeded|Build FAILED"
```

Expected: `Build Succeeded`

- [ ] **Step 3.3: Commit**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
git add RoadFlare/RoadFlare/Views/Settings/DeleteAccountSheet.swift
git commit -m "feat(ui): add DeleteAccountSheet with scan + two-tier deletion flow"
```

---

## Task 4: Wire into SettingsTab

**Files:**
- Modify: `RoadFlare/RoadFlare/Views/Settings/SettingsTab.swift`

- [ ] **Step 4.1: Add state variable and Delete Account button**

Add to the state variables at the top of `SettingsTab` (after line 11):

```swift
@State private var showDeleteAccount = false
```

Add a "Delete Account" button below the existing Logout button. After the Logout button's closing `}` at line 182, add:

```swift
// Delete Account
Button { showDeleteAccount = true } label: {
    Text("Delete Account")
        .font(RFFont.body(15))
        .foregroundColor(Color.rfError)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))
}
```

Add the sheet presentation after the existing `.sheet(isPresented: $showEditProfile)` at line 195:

```swift
.sheet(isPresented: $showDeleteAccount) { DeleteAccountSheet() }
```

- [ ] **Step 4.2: Build to confirm no compile errors**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
xcodebuild build \
  -workspace RoadFlare.xcworkspace \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "error:|Build Succeeded|Build FAILED"
```

Expected: `Build Succeeded`

- [ ] **Step 4.3: Run all SDK tests to confirm no regression**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
xcodebuild test \
  -workspace RoadFlare.xcworkspace \
  -scheme RidestrSDK \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "Test.*passed|Test.*failed|Build Succeeded|Build FAILED|error:"
```

Expected: all tests pass.

- [ ] **Step 4.4: Commit**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
git add RoadFlare/RoadFlare/Views/Settings/SettingsTab.swift
git commit -m "feat(ui): wire Delete Account into Settings tab"
```

---

## Edge Cases & Implementation Notes

### Mid-ride guard
`scanRelaysForDeletion()` throws `AccountDeletionError.activeRideInProgress` when `rideCoordinator?.session.stage.isActiveRide` is true. Page 1 shows this as a user-facing error. Note: `.waitingForAcceptance` and `.driverAccepted` are NOT active rides and don't block — offers expire after 120s and are harmless.

### No events to delete
If the scan finds 0 events (new account, never published), the Continue button shows "0 events found" and Page 2's buttons still work — `deleteRoadflareEvents` with empty scan returns `publishedSuccessfully: true` and proceeds to `logout()`.

### Relay connection lost after scan
If the relay disconnects between scan and delete, `publish()` throws and the `RelayDeletionResult.publishError` captures it. The deletion methods still call `logout()` to complete local cleanup — the user has already committed to deleting.

### Deletion is best-effort
NIP-09 Kind 5 is advisory. The "About Nostr & Account Deletion" explainer sets expectations. Page 2's button descriptions reinforce this ("Removes... from relays" / "requests deletion").

### Sheet dismissal on logout
When `deleteRoadflareEvents`/`deleteAllRidestrEvents` call `logout()`, `authState = .loggedOut` causes RootView to replace MainTabView with WelcomeView. The sheet's parent view (SettingsTab inside MainTabView) disappears, automatically dismissing the sheet. This is the same mechanism the existing logout alert uses.

### Passkeys
iCloud Keychain passkeys are NOT programmatically deletable by iOS apps. Not mentioned in the UI — known platform limitation.

### `roadflare_has_launched` flag
Intentionally NOT cleared (same as logout). Prevents stale-key detection on next key import.

---

## Acceptance Criteria Checklist

- [ ] Settings tab has a "Delete Account" button distinct from "Log Out"
- [ ] Tapping "Delete Account" opens a sheet
- [ ] Page 1 shows relay list and a collapsible "About Nostr & Account Deletion" explainer
- [ ] Page 1 "Scan Relays" queries all 12 Ridestr kinds + Kind 0 and shows progress
- [ ] Page 1 shows event count and enables Continue after scan completes
- [ ] Page 1 Cancel button is always visible except during scan
- [ ] Page 2 shows scan result summary (RoadFlare events + metadata events)
- [ ] Page 2 "Delete RoadFlare Events" shows simple "are you sure?" confirmation
- [ ] Page 2 "Delete All Ridestr Events" shows checkbox confirmation sheet with 3 items
- [ ] Checkbox delete button is disabled until all 3 checkboxes are checked
- [ ] RoadFlare deletion targets only the 12 Ridestr kinds (not Kind 0)
- [ ] Full deletion targets all 12 + Kind 0 metadata
- [ ] Both options clear all local data and return app to onboarding after relay deletion
- [ ] Mid-ride: scan fails with a clear error message
- [ ] Page 2 back button navigates to scan results; hidden during deletion
- [ ] All SDK tests pass
- [ ] Full Xcode project builds clean (`xcodebuild build`)
