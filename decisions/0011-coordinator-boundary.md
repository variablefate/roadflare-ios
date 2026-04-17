# ADR-0011: Coordinator Boundary Review — RoadFlareCore vs RidestrSDK

**Status:** Active
**Created:** 2026-04-17
**Tags:** refactor, architecture, coordinator-boundary, ridestr-sdk

## Context

ADR-0001 decomposed `AppState` into coordinator classes (`SyncCoordinator`,
`ConnectionCoordinator`). ADR-0005 introduced the `RoadFlareCore` framework as the
boundary between the app-layer orchestration and the SDK. The intent was that
`AppState` would become "a thin shell that holds coordinators privately and exposes
forwarding methods for views." That decomposition happened, but two residual problems
remain:

1. **View bypass**: SwiftUI views still reach through `AppState` to access SDK
   repositories directly (`appState.driversRepository`, `appState.relayManager`,
   `appState.roadflareDomainService`). Views import `RidestrSDK` and call methods on
   `FollowedDriversRepository`, `RelayManager`, and `RoadflareDomainService` without
   going through any AppState façade method.

2. **Boundary review due**: The five coordinator classes have not been formally
   reviewed for whether they are sitting at the right abstraction layer. This ADR
   captures that review.

The five coordinators are:
- `AppState` — owns SDK services, auth lifecycle, orchestration (~650 LOC)
- `SyncCoordinator` — Nostr sync orchestration, startup resolution, dirty-tracking
- `RideCoordinator` — app-layer adapter around `RiderRideSession`; owns UI state,
  chat/location coordinators, ride state persistence
- `ChatCoordinator` — manages in-ride chat messaging (Kind 3178) subscriptions and
  send/receive
- `LocationCoordinator` — manages location (Kind 30014) and key share (Kind 3186)
  subscription lifetimes; feeds events into `LocationSyncCoordinator` (SDK)

## Decision

Each coordinator stays in RoadFlareCore or moves to SDK as follows:

**AppState — stays in RoadFlareCore.**
AppState is pure iOS app orchestration: it owns Keychain-backed key storage, wires
UserDefaults-backed repositories, manages `authState` transitions driven by
`UserSettingsRepository`, starts the connection watchdog, and drives the onboarding
flow. None of that is Nostr protocol logic. The existing pattern of AppState holding
private coordinators and exposing forwarding methods is correct. The immediate
follow-up (this PR, Phase B) is to add façade computed properties and action methods
to AppState so views no longer access `driversRepository` and `relayManager`
directly.

AppState does contain one piece of protocol logic that warrants review: the
`sendDriverPing` method builds and publishes a Kind 3189 event. This is symmetric
with `sendFollowNotification` (Kind 3187). Both build Nostr events inline in AppState
using `RideshareEventBuilder` and publish via `RelayManager`. The event-building
itself is SDK logic, but publishing is already a one-liner delegating to the SDK —
the business logic here is the cooldown state machine and pre-flight checks, which
are app-level concerns (cooldown lives in memory for the process lifetime, resets on
logout). This is correctly placed.

**SyncCoordinator — stays in RoadFlareCore. Clean.**
SyncCoordinator is pure wiring: it calls SDK types (`SyncDomainResolver`,
`ProfileBackupCoordinator`, `RideHistorySyncCoordinator`, `SyncDomainTracker`,
`RoadflareDomainService`) and delegates everything to them. The startup sync
orchestration is coordination logic, not protocol logic — it decides which SDK
resolver to call and in what order, and reports progress to AppState's UI state
properties. That belongs in the app layer. Teardown ordering (callbacks nil'd before
`clearAll`) is an app-lifecycle invariant, not an SDK concern. SyncCoordinator is the
cleanest of the five coordinators.

**RideCoordinator — stays in RoadFlareCore.**
RideCoordinator wraps `RiderRideSession` (SDK) and owns: (a) app-layer UI state
(`currentFareEstimate`, `selectedPaymentMethod`, `pickupLocation`,
`destinationLocation`, `lastError`), (b) ride history recording with platform
persistence, (c) delegation of session lifecycle events to child coordinators
(`ChatCoordinator`, `LocationCoordinator`), and (d) ride-state snapshot
persistence via `RideStateRepository`. The `sendRideOffer` method constructs
`RideOfferContent` from app-layer inputs (settings, fare estimates, number-formatting
concerns) — that assembly logic is correctly app-layer. No SDK protocol logic
should move up. The ride-state persistence mapping (converting SDK `RiderStage`
structs to/from `PersistedRideState`) is already in the SDK; `RideCoordinator` only
calls it.

There is one open question: `RideCoordinator` directly constructs `RideOfferContent`
including fiat-formatting logic (a `NumberFormatter`, USD-to-sats conversion, fiat
rail selection per ADR-0008). This is complex enough that a helper on
`RideOfferContent` or a builder in the SDK might be cleaner, but that is a
single-file refactor, not a boundary move.

**ChatCoordinator — stays in RoadFlareCore, but has SDK-extractable logic.**
ChatCoordinator (176 LOC) does two things:

1. *Subscription lifetime management*: starts/stops a Kind 3178 WebSocket
   subscription with a generation-counter guard pattern. This is the same
   `ManagedSubscription` pattern used in `LocationCoordinator`. It is app-layer
   infrastructure (managing `Task` lifetimes and `SubscriptionID` handles against a
   `RelayManagerProtocol`). Belongs in RoadFlareCore.

2. *Event parsing, deduplication, sorting, and haptics*: calls
   `RideshareEventParser.parseChatMessage`, deduplicates by event ID, sorts by
   timestamp, caps at 500 messages, increments `unreadCount`, and calls
   `HapticManager.messageReceived()`. The parsing call is an SDK delegation. The
   deduplication, capping, and sorting are generic message-list management that could
   live in an SDK-owned `ChatMessageStore` type if a driver-side app were ever built
   that needed the same logic. The haptics call (`HapticManager`) is iOS-platform
   specific and must stay in the app layer.

**Verdict**: No logic moves to the SDK now. If a driver-side app is built, the
message deduplication and sorting logic (minus haptics) is a natural extraction
candidate at that point. See follow-up issue filed below.

**LocationCoordinator — stays in RoadFlareCore. Already at the right abstraction.**
LocationCoordinator is a thin subscription lifetime manager. After
`LocationSyncCoordinator` was extracted into the SDK (which owns key share state
machines, stale key detection, and ack publishing), `LocationCoordinator` does only:
start/stop two subscriptions (`roadflare-locations` and `key-shares`) using the same
generation-counter guard pattern, and delegate all event handling to the SDK's
`LocationSyncCoordinator`. The `handleLocationEvent` method calls
`RideshareEventParser.parseRoadflareLocation` (SDK) and
`FollowedDriversRepository.updateDriverLocation` (SDK) — both are pure SDK
delegations. This is the right split.

## Rationale

The primary principle is: **Nostr protocol logic (event building, parsing,
subscription filters, state machines) lives in RidestrSDK. App-layer orchestration,
platform persistence (Keychain, UserDefaults), iOS lifecycle, and UI state live in
RoadFlareCore.**

By this principle, none of the five coordinators has protocol logic that needs to
move to the SDK today. The SDK already owns `LocationSyncCoordinator`,
`ProfileBackupCoordinator`, `RideHistorySyncCoordinator`, `SyncDomainTracker`,
`SyncDomainResolver`, `RiderRideSession`, and `AccountDeletionService`. RoadFlareCore
coordinators are already thin wrappers and wiring layers.

The more pressing issue is not coordinator placement but **view bypass**: views
importing `RidestrSDK` directly to read `FollowedDriversRepository` properties,
pass `FollowedDriver` values, and call `RelayManager`. That is addressed in Phase B
of this PR (ADR-0011 companion, issue #48).

## Alternatives Considered

- **Move ChatCoordinator's message deduplication/sorting into a SDK `ChatMessageStore`** —
  deferred, not rejected. Worth doing if a driver-side app is built. No reason to do
  it now when there is one consumer and the logic is stable.

- **Move `sendDriverPing` / `sendFollowNotification` logic into a new SDK service** —
  rejected for now. The cooldown state machine and pre-flight checks are app-level
  concerns. The event building already delegates to `RideshareEventBuilder` (SDK). No
  protocol logic is stranded in the app layer.

- **Move subscription lifetime management (the `ManagedSubscription` pattern shared
  by `ChatCoordinator` and `LocationCoordinator`) into an SDK utility** — rejected.
  `Task` and `SubscriptionID` management is app-layer infrastructure tied to
  `@MainActor` and `RelayManagerProtocol`. It would add an SDK dependency on Swift
  concurrency task management patterns that are only needed in the app layer.

## Consequences

- No code moves to the SDK as a result of this ADR. The boundary is confirmed
  correct for all five coordinators.
- Phase B (issue #48, this PR) adds façade computed properties and action methods to
  `AppState` so views can stop importing `RidestrSDK` for their normal rendering path.
- A follow-up issue is filed for the ChatCoordinator SDK extraction question to
  revisit when a driver-side consumer exists.
- Future coordinators added to RoadFlareCore should follow the established patterns:
  thin subscription lifetime management, delegation to SDK state machines, and no
  inline event building beyond what `RideshareEventBuilder` already provides.

## Affected Files

- `RoadFlare/RoadFlareCore/ViewModels/AppState.swift`
- `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift`
- `RoadFlare/RoadFlareCore/ViewModels/SyncCoordinator.swift`
- `RoadFlare/RoadFlareCore/ViewModels/ChatCoordinator.swift`
- `RoadFlare/RoadFlareCore/ViewModels/LocationCoordinator.swift`
- `RoadFlare/RoadFlare/Views/Drivers/DriversTab.swift` (Phase B: remove SDK bypass)
- `RoadFlare/RoadFlare/Views/Drivers/DriverDetailSheet.swift` (Phase B: remove SDK bypass)
- `RoadFlare/RoadFlare/Views/Drivers/AddDriverSheet.swift` (Phase B: remove SDK bypass)
- `RoadFlare/RoadFlare/Views/Ride/RideRequestView.swift` (Phase B: remove SDK bypass)
- `RoadFlare/RoadFlare/Views/History/HistoryTab.swift` (Phase B: remove SDK bypass)
- `RoadFlare/RoadFlare/Views/Settings/SettingsTab.swift` (Phase B: remove SDK bypass)
- `RoadFlare/RoadFlare/Views/Settings/SavedLocationsView.swift` (Phase B: remove SDK bypass)
- `RoadFlare/RoadFlare/Views/Shared/ConnectivityIndicator.swift` (Phase B: remove SDK bypass)
- `RoadFlare/RoadFlare/Views/Ride/RideTab.swift` (Phase B: remove SDK bypass)
