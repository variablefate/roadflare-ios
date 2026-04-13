# ADR-0007: Extract Ride-History Publish Logic to RideHistorySyncCoordinator

**Status:** Active
**Created:** 2026-04-13
**Tags:** refactor, sdk, architecture, sync, coordinator

## Context

Ride-history sync has two code paths that both touch `.rideHistory` dirty state, and they conflict in a subtle way.

**Passive path (`SyncDomainTracker`):** wires a callback on the `RideHistoryRepository` mutation hook so that any `addRide`, `removeRide`, `restoreFromBackup`, `mergeFromBackup`, or `clearAll` marks the domain dirty:

```swift
rideHistory.onRidesChanged = { [weak store] in
    store?.markDirty(.rideHistory)
}
```

This fires on relay-side restores during startup sync. When `restoreFromBackup` is called because the relay returned a newer backup, or when `mergeFromBackup` adds relay-authoritative rides that do not already exist locally, the passive path marks `.rideHistory` dirty — semantically wrong, because the local state was just *synchronised from* the relay, not changed in a way that needs publishing back. Both `restoreFromBackup` and `mergeFromBackup` are relay-authoritative operations, not user actions.

**Active path (`RideCoordinator.backupRideHistory()`):** publishes immediately and marks dirty only on failure:

```swift
Task {
    do {
        let content = RideHistoryBackupContent(rides: rideHistory.rides)
        let event = try await service.publishRideHistoryBackup(content)
        syncStore.markPublished(.rideHistory, at: event.createdAt)
    } catch {
        syncStore.markDirty(.rideHistory)
    }
}
```

The active path already handles dirty-on-failure, so the passive path's `markDirty` is fully redundant for the mutation case. The only genuine passive safety net is the reconnect-retry path (`flushPendingSyncPublishes` checks `isDirty`), which is not wired through `SyncDomainTracker` and is not changed.

The publish logic in `backupRideHistory()` also lives in the wrong layer: `RideCoordinator` is app-side view-model glue, but the decision of *how* to publish ride history and *when* to mark the domain dirty is protocol-level knowledge that belongs in the SDK alongside `ProfileBackupCoordinator`, which already owns the same pattern for Kind 30177.

## Decision

Introduce `RideHistorySyncCoordinator` (SDK, `public final class`) as the single owner of ride-history publish-and-mark logic:

- **`RideHistorySyncCoordinator`** (SDK): accepts the `RideHistoryRepository`, `RidestrService`, and `SyncStore` dependencies; exposes a single `sync()` method that publishes, calls `markPublished` on success, and calls `markDirty` on failure. It mirrors the publish-mark *responsibility* of `ProfileBackupCoordinator` (the same pattern applied to Kind 30078 instead of Kind 30177), but is a simplified subset: there is no republish-on-dirty loop (ride history has no concurrent republish requirement) and no template field. Reconnect-retry is handled by `flushPendingSyncPublishes`, not by a loop inside the coordinator.
- **`SyncDomainTracker`** (SDK, MODIFY): remove the `rideHistory.onRidesChanged` callback wiring. The coordinator's `catch { markDirty }` is the only dirty-setter for this domain outside of `flushPendingSyncPublishes`.
- **`RideCoordinator.backupRideHistory()`** (app, MODIFY): replace the inline `Task { publish… }` body with a call to `RideHistorySyncCoordinator.sync()`.
- **`SyncCoordinator`** (app, MODIFY): construct and hold a `RideHistorySyncCoordinator` instance, passing it to `RideCoordinator`.

## Rationale

Protocol-level publish logic belongs in the SDK. The "publish ride history backup then markPublished / markDirty" sequence is no different in kind from `ProfileBackupCoordinator`'s sequence for Kind 30177, and it carries the same requirement that any future Ridestr client implement it identically. Duplicating protocol semantics in the app layer repeats the mistake that ADR-0002 and ADR-0004 corrected for repositories.

Removing the passive `onRidesChanged` wiring eliminates the false-dirty problem at startup: `restoreFromBackup` no longer triggers a dirty flag, so the reconnect-retry path will not attempt to re-publish content that was just restored from the relay.

Making the coordinator the sole dirty-setter (outside of `flushPendingSyncPublishes`) creates a simple, auditable rule: `.rideHistory` becomes dirty if and only if a publish attempt fails. This is the correct semantics for an optimistic-publish-with-retry model.

## Alternatives Considered

- **Keep both paths, accept redundancy** — rejected. The passive path marks dirty during `restoreFromBackup` at startup, which is semantically wrong: it causes the next flush to re-publish content we just restored from the relay. Redundant dirty-setting also makes it harder to reason about when the domain is actually out of sync.
- **Move publish into the `SyncDomainTracker` callback directly** — rejected. `SyncDomainTracker` is for `markDirty` wiring only; introducing `async` publish side-effects into a synchronous callback violates its single responsibility and creates a new class of re-entrancy risk.
- **Make `backupRideHistory()` call `markDirty` instead of publishing** — rejected. Deferring to `flushPendingSyncPublishes` loses the immediate-publish guarantee for online sessions. A user adding a ride while connected should not have to wait for the next reconnect event to back it up.

## Consequences

- `SyncDomainTracker` no longer holds a callback on `RideHistoryRepository`. The coordinator's `catch { markDirty }` is the only dirty-setter for `.rideHistory` outside of `flushPendingSyncPublishes`.
- `restoreFromBackup` and `mergeFromBackup` during startup sync no longer produce a spurious dirty flag.
- `RideHistorySyncCoordinator` is SDK-testable without iOS dependencies, consistent with `ProfileBackupCoordinator`.
- `RideCoordinator.backupRideHistory()` becomes a thin delegation stub — protocol-level logic is no longer duplicated in the app layer.
- `RoadflareDomainService.publishRideHistoryAndMark(from:syncStore:)` is **NOT removed** and is **NOT changed**. It continues to be called by `SyncCoordinator.flushPendingSyncPublishes` and `performStartupSync` — those paths do not route through the coordinator. `RideHistorySyncCoordinator.sync()` calls `publishRideHistoryBackup(_:)` directly and handles `markPublished`/`markDirty` itself. `RoadflareDomainService.swift` is therefore not in Affected Files.
- `SyncCoordinator.flushPendingSyncPublishes` is intentionally NOT changed to route through the coordinator. It continues to call `service.publishRideHistoryAndMark` directly for the reconnect-flush path. The coordinator's `markDirty`-on-failure sets the dirty flag that `flushPendingSyncPublishes` will eventually act on.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/RoadFlare/RideHistorySyncCoordinator.swift` (CREATE)
- `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/RideHistorySyncCoordinatorTests.swift` (CREATE)
- `decisions/0007-ride-history-sync-coordinator.md` (CREATE — this file)
- `RoadFlare/RoadFlareCore/ViewModels/SyncCoordinator.swift` (MODIFY)
- `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift` (MODIFY)
- `RidestrSDK/Sources/RidestrSDK/RoadFlare/SyncDomainTracker.swift` (MODIFY)
- `RoadFlare/RoadFlare/Views/History/HistoryTab.swift` (NO CHANGE)
