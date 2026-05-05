# ADR-0015: Onboarding Publish Failure Surface

**Status:** Active
**Created:** 2026-05-05
**Tags:** ux, sync, onboarding, concurrency, public-api

## Context

[ADR-0014](0014-optimistic-onboarding-publish.md) decoupled the onboarding UI from the Nostr relay round-trip — `completeProfileSetup` and `completePaymentSetup` flip `authState` immediately and spawn the publish as a fire-and-forget `Task`. That fixed the multi-second freeze on Continue, but it explicitly deferred the user-visible failure surface to issue #88: a relay-unreachable user finishes onboarding silently, the dirty flag is preserved by `RoadflareSyncStateStore`, and `SyncCoordinator.flushPendingSyncPublishes` is gated on `authState == .ready`. A user who reaches `.ready` and then never reconnects (or never foregrounds) is in a state where their profile + settings have never reached a relay, with no UI indication and no manual retry path. ADR-0014's "Consequences" section explicitly named this gap: *"Issue #88 is now load-bearing for the user-visible failure surface."*

The failure mode that needs covering is narrow: the user is on the device, has finished onboarding, the relay was unreachable during the onboarding window, and the sync coordinator's reconnect-flush path will eventually publish — *but only the next time `reconnectAndRestoreSession` runs*. If the user moves to a different device before that, their data is lost.

## Decision

Add a thin observation layer on `AppState` and a banner pinned to the top of `RootView`:

1. **Observable surface.** New `OnboardingPublishStatus` enum (`.idle` / `.failed(domain:)`) and `OnboardingPublishDomain` enum (`.profile` / `.settingsBackup`) live on `AppState` as `public var onboardingPublishStatus`. Views observe via `@Environment(AppState.self)`.

2. **Twin-Task watchdog.** `startOnboardingPublish(domain:)` spawns two MainActor-isolated Tasks alongside flipping `authState`:
   - **Publish Task** — invokes `publishProfile()` or `saveAndPublishSettings()`. Has an early-bail `guard !Task.isCancelled` before the SDK switch so a fast retry/chain that lands before the Task is scheduled avoids the duplicate publish. Once `await publishProfile()` is in flight, the SDK call (`publishProfileAndMark`) does not observe cooperative cancellation — the relay round-trip completes regardless.
   - **Watchdog Task** — sleeps the timeout window (`60s` in production), then checks `isOnboardingDomainDirty(domain)` against `RoadflareSyncStateStore`. If still dirty AND the relay is reachable (`relayManager.isConnected`), flips status to `.failed(domain:)` and lets `RootView` render the banner. If still dirty AND offline, parks on a `10s` rearm-poll loop (recursive `Task.sleep` + re-check) until either the publish clears the flag or connectivity returns.

3. **Three failure-clearing paths.**
   - **Manual retry** — `retryOnboardingPublish()` cancels the prior twin-Task pair, sets status to `.idle`, and re-invokes `startOnboardingPublish(domain:)`. Banner self-dismisses on the next watchdog cycle if dirty has cleared.
   - **Background flush** — `reconnectAndRestoreSession` calls `clearOnboardingPublishStatusIfDomainsClean()` after the existing `flushPendingSyncPublishes`. If the flush succeeded, the dirty flag is now clean → cancel watchdog + publish, set status `.idle`. The user sees the banner disappear without tapping anything.
   - **Identity replacement** — `prepareForIdentityReplacement` cancels both Tasks and resets status to `.idle` alongside `pingCooldowns` and `keyRefreshCooldowns`.

4. **Banner placement.** `OnboardingPublishFailureBanner` is rendered as the first child of a `VStack` in `RootView`, above the auth-state switch (`@ViewBuilder` `authStateContent`). SwiftUI's default safe-area handling places the banner below the status bar without explicit insets. The banner copy is domain-specific ("Your profile hasn't been backed up yet" / "Your profile and settings haven't been backed up yet"). Retry button is a discrete focusable accessibility element.

5. **Test seams.** `setOnboardingPublishHooksForTesting(...)` (DEBUG-only) overrides publish behavior, connectivity, dirty-flag check, timeout, and rearm interval. Modeled on `setKeyRefreshSDKHookForTesting` from ADR-0013. Lets the watchdog be unit-tested in milliseconds against the test seam without standing up a full RelayManager + SyncCoordinator. 9 tests cover idle/failed/parked/retry/chain-cancel/reconnect-clears paths.

## Rationale

- **60-second timeout** matches the App Store push deadline UX bar — long enough to absorb a slow first-time relay handshake (Nostr WebSocket + initial publish often takes 5–15s on cellular), short enough that a stranded user finds out before they've moved on. Any shorter risks a banner-flash-and-clear under normal operation; any longer leaves stranded users in the dark for too long.

- **Connectivity-aware (vs raw wallclock).** Without the connectivity gate, a user who toggled airplane mode mid-onboarding would see the banner fire after 60s of being offline by choice — clearly not what we want to surface. The `isRelayConnected()` check ensures the banner means "the relay is reachable but we still couldn't publish" rather than "the user is offline." When offline, the watchdog parks on a 10s poll loop until connectivity returns or the publish lands; the banner only appears for the actual relay-broken case.

- **Twin-Task pattern (separate publish + watchdog).** Spawning the publish unsupervised (matches ADR-0014's optimistic contract) and tracking only the watchdog Task would have left a stale publish racing the new one on retry. Tracking both lets the cancellation propagate atomically. The publish Task's `Task.isCancelled` guard at the function entry is honest about what cancellation does and doesn't accomplish — it avoids the duplicate when cancel lands pre-schedule (the common case for back-to-back Continue taps), but cannot abort an in-flight relay round-trip.

- **Banner observed via flush-clears-status (vs "user must tap Retry").** A subtle but important UX bug in the first implementation: a user who tapped Retry on a flaky relay, got online again, and had `flushPendingSyncPublishes` succeed silently in the background would still see the banner until they tapped Retry again. `clearOnboardingPublishStatusIfDomainsClean` invoked after every successful flush makes the banner self-dismiss when the underlying state is clean, regardless of how the publish actually succeeded.

- **Reconnect-flush is gated on `.ready`** (per ADR-0014). The watchdog runs *during* the `.paymentSetup → .ready` window when reconnect-flush does not fire. This is by design: during the onboarding window, the natural retry from `completePaymentSetup` republishing profile via `saveAndPublishSettings` is the fast path; the watchdog only fires when even that fast path didn't land. Once `.ready`, the standard reconnect-flush path is the retry, and `clearOnboardingPublishStatusIfDomainsClean` makes its success visible.

- **Test seam on the same pattern as `setKeyRefreshSDKHookForTesting`.** Five hooks (publish, connectivity, isDirty, timeout, rearmInterval) sound like a lot, but each is needed: replacing publish lets the test control whether dirty stays set without hitting a relay; connectivity drives the offline-park branch deterministically; isDirty isolates the watchdog from a full SyncCoordinator setup; the two timing knobs make tests run in milliseconds. Wiring a real `RelayManager + SyncCoordinator + RoadflareDomainService` for unit tests would have been disproportionate.

## Alternatives Considered

- **Plain wallclock timer (no connectivity gate).** Simpler — single `Task.sleep(60)`. Rejected because a user toggling airplane mode would see false alarms framed as "we couldn't reach the relay" when the cause was their own connectivity choice. The agent UX bar for first-time onboarding is very low.

- **Bind the banner directly to `syncStore.metadata(for: .profile).isDirty` via `@Observable`.** Cleaner architecturally, but `RoadflareSyncStateStore` lives in `RidestrSDK` and is not `@Observable` — and making it observable just for this UI surface would push UI concerns into the SDK, contradicting `.claude/CLAUDE.md`'s "Sync domain logic belongs in the SDK" but in reverse (UI-binding logic doesn't belong in the SDK either). The `OnboardingPublishStatus` shim on `AppState` keeps the boundary clean.

- **Fire the banner immediately when the publish errors.** `publishProfileAndMark` swallows errors silently (logs only) — surfacing them would require a substantial SDK API change to propagate failure outcomes to the caller. Out of scope for #88; would land as its own ADR.

- **Modal alert instead of inline banner.** Rejected because modals interrupt the user mid-task. The banner is non-blocking, allowing the user to finish whatever they were doing and tap Retry on their own schedule.

- **Persist `OnboardingPublishStatus` across launches.** Rejected because (a) the dirty flag in `RoadflareSyncStateStore` is the source of truth and already persists, and (b) re-arming the watchdog on cold launch would require deciding when to restart the timer, which is conceptually messy. App-launch resume is already handled by `setupServicesWithSync`'s startup sync — that path runs reconnect-flush and would benefit from `clearOnboardingPublishStatusIfDomainsClean`, but since status is `.idle` on cold launch, there's nothing to clear.

- **One-Task pattern (publish supervises its own timeout via async-let + cancel-on-timeout).** Considered; rejected because the publish needs to keep running even if the watchdog fires (the Kind 0 round-trip may still succeed after 60s, and we want the dirty flag cleared if it does). Separating watchdog and publish lifecycles lets each run to its natural conclusion.

## Consequences

- **New public API on `AppState`:** `OnboardingPublishStatus`, `OnboardingPublishDomain`, `var onboardingPublishStatus`, `func retryOnboardingPublish()`. New private API: `startOnboardingPublish(domain:)`, the watchdog impl, and the test seam.
- **`RootView` is now a `VStack`-rooted view** (banner + auth-state content) rather than a bare auth-state switch. The auth-state subviews retain their own `Color.rfSurface.ignoresSafeArea()` backgrounds; SwiftUI's default safe-area handling on the VStack root keeps the banner below the status bar.
- **Issue #88 is closed.** ADR-0014's "Consequences §4" deferral now resolves — the failure surface exists. The failure mode for "user finishes onboarding offline, never reconnects, never foregrounds, never restarts" is now: banner stays up until the user takes one of those actions. If they migrate to a different device first, data loss still occurs — surfacing that with a stronger guarantee (e.g. blocking onboarding completion until publish lands) was deemed worse than the current trade-off.
- **Test seam adds DEBUG-only code paths.** The `#if DEBUG` blocks in `runOnboardingPublishImpl`, `isOnboardingDomainDirty`, `isOnboardingPublishOnline`, and the timing helpers are stripped from Release builds.
- **Watchdog lifetime.** Both Tasks survive backgrounding (no explicit cancellation on app suspension), bounded by retry, identity replacement, and process death. A user who backgrounds while parked offline keeps a Task alive until they foreground or terminate; cheap (10s sleeps in a heap-allocated continuation, no real stack consumption) and self-dismisses on app launch reset.

## Affected Files

- `RoadFlare/RoadFlareCore/ViewModels/AppState.swift` — types, observable state, watchdog Tasks, `startOnboardingPublish`, `retryOnboardingPublish`, `clearOnboardingPublishStatusIfDomainsClean`, helper accessors with DEBUG overrides, test seams (`setOnboardingPublishHooksForTesting`, `clearOnboardingPublishStatusIfDomainsCleanForTesting`), reset block in `prepareForIdentityReplacement`, integration call from `reconnectAndRestoreSession`.
- `RoadFlare/RoadFlare/Views/Shared/OnboardingPublishFailureBanner.swift` — new view.
- `RoadFlare/RoadFlare/Views/RootView.swift` — VStack-rooted layout with banner above `@ViewBuilder` `authStateContent`.
- `RoadFlare/RoadFlareTests/AppState/OnboardingPublishWatchdogTests.swift` — 9 watchdog tests via the test seam.
- `decisions/0015-onboarding-publish-failure-surface.md` — this file.
