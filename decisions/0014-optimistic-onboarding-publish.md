# ADR-0014: Optimistic Onboarding Publish

**Status:** Active
**Created:** 2026-04-29
**Tags:** concurrency, ux, sync, onboarding

## Context

`AppState.completeProfileSetup(name:)` and `completePaymentSetup()` previously awaited a Nostr relay publish before flipping `authState` to the next stage:

```swift
public func completeProfileSetup(name: String) async {
    settings.setProfileName(name)
    syncCoordinator?.markDirty(.profile)
    await publishProfile()              // ← network round-trip
    authState = .paymentSetup           // ← gated on the round-trip
}
```

Tapping Continue on either onboarding screen left the view visibly frozen for several seconds while the publish completed — one Kind 0 publish on profile setup, one Kind 0 + one Kind 30177 on payment setup. The freeze was reported during device testing of issue #83's layout fix on iPhone 16e and reproduced consistently on cellular networks. The SDK's `publishProfileAndMark` already swallows publish errors silently (logs only), so the awaited round-trip was not providing a user-visible failure surface — it was only blocking the UI.

The publish state machine already records intent durably: `RoadflareSyncStateStore.markDirty` writes the dirty flag synchronously to UserDefaults, and `SyncCoordinator.flushPendingSyncPublishes` republishes any dirty domain on relay reconnect. The retry path existed; the awaited publish was redundant durability for a state machine that already had a stronger guarantee.

## Decision

Advance `authState` immediately after marking the relevant sync domain dirty, and spawn the publish as a fire-and-forget `Task`:

```swift
public func completeProfileSetup(name: String) async {
    settings.setProfileName(name)
    syncCoordinator?.markDirty(.profile)   // persists dirty flag synchronously
    authState = .paymentSetup              // optimistic
    Task { await self.publishProfile() }   // fire-and-forget
}

public func completePaymentSetup() async {
    settings.setProfileCompleted(true)
    syncCoordinator?.markDirty(.profileBackup)
    authState = .ready
    Task { await self.saveAndPublishSettings() }
}
```

**Retry layering:**
1. **Profile-setup natural retry** — if `publishProfile` fails during the `.paymentSetup` window, `completePaymentSetup` re-attempts it via `saveAndPublishSettings`, which calls `publishProfile()` + `publishProfileBackup()` sequentially.
2. **Reconnect flush** — once `authState == .ready`, `SyncCoordinator.flushPendingSyncPublishes` republishes any still-dirty domain on the next relay reconnect (triggered by foreground transition or the connection-coordinator watchdog). The `.ready` gate is enforced at every flush call site (`handleForeground` line 463, connection-coordinator `shouldReconnect` closures lines 689/739), so flush does not fire during the `.profileIncomplete → .paymentSetup` window.
3. **App-launch resume** — the dirty flag survives termination via UserDefaults, so a publish interrupted by app kill is republished by `setupServicesWithSync`'s startup sync.

A user-visible failure surface (60s watchdog + retry banner) is intentionally deferred to issue #88 along with the AppState publish-injection test seam needed to exercise it deterministically.

## Rationale

- **The awaited publish was not load-bearing for failure surface.** `publishProfileAndMark` swallows errors internally (logs only) — awaiting it gave the UI no signal it could act on. Removing the await loses no information.
- **The dirty flag is the source of truth, not the await.** `markDirty` writes synchronously to UserDefaults; the retry path is already in place. Awaiting the publish was duplicating the durability guarantee with a slow synchronous round-trip.
- **Onboarding is the worst surface for blocking on the network.** First-time users on cellular often have multi-second relay handshakes. A frozen Continue button reads as a broken app and abandons users at the highest-value moment in the funnel.
- **Layered retry covers the realistic failure modes.** A profile publish that fails during `.paymentSetup` gets a free retry from `completePaymentSetup`. A profile-backup publish that fails during `.ready` gets retried by foreground reconnect. An app-kill mid-publish gets retried at next launch. The only case left uncovered is "user reaches `.ready` and never reconnects, never foregrounds, never restarts" — the case #88's user-visible surface targets explicitly.

## Alternatives Considered

- **Keep awaited publish.** Status quo. Multi-second freeze on Continue. Rejected — direct user-visibility regression with no failure-surface benefit (errors already silent).
- **Awaited publish + loading spinner / disabled button.** Better UX than frozen view, still slow. Doesn't fix the underlying redundancy. Rejected — adds UI for a wait the user shouldn't have to see.
- **Optimistic transition + immediate failure-surface watchdog (60s + banner + retry button).** This is the right end state, but the watchdog needs an AppState publish-injection test seam that doesn't yet exist, and the banner needs UI design (placement, copy, persistence-across-launches semantics). Splitting it from the lag-fix lets the layout fix and the lag fix ship under the App Store deadline; the watchdog work is tracked in #88.
- **Move the optimistic-publish coordination into a new SDK API (e.g., `markDirtyAndPublishInBackground`).** Considered for module-boundary cleanliness per `.claude/CLAUDE.md`'s "sync domain logic belongs in the SDK." Rejected because the fire-and-forget `Task { await self.publishProfile() }` is UI-orchestration sequencing, not protocol semantics — the actual publish (`publishProfileAndMark`) already lives in the SDK. A helper that wraps "spawn a Task to call an SDK method" would be a one-line indirection that adds an SDK API for one app-side caller. Tracked as a candidate consolidation if a second caller appears.

## Consequences

- Both `completeProfileSetup` and `completePaymentSetup` return immediately on the call's `await`. Call sites that previously assumed publish completion before the function returns no longer hold (none in production code; the test suite did not assert on this either).
- The doc comments on both methods explicitly describe the retry layering and the `.ready` gate, so a future reader looking at `Task { await self.publishProfile() }` finds the contract in the same place as the code.
- Failure mode is unchanged from `main`: previously silent (errors swallowed), now still silent. PR #85 does not regress error visibility — it just stops blocking the UI on it.
- Issue #88 is now load-bearing for the user-visible failure surface. If #88 ships, it will leverage the same dirty-flag mechanism this ADR describes; if it slips, the failure mode remains identical to pre-PR-#85 (silent + retry-on-reconnect).

## Affected Files

- `RoadFlare/RoadFlareCore/ViewModels/AppState.swift` — `completeProfileSetup`, `completePaymentSetup` (commit 9ae695c, doc comments tightened in c5ab595)
- `decisions/0014-optimistic-onboarding-publish.md` — this file
