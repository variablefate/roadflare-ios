# Ride History Cancellation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist cancelled rides to local + Nostr-backed history with `status="cancelled"` and red "Cancelled" UI; fix `forceEndRide` $0 bug; add `appOrigin` display filter for cross-app coexistence.

**Architecture:** Coordinator-side ride-identity cache populated when transitioning into active stages and on session restore, used as a fallback when the SDK has cleared session state by the time `sessionDidReachTerminal` fires. No SDK changes; only additive `RideHistoryEntry.Status` enum extension. Single fare source: the rider's `currentFareEstimate`.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`/`@Suite`), `xcodebuild`. Existing `RidestrSDK` + `RoadFlareCore` boundaries unchanged.

**Spec:** `docs/superpowers/specs/2026-04-27-ride-history-cancellation-design.md`

**Tracks:** [roadflare-ios#65](https://github.com/variablefate/roadflare-ios/issues/65)

---

## File map

| File | Action | Responsibility |
|---|---|---|
| `RidestrSDK/Sources/RidestrSDK/Models/RoadflareModels.swift` | Modify (append) | Add `RideHistoryEntry.Status` enum extension + `statusEnum` projection |
| `RidestrSDK/Tests/RidestrSDKTests/Models/RoadflareModelsTests.swift` | Modify (append) | Test `statusEnum` round-trip + fail-open behavior |
| `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift` | Modify | Add `lastActiveRideIdentity` cache, populate sites, refactor `recordRideHistory`, update `sessionDidReachTerminal` |
| `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift` | Modify (append) | New tests for cancellation persistence paths |
| `RoadFlare/RoadFlareCore/Presentation/RideHistoryRow.swift` | Modify | Replace stored `isCompleted` with stored `status` + computed `isCompleted`/`isCancelled`; cancelled `fareLabel` |
| `RoadFlare/RoadFlareTests/Presentation/PresentationTypesTests.swift` | Modify (append) | New tests for cancelled fareLabel + computed properties |
| `RoadFlare/RoadFlareCore/ViewModels/AppState+Presentation.swift` | Modify | Add `appOrigin == "roadflare"` filter to `rideHistoryRows` |
| `RoadFlare/RoadFlareTests/AppState/AppStatePresentationTests.swift` | Modify (append) | Test that ridestr-origin entries are filtered out |
| `RoadFlare/RoadFlare/Views/History/HistoryTab.swift` | Modify (1 line) | Fare-label color override for cancelled rides |

---

## Build verification commands

Per project convention (`.claude/CLAUDE.md` "Build verification"), the canonical test command is `xcodebuild` on the full project. Use this between major tasks:

```bash
cd ~/Documents/Projects/roadflare-ios
xcodebuild test \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tail -50
```

For faster iteration on SDK-only changes, `swift test --package-path RidestrSDK` is acceptable but DOES NOT catch app-target concurrency errors.

---

## Task 1: Add `RideHistoryEntry.Status` enum extension to SDK

**Files:**
- Modify: `RidestrSDK/Sources/RidestrSDK/Models/RoadflareModels.swift` (append after line 533, end of `RideHistoryEntry`)
- Modify: `RidestrSDK/Tests/RidestrSDKTests/Models/RoadflareModelsTests.swift` (append a new test suite or new tests in the existing suite)

- [ ] **Step 1.1: Write failing tests**

Append to `RoadflareModelsTests.swift` (find an existing `@Suite` or add a new one near the existing `RideHistoryEntry` tests):

```swift
@Test func statusEnumProjectsCompleted() {
    let entry = RideHistoryEntry(
        id: "r1", date: .now, status: "completed",
        counterpartyPubkey: String(repeating: "a", count: 64),
        pickupGeohash: "g1", dropoffGeohash: "g2",
        pickup: Location(latitude: 0, longitude: 0),
        destination: Location(latitude: 0, longitude: 0),
        fare: 10, paymentMethod: "cash"
    )
    #expect(entry.statusEnum == .completed)
}

@Test func statusEnumProjectsCancelled() {
    let entry = RideHistoryEntry(
        id: "r2", date: .now, status: "cancelled",
        counterpartyPubkey: String(repeating: "a", count: 64),
        pickupGeohash: "g1", dropoffGeohash: "g2",
        pickup: Location(latitude: 0, longitude: 0),
        destination: Location(latitude: 0, longitude: 0),
        fare: 0, paymentMethod: "cash"
    )
    #expect(entry.statusEnum == .cancelled)
}

@Test func statusEnumFailsOpenForUnknownStatus() {
    // Forward-compat: unrecognized statuses don't redact fare data
    let entry = RideHistoryEntry(
        id: "r3", date: .now, status: "ended_early_v3",
        counterpartyPubkey: String(repeating: "a", count: 64),
        pickupGeohash: "g1", dropoffGeohash: "g2",
        pickup: Location(latitude: 0, longitude: 0),
        destination: Location(latitude: 0, longitude: 0),
        fare: 25, paymentMethod: "cash"
    )
    #expect(entry.statusEnum == .completed)
}
```

- [ ] **Step 1.2: Run tests, verify failure**

```bash
swift test --package-path RidestrSDK --filter RoadflareModelsTests/statusEnumProjectsCompleted 2>&1 | tail -20
```

Expected: compile error — `statusEnum` is not a member of `RideHistoryEntry`. Or `Status` is not a type. That's the failure we want.

- [ ] **Step 1.3: Add the enum extension**

Append to `RoadflareModels.swift` after line 533 (end of the `RideHistoryEntry` struct including `hash(into:)`):

```swift
public extension RideHistoryEntry {
    /// Type-safe projection of `status`. Two known cases; unrecognized
    /// values fail-open to `.completed` so a future cross-platform status
    /// addition (e.g. `"ended_early"`) doesn't redact fare data on old clients.
    enum Status: String, Sendable {
        case completed
        case cancelled
    }

    /// Typed projection of the raw `status` string. Fails open to `.completed`.
    var statusEnum: Status { Status(rawValue: status) ?? .completed }
}
```

- [ ] **Step 1.4: Run tests, verify pass**

```bash
swift test --package-path RidestrSDK --filter RoadflareModelsTests 2>&1 | tail -20
```

Expected: all three new tests pass; no existing tests regress.

- [ ] **Step 1.5: Commit**

```bash
git add RidestrSDK/Sources/RidestrSDK/Models/RoadflareModels.swift \
        RidestrSDK/Tests/RidestrSDKTests/Models/RoadflareModelsTests.swift
git commit -m "$(cat <<'EOF'
feat(sdk): add RideHistoryEntry.Status enum projection

Additive: introduces a Status enum (.completed, .cancelled) and a
statusEnum computed property that fails open to .completed for any
unrecognized status string. Wire format and Codable shape unchanged.

Issue #65 prep — RideHistoryRow and RideCoordinator will start
writing/reading "cancelled" via this enum.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add `lastActiveRideIdentity` cache to `RideCoordinator`

This task introduces the cache field and its populate/clear sites WITHOUT yet calling `recordRideHistory(status: .cancelled)`. The wiring is mechanical and doesn't change observable behavior — Task 3 is what makes the cache actually do something.

**Files:**
- Modify: `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift`

- [ ] **Step 2.1: Add the cache type and property**

Add inside the `RideCoordinator` class, near the existing private state declarations (search for `private var stageTimeoutTask` or similar — exact placement is alongside other `private` instance state, before `init`). If no clean spot exists, place it immediately after the existing `currentFareEstimate` line (around `RideCoordinator.swift:36`):

```swift
/// Snapshot of the most recently active ride's identity, captured while
/// the session still holds it (in `sessionDidChangeStage` and on session
/// restore). Used to record cancelled-ride history entries after the SDK
/// has reset state. Cleared on every terminal outcome.
private var lastActiveRideIdentity: ActiveRideIdentity?

private struct ActiveRideIdentity {
    let confirmationEventId: String
    let driverPubkey: String
}
```

- [ ] **Step 2.2: Populate cache from `sessionDidChangeStage`**

Locate `public func sessionDidChangeStage(from: RiderStage, to: RiderStage)` (around line 417). Add a populate block at the very top of the method body, before any existing logic:

```swift
public func sessionDidChangeStage(from: RiderStage, to: RiderStage) {
    if to.isActiveRide,
       let confirmationId = session.confirmationEventId,
       let driverPubkey = session.driverPubkey {
        lastActiveRideIdentity = ActiveRideIdentity(
            confirmationEventId: confirmationId,
            driverPubkey: driverPubkey
        )
    }

    // ... existing chat subscribe / cleanup logic preserved unchanged ...
    if !from.isActiveRide && to.isActiveRide,
       let driverPubkey = session.driverPubkey,
       let confirmationId = session.confirmationEventId {
        chat.subscribeToChat(driverPubkey: driverPubkey, confirmationEventId: confirmationId)
    }
    if to == .idle || to == .completed {
        chat.cleanupAsync()
    }
}
```

- [ ] **Step 2.3: Populate cache from `restoreRideState`**

Locate `func restoreRideState()` (line 108). After the existing `currentFareEstimate` assignment block (lines 156-162, the `if let fareStr = saved.fareUSD ...` block), append:

```swift
        if session.stage.isActiveRide,
           let confirmationId = session.confirmationEventId,
           let driverPubkey = session.driverPubkey {
            lastActiveRideIdentity = ActiveRideIdentity(
                confirmationEventId: confirmationId,
                driverPubkey: driverPubkey
            )
        }
```

This sits just inside the closing `}` of `restoreRideState`. (`session.restore` does NOT call `emitStageChangeIfNeeded`, so the populate must happen here directly.)

- [ ] **Step 2.4: Clear cache from `sessionDidReachTerminal`**

Locate `public func sessionDidReachTerminal(_ outcome: RideSessionTerminalOutcome)` (around line 403). For now, just add the clear at the end of the method — the body still has its current shape:

```swift
public func sessionDidReachTerminal(_ outcome: RideSessionTerminalOutcome) {
    if case .completed = outcome {
        recordRideHistory()
    } else {
        let message = terminalMessage(for: outcome)
        clearCoordinatorUIState(clearError: message == nil)
        lastError = message
    }
    lastActiveRideIdentity = nil  // NEW
}
```

- [ ] **Step 2.5: Run full test suite to confirm nothing regressed**

```bash
xcodebuild test \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tail -50
```

Expected: all tests pass (this task adds dead-but-harmless cache machinery; behavior is unchanged).

- [ ] **Step 2.6: Commit**

```bash
git add RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift
git commit -m "$(cat <<'EOF'
refactor(coordinator): add lastActiveRideIdentity cache scaffolding

Introduces ActiveRideIdentity struct and lastActiveRideIdentity
property, populated from sessionDidChangeStage (active-stage entry)
and restoreRideState (post-restore active stage), cleared at every
terminal outcome. Cache is unused so far — Task 3 wires it into
recordRideHistory to fix the cancellation persistence path.

Issue #65 prep.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Refactor `recordRideHistory` and route cancellations through it

This is the behavioral core of the fix.

**Files:**
- Modify: `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift`
- Modify: `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift` (append new tests)

- [ ] **Step 3.1: Write the failing tests**

Append these new `@Test` functions to `RideCoordinatorTests.swift` after the existing `sessionDidReachTerminalBruteForcePinSetsMessage` test (line 893):

```swift
@MainActor
@Test func cancelByRiderPostConfirmationRecordsCancelledHistory() async throws {
    let (coordinator, _, _, history, _) = try await makeCoordinator()
    coordinator.session.restore(
        stage: .rideConfirmed,
        offerEventId: "offer",
        acceptanceEventId: rideCoordinatorAcceptanceEventId,
        confirmationEventId: rideCoordinatorConfirmationEventId,
        driverPubkey: String(repeating: "d", count: 64),
        pin: "1234",
        pinVerified: true,
        paymentMethod: "zelle",
        fiatPaymentMethods: ["zelle"]
    )
    coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
    coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
    coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
    // Production fires this when entering an active stage; mimicking it here.
    coordinator.sessionDidChangeStage(from: .driverAccepted, to: .rideConfirmed)

    coordinator.sessionDidReachTerminal(.cancelledByRider(reason: "Changed plans"))

    #expect(history.rides.count == 1)
    let entry = try #require(history.rides.first)
    #expect(entry.id == rideCoordinatorConfirmationEventId)
    #expect(entry.status == "cancelled")
    #expect(entry.fare == 0)
    #expect(entry.distance == nil)
    #expect(entry.duration == nil)
}

@MainActor
@Test func cancelByRiderPreConfirmationRecordsNothing() async throws {
    let (coordinator, _, _, history, _) = try await makeCoordinator()
    // No confirmationEventId → no cache populate, even if stage-change fires
    coordinator.session.restore(
        stage: .waitingForAcceptance,
        offerEventId: "offer",
        acceptanceEventId: nil,
        confirmationEventId: nil,
        driverPubkey: String(repeating: "d", count: 64),
        pin: nil,
        pinVerified: false,
        paymentMethod: "zelle",
        fiatPaymentMethods: ["zelle"]
    )
    coordinator.sessionDidChangeStage(from: .idle, to: .waitingForAcceptance)

    coordinator.sessionDidReachTerminal(.cancelledByRider(reason: "Changed plans"))

    #expect(history.rides.isEmpty)
}

@MainActor
@Test func cancelByDriverPostConfirmationRecordsCancelledHistory() async throws {
    let (coordinator, _, _, history, _) = try await makeCoordinator()
    coordinator.session.restore(
        stage: .rideConfirmed,
        offerEventId: "offer",
        acceptanceEventId: rideCoordinatorAcceptanceEventId,
        confirmationEventId: rideCoordinatorConfirmationEventId,
        driverPubkey: String(repeating: "d", count: 64),
        pin: "1234",
        pinVerified: true,
        paymentMethod: "zelle",
        fiatPaymentMethods: ["zelle"]
    )
    coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
    coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
    coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)
    coordinator.sessionDidChangeStage(from: .driverAccepted, to: .rideConfirmed)

    coordinator.sessionDidReachTerminal(.cancelledByDriver(reason: "Driver unavailable"))

    #expect(history.rides.count == 1)
    let entry = try #require(history.rides.first)
    #expect(entry.status == "cancelled")
    #expect(entry.fare == 0)
    // Driver-cancel surfaces a toast — verify that still works alongside the new persistence
    #expect(coordinator.lastError == "Driver cancelled the ride: Driver unavailable")
}

@MainActor
@Test func forceEndRideRecordsCompletedWithEstimate() async throws {
    let (coordinator, _, _, history, _) = try await makeCoordinator()
    coordinator.session.restore(
        stage: .inProgress,
        offerEventId: "offer",
        acceptanceEventId: rideCoordinatorAcceptanceEventId,
        confirmationEventId: rideCoordinatorConfirmationEventId,
        driverPubkey: String(repeating: "d", count: 64),
        pin: "1234",
        pinVerified: true,
        paymentMethod: "zelle",
        fiatPaymentMethods: ["zelle"]
    )
    coordinator.pickupLocation = Location(latitude: 40.71, longitude: -74.01, address: "Penn Station")
    coordinator.destinationLocation = Location(latitude: 40.76, longitude: -73.98, address: "Central Park")
    coordinator.currentFareEstimate = FareEstimate(distanceMiles: 5, durationMinutes: 15, fareUSD: 12.5)

    await coordinator.forceEndRide()

    #expect(history.rides.count == 1)
    let entry = try #require(history.rides.first)
    #expect(entry.status == "completed")
    #expect(entry.fare == Decimal(12.5))
    #expect(entry.distance == 5)
    #expect(entry.duration == 15)
}

@MainActor
@Test func restoreRideStateInActiveStagePopulatesCacheForLaterCancel() async throws {
    let (coordinator, _, _, history, persistence) = try await makeCoordinator(clearRidePersistence: false)
    // Seed persistence with an active ride state.
    let driverPubkey = String(repeating: "d", count: 64)
    let saved = PersistedRideState(
        stage: RiderStage.rideConfirmed.rawValue,
        offerEventId: "offer",
        acceptanceEventId: rideCoordinatorAcceptanceEventId,
        confirmationEventId: rideCoordinatorConfirmationEventId,
        driverPubkey: driverPubkey,
        pin: "1234",
        pinVerified: true,
        paymentMethodRaw: "zelle",
        fiatPaymentMethodsRaw: ["zelle"],
        fareUSD: "12.50",
        fareDistanceMiles: 5,
        fareDurationMinutes: 15
    )
    persistence.saveRaw(saved)
    coordinator.restoreRideState()

    // Cache should now be populated. Fire a cancel terminal directly.
    coordinator.sessionDidReachTerminal(.cancelledByRider(reason: "Changed plans"))

    #expect(history.rides.count == 1)
    #expect(history.rides.first?.status == "cancelled")
    #expect(history.rides.first?.fare == 0)
}

@MainActor
@Test func lastActiveRideIdentityClearedAfterTerminal() async throws {
    let (coordinator, _, _, history, _) = try await makeCoordinator()
    // First ride: post-confirmation cancel → records.
    coordinator.session.restore(
        stage: .rideConfirmed,
        offerEventId: "offer-1",
        acceptanceEventId: rideCoordinatorAcceptanceEventId,
        confirmationEventId: rideCoordinatorConfirmationEventId,
        driverPubkey: String(repeating: "d", count: 64),
        pin: "1234",
        pinVerified: true,
        paymentMethod: "zelle",
        fiatPaymentMethods: ["zelle"]
    )
    coordinator.sessionDidChangeStage(from: .driverAccepted, to: .rideConfirmed)
    coordinator.sessionDidReachTerminal(.cancelledByRider(reason: "First cancel"))
    #expect(history.rides.count == 1)

    // Second "ride": pre-confirmation cancel. Cache must NOT inherit from first ride.
    coordinator.session.reset()
    coordinator.session.restore(
        stage: .waitingForAcceptance,
        offerEventId: "offer-2",
        acceptanceEventId: nil,
        confirmationEventId: nil,
        driverPubkey: String(repeating: "d", count: 64),
        pin: nil,
        pinVerified: false,
        paymentMethod: "zelle",
        fiatPaymentMethods: ["zelle"]
    )
    coordinator.sessionDidChangeStage(from: .idle, to: .waitingForAcceptance)
    coordinator.sessionDidReachTerminal(.cancelledByRider(reason: "Second cancel"))

    // Still 1 — second ride did not produce an entry from stale cache.
    #expect(history.rides.count == 1)
}
```

- [ ] **Step 3.2: Run tests, verify failure**

```bash
xcodebuild test \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:RoadFlareTests/RideCoordinatorTests \
  -quiet 2>&1 | tail -50
```

Expected: the six new tests fail (cancellation tests because no entry is written; forceEnd test because fare is 0 not estimate; restore test because no entry; lastActive test passes "accidentally" since pre-confirmation cancel was already a no-op — that one may need recheck after Task 3.3).

- [ ] **Step 3.3: Refactor `recordRideHistory`**

Replace the existing `recordRideHistory` body (currently at `RideCoordinator.swift:334`) with:

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
    )
    rideHistory.addRide(entry)
    backupRideHistory()
}
```

- [ ] **Step 3.4: Update `sessionDidReachTerminal` to dispatch cancellations**

Replace the body of `sessionDidReachTerminal` (the version with the trailing `lastActiveRideIdentity = nil` line added in Task 2) with:

```swift
public func sessionDidReachTerminal(_ outcome: RideSessionTerminalOutcome) {
    switch outcome {
    case .completed:
        recordRideHistory()
    case .cancelledByRider, .cancelledByDriver:
        recordRideHistory(status: .cancelled)
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

- [ ] **Step 3.5: Run tests, verify pass**

```bash
xcodebuild test \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:RoadFlareTests/RideCoordinatorTests \
  -quiet 2>&1 | tail -50
```

Expected: all six new tests pass; existing `sessionDidReachTerminal*` tests (lines 758, 815, 836, 856, 876) remain green.

If `sessionDidReachTerminalCancelledByRiderClearsUIAndChatWithoutError` (line 815) or `sessionDidReachTerminalCancelledByDriverSurfacesMessage` (line 836) now fail, debug — they SHOULD remain green because those tests never populate the cache (no `sessionDidChangeStage` call, no restore in active stage), so `recordRideHistory(status: .cancelled)` early-returns without changing observable state.

- [ ] **Step 3.6: Commit**

```bash
git add RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift \
        RoadFlare/RoadFlareTests/RideCoordinatorTests.swift
git commit -m "$(cat <<'EOF'
fix(coordinator): persist cancelled rides + use estimate on forceEnd

Routes .cancelledByRider/.cancelledByDriver through recordRideHistory
with status="cancelled", fare=0, distance/duration nil — using the
lastActiveRideIdentity cache (populated in Task 2) since the SDK
clears session state before the terminal callback fires for cancel
outcomes.

forceEndRide already runs before session reset, so it still uses live
session IDs. With currentFareEstimate reliably populated, the
$0-on-early-end bug is fixed.

.expired and .bruteForcePin keep the no-history behavior, matching
the Ridestr Android precedent.

Fixes #65.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: `RideHistoryRow` status field + cancelled fareLabel

**Files:**
- Modify: `RoadFlare/RoadFlareCore/Presentation/RideHistoryRow.swift`
- Modify: `RoadFlare/RoadFlareTests/Presentation/PresentationTypesTests.swift` (append new tests)

- [ ] **Step 4.1: Write failing tests**

Append to `PresentationTypesTests.swift` after the existing `isCompletedFalseForCancelledStatus` test (line 533):

```swift
@Test func cancelledStatusProducesCancelledFareLabel() {
    let row = RideHistoryRow.from(makeEntry(status: "cancelled", fare: 0, distance: nil, duration: nil))
    #expect(row.fareLabel == "Cancelled")
}

@Test func cancelledStatusProducesNilDistanceAndDuration() {
    let row = RideHistoryRow.from(makeEntry(status: "cancelled", fare: 0, distance: nil, duration: nil))
    #expect(row.distanceLabel == nil)
    #expect(row.durationLabel == nil)
}

@Test func cancelledStatusSetsIsCancelledTrue() {
    let row = RideHistoryRow.from(makeEntry(status: "cancelled", fare: 0))
    #expect(row.isCancelled == true)
    #expect(row.isCompleted == false)
}

@Test func completedStatusSetsIsCancelledFalse() {
    let row = RideHistoryRow.from(makeEntry(status: "completed"))
    #expect(row.isCancelled == false)
    #expect(row.isCompleted == true)
}

@Test func completedZeroFarePreservesEmDashFallback() {
    // Legacy synced entries may have fare=0 with status=completed.
    // Behavior preserved: shown as em-dash, not "Cancelled".
    let row = RideHistoryRow.from(makeEntry(status: "completed", fare: 0))
    #expect(row.fareLabel == "–")
    #expect(row.isCancelled == false)
}
```

- [ ] **Step 4.2: Run tests, verify failure**

```bash
xcodebuild test \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:RoadFlareTests/PresentationTypesTests \
  -quiet 2>&1 | tail -30
```

Expected: compile error — `isCancelled` is not a member of `RideHistoryRow`. Also: cancelled-status currently produces `"–"` (legacy fare==0 fallback), not `"Cancelled"`.

- [ ] **Step 4.3: Update `RideHistoryRow` shape**

Open `RoadFlare/RoadFlareCore/Presentation/RideHistoryRow.swift`. Replace the `isCompleted` field (line 50):

**OLD (line 50):**
```swift
public let isCompleted: Bool
```

**NEW (replaces line 50):**
```swift
/// Underlying status used to drive UI branches.
public let status: RideHistoryEntry.Status

/// True if `status == .completed`. Computed for backward compat with
/// existing callers (`HistoryTab`, presentation tests).
public var isCompleted: Bool { status == .completed }

/// True if `status == .cancelled`. Drives red "Cancelled" rendering.
public var isCancelled: Bool { status == .cancelled }
```

- [ ] **Step 4.4: Update `RideHistoryRow.from(_:)` factory**

Replace the body of `from(_:)` (the `fareLabel` derivation block, lines 64-77, and the entry-construction `isCompleted: entry.status == "completed"` at line 82). The full new factory:

```swift
public static func from(_ entry: RideHistoryEntry) -> RideHistoryRow {
    let fareLabel: String
    switch entry.statusEnum {
    case .cancelled:
        fareLabel = "Cancelled"
    case .completed:
        if entry.fare == 0 {
            fareLabel = "–"
        } else {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.locale = Locale(identifier: "en_US")
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
            fareLabel = formatter.string(from: entry.fare as NSDecimalNumber) ?? "$\(entry.fare)"
        }
    }

    let distanceLabel = entry.distance.map { String(format: "%.1f mi", $0) }
    let durationLabel = entry.duration.map { "\($0) min" }

    return RideHistoryRow(
        id: entry.id,
        date: entry.date,
        counterpartyName: entry.counterpartyName,
        pickupAddress: entry.pickup.address,
        destinationAddress: entry.destination.address,
        fareLabel: fareLabel,
        distanceLabel: distanceLabel,
        durationLabel: durationLabel,
        paymentMethodLabel: PaymentMethod.displayName(for: entry.paymentMethod),
        status: entry.statusEnum
    )
}
```

(Note the final argument: `status: entry.statusEnum` instead of `isCompleted: entry.status == "completed"`.)

- [ ] **Step 4.5: Run tests, verify pass**

```bash
xcodebuild test \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:RoadFlareTests/PresentationTypesTests \
  -only-testing:RoadFlareTests/AppStatePresentationTests \
  -quiet 2>&1 | tail -50
```

Expected: all new tests pass; existing `isCompleted*` tests at lines 526 + 531 still pass (`isCompleted` is now computed but returns the same Bool); existing `AppStatePresentationTests` line 265 (`isCompleted == true`) still passes.

- [ ] **Step 4.6: Commit**

```bash
git add RoadFlare/RoadFlareCore/Presentation/RideHistoryRow.swift \
        RoadFlare/RoadFlareTests/Presentation/PresentationTypesTests.swift
git commit -m "$(cat <<'EOF'
feat(presentation): cancelled-status fareLabel + isCancelled projection

RideHistoryRow now stores status (RideHistoryEntry.Status) and
projects both isCompleted and isCancelled as computed properties.
The from(_:) factory renders "Cancelled" in place of dollars when
status is cancelled; em-dash fallback preserved for legacy completed
entries with fare=0.

Existing isCompleted callers (HistoryTab + 3 tests) continue to work
without change.

Issue #65.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: appOrigin filter in `AppState.rideHistoryRows`

**Files:**
- Modify: `RoadFlare/RoadFlareCore/ViewModels/AppState+Presentation.swift`
- Modify: `RoadFlare/RoadFlareTests/AppState/AppStatePresentationTests.swift` (append new test)

- [ ] **Step 5.1: Write failing test**

Append to `AppStatePresentationTests.swift` inside the existing `@Suite("AppState.rideHistoryRows")` (`AppStateRideHistoryRowsTests` struct, around line 235), after the `mapsEntryToRow` test:

```swift
@Test func filtersOutNonRoadflareAppOriginEntries() {
    let (appState, rideHistory, _) = makeAppStateWithInMemoryStores()

    // Roadflare-origin entry: should appear.
    let roadflareEntry = RideHistoryEntry(
        id: "roadflare-1",
        date: Date(timeIntervalSince1970: 1_000),
        counterpartyPubkey: fakePubkeyA,
        counterpartyName: "Driver A",
        pickupGeohash: "abc", dropoffGeohash: "def",
        pickup: Location(latitude: 0, longitude: 0),
        destination: Location(latitude: 1, longitude: 1),
        fare: Decimal(10),
        paymentMethod: "cash"
        // appOrigin defaults to "roadflare"
    )
    // Ridestr-origin entry (synced from Android rider app): should be hidden.
    let ridestrEntry = RideHistoryEntry(
        id: "ridestr-1",
        date: Date(timeIntervalSince1970: 2_000),
        counterpartyPubkey: fakePubkeyA,
        counterpartyName: "Driver B",
        pickupGeohash: "abc", dropoffGeohash: "def",
        pickup: Location(latitude: 0, longitude: 0),
        destination: Location(latitude: 1, longitude: 1),
        fare: Decimal(20),
        paymentMethod: "cash",
        appOrigin: "ridestr"
    )
    rideHistory.addRide(roadflareEntry)
    rideHistory.addRide(ridestrEntry)

    let rows = appState.rideHistoryRows
    #expect(rows.count == 1)
    #expect(rows.first?.id == "roadflare-1")
}
```

- [ ] **Step 5.2: Run test, verify failure**

```bash
xcodebuild test \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:RoadFlareTests/AppStatePresentationTests/AppStateRideHistoryRowsTests/filtersOutNonRoadflareAppOriginEntries \
  -quiet 2>&1 | tail -30
```

Expected: test fails (`rows.count` is 2, not 1) — no filter applied yet.

- [ ] **Step 5.3: Add the filter**

Open `RoadFlare/RoadFlareCore/ViewModels/AppState+Presentation.swift`. Replace `rideHistoryRows` (line 65):

**OLD:**
```swift
public var rideHistoryRows: [RideHistoryRow] {
    rideHistory.rides.map { RideHistoryRow.from($0) }
}
```

**NEW:**
```swift
public var rideHistoryRows: [RideHistoryRow] {
    rideHistory.rides
        .filter { $0.appOrigin == "roadflare" }
        .map { RideHistoryRow.from($0) }
}
```

- [ ] **Step 5.4: Run test, verify pass**

```bash
xcodebuild test \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:RoadFlareTests/AppStatePresentationTests \
  -quiet 2>&1 | tail -30
```

Expected: all `AppStateRideHistoryRowsTests` tests pass, including the existing `mapsEntryToRow` (the static `fakeEntry` defaults to `appOrigin == "roadflare"`).

- [ ] **Step 5.5: Commit**

```bash
git add RoadFlare/RoadFlareCore/ViewModels/AppState+Presentation.swift \
        RoadFlare/RoadFlareTests/AppState/AppStatePresentationTests.swift
git commit -m "$(cat <<'EOF'
feat(history): filter rideHistoryRows by appOrigin == roadflare

Required for proper cross-app coexistence when a user runs both
RoadFlare iOS and Ridestr Android against the same account. Each app
publishes Kind 30174 to a shared d-tag and merges other-origin entries
into the local store on read; this filter limits the iOS history view
to its own origin, mirroring Ridestr Android's filter.

Issue #65.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Cancelled-row fare-color override in `HistoryTab.swift`

**Files:**
- Modify: `RoadFlare/RoadFlare/Views/History/HistoryTab.swift`

- [ ] **Step 6.1: Make the one-line change**

Open `RoadFlare/RoadFlare/Views/History/HistoryTab.swift`. Locate `RideHistoryCard` (line 69). The fare label is rendered at lines 83-85:

```swift
Text(row.fareLabel)
    .font(RFFont.headline(18))
    .foregroundColor(Color.rfPrimary)
```

Change line 85 (the `.foregroundColor(...)` line) to:

```swift
    .foregroundColor(row.isCancelled ? Color.rfError : Color.rfPrimary)
```

The font and Text contents are unchanged. The `FlareIndicator` at line 74 already uses `.rfError` for non-completed rows via `row.isCompleted`, so it auto-flips for cancelled entries with no further edit.

- [ ] **Step 6.2: Build and run full test suite**

```bash
xcodebuild test \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tail -50
```

Expected: build succeeds; all tests pass.

- [ ] **Step 6.3: Commit**

```bash
git add RoadFlare/RoadFlare/Views/History/HistoryTab.swift
git commit -m "$(cat <<'EOF'
feat(ui): render cancelled-ride fare label in red

RideHistoryCard now swaps the fare-label foreground color to
Color.rfError when row.isCancelled. The label text itself is
"Cancelled" (set in RideHistoryRow.from), so the row reads as
"Cancelled" in red where dollars previously appeared.

Issue #65.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Final verification

- [ ] **Step 7.1: Run the full Xcode test suite**

```bash
cd ~/Documents/Projects/roadflare-ios
xcodebuild test \
  -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet 2>&1 | tail -80
```

Expected: all tests pass, no warnings introduced. If concurrency warnings or new compile errors appear in the app target that didn't appear in `swift test`, this is the catch-net.

- [ ] **Step 7.2: Run `gitnexus_detect_changes`**

Per `.claude/CLAUDE.md`, before declaring done:

```bash
npx -y gitnexus@1.5.3 analyze
```

Then via the GitNexus MCP, verify the changed-symbols list matches expectations: `RideHistoryEntry` (extension only), `RideCoordinator.recordRideHistory`, `RideCoordinator.sessionDidReachTerminal`, `RideCoordinator.sessionDidChangeStage`, `RideCoordinator.restoreRideState`, `RideHistoryRow`, `RideHistoryRow.from`, `AppState.rideHistoryRows`, `RideHistoryCard`. Nothing else.

- [ ] **Step 7.3: Manual smoke check (optional but recommended)**

Build and run on simulator, drive a ride to the rideConfirmed stage, then:
1. Tap "Cancel Ride" → confirm in alert. Verify history shows "Cancelled" in red where the fare would be.
2. Drive another ride to inProgress, tap "Close Ride" before driver completion. Verify history shows the estimated fare normally (not "$0" or "–").

- [ ] **Step 7.4: Verify all acceptance criteria from the spec**

Check off against the spec's "In scope" list:
- [x] Persist cancelled rides to local + Nostr-backed history
- [x] Fix forceEndRide $0 fallback
- [x] appOrigin display filter
- [x] "Cancelled" red label UI
- [x] Test coverage

If all green: link the PR to issue #65 and the spec doc.

---

## Self-review checklist

After writing the plan, the author ran the following checks:

**Spec coverage:** Each "In scope" bullet from the spec maps to a task — Status enum (Task 1), persistence + cache (Tasks 2 + 3), forceEnd fix (Task 3), appOrigin filter (Task 5), UI (Tasks 4 + 6), tests (interleaved). The "Out of scope" items (schema bump, expired/bruteForcePin persistence, detail-view UX) are not implemented — correct.

**Placeholder scan:** No "TBD", "TODO", or "implement later". Every code step has full code. Every test step has the assertion. The one verification command per task uses an explicit `xcodebuild` invocation.

**Type consistency:** `ActiveRideIdentity` defined in Task 2 → used in Task 3. `RideHistoryEntry.Status` defined in Task 1 → used in Tasks 3, 4. `lastActiveRideIdentity` named consistently across Tasks 2, 3. `isCancelled` introduced in Task 4, consumed in Task 6.
