# ADR-0001: Decompose AppState god object into coordinator classes

**Status:** Active
**Created:** 2026-04-01
**Tags:** refactor, architecture, lifecycle, coordinator-pattern

## Context

`AppState.swift` grew to 727 lines as a single `@MainActor @Observable` class owning: auth lifecycle, SDK service initialization, sync orchestration for 4 Nostr domains, publish methods, connection watchdog, identity replacement, and UI state. Flagged at the 99th percentile hotspot with 19 co-change partners. A sync regression (stale callback captures after logout) traced directly to too many lifecycle concerns in one class.

## Decision

Extract two focused coordinator classes:

1. **`SyncCoordinator`** owns Nostr sync orchestration — startup resolution, publish methods, dirty-tracking callback wiring, and reconnect flushing.
2. **`ConnectionCoordinator`** owns the periodic relay connectivity watchdog task.

`AppState` becomes a thin shell (~390 lines) that holds coordinators privately and exposes forwarding methods for views. Public API surface of `AppState` is preserved exactly so zero view files change.

## Rationale

Consolidates all callback detachment into `SyncCoordinator.teardown()` which MUST fire before any repository `clearAll()` call — closes the class of bug where stale callbacks write dirty flags during logout. Removes 160 LOC from AppState. Each coordinator has a single lifecycle responsibility, making teardown invariants explicit. Follows the coordinator pattern used by iOS app conventions (distinct from the SDK repository pattern).

## Alternatives Considered

- **Leave AppState as-is and just fix the callback regression inline** — rejected because the 727-line god object would keep attracting new responsibilities and accumulating similar bugs.
- **Extract a single mega-coordinator owning sync + connection + publishing** — rejected because the concerns have different lifecycles (sync is per-identity, connection is per-session).
- **Refactor more aggressively by moving AppState's sync state into UserDefaults-backed objects** — deferred as scope creep.

## Consequences

- `SyncCoordinator` now owns the teardown ordering invariant (callbacks nil'd before `clearAll`); new sync domains must plug into its `wireTrackingCallbacks` and `teardown` methods.
- Tests that previously tested AppState sync methods directly migrated to `SyncCoordinator`.
- `AppState` still holds `syncCoordinator`, `connectionCoordinator`, and service refs, so it remains the orchestration point — but each coordinator is testable in isolation.

## Affected Files

- `RoadFlare/RoadFlare/ViewModels/AppState.swift`
- `RoadFlare/RoadFlare/ViewModels/SyncCoordinator.swift`
- `RoadFlare/RoadFlare/ViewModels/ConnectionCoordinator.swift`
- `RoadFlare/RoadFlareTests/RoadFlareTests.swift`
