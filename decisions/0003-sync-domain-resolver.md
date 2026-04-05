# ADR-0003: Generalize sync resolution and move publish wrappers to SDK

**Status:** Active
**Created:** 2026-04-05
**Tags:** refactor, sdk, architecture, sync, concurrency, state-machine

## Context

`SyncCoordinator` had 4 near-identical `applyXResolution` methods (profile, drivers, profileBackup, rideHistory), one of which had dropped the "undecodable remote event" warning branch through copy-paste drift. Additionally, `publishProfile`, `publishProfileBackup` (with republish state machine), `buildProfileBackupContent`, and `applyRemoteProfileBackup` all lived app-side even though they are pure protocol logic. `SyncCoordinator` sat at 412 LOC of mixed orchestration + business logic.

## Decision

Introduce two new SDK types:

1. **`SyncDomainResolver` enum + `SyncDomainStrategy<Value>` struct** — generic resolution for all 4 sync domains via `@Sendable async` closures.
2. **`ProfileBackupCoordinator` class** — owns the Android-template preservation field + republish-on-dirty state machine + `applyRemote`/`buildContent`/`publishAndMark` methods.

Add `publishAndMark` convenience methods to `RoadflareDomainService` for profile/drivers/rideHistory. Rewrite `SyncCoordinator.performStartupSync` to define 4 strategies inline and call `SyncDomainResolver.apply` for each. Delete 4 `applyXResolution` methods, 6 facade methods, and 3 state fields from `SyncCoordinator`. `AppState` forwarders route through SDK helpers directly. `SyncCoordinator` shrinks to ~240 LOC of pure wiring.

## Rationale

Eliminates the class of bugs where 4 copy-pasted methods drift apart. `ProfileBackupCoordinator`'s publish state machine closes two latent concurrency bugs in the app-side equivalent:

1. **Lost-update race** between while-loop exit and defer — fixed via atomic exit in a single lock critical section.
2. **clearAll-during-in-flight-publish race** where old session clobbers new session's `isPublishing` flag — fixed via generation counter that invalidates crossed sessions.

Both bugs existed in the previous `SyncCoordinator.publishProfileBackup` but were masked by `@MainActor` serialization. The SDK version is strictly safer. Any RoadFlare client gets complete sync machinery (resolver + publish + state machine) by importing the SDK.

## Alternatives Considered

- **Keep 4 copy-pasted methods and just add the missing undecodable branch** — rejected, accepts continued drift.
- **Move resolver but keep publish wrappers app-side** — rejected, leaves `SyncCoordinator` owning state machines it shouldn't.
- **Make publishAndMark methods throw so callers handle errors** — rejected in favor of swallow+log since current callers are fire-and-forget and logging satisfies observability.
- **Make the resolver synchronous and do isolation at the strategy level** — rejected, `@Sendable async` closures are the cleaner cross-actor contract.

## Consequences

- `ProfileBackupCoordinator` is `@unchecked Sendable` with `NSLock`; it is stricter than sibling SDK repos (atomic loop-exit + generation counter). Added regression test verifying generation invalidates in-flight publishes.
- Log messages for publish confirmations shifted from `AppLogger.auth` to `RidestrLogger` subsystem — surfaced a separate bug that `RidestrLogger.handler` was never set in the app (fixed via `AppLogger.bootstrapSDKLogging`).
- `rideHistory` domain now logs undecodable-remote warnings matching the other 3 domains (observability fix).
- Any new sync domain added in the future just defines a `SyncDomainStrategy` — no new `applyXResolution` copy-paste.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/RoadFlare/SyncDomainResolver.swift`
- `RidestrSDK/Sources/RidestrSDK/RoadFlare/ProfileBackupCoordinator.swift`
- `RidestrSDK/Sources/RidestrSDK/RoadFlare/RoadflareDomainService.swift`
- `RoadFlare/RoadFlare/ViewModels/SyncCoordinator.swift`
- `RoadFlare/RoadFlare/ViewModels/AppState.swift`
- `RoadFlare/RoadFlare/RoadFlareApp.swift`
- `RoadFlare/RoadFlare/Services/AppLogger.swift`
