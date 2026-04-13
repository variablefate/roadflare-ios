# ADR-0006: Extract Sync Change-Tracking Callback Wiring to SyncDomainTracker

**Status:** Active
**Created:** 2026-04-12
**Tags:** refactor, sdk, architecture, sync, callback-wiring

## Context

`SyncCoordinator` (app layer) owned five callback→domain mappings that encode protocol-level knowledge: which repository mutations dirty which Nostr sync domain. These mappings are not iOS-specific — they reflect Ridestr protocol semantics (e.g., `.sync`-sourced driver mutations must not dirty `.followedDrivers` because they originate from the relay, not from local edits; `savedLocations.onChange` maps to `.profileBackup` because location data is included in Kind 30177).

A prior regression (`bef926b`) established that callback teardown must happen before any `clearAll()` on repositories to prevent stale dirty flags after logout. `SyncCoordinator.teardown()` serialised this requirement correctly, but the five individual `nil` assignments were fragile — any future callback addition could miss teardown, and the protocol-level mapping logic was hidden in app wiring code.

Additionally, `wireTrackingCallbacks` was called repeatedly on identity replacement (logout/login), which required careful ARC ordering: without explicit detach, the old tracker's `deinit` fires after the new tracker's `init` wires callbacks, immediately nil-ing the fresh callbacks.

## Decision

Extract all change-tracking callback wiring into a new SDK class `SyncDomainTracker`:

- **`SyncDomainTracker`** (SDK, `public final class`): owns all five callback wirings in `init`, exposes a single `@MainActor detach()` method that nils them all, and calls `detach()` from `deinit` as a safety net.
- **`SyncCoordinator.wireTrackingCallbacks`** (app): delegates to a fresh tracker using explicit detach+nil+create sequence so the old tracker's `deinit` fires with nil callbacks.
- **`SyncCoordinator.teardown`** (app): calls `tracker.detach()` then `tracker = nil` before any `clearAll()`.

## Rationale

The "which mutation dirties which domain" mapping is protocol-level knowledge — identical to why `UserSettingsRepository` (ADR-0002) and `RideStateRepository` (ADR-0004) moved to the SDK. Any future Ridestr client must implement the same filtering logic (e.g., `.sync` mutations must not mark `.followedDrivers` dirty). Centralising it in the SDK makes the contract explicit and testable without iOS dependencies.

The single-object lifecycle (`detach()` nils all five callbacks atomically from the caller's perspective) eliminates the class of bug where a future callback addition forgets teardown. `SyncCoordinator.teardown()` reduces to two lines regardless of how many callbacks `SyncDomainTracker` manages.

`@MainActor` on `detach()` enforces at compile time the invariant that teardown is always main-actor-serialised (matching `SyncCoordinator`'s own isolation), preventing the data-race window where `deinit` fires off-actor while a background callback fires concurrently.

## Alternatives Considered

- **Keep wiring in SyncCoordinator, extract only the domain mapping as a constant** — rejected because it doesn't move the protocol knowledge to the SDK, and teardown still requires per-callback nil assignments.
- **Protocol with default implementation rather than a concrete class** — rejected because there is exactly one implementation; a protocol adds indirection without benefit.
- **Weak reference to `SyncDomainTracker` in `SyncCoordinator`** — rejected because the app must keep the tracker alive for callbacks to fire; `SyncCoordinator` owns the tracker's lifetime exactly.

## Consequences

- Protocol-level callback→domain mappings are SDK-tested without iOS dependencies (8 new tests + 1 clearAll regression test).
- `SyncCoordinator.teardown()` is 2 lines regardless of future callback additions.
- `detach()` is `@MainActor`, so callers get a compile-time guarantee that teardown is always serialised on the main actor.
- `SyncDomainTracker.init` is not `@MainActor` — construction can happen synchronously in `@MainActor` callers (as now) without requiring async.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/RoadFlare/SyncDomainTracker.swift` (NEW)
- `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/SyncDomainTrackerTests.swift` (NEW)
- `RoadFlare/RoadFlareCore/ViewModels/SyncCoordinator.swift` (MODIFIED)
- `RoadFlare/RoadFlareTests/RoadFlareTests.swift` (MODIFIED)
