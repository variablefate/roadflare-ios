# ADR-0013: User-Initiated Stale-Key Refresh Flow

**Status:** Active
**Created:** 2026-04-28
**Tags:** architecture, ux, sync, public-api

## Context

The SDK has had `LocationSyncCoordinator.requestKeyRefresh(driverPubkey:)` since the RoadFlare protocol was introduced — a Kind 3188 "stale" ack telling a driver to re-publish their Kind 3186 key share. But it was only invoked from the periodic `checkForStaleKeys` sweep. Riders whose driver keys had rotated saw a red "Key outdated" pill on the drivers tab and a silently-filtered ride-request list with no way to recover unless that automatic sweep happened to succeed (which it can't if the relay was briefly unreachable, the rate-limit window was active driver-side, or the rider's `key_updated_at` never advanced past stale).

Issue #72 collected three symptoms of the same incomplete loop: a misleading "Active" green label on stale keys in the detail sheet (Bug 1), no user-initiated path to request a refresh (Bug 2), and a re-add flow that triggered cross-driver over-rotation because Kind 3187 was published before the local key restore (Bug 3). Each fix individually was small; together they form the user-facing half of the protocol the SDK already supported.

The Android rider app implements an equivalent flow (`rider-app/.../RoadflareTab.kt:109-178`) with a per-driver `keyRefreshRequests` map and a 60-second cooldown. The iOS app needed to surface the same primitive without breaking the rate-limit assumptions the driver-side Android client makes.

## Decision

Wire the user-initiated key-refresh flow through a new app-layer rate-limiter and surface it on two views:

1. **`AppState.requestKeyRefresh(pubkey:) async -> KeyRefreshOutcome`** — public, rate-limited entry point. Outcomes: `.sent`, `.rateLimited(retryAt:)`, `.publishFailed`. The cooldown slot is claimed eagerly (before the SDK await, mirroring the `sendDriverPing` race-protection pattern in the same file) and rolled back on `.publishFailed` so the rider can retry immediately rather than wait out 60 seconds for nothing. This required making `LocationSyncCoordinator.requestKeyRefresh` `throws` so the publish failure surfaces to the caller (previously it caught everything internally as "best effort").

2. **Per-pubkey cooldown of 60 seconds**, stored in `keyRefreshCooldowns: [String: Date]` on `AppState`, cleared in `prepareForIdentityReplacement` alongside `pingCooldowns`. 60s matches Android.

3. **`AppState.staleKeyDriverPubkeys: [String]`** — sorted projection of `FollowedDriversRepository.staleKeyPubkeys`, used by the empty-state banner.

4. **`AppState.refreshAllStaleDriverKeys() async -> Int`** — fan-out for the empty-state banner, returning the number of `.sent` outcomes for toast feedback.

5. **`DriverDetailViewState.isKeyStale: Bool`** — exposed so the detail sheet can render the truthful red "Outdated" / green "Active" branch instead of hardcoded "Active".

6. **`StaleKeyRefreshBanner`** in `RideRequestView`'s empty-state branch — shown when the rider has no eligible online drivers but at least one stale-key driver. Tapping it fan-outs through `refreshAllStaleDriverKeys`.

7. **`AddDriverSheet.addDriver` reordering** — `restoreKeyFromBackup` runs *before* `sendFollowNotification`, with explicit outcome handling (`.restored` / `.notInBackup` / `.backupUnavailable`) replacing the previous opaque `Void` return. The `restartKeyShareSubscription` side-effect from PR #54 is preserved on the re-add early-return path via a new `AppState.restartKeyShareSubscription()` shim.

## Rationale

- **App-layer cooldown over SDK-layer cooldown** because the rate limit guards a *user-tap* surface, not the protocol primitive itself; the SDK's `requestKeyRefresh` should remain a low-level fire-once primitive that other callers (e.g. the periodic sweep) use unrate-limited. Precedent: `pingCooldowns` (ADR-0009) lives in the same place for the same reason. A future consolidation (cross-client cooldown semantics moved into the SDK) is out of scope for this fix and tracked separately.

- **`KeyRefreshOutcome` instead of `throws`** because the call site is a SwiftUI button handler that needs to render three distinct user-facing states (success toast, wait-N-seconds toast, publish-failed toast), not a do/catch block. Plain `throws` would force every caller to either `try?` (silent failure — the bug we're fixing) or invent its own error-classification.

- **`restoreKeyFromBackup` outcome enum** because the previous `Void` return collapsed three semantically-different cases ("backup said no key", "backup unreachable", "backup said yes and applied"). The add-driver flow's correctness depends on distinguishing them: a transient unreachable case must NOT silently fall through to Kind 3187 if it can be avoided, and when it must (graceful degradation), the choice should be logged so user reports can be diagnosed.

- **Restore-before-notify ordering** is the iOS-side half of the Bug 3 fix. The Android driver client treats Kind 3187 as a fresh-follow signal that may rotate keys for all followers, marking every other rider's stored key as stale on their next sweep. Restoring the key from our own Kind 30011 backup first lets us short-circuit on re-adds without touching the driver. The Android-side complement (driver reads existing follower from mute list and re-delivers without rotating) is tracked separately on the Drivestr repo.

- **`restartKeyShareSubscription` preserved on re-add path** because PR #54's subscription-restart side effect on `sendFollowNotification` was added to force relay re-delivery of Kind 3186 events the long-lived subscription may have missed. Restoring a key from backup doesn't satisfy that goal — backups give us a *snapshot*, not a fresh subscription. Splitting the side effect into its own AppState method keeps both flows correct.

## Alternatives Considered

- **Auto-refresh in the periodic sweep only.** Already implemented; insufficient because a single sweep failure (relay flake, rate-limit window) leaves the rider locked out indefinitely. The user has no agency.
- **Fire `.sent` regardless of publish outcome (status-quo before this PR).** Original implementation. Causes a false-success toast plus a 60s lockout on publish failure. Rejected during code review (verify-and-fix pass 2).
- **Move the cooldown into `LocationSyncCoordinator`.** Rejected for this PR because it would also require moving `pingCooldowns` for consistency, expanding scope. Tracked separately.
- **Banner everywhere a stale driver exists, not just empty state.** Rejected for this PR because the empty-state CTA is the dead-end the issue identifies; broader placement is a UX scope decision. Tracked separately.

## Consequences

- The SDK's `requestKeyRefresh` now `throws`. Existing best-effort callers wrap with `try?` (one site in `LocationSyncCoordinator.checkForStaleKeys`).
- New public API on `AppState` (`KeyRefreshOutcome`, `RestoreKeyFromBackupOutcome`, `requestKeyRefresh(pubkey:)`, `staleKeyDriverPubkeys`, `refreshAllStaleDriverKeys`, `restartKeyShareSubscription`) and a new public field on `DriverDetailViewState` (`isKeyStale`).
- The add-driver flow's behavior on `.backupUnavailable` is the same as the pre-fix flow (graceful degradation, logged). A future enhancement could retry the backup fetch with backoff before falling through.
- Riders now have both a per-driver "Request Fresh Key" button (DriverDetailSheet) and a fan-out empty-state banner (RideRequestView).
- Any future caller that compares `staleKeyDriverPubkeys` arrays directly will get deterministic ordering.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/RoadFlare/LocationSyncCoordinator.swift` — `requestKeyRefresh` throws; `checkForStaleKeys` wraps with `try?`
- `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/LocationSyncCoordinatorTests.swift` — added throw-on-publish-failure test
- `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/FollowedDriversRepositoryTests.swift` — Bug 3 cross-driver invariant test
- `RoadFlare/RoadFlareCore/ViewModels/AppState.swift` — new public outcomes, cooldown storage, `requestKeyRefresh(pubkey:)`, `staleKeyDriverPubkeys` (sorted), `refreshAllStaleDriverKeys`, `restartKeyShareSubscription`, `restoreKeyFromBackup` outcome enum
- `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift` — `requestKeyRefresh` throws
- `RoadFlare/RoadFlareCore/ViewModels/LocationCoordinator.swift` — `requestKeyRefresh` throws
- `RoadFlare/RoadFlareCore/Presentation/DriverDetailViewState.swift` — `isKeyStale` field
- `RoadFlare/RoadFlare/Views/Drivers/DriverDetailSheet.swift` — truthful key-status branch + "Request Fresh Key" button
- `RoadFlare/RoadFlare/Views/Drivers/AddDriverSheet.swift` — reordered handshake + outcome switch
- `RoadFlare/RoadFlare/Views/Ride/RideRequestView.swift` — `StaleKeyRefreshBanner`
- `RoadFlare/RoadFlareTests/AppState/RequestKeyRefreshTests.swift` — new test suite
- `RoadFlare/RoadFlareTests/Presentation/PresentationTypesTests.swift` — `isKeyStale` projection tests
