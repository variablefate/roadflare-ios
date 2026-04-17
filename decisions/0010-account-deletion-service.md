# ADR-0010: Account Deletion as Stateless SDK Service with Two-Tier UX

**Date:** 2026-04-16
**Status:** Accepted
**Issue:** #51 — In-app account deletion

## Context

Users need an in-app path to permanently delete their RoadFlare account. Unlike logout (which only clears local state), deletion must publish NIP-09 Kind 5 deletion events to every relay before tearing down the local key so the user's data does not linger on public relays.

Three pressures shape the design:

1. **Nostr is decentralized** — relays are independently operated, so the client must publish deletion requests to every relay it has used. There is no server-side "DELETE /account" endpoint.
2. **Key destruction is terminal** — the user's keypair lives only on-device. Once `logout()` destroys the keys, a failed publish cannot be retried by the same identity. This makes the publish step non-idempotent and high-stakes.
3. **Mixed identity** — users may have a shared Nostr profile (Kind 0) used by other Nostr apps. Wholesale deletion of Kind 0 is destructive outside RoadFlare's scope, so the UX must separate "delete RoadFlare events" from "delete all Ridestr events including my Nostr profile."

## Decision

**Service placement (SDK vs app).** A new stateless `AccountDeletionService` in `RidestrSDK/Sources/RidestrSDK/RoadFlare/AccountDeletionService.swift` owns the Nostr protocol semantics: scanning relays for rider-authored events, building Kind 5 deletion events, and publishing with retry. The service is `final Sendable` with two `let` dependencies (`relayManager`, `keypair`) — no mutable state, no `@unchecked Sendable` / `NSLock` needed. Callers create a fresh instance per flow.

**App-layer wrapper.** `AppState` exposes three methods that layer in app-specific preflight and teardown:

- `scanRelaysForDeletion()` — checks keypair + relayManager are live, checks no active ride is in progress (throws `activeRideInProgress`), calls `reconnectIfNeeded()` + `rideCoordinator?.restoreLiveSubscriptions()` to defensively rebuild dead WebSockets (without stranding live ride subscriptions), then delegates to the service. Deliberately does NOT call `reconnectAndRestoreSession()` because that also flushes pending sync publishes — flushing dirty profile/drivers/history state right before the user asks to delete everything wastes relay traffic and risks a race where freshly-flushed events aren't indexed in time for the scan query.
- `deleteRoadflareEvents(from:)` / `deleteAllRidestrEvents(from:)` — re-check the active-ride guard at delete time (the user could have accepted an offer in another tab after the scan completed), publish the Kind 5 event via the service, then call `logout()` to tear down local state.

**Single-button deletion UX.** The UI (`DeleteAccountSheet`) offers one "Delete Account" action on page 2. It wipes everything: all 12 Ridestr kinds + Kind 0 metadata, destroys the local keypair, and calls `logout()`. A three-checkbox confirmation sheet (profile impact, other-app impact, key-backup acknowledgement) gates the destructive publish.

An earlier design offered two tiers (preserve Kind 0 vs. delete Kind 0). This was collapsed after App Review feedback made clear that multiple "delete" affordances confuse reviewers who expect a single unambiguous path per App Store guideline 5.1.1(v). The SDK still exposes both `deleteRoadflareEvents` and `deleteAllRidestrEvents` — the app just never calls the former today. Keeping the preserve-Kind-0 option in the SDK is cheap insurance if a power-user disclosure ever re-emerges.

**Retry on publish.** The service uses `publishWithRetry(_:)` (not plain `publish`) because the deletion event is critical and non-retryable after logout. Transient relay failures would otherwise be the final error the user ever sees on this identity.

**Error surfacing.** Publish failures are captured in `RelayDeletionResult.publishError` and surfaced to the user in `DeleteAccountResultsView` as a persistent banner (not just a log line). Scan errors are surfaced on page 1 via the existing `scanErrorWarning` affordance.

**Logout timing.** `logout()` is called only when the Kind 5 publish succeeds. On publish failure the session is preserved so the error banner can render and the user can retry — logging out would destroy the keypair before the error is visible, stranding their events on relays with no retry path from this device. Active-ride and services-not-ready guards also short-circuit before logout so the sheet remains visible with the guard message.

## Rationale Over Alternatives

| Alternative | Rejected because |
|---|---|
| Place deletion logic in `AppState` directly | Nostr protocol semantics (kind list, Kind 5 construction, filter queries) belong in the SDK per project convention — `AppState` should only glue iOS lifecycle to SDK calls |
| One-tier "delete everything" UX | Users with a shared Nostr identity would lose profile data used by unrelated Nostr apps — a destructive surprise |
| `reconnectIfNeeded()` alone before scan | Tears down ride-coordinator subscriptions per its documented contract ("callers must re-subscribe after this returns") — would strand live ride sessions if the user cancels the sheet. `reconnectAndRestoreSession()` already bundles the reconnect + `restoreLiveSubscriptions()` pair used elsewhere |
| Plain `publish` (no retry) | Deletion is one-shot after logout; a transient relay hiccup would silently leave events on relays with no user-visible recovery path |
| Log publish errors only (no UI banner) | "I confidently deleted my account but my events are still on relays" is the exact footgun NIP-09 is designed to avoid — silent log-only failure reproduces it |
| Delete without re-checking active-ride state | `logout()` → `prepareForIdentityReplacement()` calls `rideCoordinator?.clearAll()`, which would tear down a live ride mid-flight if one started between scan and confirm |

## Consequences

**Enables:**
- In-app compliance with user-initiated data deletion expectations (App Store guideline 5.1.1(v)).
- Reusable SDK surface — `AccountDeletionService` can be consumed by future clients (e.g. drivestr) without app-layer changes.
- Clear separation: the scan/delete protocol is tested in the SDK (9 tests); the app-layer glue (active-ride guard, error surfacing) is tested in `RoadFlareTests`.

**Known tradeoffs:**
- Relay independence means deletion cannot be guaranteed — a relay may refuse to honour NIP-09. This is disclosed to the user in the page 1 explainer ("RoadFlare sends a deletion request … but because relays are independently operated, removal cannot be guaranteed"). No code-level mitigation is possible.
- The retry (up to 3 attempts with exponential backoff) extends the publish window by up to ~3s before the user is logged out. Acceptable tradeoff for a deliberate, user-initiated action.
- The active-ride guard at delete time rejects the deletion outright rather than offering a "cancel ride first" flow. A future enhancement could auto-cancel the ride as part of the deletion path.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/RoadFlare/AccountDeletionService.swift` (new)
- `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/AccountDeletionServiceTests.swift` (new)
- `RoadFlare/RoadFlareCore/ViewModels/AppState.swift` — new `AccountDeletionError`, `scanRelaysForDeletion`, `deleteRoadflareEvents`, `deleteAllRidestrEvents`
- `RoadFlare/RoadFlare/Views/Settings/DeleteAccountSheet.swift` (new) — two-page flow
- `RoadFlare/RoadFlare/Views/Settings/SettingsTab.swift` — Delete Account button
- `RoadFlare/RoadFlare/Views/Shared/DesignSystem.swift` — `RFDestructiveButtonStyle`, `RFDestructiveSecondaryButtonStyle`
- `RoadFlare/RoadFlareTests/RoadFlareTests.swift` — `AppState` guard tests
