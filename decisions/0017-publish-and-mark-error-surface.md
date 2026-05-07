# ADR-0017: SDK Publish-and-Mark Error Surface

**Status:** Active
**Created:** 2026-05-05
**Tags:** sync, ux, public-api, sdk

## Context

[ADR-0016](0016-onboarding-publish-failure-surface.md) shipped a 60-second watchdog that fires the onboarding publish-failure banner after the dirty flag in `RoadflareSyncStateStore` has stayed set past the timeout window. The watchdog observes the dirty flag as a *proxy* for failure — the SDK's `RoadflareDomainService.publishProfileAndMark` and `ProfileBackupCoordinator.publishAndMark` both swallow `try`-thrown errors at the SDK boundary (log only, return `Void`). The watchdog is the only signal the app has that something went wrong.

This works, but it has two costs:

1. **Latency.** A relay that returns an explicit error in 200ms still leaves the user staring at a "successful" Continue tap for the full 60-second window before the banner appears. The dirty-flag proxy can't distinguish "publish failed instantly" from "publish is in flight" from "publish hung."

2. **No diagnostic precision.** The banner copy is generic ("Your profile hasn't been backed up yet") because the watchdog has no `Error` to look at — at the moment the banner is decided, the original failure cause has been logged and discarded. Even if we wanted to differentiate "relay rejected your event" from "we couldn't reach the relay," the information is gone.

Issue #97 item 2 captured this as the next architectural follow-up. The precedent — [ADR-0013](0013-stale-key-refresh-flow.md)'s `LocationSyncCoordinator.requestKeyRefresh` migration from "best-effort, swallows errors" to `throws` — already exists.

## Decision

Promote `RoadflareDomainService.publishProfileAndMark` and `ProfileBackupCoordinator.publishAndMark` from `async` to `async throws`. App-side wrappers (`AppState.publishProfile`, `publishProfileBackup`, `saveAndPublishSettings`) propagate. `runOnboardingPublishImpl` catches at the AppState boundary and surfaces the banner eagerly when online.

### Scope

Two SDK helpers change signature:

- `RoadflareDomainService.publishProfileAndMark(from:syncStore:)` — `async` → `async throws`
- `ProfileBackupCoordinator.publishAndMark(settings:savedLocations:)` — `async` → `async throws`

Two SDK helpers stay `async` (out of scope):

- `RoadflareDomainService.publishFollowedDriversListAndMark` — not on the onboarding watchdog path. The watchdog observes `.profile` and `.profileBackup` only; followed-drivers failures are caught by the next reconnect-flush. Migrating this would be cosmetic.
- `RoadflareDomainService.publishRideHistoryAndMark` — same reason. Plus `RideHistorySyncCoordinator.publishAndMark` already marks the domain dirty on failure inside its own internal `Task`, which is the contract its callers rely on. Throwing out of it would change a fire-and-forget API into one its synchronous call sites can't observe.

Limiting scope to the two helpers the onboarding watchdog actually consumes keeps the change focused. Future need (e.g. surfacing followed-drivers backup failures with a different UI) can revisit.

### Eager-error path in `runOnboardingPublishImpl`

`runOnboardingPublishImpl` wraps the publish in `do/catch`. On catch:

1. Re-check `Task.isCancelled` (a retry that lands during the await must not clobber the new state).
2. Log the underlying error so the diagnostic context survives.
3. Run the same `isOnboardingPublishOnline()` connectivity check the watchdog uses.
4. If online: set `onboardingPublishStatus = .failed(domain:)` and cancel the watchdog (it would otherwise fire at +60s with the same value — idempotent but noisy).
5. If offline: do nothing. The watchdog's offline-park loop is the right place to wait for connectivity to come back; no point duplicating it inside the publish Task.

The watchdog Task itself is preserved unchanged. It now serves two narrower purposes: (a) safety net for the case where the SDK call hangs without returning at all (no `throw`, no completion), and (b) the offline-park loop the eager path defers to.

### Test seam migration

`setOnboardingPublishHooksForTesting`'s `publish` parameter changes from `((OnboardingPublishDomain) async -> Void)?` to `((OnboardingPublishDomain) async throws -> Void)?`. Existing tests' non-throwing closures stay valid (Swift accepts a non-throwing closure where a throwing closure is expected). One new test exercises the eager-error path by throwing from the hook.

## Rationale

- **`throws` over `Outcome` enum.** ADR-0013's `KeyRefreshOutcome` is an enum because the SwiftUI button handler renders three distinct states (success toast, rate-limit toast, publish-failed toast). Onboarding has only two: success (banner stays idle) and failure (banner fires). A binary outcome is what `throws` is for, and it preserves the underlying error type for logging without forcing every caller to invent its own error-classification.

- **Two helpers, not all four.** Migrating `publishFollowedDriversListAndMark` and `publishRideHistoryAndMark` simultaneously would touch ~30 lines of test fixtures and three additional call sites for no observable user benefit — neither feeds the onboarding watchdog. The `RideHistorySyncCoordinator.publishAndMark` case is an actual mismatch: its callers don't `await` it (it spawns its own internal `Task`), so making the inner publish throw would change a fire-and-forget contract.

- **Eager path defers to the watchdog when offline.** The first cut of this design had the eager-error path call `checkOnboardingPublishOutcome` directly, which would have made the publish Task itself become the offline-park loop (recursive `Task.sleep` until connectivity returns). That works but conflates publish-Task lifetime with watchdog-Task lifetime in a way that's hard to reason about (why is the publish Task still running 30 seconds after the publish errored?). Letting the watchdog own the offline-park branch keeps each Task's purpose distinct.

- **Online-eager-fire cancels the watchdog.** When the eager path fires the banner, the watchdog's +60s `.failed(domain:)` write would be a redundant idempotent set — same value. Cancelling the watchdog avoids a stray `Task.sleep(60)` continuation hanging around for no purpose. (Cancellation is cheap; the continuation wakes early with `CancellationError`, the catch returns, the Task deallocates.)

- **`ProfileBackupCoordinator.publishAndMark` republish-loop semantics preserved.** The coordinator has a republish-on-dirty loop that coalesces concurrent `publishAndMark` calls. A naive `try await` inside the loop would throw on the first iteration's error and abandon the queued republish. Instead, the loop tracks the most recent iteration's error, returns success (no throw) if any iteration succeeded during the call window, and throws the *final* iteration's error if no successful publish landed. This preserves the existing coalescing semantic (a fast follow-up call can still rescue an initial failure) while still surfacing terminal failures.

- **Why the connectivity gate at all on the eager path.** A `try` failure can be a network error ("can't reach relay") just as easily as a relay-rejection error. Without the connectivity gate, a user who toggled airplane mode mid-onboarding would get an instant banner saying "your profile hasn't been backed up" — which is true, but the cause is their own network choice, not a server-side problem. Same reasoning as ADR-0016's connectivity gate; it applies identically to the eager-error path.

## Alternatives Considered

- **Outcome enum (`PublishAndMarkOutcome { case published(eventId), failed(Error) }`).** Rejected as ADR-0013 precedent doesn't apply: that enum existed to gate three SwiftUI render branches; here we have two, which is exactly the case `throws` was designed for. Adding an enum would also add a public type to the SDK API surface for no observable benefit.

- **Add a parallel throwing variant alongside the existing `Void` one (`publishProfileAndMarkThrowing`).** Rejected because the `Void` variant has no remaining call site that *actively benefits* from error suppression — every existing caller either (a) catches with `try?` (no behavior change), or (b) wants the error (the new onboarding path). Keeping both variants would just add API surface that callers have to choose between, with no clear "use this when..." guidance.

- **Migrate all four `publishXAndMark` helpers in one PR.** Rejected as out of scope for #97 item 2; the followed-drivers and ride-history paths have different consumer expectations. Future need can revisit (e.g. if a new feature wants to surface ride-history backup failures).

- **Retire the watchdog entirely now that the eager path exists.** Rejected because the watchdog covers a case the eager path can't: a `try await publishProfile()` that hangs indefinitely without throwing. Rare, but observed enough on flaky relays that the safety net is worth keeping. The +60s window for the hang case is the same as it was before the eager path existed — no regression.

- **Differentiate banner copy by error type ("relay rejected" vs "couldn't reach relay").** Rejected for now. The user's action in both cases is the same (tap Retry); differentiated copy would mostly just communicate "we tried and something specific happened" without giving the user new agency. The error is still logged, which is enough for diagnostic purposes. A future UX iteration could revisit.

## Consequences

- **SDK API change.** Two `public` methods become `throws`. Existing call sites in `SyncCoordinator.flushPendingSyncPublishes` and `SyncCoordinator.performStartupSync` (via `SyncDomainStrategy.publishLocal` closures) wrap with `try?` to preserve current best-effort behavior. The previous SDK-level log line (`"[RoadflareDomainService] Failed to publish profile: ..."`) moves up to the call site that cares — `runOnboardingPublishImpl` logs in its catch block; `try?` discard sites lose the log because the dirty flag is enough signal there (the next reconnect-flush will retry).

- **Eager banner.** A relay-rejected onboarding publish surfaces the banner in the time it takes to round-trip the rejection (~hundreds of ms) instead of waiting +60s. Watchdog still fires for the hang case.

- **Test seam signature change.** `setOnboardingPublishHooksForTesting`'s `publish` parameter is now `((OnboardingPublishDomain) async throws -> Void)?`. Existing non-throwing test closures keep working without modification.

- **No persistence change.** Dirty flags continue to be the source of truth for "did this domain reach a relay." The `throws` change only adds a faster *signal* for the failure case; it doesn't change what the SDK persists.

- **One new failure-mode test (`OnboardingPublishWatchdogTests`).** Verifies that an SDK throw fires the banner without waiting for the watchdog timeout.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/RoadFlare/RoadflareDomainService.swift` — `publishProfileAndMark` becomes `throws`; SDK-level catch+log removed.
- `RidestrSDK/Sources/RidestrSDK/RoadFlare/ProfileBackupCoordinator.swift` — `publishAndMark` becomes `throws`; republish loop tracks last-iteration error and rethrows on terminal failure.
- `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/RoadflareDomainServiceTests.swift` — `try await` at the test call site; new throw-on-relay-failure assertion.
- `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/ProfileBackupCoordinatorTests.swift` — `try await` at test call sites; failure-path test asserts the throw.
- `RoadFlare/RoadFlareCore/ViewModels/AppState.swift` — `publishProfile`, `publishProfileBackup`, `saveAndPublishSettings` propagate; `runOnboardingPublishImpl` catches and runs the connectivity-gated eager surface; test seam hook signature now `throws`; doc-comment on `onboardingPublishTask` updated.
- `RoadFlare/RoadFlareCore/ViewModels/SyncCoordinator.swift` — `flushPendingSyncPublishes` and the four `SyncDomainStrategy.publishLocal` closures wrap the now-throwing helpers with `try?`.
- `RoadFlare/RoadFlareTests/AppState/OnboardingPublishWatchdogTests.swift` — new test for the eager-error path.
- `decisions/0017-publish-and-mark-error-surface.md` — this file.
