# ADR-0012: Coordinator-side ride identity cache

**Status:** Active
**Created:** 2026-04-28
**Tags:** architecture, coordinator, sdk-boundary

## Context

When `RiderRideSession` reaches a cancellation terminal outcome (`.cancelledByRider`, `.cancelledByDriver`, `.bruteForcePin`), the SDK clears `confirmationEventId` and `driverPubkey` from the state machine **before** invoking `RiderRideSessionDelegate.sessionDidReachTerminal(_:)`. Concretely:

- `RideStateMachine.swift`'s `.cancel` event handler returns `RideContext(riderPubkey: current.riderPubkey)`, which atomically replaces the context and nils every other field.
- `RiderRideSession.cancelRide` calls `stateMachine.reset()` (also atomic context replacement) before firing the delegate.
- `handleDriverStateEvent` and `handleCancellationEvent` rely on `receiveCancellationEvent`/`receiveDriverStateEvent` having already mutated the state machine via the same `.cancel` event.

The `.completed` outcome is the asymmetric exception — the state machine stays at `.completed` (no reset), so session IDs remain readable when the delegate fires. That's why the pre-existing completion path in `RideCoordinator.recordRideHistory` could read `session.confirmationEventId` directly.

This asymmetry blocks a naive implementation of "persist cancelled rides to history" in the coordinator: by the time the cancellation terminal callback reaches the app layer, the IDs needed to construct a `RideHistoryEntry` are already gone.

## Decision

The coordinator caches ride identity (`confirmationEventId`, `driverPubkey`) into a `lastActiveRideIdentity: ActiveRideIdentity?` field while session state still holds it, and uses that cache as a fallback in `recordRideHistory` when the live session fields are nil.

The cache is populated at two sites:

1. **`sessionDidChangeStage(from:to:)`** — when transitioning into a stage where `to.isActiveRide == true` (`.rideConfirmed`, `.enRoute`, `.driverArrived`, `.inProgress`) and both IDs are non-nil.
2. **`restoreRideState()`** — immediately after `session.restore(...)` if the restored stage is active and both IDs are non-nil. Required because `session.restore` does not call `emitStageChangeIfNeeded`, so `sessionDidChangeStage` is not fired during restore.

The cache is cleared unconditionally at the end of `sessionDidReachTerminal(_:)` for every outcome, preventing a new ride from inheriting stale identity.

`recordRideHistory` reads live session IDs first and falls back to cached identity only when both live fields are nil — preserving the original code path for `.completed` and `forceEndRide`, which both run before any state reset.

## Rationale

The decision deliberately chooses **app-layer caching** over **SDK contract change** for three reasons:

1. **SDK API stability.** Changing `RiderRideSessionDelegate` (e.g., enriching the terminal outcome enum with associated IDs, or adding a `sessionWillReachTerminal` hook) is a breaking change for every conformer. The cache is purely additive coordinator state.
2. **Smaller blast radius.** The fix touches `RideCoordinator` and three call-site stubs. An SDK ordering change would touch `cancelRide`, both event handlers, every test that asserts post-terminal session state, and any future consumer relying on the documented contract that "session is reset when terminal fires for cancellations."
3. **Cross-platform symmetry.** The Android Ridestr rider app (`rider-app/src/main/java/com/ridestr/rider/viewmodels/RiderViewModel.kt`) uses the same pattern: capture `session.confirmationEventId` / `session.acceptance?.driverPubKey` into local variables BEFORE invoking cancel, then use the captured values inside the launched coroutine that persists history. Coordinator-level capture is the established cross-platform pattern.

## Alternatives Considered

- **Add `confirmationEventId` and `driverPubkey` to the `RideSessionTerminalOutcome` enum cases.** Cleanest from a contract perspective — terminal outcomes become self-contained — but breaks every pattern-match callsite, requires nilable IDs to handle pre-confirmation cancellation, and the SDK still has to capture the IDs before the reset. The SDK code complexity is similar; the app code is simpler at the cost of every consumer in the callgraph.
- **Reorder the SDK so `sessionDidReachTerminal` fires BEFORE `stateMachine.reset()` in cancel paths.** Would align cancel with completed semantics. Rejected because the contract change is silent (no compile-time signal) and existing tests in `RideCoordinatorTests.swift` (lines 815-893) implicitly depend on the current ordering — they don't call `session.restore` for cancellation tests precisely because the contract says session state is gone by the time the callback fires.
- **Move history recording into the SDK.** `RideHistoryRepository` already lives in the SDK, so this isn't a layering violation in principle. Rejected because it conflates protocol semantics (when does a ride happen) with persistence policy (which app's history is this written to, with what `appOrigin`), and `RideHistoryEntry` construction needs UI-level state (`pickupLocation`, `currentFareEstimate`) that the SDK doesn't track.

## Consequences

- **Enables persistence of cancelled rides.** `.cancelledByRider` and `.cancelledByDriver` now flow through `recordRideHistory(status: .cancelled)` and produce history entries with `status="cancelled"`, `fare=0`, distance/duration nil — matching the Ridestr Android pattern.
- **Pre-confirmation cancellations correctly drop.** `confirmationEventId` is only set when transitioning into `.rideConfirmed`; the cache populate guards `let confirmationId = session.confirmationEventId`, so pre-confirmation stages never populate the cache, and `recordRideHistory`'s "no live IDs and no cache" branch returns early. This matches Ridestr's `shouldSaveCancelledHistory = rideStage in [RIDE_CONFIRMED, DRIVER_ARRIVED, IN_PROGRESS]` gate without an explicit stage check.
- **`.expired` and `.bruteForcePin` keep no-history behavior.** Mirrors Ridestr precedent. If we want to persist these later, we route them through the same `recordRideHistory(status: .cancelled)` call — the cache machinery already supports it.
- **Load-bearing call ordering at terminal sites.** `recordRideHistory` reads coordinator state (`pickupLocation`, `destinationLocation`, `currentFareEstimate`); `clearCoordinatorUIState` zeroes those fields. The terminal-handler ordering (record before clear) is now load-bearing. Documented inline at `RideCoordinator.recordRideHistory`'s doc comment.
- **Tests document the populate path explicitly.** `RideCoordinatorTests` cancellation tests now call `coordinator.sessionDidChangeStage(from: .driverAccepted, to: .rideConfirmed)` after `session.restore` to mimic the production populate point. Existing tests at lines 815-893 that don't call this still pass — they correctly model the "no cache, no record" path.

## Affected Files

- `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift` — cache field + populate sites + `recordRideHistory` refactor + `sessionDidReachTerminal` switch
- `RidestrSDK/Sources/RidestrSDK/Models/RoadflareModels.swift` — `RideHistoryEntry.Status` enum + `statusEnum` projection (additive; supports both completed and cancelled cases)
- `RoadFlare/RoadFlareCore/Presentation/RideHistoryRow.swift` — `status: RideHistoryEntry.Status` stored property + `isCancelled` computed property; `from(_:)` produces "Cancelled" `fareLabel` for cancelled entries
- `RoadFlare/RoadFlareCore/ViewModels/AppState+Presentation.swift` — `appOrigin == "roadflare"` filter on `rideHistoryRows` for cross-app coexistence
- `RoadFlare/RoadFlare/Views/History/HistoryTab.swift` — `Color.rfError` foreground when `row.isCancelled`
- `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift` — six new tests covering rider-cancel post-confirmation, rider-cancel pre-confirmation, driver-cancel post-confirmation, forceEnd-with-estimate, restore-then-cancel, and post-terminal cache clear
- `RoadFlare/RoadFlareTests/Presentation/PresentationTypesTests.swift` — five new tests for cancelled `fareLabel`, `isCancelled` projection, and em-dash legacy fallback
- `RoadFlare/RoadFlareTests/AppState/AppStatePresentationTests.swift` — `filtersOutNonRoadflareAppOriginEntries`
- `RidestrSDK/Tests/RidestrSDKTests/Models/RoadflareModelsTests.swift` — three `statusEnum` projection tests
