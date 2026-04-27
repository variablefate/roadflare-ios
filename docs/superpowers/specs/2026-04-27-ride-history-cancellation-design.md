# Ride History Cancellation — Design Spec

Tracks: [roadflare-ios#65](https://github.com/variablefate/roadflare-ios/issues/65)

## Purpose

Today, RoadFlare iOS treats every terminal ride event the same way at the history layer:

- **Rider taps "Close Ride" while ride is still active** (`forceEndRide()`) → records history with `fare = 0` (no fare estimate fallback) and default `status = "completed"`. User sees `"–"` / a phantom $0.00 ride.
- **Rider taps "Cancel Ride"** (`cancelRide()`) → ride vanishes; never enters history.
- **Driver sends Kind 3179 cancellation** (`.cancelledByDriver`) → also vanishes.
- **Driver completes ride** (`.completed`) → records correctly.

The Android Ridestr rider app (`~/Documents/Projects/ridestr/rider-app`) already solves this: cancelled rides are persisted with `status = "cancelled"`, `fare = 0`, and rendered with red error styling. Cross-app coexistence (Ridestr + Drivestr same account) is handled by writing all rides to a shared Kind 30174 backup and filtering display by `appOrigin`.

This spec brings RoadFlare iOS to parity with that proven pattern, scoped to what RoadFlare actually needs (fiat-only, USD-only, no Bitcoin, no out-of-app payment integration).

## Scope

**In scope:**
1. Persist cancelled rides to local + Nostr-backed history (`status = "cancelled"`, `fare = 0`).
2. Fix `forceEndRide()` to record with the fare estimate, not a $0 fallback.
3. Add `appOrigin` display filter to `AppState.rideHistoryRows`, mirroring Ridestr's filter — required for correct multi-app coexistence on the same account.
4. UI treatment for cancelled rides: replace fare amount with the word "Cancelled" in `Color.rfError`; hide distance/duration.
5. Test coverage for all of the above.

**Explicitly out of scope (mentioned for clarity):**
- **Schema version bump.** A separate next-release task will bump `RideHistoryEntry.schemaVersion` (and sibling `FollowedDriversBackup`, `RideHistoryBackupContent`) from `1` → `2`. The current fix uses fields already present in v1 (`status`, `appOrigin`); no bump is required to ship this issue. Tracked as a follow-up.
- **Driver-side (Drivestr Android) cancelled-history behavior.** Already implemented in `drivestr/.../DriverViewModel.kt`.
- **Detail-view UX for cancelled rides** (showing reason / which party cancelled). The `cancelledByRider(reason:)` and `cancelledByDriver(reason:)` payloads already carry a reason string; surfacing it in a detail screen is a future feature.
- **`.expired` and `.bruteForcePin` history entries.** Ridestr's rider app does not persist these either. Keep current behavior (no entry).
- **Replacing fare estimate with driver's `finalFare` field.** RoadFlare is fiat-only with out-of-app payment; the rider's fare estimate IS the canonical fare for both apps' display. There is one fare amount.

## Architecture

### Data model (no schema change)

`RideHistoryEntry.status: String` already exists (`RidestrSDK/Sources/RidestrSDK/Models/RoadflareModels.swift:492`). Default is `"completed"`. We start writing `"cancelled"` for the cancelled cases.

Add a typed projection on the SDK model:

```swift
public extension RideHistoryEntry {
    enum Status: String, Sendable {
        case completed
        case cancelled
    }
    /// Fail-open: any unrecognized status string is treated as completed
    /// so unknown / future statuses don't redact fare data.
    var statusEnum: Status { Status(rawValue: status) ?? .completed }
}
```

This is purely additive — no Codable change, no wire-format change. The string field stays the source of truth.

### Wiring constraint: SDK clears ride identity before terminal callback fires

When `sessionDidReachTerminal` fires for **cancellation** outcomes (`.cancelledByRider`, `.cancelledByDriver`, `.bruteForcePin`), the rider session's `confirmationEventId` and `driverPubkey` are already `nil`. This is because:

- The state machine's `.cancel` event handler (`RideStateMachine.swift:189-191`) returns `RideContext(riderPubkey: current.riderPubkey)`, clearing all other fields.
- `RiderRideSession.cancelRide` calls `stateMachine.reset()` (line 367) which does the same clear.
- Both happen BEFORE `delegate?.sessionDidReachTerminal(...)` fires (lines 370, 500, 563).
- For `.completed`, the state machine stays at `.completed` (no reset), so IDs remain readable — that's why the existing completed-path `recordRideHistory()` works.

This is verified by the existing test pattern: `RideCoordinatorTests.swift:815-853` tests cancellation by calling `coordinator.sessionDidReachTerminal(...)` directly **without** calling `session.restore` first — exactly because the contract says session state is gone.

A naive `recordRideHistory(status: .cancelled)` call inside the cancellation branch would hit the existing `guard let confirmationId = session.confirmationEventId` and silently no-op every time.

**Resolution: coordinator-side identity cache.** Keep the SDK contract unchanged; have the coordinator cache the ride identity while it's still readable, and use the cached values for cancellation history records.

### Coordinator routing

**File:** `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift`

**New cache field on the coordinator:**

```swift
/// Snapshot of the most recently active ride's identity, captured while the
/// session still holds it (in `sessionDidChangeStage` and on session restore).
/// Used to record cancelled-ride history entries after the SDK has reset state.
/// Cleared on terminal outcome (whether completed, cancelled, or otherwise).
private var lastActiveRideIdentity: ActiveRideIdentity?

private struct ActiveRideIdentity {
    let confirmationEventId: String
    let driverPubkey: String
}
```

**Cache populate sites:**

1. **`sessionDidChangeStage(from: to:)` at `RideCoordinator.swift:417`** — extend the existing handler. When `to.isActiveRide` is true and both `session.confirmationEventId` and `session.driverPubkey` are present, populate `lastActiveRideIdentity`. (`isActiveRide` is defined in `RidestrSDK/Sources/RidestrSDK/Models/RideModels.swift:33-38` and includes only `.rideConfirmed`, `.enRoute`, `.driverArrived`, `.inProgress`.)

2. **Session-restore path at `RideCoordinator.swift:162`** — immediately after the `currentFareEstimate` assignment block (lines 156-162), check `session.stage.isActiveRide` and populate `lastActiveRideIdentity` from `session.confirmationEventId` and `session.driverPubkey`. Note: `session.restore` does NOT call `emitStageChangeIfNeeded`, so `sessionDidChangeStage` will NOT fire for restored sessions — the restore path must populate the cache directly.

`confirmationEventId` is first set when transitioning into `.rideConfirmed` (the rider publishes the confirmation, fires `.confirm` event in the state machine). Earlier stages (`.waitingForAcceptance`, `.driverAccepted`) have `confirmationEventId == nil`. So both populate sites correctly skip pre-confirmation stages, and the cache stays nil — matching Ridestr's `shouldSaveCancelledHistory = rideStage in [RIDE_CONFIRMED, DRIVER_ARRIVED, IN_PROGRESS]` gate exactly.

**`recordRideHistory(...)` gains a status parameter and uses cached identity as fallback:**

```swift
private func recordRideHistory(status: RideHistoryEntry.Status = .completed) {
    let confirmationId: String
    let driverPubkey: String
    if let live = session.confirmationEventId, let livePubkey = session.driverPubkey {
        confirmationId = live
        driverPubkey = livePubkey
    } else if let cached = lastActiveRideIdentity {
        confirmationId = cached.confirmationEventId
        driverPubkey = cached.driverPubkey
    } else {
        return  // pre-confirmation cancellation or untracked state — drop silently
    }

    let pickup = pickupLocation ?? session.precisePickup ?? Location(latitude: 0, longitude: 0)
    let destination = destinationLocation ?? session.preciseDestination ?? Location(latitude: 0, longitude: 0)
    let isCancelled = (status == .cancelled)

    let entry = RideHistoryEntry(
        id: confirmationId,
        date: .now,
        status: status.rawValue,
        counterpartyPubkey: driverPubkey,
        counterpartyName: driversRepository.cachedDriverName(pubkey: driverPubkey),
        pickupGeohash: ProgressiveReveal.historyGeohash(for: pickup),
        dropoffGeohash: ProgressiveReveal.historyGeohash(for: destination),
        pickup: pickup,
        destination: destination,
        fare: isCancelled ? 0 : (currentFareEstimate?.fareUSD ?? 0),
        paymentMethod: session.paymentMethod ?? selectedPaymentMethod ?? PaymentMethod.cash.rawValue,
        distance: isCancelled ? nil : currentFareEstimate?.distanceMiles,
        duration: isCancelled ? nil : currentFareEstimate.map { Int($0.durationMinutes) }
        // appOrigin defaults to "roadflare" via RideHistoryEntry.init
    )
    rideHistory.addRide(entry)
    backupRideHistory()
}
```

**Updated `sessionDidReachTerminal`:**

```swift
public func sessionDidReachTerminal(_ outcome: RideSessionTerminalOutcome) {
    switch outcome {
    case .completed:
        recordRideHistory()  // session IDs still live for completion path
    case .cancelledByRider, .cancelledByDriver:
        recordRideHistory(status: .cancelled)  // falls through to lastActiveRideIdentity
        let message = terminalMessage(for: outcome)
        clearCoordinatorUIState(clearError: message == nil)
        lastError = message
    case .expired, .bruteForcePin:
        let message = terminalMessage(for: outcome)
        clearCoordinatorUIState(clearError: message == nil)
        lastError = message
    }
    lastActiveRideIdentity = nil
}
```

Routing changes (full picture):

| Path | Today | New |
|---|---|---|
| `forceEndRide()` (line ~300) | `recordRideHistory()` with `fare ?? 0` fallback if estimate nil | unchanged call shape; estimate is reliably present (restored on cold-start from `PersistedRideState.fareUSD`) and now correctly recorded |
| `sessionDidReachTerminal(.completed)` | `recordRideHistory()` | unchanged |
| `sessionDidReachTerminal(.cancelledByRider)` | drops; no record | `recordRideHistory(status: .cancelled)` via cached identity |
| `sessionDidReachTerminal(.cancelledByDriver)` | drops + shows toast | `recordRideHistory(status: .cancelled)` via cached identity, continue with existing toast |
| `sessionDidReachTerminal(.expired)` | drops + shows toast | unchanged (out of scope per Ridestr precedent) |
| `sessionDidReachTerminal(.bruteForcePin)` | drops + shows toast | unchanged |

Pre-confirmation cancellations still produce no entry: the cache is only populated when `confirmationEventId` is non-nil at stage-change time, so `lastActiveRideIdentity` stays nil and `recordRideHistory` returns early. This matches Ridestr's `shouldSaveCancelledHistory = rideStage in [RIDE_CONFIRMED, DRIVER_ARRIVED, IN_PROGRESS]` gate.

### Sync

No new sync code. `addRide(entry)` chains into `backupRideHistory()` → `RideHistorySyncCoordinator.publishAndMark(from:)` → `domainService.publishRideHistoryBackup(content)` → Kind 30174 publish. The `RideHistoryEntry`'s `status` field is included in the standard `Codable` encoding. Cancelled entries flow through the existing pipeline.

**Cross-app coexistence (the "syncs properly" requirement):**

iOS and Android both publish Kind 30174 to the same d-tag (`"rideshare-history"`) and pubkey. The replaceable-event semantics mean each publish overwrites the previous — but `RideHistoryRepository.mergeFromBackup(_:)` already merges by ID on read, so cross-app entries persist locally. The missing piece on iOS is the **display filter** that Ridestr already has.

**File:** `RoadFlare/RoadFlareCore/ViewModels/AppState+Presentation.swift`, line 65.

```swift
public var rideHistoryRows: [RideHistoryRow] {
    rideHistory.rides
        .filter { $0.appOrigin == "roadflare" }
        .map { RideHistoryRow.from($0) }
}
```

Note: `RideHistoryEntry.appOrigin` is non-optional `String` defaulting to `"roadflare"` (`RoadflareModels.swift:505,517`). The Codable-synthesis for non-optional String requires the key be present in any decoded JSON — so a hypothetical legacy entry without `appOrigin` would fail to decode entirely and never reach this filter. No legacy-string fallback needed (this is the difference from Ridestr's Kotlin filter, which handles `appOrigin == null` because Kotlin Strings are nullable). If we ever need to accept legacy entries, we'd add a custom `init(from decoder:)` that defaults missing keys — out of scope here.

### UI

**File:** `RoadFlare/RoadFlareCore/Presentation/RideHistoryRow.swift`

Replace the stored `isCompleted: Bool` field (line 50) with a stored `status` and computed projections (additive — keeps existing `isCompleted` callers green):

```swift
public let status: RideHistoryEntry.Status
public var isCompleted: Bool { status == .completed }
public var isCancelled: Bool { status == .cancelled }
```

In `RideHistoryRow.from(_:)` (line 55+), the factory passes `status: entry.statusEnum` instead of `isCompleted: entry.status == "completed"` (line 82). The `fareLabel` derivation (lines 64-77) gains a cancelled-status branch that overrides the formatted dollars:

```swift
let fareLabel: String
switch entry.statusEnum {
case .cancelled:
    fareLabel = "Cancelled"
case .completed:
    if entry.fare == 0 {
        fareLabel = "–"  // existing legacy fallback for unknown completed-fare entries
    } else {
        // existing NumberFormatter logic preserved
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        fareLabel = formatter.string(from: entry.fare as NSDecimalNumber) ?? "$\(entry.fare)"
    }
}
```

Distance/duration labels stay nil-safe and will be `nil` for cancelled entries because the coordinator skips populating them on the entry.

**Existing callers of `row.isCompleted` continue to work** (verified during exploration — 4 call sites):
- `RoadFlare/RoadFlare/Views/History/HistoryTab.swift:74` — `FlareIndicator(color: row.isCompleted ? .rfOnline : .rfError)`. Stays as-is.
- `RoadFlare/RoadFlareTests/Presentation/PresentationTypesTests.swift:526` (`isCompletedTrueForCompletedStatus`) and `:531` (`isCompletedFalseForCancelledStatus`). Stay as-is.
- `RoadFlare/RoadFlareTests/AppState/AppStatePresentationTests.swift:265` — `#expect(rows[0].isCompleted == true)`. Stays as-is.

**File:** `RoadFlare/RoadFlare/Views/History/HistoryTab.swift`

The `RideHistoryCard` view (lines ~67+) renders `row.fareLabel` somewhere in the card body — the existing `Text` view rendering needs a foreground color override when `row.isCancelled`:

```swift
Text(row.fareLabel)
    .foregroundColor(row.isCancelled ? Color.rfError : <existing color>)
```

The exact `Text` callsite and existing styling are deferred to the implementation plan (the plan should `grep` for `row.fareLabel` in `HistoryTab.swift` to identify the exact location). The design constraint is unambiguous: when `row.isCancelled`, the fare label reads "Cancelled" in `Color.rfError`; everything else inherits existing styling.

Note: `FlareIndicator` (line 74) already uses `.rfError` for non-completed rides, so cancelled entries get the red flare automatically — no change needed there.

### What does NOT change

- `RideHistoryEntry` Codable shape, JSON wire format, or schema version
- Kind 30174 d-tag (`"rideshare-history"`)
- `RideHistoryRepository.mergeFromBackup` / `restoreFromBackup` / publish logic
- `RideHistorySyncCoordinator`
- Driver-side history logic (already correct in Drivestr Android; iOS has no driver app)
- Out-of-app payment flows (no fare changes hands for cancelled rides; this is a display fix only)

## Behavior matrix

Walked through every realistic terminal interleaving:

| Scenario | Outcome | History row | Sync |
|---|---|---|---|
| Driver completes ride (happy path) | `.completed` | `status=completed`, fare=estimate | published |
| Rider taps Close while still active (escape hatch) | `forceEndRide` (no terminal callback) | `status=completed`, fare=estimate | published |
| Rider taps Cancel pre-confirmation | `.cancelledByRider`, no `confirmationId` | none (guard skips) | n/a |
| Rider taps Cancel post-confirmation | `.cancelledByRider` | `status=cancelled`, fare=0 | published |
| Driver sends 3179 pre-confirmation | `.cancelledByDriver`, no `confirmationId` | none | n/a |
| Driver sends 3179 post-confirmation | `.cancelledByDriver` | `status=cancelled`, fare=0 | published + toast |
| Stage timeout pre/post-confirmation | `.expired` | none (out of scope) | n/a |
| 3 PIN failures | `.bruteForcePin` (via `cancelRide(terminalOverride:)`) | none (out of scope) | n/a |
| App killed mid-ride, restored, rider closes | `forceEndRide` (estimate restored from `PersistedRideState.fareUSD`) | `status=completed`, fare=estimate | published |
| Driver completes after rider already force-ended | rider session torn down; driver event arrives at no-listener; `addRide` is idempotent (`RideHistoryRepository.addRide` early-outs on duplicate `id`) — no double entry | n/a | n/a |
| Rider cancels then immediately starts a new ride | terminal handler clears `lastActiveRideIdentity` before next ride starts; new ride re-populates cache on stage transition | n/a | n/a |
| App killed mid-ride, restored, rider cancels | restore path populates `lastActiveRideIdentity` after `session.restore`; cancel records correctly with restored identity | published | n/a |
| Cross-app: Ridestr Android entries pulled into iOS local store | merged in via `mergeFromBackup` | hidden by appOrigin filter | iOS re-publishes full set including foreign entries (preserves them in backup) |

## Tests

### Existing tests that need updating

`RoadFlare/RoadFlareTests/RideCoordinatorTests.swift`:

- **`sessionDidReachTerminalCancelledByRiderClearsUIAndChatWithoutError`** (line 816) and **`sessionDidReachTerminalCancelledByDriverSurfacesMessage`** (line 836) currently model the SDK contract that ride identity is gone by terminal-callback time, so they don't call `session.restore`. With the new design, these tests still hold their existing assertions (UI clears, error message surfaces), but the coordinator's terminal handler now ALSO calls `recordRideHistory(status: .cancelled)`. With `lastActiveRideIdentity` nil (test never populated it), `recordRideHistory` early-returns — so `history.rides` stays empty and the existing tests stay green. **No change required.**

- **Existing `sessionDidReachTerminalExpiredSetsTimeoutMessage`** (line 856) and **`sessionDidReachTerminalBruteForcePinSetsMessage`** (line 876) stay unchanged — those outcomes don't persist history under the new design either.

- **Existing `sessionDidReachTerminalCompletedRecordsHistoryAndKeepsUI`** (line 758) stays green; the completed path uses live session IDs (set via `session.restore` in this test).

In other words, the existing tests don't need code changes. They naturally test the "no cache populated → no record" path. The new tests below cover the "cache populated → record" paths.

### New tests

1. **`RideCoordinatorTests`** — additions. Each populates the cache by calling `session.restore(...)` to land in an active stage, then calls `coordinator.sessionDidChangeStage(from: .driverAccepted, to: .rideConfirmed)` to manually trigger the populate (mirrors the production flow where `restoreRideState()` would populate the cache after `session.restore`):
   - `cancelByRiderPostConfirmationRecordsCancelledHistory` — restore into `.rideConfirmed`, populate cache via stage-change call, fire `.cancelledByRider`, assert `history.rides.count == 1` with `status == "cancelled"`, `fare == 0`, `distance == nil`, `duration == nil`.
   - `cancelByRiderPreConfirmationRecordsNothing` — restore into `.waitingForAcceptance` (where `confirmationEventId == nil`); the stage-change call into a non-active stage does NOT populate the cache; fire `.cancelledByRider`, assert `history.rides.isEmpty`.
   - `cancelByDriverPostConfirmationRecordsCancelledHistory` — same setup as rider variant but with `.cancelledByDriver`.
   - `forceEndRideRecordsCompletedWithEstimate` — restore into `.rideConfirmed`, set `currentFareEstimate`, call `coordinator.forceEndRide()`, assert entry has `status == "completed"`, `fare == estimate.fareUSD`, `distance == estimate.distanceMiles`. The forceEnd path uses live session IDs (no cache fallback needed) because `forceEndRide` records BEFORE calling `session.forceEndRide()`.
   - `restoreRideStateInActiveStagePopulatesCacheForLaterCancel` — set up `rideStateRepository` with a persisted active-stage snapshot, call `coordinator.restoreRideState()`, then fire `.cancelledByRider` directly (no manual stage-change call). Assert history entry recorded — verifies the restore-path populate works end-to-end.
   - `lastActiveRideIdentityClearedAfterTerminal` — populate cache, fire `.completed`, then start a fresh `.waitingForAcceptance` flow and fire `.cancelledByRider` from pre-confirmation. Assert no second history entry (cache was cleared, not inherited from previous ride).

2. **`RoadflareModelsTests`** — `RideHistoryEntry.statusEnum` round-trip:
   - `"completed"` → `.completed`
   - `"cancelled"` → `.cancelled`
   - `"unknown_future_value"` → `.completed` (fail-open assertion)

3. **`PresentationTypesTests`** — `RideHistoryRow.from(_:)`:
   - cancelled entry → `fareLabel == "Cancelled"`, `distanceLabel == nil`, `durationLabel == nil`, `isCancelled == true`
   - completed entry with `fare == 0` → `fareLabel == "–"` (preserve legacy behavior)
   - completed entry with `fare > 0` → existing currency formatting unchanged

4. **`AppStatePresentationTests`** — appOrigin filter:
   - mix of `appOrigin == "roadflare"` and `appOrigin == "ridestr"` entries → `rideHistoryRows` returns only the roadflare entries.

5. **Existing `PersistenceTests` round-trip** — verify cancelled entry survives `RideHistoryPersistence` round-trip without changes (no test code change; just confirm green).

## Open questions

None. All design decisions resolved through brainstorming with the issue author:
- Force-end keeps `"completed"` semantics (option B).
- Cancellation event = persistence trigger (cancel-button or received Kind 3179).
- Single fare amount = the rider's estimate.
- UI: word "Cancelled" in red where dollars would be; no card tint or pill.
- Cross-app sync via `appOrigin` display filter (parity with Ridestr).
- Schema version bump deferred to next overall release.

## References

- Issue: [roadflare-ios#65](https://github.com/variablefate/roadflare-ios/issues/65)
- Ridestr Android rider cancel persistence: `~/Documents/Projects/ridestr/rider-app/src/main/java/com/ridestr/rider/viewmodels/RiderViewModel.kt:3049`, `:4097`
- Ridestr Android cancelled-row UI: `~/Documents/Projects/ridestr/common/src/main/java/com/ridestr/common/ui/components/HistoryComponents.kt:154`
- Ridestr Android appOrigin filter: `~/Documents/Projects/ridestr/rider-app/src/main/java/com/ridestr/rider/ui/screens/HistoryScreen.kt:32`
- iOS `RideHistoryEntry`: `RidestrSDK/Sources/RidestrSDK/Models/RoadflareModels.swift:488`
- iOS `RideCoordinator.recordRideHistory`: `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift:334`
- iOS `RideCoordinator.sessionDidReachTerminal`: `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift:403`
- iOS `RideHistoryRow.from`: `RoadFlare/RoadFlareCore/Presentation/RideHistoryRow.swift:55`
- iOS `AppState.rideHistoryRows`: `RoadFlare/RoadFlareCore/ViewModels/AppState+Presentation.swift:65`
- iOS `HistoryTab` & `RideHistoryCard`: `RoadFlare/RoadFlare/Views/History/HistoryTab.swift`
