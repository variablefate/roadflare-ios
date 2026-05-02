# ADR-0015: Kind 30173 Driver-Availability Subscription for Live Vehicle Display

**Status:** Active
**Created:** 2026-05-02
**Tags:** architecture, nostr-subscription, ride-presentation

## Context

Riders couldn't see drivers' currently active vehicle on `DriverDetailSheet`,
the requestable-drivers card, or the active-ride card. iOS was reading vehicle
data from Kind 0 (profile metadata) only — but Drivestr is multi-vehicle and
does not reliably re-publish Kind 0 when a driver swaps which vehicle they're
online in. The live signal for "currently active vehicle" lives on Kind 30173
(`DriverAvailabilityEvent`); iOS had no subscription for it. PR #86 wired the
UI to render `vehicleDescription`, which made the absence of the signal
user-visible. See issue #91.

Constraints:

- Multi-vehicle is a first-class Drivestr behaviour; field-level merging would
  silently leak old data across vehicle swaps.
- `RidestrUI` ride surfaces are shared with Android; the on-wire Kind 30173
  shape and `d`-tag are already pinned by the protocol.
- ADR-0011 (coordinator boundary) constrains where Nostr-protocol logic vs.
  iOS-presentation logic may live.
- The active-ride view must stay locked to the vehicle the rider agreed to,
  even when the driver swaps mid-trip.

## Decision

Add a third managed Nostr subscription to `LocationCoordinator` —
`activeDriverAvailabilitySubscription` — modeled exactly on the existing
`activeLocationSubscription` and `activeKeyShareSubscription` (so
`LocationCoordinator` now manages three subscriptions; ADR-0011's "two
subscriptions" prose is superseded by this ADR). The `FollowedDriversRepository`
carries an in-memory `driverVehicles: [String: VehicleInfo]` cache with
**overwrite-only semantics** (never merge).

`RideCoordinator.activeRideVehicle` is populated through three deliberate paths:

1. **Acceptance transition** — `sessionDidChangeStage(.waitingForAcceptance →
   .driverAccepted)` reads `driversRepository.cachedDriverVehicle(...)`. Locks
   immediately when the cache is warm.
2. **Cold-start direct read** — `restoreRideState()` (called from
   `RideCoordinator.init`) reads `cachedDriverVehicle(...)` for the restored
   driver. The cache is empty at this point in the launch sequence
   (`restoreLiveSubscriptions()` starts the Kind 30173 stream later), so this
   path almost always sets nil; the assignment is kept defensively in case a
   future startup-sync change pre-populates the cache.
3. **First-arrival adoption** — `LocationCoordinator.handleDriverAvailabilityEvent`
   fires `onDriverVehicleUpdate` after every successful parse;
   `RideCoordinator.adoptVehicleIfNeeded(...)` adopts the *first* event observed
   for the active driver while the snapshot is still nil, then ignores
   subsequent events. This is what actually rescues cold-started mid-rides.

Presentation projections (`DriverDetailViewState`, `DriverListItem`) prefer the
live cache and fall back to the Kind 0 profile.

## Rationale

- **Mirrors a well-understood pattern.** `LocationCoordinator` already manages
  two subscriptions with the same `ManagedSubscription` + UUID-generation
  pattern. Reusing the pattern minimises new failure modes (race between
  cancel/start, generation-checked task body, idempotent restart).
- **Overwrite-only matches the protocol.** Kind 30173 is a NIP-33 parameterized
  replaceable event; the latest payload is authoritative, so per-field merging
  would actively reintroduce stale data on vehicle swap. Tests pin this
  (`updateDriverVehicleOverwriteSemanticsClearOmittedFields`).
- **Snapshot-at-acceptance protects the rider's agreement.** Once the driver
  accepts, the rider committed to *that* vehicle. Subsequent Kind 30173 events
  must not mutate the active-ride view. The `from == .waitingForAcceptance &&
  to == .driverAccepted` guard is the single capture point for fresh sessions.
- **First-arrival adoption rescues restored rides.** `restoreRideState()` runs
  inside `RideCoordinator.init`, before `restoreLiveSubscriptions()` starts the
  Kind 30173 stream — so the cache is empty at restore time. To avoid leaving
  the snapshot permanently nil for cold-started mid-rides, `LocationCoordinator`
  fires `onDriverVehicleUpdate` after every successful parse, and
  `RideCoordinator.adoptVehicleIfNeeded` adopts the *first* event observed for
  the active driver, then locks the snapshot for the rest of the ride.
- **ADR-0011 boundary preserved.** Parser, model, filter, and cache live in
  `RidestrSDK` (Nostr-protocol semantics). Subscription lifecycle and the
  `activeRideVehicle` UI snapshot live in `RoadFlareCore` (platform glue).

## Alternatives Considered

- **Persist `activeRideVehicle` in `PersistedRideState`** — would survive cold
  start without first-arrival adoption. Rejected for v1 because it requires a
  cross-platform schema bump on a contract shared with Android Ridestr; the
  in-memory snapshot + first-arrival adoption is sufficient for the P1 fix and
  introduces no schema risk.
- **Compute `vehicleDescription` from the live cache directly in
  `ActiveRideView`** — simplest implementation, but breaks the snapshot
  semantic the moment the driver swaps mid-ride.
- **Push the snapshot into `RiderRideSession` / `RideContext`** — keeps the
  ride-state machine aware of vehicle, but the SDK has no protocol-level reason
  to know about vehicle data, so this would conflate UI presentation with ride
  protocol state. Rejected per ADR-0011.
- **Replace the `onDriverVehicleUpdate` callback with `@Observable` reactive
  observation of `driversRepository.driverVehicles`** — `RideCoordinator` is
  itself `@Observable`, so it would naturally re-render when the repo's
  `driverVehicles` changed. Commit `a88d1b7` (PR #38) used exactly this
  reasoning to remove an unused `onFavoritesChanged` callback. Rejected here
  because: (a) `withObservationTracking` is single-shot — re-establishing
  tracking after each fire to detect the *first* arrival adds more code than
  the closure, (b) the snapshot is set imperatively (it must lock after the
  first observation), which is awkward to express purely through view-driven
  re-rendering, and (c) `RideCoordinator` is the sole consumer today; if a
  second consumer ever appears the closure can be promoted to a multicast
  helper without disturbing the first-arrival semantics.

## Consequences

- Riders see live vehicle info on all three surfaces (drivers list, detail
  sheet, active ride) and the active-ride view stays stable across mid-trip
  driver swaps.
- `LocationCoordinator` adds one package-internal `var onDriverVehicleUpdate`
  closure (no `public` modifier; only `RoadFlareCore` callers can attach).
  `RideCoordinator` is the sole consumer today. The single-closure shape is a
  deliberate trade-off: it matches the snapshot semantics (one consumer that
  needs first-arrival adoption), and the multicast case can be revisited if and
  when a second concrete consumer appears.
- A driver who swaps vehicles between the rider accepting and the rider
  cold-starting their app will see the rider's snapshot lock to the *new*
  vehicle on first-arrival, not the original agreement. Documented in the
  `activeRideVehicle` doc comment; revisit only if persistence becomes
  necessary for another reason.
- `prepareForIdentityReplacement` already calls `clearAll()`, which clears
  `driverVehicles` — no separate cleanup hook required.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/Models/RoadflareModels.swift` — `VehicleInfo`, `DriverAvailabilityEventData`
- `RidestrSDK/Sources/RidestrSDK/Nostr/RideshareEventParser.swift` — `parseDriverAvailability`
- `RidestrSDK/Sources/RidestrSDK/Nostr/NostrFilter.swift` — `driverAvailability(driverPubkeys:)`
- `RidestrSDK/Sources/RidestrSDK/RoadFlare/FollowedDriversRepository.swift` — `driverVehicles` cache + cleanup
- `RoadFlare/RoadFlareCore/ViewModels/LocationCoordinator.swift` — third subscription + `onDriverVehicleUpdate`
- `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift` — `activeRideVehicle` + `adoptVehicleIfNeeded`
- `RoadFlare/RoadFlareCore/ViewModels/AppState.swift` — `restartDriverAvailabilitySubscription` + restart sites
- `RoadFlare/RoadFlareCore/Presentation/DriverDetailViewState.swift`, `DriverListItem.swift` — vehicle precedence
- `RoadFlare/RoadFlare/Views/Drivers/AddDriverSheet.swift` — restart on re-add paths
- `RoadFlare/RoadFlare/Views/Ride/ActiveRideView.swift` — read snapshot before profile fallback
