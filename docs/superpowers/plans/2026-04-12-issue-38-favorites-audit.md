# Issue #38 — Audit & Remove `onFavoritesChanged`

**Date:** 2026-04-12
**Issue:** #38
**Branch:** `claude/issue-38-favorites-audit`

---

## Summary

`SavedLocationsRepository.onFavoritesChanged` is a public callback that fires when the pinned-favorites set changes (add/remove/rename/clear). It has a supporting private helper (`notifyFavoritesChangedIfNeeded`) and a private struct (`FavoriteSignature`) that exist solely to compute whether favorites actually changed. Despite being fully implemented and covered by two tests, **no production code ever assigns a closure to it**. The fix is to remove the property, its supporting infrastructure, the nil-out in `SyncDomainTracker._detachUnchecked()`, and the two tests that cover it.

---

## Research Findings

### All references to `onFavoritesChanged` and its supporting infrastructure (main tree only, excluding worktrees and docs)

| File | Line | Role |
|------|------|------|
| `RidestrSDK/Sources/RidestrSDK/RoadFlare/SavedLocationsRepository.swift` | 29 | Declaration (`public var`) |
| `RidestrSDK/Sources/RidestrSDK/RoadFlare/SavedLocationsRepository.swift` | 164 | `persistAndNotify(previousFavorites:)` signature — takes `[FavoriteSignature]` param (must change to no-arg) |
| `RidestrSDK/Sources/RidestrSDK/RoadFlare/SavedLocationsRepository.swift` | 168 | `notifyFavoritesChangedIfNeeded` call inside `persistAndNotify` (must be removed) |
| `RidestrSDK/Sources/RidestrSDK/RoadFlare/SavedLocationsRepository.swift` | 179 | Called inside `notifyFavoritesChangedIfNeeded` |
| `RidestrSDK/Sources/RidestrSDK/RoadFlare/SyncDomainTracker.swift` | 86 | Nil'd in `_detachUnchecked()` (with explanatory comment) |
| `RoadFlare/RoadFlareTests/RoadFlareTests.swift` | 131 | Test: `recentsDoNotTriggerFavoritesChanged` |
| `RoadFlare/RoadFlareTests/RoadFlareTests.swift` | 148 | Test: `pinningFavoriteTriggersFavoritesChanged` |

There are no references in `RoadFlare/RoadFlareCore/` production source (the main-tree `SyncCoordinator.swift` has zero hits — the old teardown nil-out was already migrated to `SyncDomainTracker` when PR #37 landed).

### Supporting dead code pulled in by the property

`onFavoritesChanged` is the sole reason three other private items exist:

- `notifyFavoritesChangedIfNeeded(_:)` — private method, only calls `onFavoritesChanged?()`
- `favoriteSignaturesLocked()` — private method, builds `[FavoriteSignature]` for diffing; called only from `notifyFavoritesChangedIfNeeded` and the mutation methods that pass snapshots to it
- `FavoriteSignature` — private `Equatable` struct, exists solely for the diff comparison

Removing `onFavoritesChanged` makes all four of these unreachable and eligible for deletion.

### `previousFavorites` snapshot captures in mutation methods

Every public mutation method (`save`, `pin`, `unpin`, `remove`, `restoreFromBackup`, `clearAll`) captures a `previousFavorites` snapshot via `favoriteSignaturesLocked()` before mutating, then passes it to `persistAndNotify(previousFavorites:)` or `notifyFavoritesChangedIfNeeded`. All of these call sites must be cleaned up when the helper is removed.

### Why it is truly dead code

- `onChange` already fires for every location mutation including favorites changes. `SyncDomainTracker.wireCallbacks()` wires `onChange → markDirty(.profileBackup)`. A separate `onFavoritesChanged → profileBackup` mapping would double-fire `markDirty` on favorites mutations.
- All favorites-aware UI uses SwiftUI's `@Observable` auto-refresh; no imperative callback is needed.
- The nil-out in `_detachUnchecked()` is documented in-code as a guard against a callback that is "intentionally NOT wired."
- `onFavoritesChanged` was present from the first commit of `SavedLocationsRepository` (65ef4a3, 2026-03-31) and has never had a production caller assigned to it.

### Is this prerequisite on #29?

The issue notes #29 as a prerequisite ("SyncDomainTracker adds a new nil-out"). PR #37 (merged, now on main) already moved the nil-out from `SyncCoordinator.teardown()` into `SyncDomainTracker._detachUnchecked()`. The main tree at `09f70bf` reflects that state. There is no additional nil-out pending from #29 that would affect this cleanup.

---

## Decision

**Remove it.** YAGNI applies: zero production callers, UI is `@Observable`-driven, sync already covered by `onChange`. The `FavoriteSignature` diff machinery is non-trivial complexity (snapshot before every mutation + `Equatable` struct) to support a callback that does nothing. Removing it reduces public API surface and eliminates dead code paths exercised on every location mutation.

No ADR needed — this is an internal property removal with no public API consumers and no module-boundary or concurrency-model change.

---

## Implementation Steps

### 1. `RidestrSDK/Sources/RidestrSDK/RoadFlare/SavedLocationsRepository.swift`

a. Remove the `onFavoritesChanged` property declaration (line 28–29).

b. Remove the `notifyFavoritesChangedIfNeeded(_:)` private method (lines 176–180).

c. Remove the `FavoriteSignature` private struct (lines 198–206).

d. Remove the `favoriteSignaturesLocked()` private method (lines 182–195).

e. In each public mutation method, remove the `previousFavorites` snapshot capture and update the call to `persistAndNotify` / `clearAll` helper:
   - `save(_:)`: remove `let previousFavorites = favoriteSignaturesLocked()` and change `persistAndNotify(previousFavorites:)` to a no-arg call (or inline `persistAndNotify`)
   - `pin(id:nickname:)`: same
   - `unpin(id:)`: same
   - `remove(id:)`: same
   - `restoreFromBackup(_:)`: same
   - `clearAll()`: remove snapshot + `notifyFavoritesChangedIfNeeded(previousFavorites)` call

f. Update `persistAndNotify` to remove its `previousFavorites` parameter (it will just call `persistence.saveLocations` + `notifyChanged()`).

### 2. `RidestrSDK/Sources/RidestrSDK/RoadFlare/SyncDomainTracker.swift`

Remove lines 82–86 in `_detachUnchecked()` — the explanatory comment block and the `savedLocations.onFavoritesChanged = nil` assignment.

### 3. `RoadFlare/RoadFlareTests/RoadFlareTests.swift`

Remove the two test functions that exercise `onFavoritesChanged`:
- `recentsDoNotTriggerFavoritesChanged()` (lines 125–142)
- `pinningFavoriteTriggersFavoritesChanged()` (lines 144–163)

---

## Test Strategy

1. After edits, verify no remaining references: `grep -r "onFavoritesChanged\|favoriteSignaturesLocked\|FavoriteSignature\|notifyFavoritesChangedIfNeeded" RidestrSDK/ RoadFlare/`

2. Build the full Xcode project (not just SPM) to catch any concurrency or compile errors:
   ```
   xcodebuild -project RoadFlare/RoadFlare.xcodeproj \
     -scheme RoadFlare \
     -destination 'platform=iOS Simulator,name=iPhone 16' \
     build test
   ```

3. Confirm the remaining `SavedLocationsRepositoryTests` still pass (`restoreFromBackupReplacesAll`, `persistsViaPersistence`, and any others that do not touch `onFavoritesChanged`).

---

## No ADR Required

Per CLAUDE.md: ADRs are not needed for bug fixes, internal single-file refactors, test additions, or doc updates. Removing an unwired internal callback across two source files and one test file qualifies as internal cleanup — no new public API, no concurrency model change, no module boundary shift.
