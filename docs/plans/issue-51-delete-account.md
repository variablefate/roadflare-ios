# Delete Account Feature (Issue #51) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a two-page in-app Delete Account flow that (1) publishes NIP-09 deletion requests for the user's Nostr events to all known relays and shows per-relay status, then (2) performs full local account cleanup and returns the app to the logged-out/onboarding state.

**Architecture:** A new `AccountDeletionService` in RidestrSDK handles event-ID fetching and Kind 5 deletion publishing via `RelayManagerProtocol`. `AppState` gains `beginRelayDeletion()` and `completeAccountDeletion()` methods. The UI is a sheet with a `NavigationStack` hosting two views — `DeleteAccountRelayView` (Page 1: relay deletion) and `DeleteAccountFinalView` (Page 2: local cleanup confirmation) — triggered from a new "Delete Account" button added to `SettingsTab`.

**Tech Stack:** SwiftUI, RidestrSDK (`NostrFilter`, `RideshareEventBuilder`, `RelayManagerProtocol`, `DefaultRelays`), `AppState` (`@Observable`, `@MainActor`), `FakeRelayManager` + Swift Testing for unit tests

---

## Background & Codebase Context

### What constitutes "an account"

A RoadFlare account is:
1. **A Nostr keypair** — private key stored in Keychain at service `"com.roadflare.keys"`, key `"nostr_identity_private_key"`. Cleared by `KeyManager.deleteKeys()`.
2. **Local UserDefaults data** — profile name, payment methods, saved locations, ride history, followed drivers, sync metadata. Cleared by repository `clearAll()` calls in `prepareForIdentityReplacement()`.
3. **Nostr-backed events on relays** — the four kinds below. NOT cleared by current `logout()`.

### Nostr events that must be deleted (rider-authored, non-ephemeral)

| Kind | Name | d-tag filter |
|------|------|--------------|
| 0 | metadata (profile name) | — (use `NostrFilter.metadata`) |
| 30011 | followedDriversList | `"roadflare-drivers"` |
| 30174 | rideHistoryBackup | `"rideshare-history"` |
| 30177 | unifiedProfile / profileBackup | `"rideshare-profile"` |

Ephemeral kinds (3173–3189) expire naturally and do **not** need deletion.

### Current logout flow (reuse for step 2)

`AppState.logout()` in `RoadFlare/RoadFlareCore/ViewModels/AppState.swift:341`:
```swift
public func logout() async {
    await prepareForIdentityReplacement(clearPersistedSyncState: true)
    try? await keyManager?.deleteKeys()
    keypair = nil
    authState = .loggedOut
}
```
`prepareForIdentityReplacement()` at line 458 stops all coordinators, clears all repos, nils service refs.

### Mid-ride guard

Check `rideCoordinator?.session.stage.isActiveRide` (defined in `RidestrSDK/Sources/RidestrSDK/Models/RideModels.swift:33`). Active stages are `.rideConfirmed`, `.enRoute`, `.driverArrived`, `.inProgress`.

### Relay infrastructure

`RelayManagerProtocol.fetchEvents(filter:timeout:)` — one-shot EOSE-aware query, returns matching events.  
`RelayManagerProtocol.publish(_:)` — publishes to all connected relays.  
`DefaultRelays.all` — `[wss://relay.damus.io, wss://nos.lol, wss://relay.primal.net]` (3 relays, SDK-defined).  
`RideshareEventBuilder.deletion(eventIds:reason:kinds:keypair:)` — already implemented in `RidestrSDK/Sources/RidestrSDK/Nostr/RideshareEventBuilder.swift:331`.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `RidestrSDK/Sources/RidestrSDK/RoadFlare/AccountDeletionService.swift` | Fetch event IDs + publish Kind 5 deletion |
| Create | `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/AccountDeletionServiceTests.swift` | Unit tests for the service |
| Create | `RoadFlare/RoadFlare/Views/Settings/DeleteAccountSheet.swift` | Two-page deletion UI (both pages) |
| Modify | `RoadFlare/RoadFlareCore/ViewModels/AppState.swift` | Add `beginRelayDeletion()` + `completeAccountDeletion()` |
| Modify | `RoadFlare/RoadFlare/Views/Settings/SettingsTab.swift` | Add Delete Account button + sheet presentation |

---

## Task 1: AccountDeletionService — SDK type and result model

**Files:**
- Create: `RidestrSDK/Sources/RidestrSDK/RoadFlare/AccountDeletionService.swift`
- Create: `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/AccountDeletionServiceTests.swift`

- [ ] **Step 1.1: Write the failing test file**

```swift
// RidestrSDK/Tests/RidestrSDKTests/RoadFlare/AccountDeletionServiceTests.swift
import Foundation
import Testing
@testable import RidestrSDK

// Decode a stub NostrEvent from JSON (same pattern as NostrEventTests.swift).
// Lets us set arbitrary kind/id without calling EventSigner (which needs real crypto).
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

    // MARK: - No events

    @Test func noEvents_returnsSuccessWithEmptyIds_publishesNothing() async throws {
        let (sut, relay, _) = try makeKit()
        relay.fetchResults = []

        let result = await sut.deleteUserEvents()

        #expect(result.publishedSuccessfully == true)
        #expect(result.targetedEventIds.isEmpty)
        #expect(result.publishError == nil)
        #expect(result.queriedKinds == AccountDeletionService.deletableKinds)
        #expect(result.targetRelayURLs == DefaultRelays.all)
        #expect(relay.publishedEvents.isEmpty)  // no Kind 5 when nothing to delete
    }

    // MARK: - Events found

    @Test func foundEvents_publishesKind5WithETagsForEachEventId() async throws {
        let (sut, relay, pubkey) = try makeKit()
        let event = stubEvent(id: "aabbcc", kind: 0, pubkey: pubkey)
        relay.fetchResults = [event]  // returned for every fetchEvents call

        let result = await sut.deleteUserEvents()

        #expect(result.publishedSuccessfully == true)
        #expect(result.targetedEventIds.contains("aabbcc"))
        #expect(relay.publishedEvents.count == 1)
        let kind5 = relay.publishedEvents[0]
        #expect(kind5.kind == 5)
        let eTagIds = kind5.tagValues("e")
        #expect(eTagIds.contains("aabbcc"))
    }

    @Test func foundEvents_publishError_returnsFailureResultWithEventIds() async throws {
        let (sut, relay, pubkey) = try makeKit()
        let event = stubEvent(id: "aabbcc", kind: 0, pubkey: pubkey)
        relay.fetchResults = [event]
        relay.shouldFailPublish = true

        let result = await sut.deleteUserEvents()

        #expect(result.publishedSuccessfully == false)
        #expect(result.publishError != nil)
        #expect(result.targetedEventIds.contains("aabbcc"))
    }

    // MARK: - Deletable kinds contract

    @Test func deletableKinds_containsExpectedKinds() {
        let rawValues = AccountDeletionService.deletableKinds.map(\.rawValue)
        #expect(rawValues.contains(0))      // Kind 0: metadata
        #expect(rawValues.contains(30011))  // Kind 30011: followedDriversList
        #expect(rawValues.contains(30174))  // Kind 30174: rideHistoryBackup
        #expect(rawValues.contains(30177))  // Kind 30177: unifiedProfile
    }

    @Test func deletableKinds_doesNotContainEphemeralKinds() {
        let rawValues = AccountDeletionService.deletableKinds.map(\.rawValue)
        // Ephemeral kinds (3173–3189) should not be targeted — they expire naturally
        for ephemeral: UInt16 in [3173, 3175, 3178, 3179, 3186, 3187, 3188, 3189] {
            #expect(!rawValues.contains(ephemeral))
        }
    }

    // MARK: - Filter queries

    @Test func queriesAllDeletableKinds() async throws {
        let (sut, relay, _) = try makeKit()
        relay.fetchResults = []

        _ = await sut.deleteUserEvents()

        // One fetchEvents call per deletable kind
        #expect(relay.fetchCalls.count == AccountDeletionService.deletableKinds.count)
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

// MARK: - Result Model

/// Result of a relay-side account event deletion pass.
///
/// Deletion on Nostr is best-effort — relays may honour or ignore Kind 5 events.
/// This result tells the caller what was attempted, not what was guaranteed.
public struct RelayDeletionResult: Sendable {
    /// Event IDs found on relays and targeted for deletion.
    public let targetedEventIds: [String]
    /// Event kinds that were queried (always `AccountDeletionService.deletableKinds`).
    public let queriedKinds: [EventKind]
    /// Relay URLs the deletion request was published to.
    public let targetRelayURLs: [URL]
    /// True if the Kind 5 deletion event was published without error,
    /// or if there were no events to delete (vacuously successful).
    public let publishedSuccessfully: Bool
    /// Human-readable error from the publish step, if any.
    public let publishError: String?
}

// MARK: - Service

/// Fetches all rider-authored Nostr events and publishes a NIP-09 Kind 5 deletion request.
///
/// Intended for use in the two-page Delete Account flow. Create with the app's live
/// `relayManager` (already connected to `DefaultRelays.all`). Call `deleteUserEvents()`
/// from Page 1 of the flow before tearing down services.
public final class AccountDeletionService: Sendable {
    private let relayManager: any RelayManagerProtocol
    private let keypair: NostrKeypair

    /// Rider-authored event kinds that should be deleted on account closure.
    /// Ephemeral kinds (3173–3189) expire naturally and are excluded.
    public static let deletableKinds: [EventKind] = [
        .metadata,
        .followedDriversList,
        .rideHistoryBackup,
        .unifiedProfile,
    ]

    public init(relayManager: any RelayManagerProtocol, keypair: NostrKeypair) {
        self.relayManager = relayManager
        self.keypair = keypair
    }

    /// Fetch all deletable user events from relays, publish a Kind 5 deletion request,
    /// and return a result describing what was attempted.
    ///
    /// - Never throws. Errors from relay fetch are silently treated as "no events found"
    ///   (best-effort); errors from publish are captured in `RelayDeletionResult.publishError`.
    public func deleteUserEvents() async -> RelayDeletionResult {
        // 1. Query each deletable kind. Treat fetch errors as empty (relay may be down).
        var eventIds: [String] = []
        for kind in Self.deletableKinds {
            let filter = buildFilter(for: kind)
            let events = (try? await relayManager.fetchEvents(
                filter: filter,
                timeout: RelayConstants.eoseTimeoutSeconds
            )) ?? []
            eventIds.append(contentsOf: events.map(\.id))
        }

        // 2. Nothing to delete — vacuous success (no Kind 5 published).
        guard !eventIds.isEmpty else {
            return RelayDeletionResult(
                targetedEventIds: [],
                queriedKinds: Self.deletableKinds,
                targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: true,
                publishError: nil
            )
        }

        // 3. Build and publish a single Kind 5 event covering all found event IDs.
        do {
            let deletionEvent = try await RideshareEventBuilder.deletion(
                eventIds: eventIds,
                reason: "Account deleted by user",
                kinds: Self.deletableKinds,
                keypair: keypair
            )
            _ = try await relayManager.publish(deletionEvent)
            return RelayDeletionResult(
                targetedEventIds: eventIds,
                queriedKinds: Self.deletableKinds,
                targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: true,
                publishError: nil
            )
        } catch {
            return RelayDeletionResult(
                targetedEventIds: eventIds,
                queriedKinds: Self.deletableKinds,
                targetRelayURLs: DefaultRelays.all,
                publishedSuccessfully: false,
                publishError: error.localizedDescription
            )
        }
    }

    // MARK: - Private

    private func buildFilter(for kind: EventKind) -> NostrFilter {
        switch kind {
        case .followedDriversList:
            return .followedDriversList(myPubkey: keypair.publicKeyHex)
        case .rideHistoryBackup:
            return .rideHistoryBackup(myPubkey: keypair.publicKeyHex)
        case .unifiedProfile:
            return .profileBackup(myPubkey: keypair.publicKeyHex)
        case .metadata:
            return .metadata(pubkeys: [keypair.publicKeyHex])
        default:
            return NostrFilter().kinds([kind]).authors([keypair.publicKeyHex])
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

Expected: all 6 tests pass

- [ ] **Step 1.5: Commit**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
git add \
  RidestrSDK/Sources/RidestrSDK/RoadFlare/AccountDeletionService.swift \
  RidestrSDK/Tests/RidestrSDKTests/RoadFlare/AccountDeletionServiceTests.swift
git commit -m "feat(sdk): add AccountDeletionService for NIP-09 relay event deletion"
```

---

## Task 2: AppState — orchestration methods

**Files:**
- Modify: `RoadFlare/RoadFlareCore/ViewModels/AppState.swift`

Add the following block after `logout()` (line 346):

- [ ] **Step 2.1: Add error enum and methods to AppState.swift**

Insert this block directly after the closing `}` of `logout()` at line 346:

```swift
// MARK: - Account Deletion

/// Reasons beginRelayDeletion() can fail before contacting relays.
public enum AccountDeletionError: Error {
    /// Services not ready — user not logged in or relay not connected.
    case servicesNotReady
    /// Cannot delete account while a ride is in progress.
    case activeRideInProgress
}

/// Phase 1 of account deletion: publish NIP-09 Kind 5 deletion events to relays.
///
/// Call this while the user is still logged in (relay + keypair are live).
/// Guards against active rides. Returns a result describing what was attempted.
///
/// - Throws: `AccountDeletionError.servicesNotReady` if not logged in.
/// - Throws: `AccountDeletionError.activeRideInProgress` if a ride is ongoing.
public func beginRelayDeletion() async throws -> RelayDeletionResult {
    guard let keypair, let relayManager else {
        throw AccountDeletionError.servicesNotReady
    }
    guard !(rideCoordinator?.session.stage.isActiveRide ?? false) else {
        throw AccountDeletionError.activeRideInProgress
    }
    let service = AccountDeletionService(relayManager: relayManager, keypair: keypair)
    return await service.deleteUserEvents()
}

/// Phase 2 of account deletion: clear all local data and return to onboarding.
///
/// Reuses the existing logout path. Call only after `beginRelayDeletion()` completes.
public func completeAccountDeletion() async {
    await logout()
}
```

- [ ] **Step 2.2: Build the full project to confirm no new errors**

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
git commit -m "feat: add beginRelayDeletion() and completeAccountDeletion() to AppState"
```

---

## Task 3: DeleteAccountSheet — two-page UI

**Files:**
- Create: `RoadFlare/RoadFlare/Views/Settings/DeleteAccountSheet.swift`

The sheet uses a `NavigationStack` with `NavigationLink` to push from Page 1 → Page 2.

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
            DeleteAccountRelayView()
        }
    }
}

// MARK: - Page 1: Relay Deletion

private enum RelayDeletionPhase {
    case idle
    case deleting
    case complete(RelayDeletionResult)
    case failed(String)
}

struct DeleteAccountRelayView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var phase: RelayDeletionPhase = .idle

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    // Icon + headline
                    VStack(spacing: 12) {
                        Image(systemName: "trash.circle.fill")
                            .font(.system(size: 52))
                            .foregroundColor(Color.rfError)
                        Text("Delete Account")
                            .font(RFFont.headline(22))
                            .foregroundColor(Color.rfOnSurface)
                        Text("Step 1 of 2 — Relay Cleanup")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }
                    .padding(.top, 8)

                    // Explanation
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RoadFlare will request deletion of your events from all known relays. This includes your profile, saved locations, payment methods, ride history, and driver list.")
                            .font(RFFont.body(14))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                        Text("Relay deletion is best-effort. Most relays honour Kind 5 deletion requests, but some may not.")
                            .font(RFFont.body(14))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }
                    .padding(16)
                    .background(Color.rfSurfaceContainer)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    // Relay list
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Target Relays")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                            .textCase(.uppercase)
                            .tracking(1)
                        VStack(spacing: 0) {
                            ForEach(DefaultRelays.all, id: \.absoluteString) { relay in
                                HStack(spacing: 12) {
                                    Image(systemName: relayStatusIcon(relay))
                                        .foregroundColor(relayStatusColor(relay))
                                        .frame(width: 20)
                                    Text(relay.host ?? relay.absoluteString)
                                        .font(RFFont.body(14))
                                        .foregroundColor(Color.rfOnSurface)
                                    Spacer()
                                    relayStatusText(relay)
                                }
                                .padding(14)
                                if relay != DefaultRelays.all.last {
                                    Divider().padding(.leading, 46)
                                }
                            }
                        }
                        .background(Color.rfSurfaceContainer)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    // Result summary (visible after deletion attempt)
                    if case .complete(let result) = phase {
                        resultSummary(result)
                    }
                    if case .failed(let msg) = phase {
                        Text("Error: \(msg)")
                            .font(RFFont.body(13))
                            .foregroundColor(Color.rfError)
                            .padding(14)
                            .background(Color.rfSurfaceContainer)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Primary action button
                    primaryButton

                    // Cancel
                    if case .idle = phase {
                        Button("Cancel") { dismiss() }
                            .font(RFFont.body(15))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.rfSurface, for: .navigationBar)
        .toolbar {
            if case .idle = phase {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Color.rfOnSurfaceVariant)
                }
            }
        }
    }

    // MARK: - Primary button

    @ViewBuilder
    private var primaryButton: some View {
        switch phase {
        case .idle:
            Button {
                Task { await startDeletion() }
            } label: {
                Text("Request Relay Deletion")
                    .font(RFFont.body(16).bold())
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.rfError)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

        case .deleting:
            HStack(spacing: 12) {
                ProgressView().tint(Color.rfOnSurface)
                Text("Contacting relays…")
                    .font(RFFont.body(15))
                    .foregroundColor(Color.rfOnSurfaceVariant)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color.rfSurfaceContainer)
            .clipShape(RoundedRectangle(cornerRadius: 16))

        case .complete(let result):
            NavigationLink {
                DeleteAccountFinalView()
            } label: {
                HStack {
                    if result.publishedSuccessfully {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Color.rfOnline)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(Color.rfError)
                    }
                    Text("Continue to Final Step")
                        .font(RFFont.body(16).bold())
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(result.publishedSuccessfully ? Color.rfError : Color.rfError.opacity(0.7))
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
    }

    // MARK: - Result summary card

    @ViewBuilder
    private func resultSummary(_ result: RelayDeletionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: result.publishedSuccessfully ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(result.publishedSuccessfully ? Color.rfOnline : Color.rfError)
                Text(result.publishedSuccessfully ? "Deletion requested" : "Deletion partially failed")
                    .font(RFFont.title(15))
                    .foregroundColor(Color.rfOnSurface)
            }
            if result.targetedEventIds.isEmpty {
                Text("No events found on relays — nothing to delete.")
                    .font(RFFont.body(13))
                    .foregroundColor(Color.rfOnSurfaceVariant)
            } else {
                Text("\(result.targetedEventIds.count) event(s) targeted across \(result.targetRelayURLs.count) relays.")
                    .font(RFFont.body(13))
                    .foregroundColor(Color.rfOnSurfaceVariant)
            }
            if let err = result.publishError {
                Text("Note: \(err)")
                    .font(RFFont.caption(12))
                    .foregroundColor(Color.rfError)
            }
            Text("You can proceed to final deletion even if relay cleanup was incomplete.")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOnSurfaceVariant)
        }
        .padding(16)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Per-relay status icons/colors/text

    private func relayStatusIcon(_ relay: URL) -> String {
        switch phase {
        case .idle: return "circle"
        case .deleting: return "arrow.triangle.2.circlepath"
        case .complete(let result):
            return result.publishedSuccessfully ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func relayStatusColor(_ relay: URL) -> Color {
        switch phase {
        case .idle: return Color.rfOffline
        case .deleting: return Color.rfPrimary
        case .complete(let result):
            return result.publishedSuccessfully ? Color.rfOnline : Color.rfError
        case .failed: return Color.rfError
        }
    }

    @ViewBuilder
    private func relayStatusText(_ relay: URL) -> some View {
        switch phase {
        case .idle:
            Text("Pending")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfOffline)
        case .deleting:
            ProgressView()
                .scaleEffect(0.7)
                .tint(Color.rfPrimary)
        case .complete(let result):
            Text(result.publishedSuccessfully ? "Requested" : "Failed")
                .font(RFFont.caption(12))
                .foregroundColor(result.publishedSuccessfully ? Color.rfOnline : Color.rfError)
        case .failed:
            Text("Error")
                .font(RFFont.caption(12))
                .foregroundColor(Color.rfError)
        }
    }

    // MARK: - Action

    private func startDeletion() async {
        phase = .deleting
        do {
            let result = try await appState.beginRelayDeletion()
            phase = .complete(result)
        } catch AccountDeletionError.activeRideInProgress {
            phase = .failed("You have an active ride in progress. Please complete or cancel your ride before deleting your account.")
        } catch AccountDeletionError.servicesNotReady {
            phase = .failed("Unable to connect — please try again.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Page 2: Final Local Removal

struct DeleteAccountFinalView: View {
    @Environment(AppState.self) private var appState
    @State private var isDeleting = false

    private let localDataItems = [
        ("key.fill", "Private key (from Keychain)"),
        ("person.fill", "Profile name"),
        ("creditcard.fill", "Payment preferences"),
        ("mappin.and.ellipse", "Saved locations & recents"),
        ("clock.arrow.circlepath", "Ride history"),
        ("person.2.fill", "Followed drivers"),
    ]

    var body: some View {
        ZStack {
            Color.rfSurface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    // Icon + headline
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 52))
                            .foregroundColor(Color.rfError)
                        Text("Final Confirmation")
                            .font(RFFont.headline(22))
                            .foregroundColor(Color.rfOnSurface)
                        Text("Step 2 of 2 — Local Data Removal")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                    }
                    .padding(.top, 8)

                    // Warning
                    Text("This will permanently remove all local account data. This action cannot be undone.")
                        .font(RFFont.body(14))
                        .foregroundColor(Color.rfOnSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)

                    // What gets deleted
                    VStack(alignment: .leading, spacing: 12) {
                        Text("What will be removed")
                            .font(RFFont.caption(12))
                            .foregroundColor(Color.rfOnSurfaceVariant)
                            .textCase(.uppercase)
                            .tracking(1)
                        VStack(spacing: 0) {
                            ForEach(localDataItems, id: \.0) { icon, label in
                                HStack(spacing: 12) {
                                    Image(systemName: icon)
                                        .frame(width: 20)
                                        .foregroundColor(Color.rfError)
                                    Text(label)
                                        .font(RFFont.body(14))
                                        .foregroundColor(Color.rfOnSurface)
                                    Spacer()
                                }
                                .padding(14)
                                if icon != localDataItems.last?.0 {
                                    Divider().padding(.leading, 46)
                                }
                            }
                        }
                        .background(Color.rfSurfaceContainer)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    // Delete button
                    Button {
                        isDeleting = true
                        Task { await appState.completeAccountDeletion() }
                    } label: {
                        Group {
                            if isDeleting {
                                HStack(spacing: 10) {
                                    ProgressView().tint(.white)
                                    Text("Deleting…")
                                }
                            } else {
                                Text("Delete Account")
                            }
                        }
                        .font(RFFont.body(16).bold())
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(isDeleting ? Color.rfError.opacity(0.6) : Color.rfError)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .disabled(isDeleting)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Final Step")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.rfSurface, for: .navigationBar)
        .navigationBarBackButtonHidden(isDeleting)
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
git commit -m "feat(ui): add DeleteAccountSheet two-page relay+local deletion flow"
```

---

## Task 4: Wire into SettingsTab

**Files:**
- Modify: `RoadFlare/RoadFlare/Views/Settings/SettingsTab.swift`

- [ ] **Step 4.1: Add state variable and Delete Account button to SettingsTab**

In `SettingsTab`, add `@State private var showDeleteAccount = false` alongside the other state variables at the top of the struct (after line 10 where `showLogoutConfirm` is declared):

```swift
@State private var showDeleteAccount = false
```

Replace the existing Logout section (lines 173–182) with the updated block below that adds a "Delete Account" button beneath "Log Out":

```swift
// Logout
Button { showLogoutConfirm = true } label: {
    Text("Log Out")
        .font(RFFont.body(15))
        .foregroundColor(Color.rfError)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Color.rfSurfaceContainer)
        .clipShape(RoundedRectangle(cornerRadius: 16))
}

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

Add the sheet presentation alongside the other sheet modifiers (after line 195 where `showEditProfile` sheet is):

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

- [ ] **Step 4.3: Run all SDK tests to confirm nothing regressed**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
xcodebuild test \
  -workspace RoadFlare.xcworkspace \
  -scheme RidestrSDK \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | grep -E "Test.*passed|Test.*failed|Build Succeeded|Build FAILED|error:"
```

Expected: all tests pass, no failures.

- [ ] **Step 4.4: Commit**

```bash
cd ~/Documents/Projects/roadflare-ios-issue-51
git add RoadFlare/RoadFlare/Views/Settings/SettingsTab.swift
git commit -m "feat(ui): wire Delete Account into Settings tab"
```

---

## Edge Cases & Implementation Notes

### Mid-ride guard
`beginRelayDeletion()` in AppState throws `AccountDeletionError.activeRideInProgress` when `rideCoordinator?.session.stage.isActiveRide` is true. The UI translates this to a user-facing message on Page 1. This prevents data corruption from tearing down services during an active protocol exchange.

### Relay unreachable / fetch errors
`AccountDeletionService.deleteUserEvents()` silently treats fetch errors as "no events found" for that kind. A single Kind 5 event covers all found event IDs. If `relayManager` is disconnected when `beginRelayDeletion()` is called, `publish()` throws and the result captures the error in `publishError`.

### No events to delete (new account)
If the user never published any events (e.g. imported a key but never completed onboarding), all `fetchEvents` calls return empty. The service returns `publishedSuccessfully: true` with empty `targetedEventIds`. Page 1 shows "No events found on relays — nothing to delete." and still allows proceeding to Page 2.

### Relay does not support NIP-09 deletion
Deletion on Nostr is advisory. The UI text ("Relay deletion is best-effort") and result summary ("You can proceed to final deletion even if relay cleanup was incomplete") set honest user expectations. The "Continue to Final Step" NavigationLink is always available after Page 1 completes, regardless of whether publish succeeded.

### Passkey / iCloud Keychain credentials
PasskeyManager passkeys sync via iCloud and are NOT cleared by `completeAccountDeletion()`. Page 2 does not mention passkeys because there is no programmatic iOS API to delete iCloud Keychain credentials from within an app. If this becomes a requirement, the user must delete passkeys manually via iOS Settings → Passwords. This is a known limitation, not a bug.

### `roadflare_has_launched` UserDefaults flag
This flag is intentionally NOT cleared by `completeAccountDeletion()` (it goes through `logout()` which leaves it intact). The flag prevents stale-key detection on reinstall. Clearing it on account deletion would cause the next key import to incorrectly trigger keychain cleanup — the current behavior is correct.

### Ordering: relay deletion before local cleanup
Page 1 runs while services are fully live (`relayManager`, `keypair`, `roadflareDomainService` all non-nil). Page 2 calls `completeAccountDeletion()` which tears everything down. This ordering is mandatory — swapping the steps would leave no relay connection to publish Kind 5.

---

## Acceptance Criteria Checklist

- [ ] Settings tab has a "Delete Account" button distinct from "Log Out"
- [ ] Tapping "Delete Account" opens a sheet (not a simple alert)
- [ ] Page 1 shows the list of target relays and an explanation of what will be deleted
- [ ] Page 1 "Request Relay Deletion" button contacts relays and shows progress
- [ ] Page 1 shows result (events targeted, relay status) before user can proceed
- [ ] Page 1 allows continuing to Page 2 even if relay deletion partially fails
- [ ] Mid-ride: Page 1 shows a clear error and does not proceed
- [ ] Page 2 lists what local data will be deleted
- [ ] Page 2 "Delete Account" button calls `completeAccountDeletion()` and returns app to onboarding
- [ ] All SDK tests pass after implementation
- [ ] Full Xcode project builds clean (`xcodebuild build`)
