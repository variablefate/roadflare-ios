# ADR-0011: Presentation Projection Layer in RoadFlareCore

**Status:** Active
**Created:** 2026-04-17
**Tags:** architecture, refactor, view-layer

## Context

Views were importing `RidestrSDK` domain models directly and computing display logic inline (status label strings, `canRequestRide` booleans, relative timestamps, formatted fares). This scattered identical business-of-display decisions across multiple SwiftUI files, made views harder to unit-test without the SDK, and blurred the boundary between protocol-layer concerns (what a `FollowedDriver` is) and display-layer concerns (how to show it).

The coordinator-boundary refactor (ADR-0001, PR #58) introduced `AppState` as the single facade for view data. To complete the boundary, views need to receive pre-projected, display-ready values rather than raw SDK types.

## Decision

Introduce an app-owned `Presentation/` sublayer inside `RoadFlareCore` containing immutable `Sendable` structs with static `from(...)` factory methods. Each type projects one SDK domain aggregate + repository context into a view-ready value with all display strings and booleans pre-computed.

Initial types: `DriverListItem`, `DriverDetailViewState`, `RideRequestDriverOption`, `RideHistoryRow`, `SavedLocationRow`.

## Rationale

- **Immutable value types** (`struct`) are safe across Swift Concurrency boundaries without locks.
- **Static factory** keeps construction logic out of views and out of the SDK. Views stay dumb; the SDK stays protocol-clean.
- **`RoadFlareCore` (not `RidestrSDK`)** is the right home: these types encode iOS display decisions (SF Symbol names, `RelativeDateTimeFormatter`, fare string format) that have no business in the protocol SDK.
- **Pre-computation at factory time** means SwiftUI's diffing compares only `Equatable` value types, not live repository state.

## Alternatives Considered

- **Pass SDK models directly to views** — rejected: views would import `RidestrSDK`, mix display logic with protocol logic, and become untestable without the full SDK stack.
- **`@Observable` ViewModels per screen** — rejected: each ViewModel would duplicate the same status-label / canRequestRide logic; cross-screen consistency harder to guarantee; harder to test in isolation.
- **Projection inside `AppState` as computed properties** — rejected: `AppState` is a coordinator, not a display transformer; mixing both concerns would grow it unboundedly.

## Consequences

- All new screen state types follow this pattern: `public struct Foo: Equatable, Sendable` with `static func from(...)`.
- Views import `RoadFlareCore` only; zero direct `RidestrSDK` imports in view files.
- Factory signatures are the contract: adding a new display field means adding a parameter (or deriving it from existing ones), keeping the call site explicit about what data each type needs.
- Callers must supply `isKeyStale:` for driver-facing types; this comes from `FollowedDriversRepository.staleKeyPubkeys`.

## Affected Files

- `RoadFlare/RoadFlareCore/Presentation/DriverListItem.swift`
- `RoadFlare/RoadFlareCore/Presentation/DriverDetailViewState.swift`
- `RoadFlare/RoadFlareCore/Presentation/RideRequestDriverOption.swift`
- `RoadFlare/RoadFlareCore/Presentation/RideHistoryRow.swift`
- `RoadFlare/RoadFlareCore/Presentation/SavedLocationRow.swift`
- `RoadFlare/RoadFlareTests/Presentation/PresentationTypesTests.swift`
