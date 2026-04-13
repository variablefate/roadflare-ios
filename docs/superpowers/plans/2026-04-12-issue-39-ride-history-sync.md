# RideHistorySyncCoordinator SDK Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Unify the two ride-history sync paths (passive `onRidesChanged → markDirty` via `SyncDomainTracker`, and active fire-and-forget publish via `RideCoordinator.backupRideHistory()`) into a single SDK class `RideHistorySyncCoordinator`, parallel to `ProfileBackupCoordinator`. Eliminate the redundant `markDirty` wiring from `SyncDomainTracker` and give the publish logic an SDK home with tests.

**Architecture:** `RideHistorySyncCoordinator` lives in `RidestrSDK/Sources/RidestrSDK/RoadFlare/` alongside `ProfileBackupCoordinator`. It owns the fire-and-forget publish Task (with `markDirty`-on-failure), a `clearAll()` for teardown, and a generation counter to safely handle identity replacement. `SyncCoordinator` owns the coordinator instance (created in `configure()`, cleared in `teardown()`). Call sites (`RideCoordinator.recordCompletedRide` / `HistoryTab.onDelete`) call `syncCoordinator.rideHistorySyncCoordinator?.publishAndMark(from: rideHistory)` instead of `rideCoordinator?.backupRideHistory()`. `SyncDomainTracker` drops the `rideHistory.onRidesChanged → markDirty(.rideHistory)` wiring (the coordinator's `markDirty`-on-failure covers offline).

**Tech Stack:** Swift, RidestrSDK (SPM package), Swift Testing framework, `@unchecked Sendable` + `NSLock` pattern, `FakeRelayManager` + `InMemoryRideHistoryPersistence` for SDK tests.

---

## ADR Note

**An ADR is required.** This creates a new public SDK type (`RideHistorySyncCoordinator`) and removes an existing wiring from `SyncDomainTracker` — both are new public API surface and a change to established callback-wiring conventions. The next available number is **ADR-0007**.

The ADR should cover:
- **Context:** two-path problem (passive `markDirty` via `SyncDomainTracker` + active `backupRideHistory()` in `RideCoordinator`), and why the passive path is redundant once the coordinator handles `markDirty`-on-failure
- **Decision:** `RideHistorySyncCoordinator` as the single owner of ride-history publish-and-mark, removal of `onRidesChanged` from `SyncDomainTracker`, `backupRideHistory()` body replaced by coordinator call
- **Rationale:** protocol-level publish logic belongs in the SDK, parallels `ProfileBackupCoordinator` pattern, removes accidental complexity, makes the "offline retry via reconnect flush" path the only passive safety net
- **Alternatives Considered:** (a) keep both paths, accept redundancy; (b) move publish into `SyncDomainTracker` callback directly (rejected — `SyncDomainTracker` is for markDirty only, not async publish); (c) make `backupRideHistory()` call `markDirty` instead of publishing (rejected — loses the immediate-publish guarantee in online sessions)
- **Consequences:** `SyncDomainTracker` no longer marks `.rideHistory` dirty on mutation — the coordinator's `catch { markDirty }` is the only dirty-setter for this domain outside of `flushPendingSyncPublishes`

---

## Research Findings

### Current ride-history sync logic in SyncCoordinator.swift

`SyncCoordinator` touches ride history in three places:

1. **`configure()`** — does not wire ride history (no coordinator yet). The `rideHistory` repository is held as a property but only passed to `SyncDomainTracker`.

2. **`wireTrackingCallbacks()` (via `SyncDomainTracker`)** — `SyncDomainTracker.init` wires:
   ```swift
   rideHistory.onRidesChanged = { [weak store] in
       store?.markDirty(.rideHistory)
   }
   ```
   This is the **passive path**: any `addRide`, `removeRide`, `restoreFromBackup`, or `clearAll` call marks `.rideHistory` dirty. It fires on relay-side restores too (via `restoreFromBackup`), which creates unnecessary dirty churn during startup sync.

3. **`flushPendingSyncPublishes()`** — checks `syncStore.metadata(for: .rideHistory).isDirty` and calls `service.publishRideHistoryAndMark(from: rideHistory, syncStore: syncStore)`. This is the **reconnect-retry path** and is the correct passive safety net for the offline case. This path must remain unchanged.

4. **`performStartupSync()` (ride history strategy)** — uses `SyncDomainStrategy<RideHistoryBackupContent>` with a `shouldPublishGuard: { true }` override (empty history is valid after deletion). Calls `service.publishRideHistoryAndMark(from: rideHistory, syncStore: syncStore)` when local state should be published. This is a startup-time path; it is not affected by this issue.

### Current ride-history sync logic in RideCoordinator.swift

`RideCoordinator` has two ride-history sync touch points:

1. **`backupRideHistory()`** (lines 336–348) — the **active publish path**:
   ```swift
   public func backupRideHistory() {
       guard let service = roadflareDomainService,
             let syncStore = roadflareSyncStore else { return }
       Task {
           do {
               let content = RideHistoryBackupContent(rides: rideHistory.rides)
               let event = try await service.publishRideHistoryBackup(content)
               syncStore.markPublished(.rideHistory, at: event.createdAt)
           } catch {
               syncStore.markDirty(.rideHistory)
           }
       }
   }
   ```
   Called from: `recordRideHistory()` (after a completed ride) and `HistoryTab.onDelete`.

2. **`recordRideHistory()`** (lines 308–332) — builds a `RideHistoryEntry`, calls `rideHistory.addRide(entry)`, then immediately calls `backupRideHistory()`. After this change, it will call `rideHistorySyncCoordinator?.publishAndMark(from: rideHistory)` instead.

### HistoryTab.swift call site

```swift
appState.rideHistory.removeRide(id: ride.id)
appState.rideCoordinator?.backupRideHistory()
```

After the change: call the coordinator directly via `appState.syncCoordinator.rideHistorySyncCoordinator?.publishAndMark(from: appState.rideHistory)`, or expose a convenience through `AppState`.

### What the passive `onRidesChanged → markDirty` path was protecting against

The passive path exists because `flushPendingSyncPublishes` only runs on relay reconnect — in a continuous online session, a deletion or new ride might never get flushed. The active `backupRideHistory()` publish fills this gap by publishing immediately. If the active publish succeeds, it calls `markPublished`, which clears the dirty flag. If it fails, it calls `markDirty`, which ensures the reconnect flush will retry.

Therefore the `onRidesChanged → markDirty(.rideHistory)` wiring in `SyncDomainTracker` is logically redundant when `backupRideHistory()` is called at every mutation site. The redundancy is safe (the two paths do not conflict) but adds accidental complexity — particularly, it marks dirty during `restoreFromBackup` during startup sync, which is semantically wrong (we just restored from the relay; there is nothing to sync back).

---

## New SDK Type: RideHistorySyncCoordinator

File: `RidestrSDK/Sources/RidestrSDK/RoadFlare/RideHistorySyncCoordinator.swift`

```swift
/// SDK-owned coordinator for ride history backup sync.
///
/// Owns the fire-and-forget publish Task for any user-initiated ride history
/// mutation (add ride after ride completion, remove ride from history).
/// On publish failure, marks `.rideHistory` dirty so `flushPendingSyncPublishes`
/// retries on the next relay reconnect.
///
/// Thread safety: NSLock-protected state. Generation counter invalidates
/// in-flight publish Tasks that cross a `clearAll()` boundary (identity
/// replacement). Parallel to `ProfileBackupCoordinator`.
///
// @unchecked Sendable: all mutable state protected by `lock`.
public final class RideHistorySyncCoordinator: @unchecked Sendable {
    private let domainService: RoadflareDomainService
    private weak var syncStoreRef: RoadflareSyncStateStore?

    private let lock = NSLock()
    /// Bumped by `clearAll()` to invalidate in-flight publish Tasks.
    private var generation: UInt64 = 0

    public init(domainService: RoadflareDomainService, syncStore: RoadflareSyncStateStore) {
        self.domainService = domainService
        self.syncStoreRef = syncStore
    }

    // MARK: - Publish

    /// Publish ride history immediately (fire-and-forget Task).
    /// Marks `.rideHistory` dirty on failure so the reconnect flush retries.
    ///
    /// Call after any user-initiated ride history mutation:
    /// - after `rideHistory.addRide(entry)` (ride completion)
    /// - after `rideHistory.removeRide(id:)` (swipe-to-delete)
    ///
    /// Safe to call from `@MainActor` — the Task captures the rides snapshot
    /// at call time via `rideHistory.rides` (main-actor isolated read).
    public func publishAndMark(from rideHistory: RideHistoryRepository) {
        let rides = rideHistory.rides
        let myGeneration: UInt64 = lock.withLock { generation }
        Task {
            let content = RideHistoryBackupContent(rides: rides)
            do {
                let event = try await domainService.publishRideHistoryBackup(content)
                lock.withLock {
                    guard generation == myGeneration else { return }
                    syncStoreRef?.markPublished(.rideHistory, at: event.createdAt)
                    RidestrLogger.info("[RideHistorySyncCoordinator] Published ride history backup")
                }
            } catch {
                lock.withLock {
                    guard generation == myGeneration else { return }
                    syncStoreRef?.markDirty(.rideHistory)
                    RidestrLogger.info("[RideHistorySyncCoordinator] Failed; marked dirty: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Cleanup

    /// Bump generation to invalidate any in-flight publish Task.
    /// Called by `SyncCoordinator.teardown()` on identity replacement.
    public func clearAll() {
        lock.withLock { generation &+= 1 }
    }
}
```

**Design notes:**
- No `isPublishing`/`republishRequested` loop (unlike `ProfileBackupCoordinator`) — ride history publish is not expected to be concurrent-heavy; a simple fire-and-forget Task per mutation is sufficient. If a mutation races with an in-flight publish, the later publish wins at the relay (Kind 30174 is replaced by `created_at`).
- Generation counter protects against `clearAll()` crossing a Task boundary — if identity changes while a publish is awaiting, the Task exits without touching the new session's sync store.
- `syncStoreRef` is `weak` — same pattern as `ProfileBackupCoordinator`, protects against the teardown race where the store is released before the Task completes.
- The rides snapshot is captured at call time (`rideHistory.rides`) from `@MainActor` context, so no concurrent access occurs.

---

## File Structure

| File | Change | Responsibility |
|------|--------|---------------|
| `RidestrSDK/Sources/RidestrSDK/RoadFlare/RideHistorySyncCoordinator.swift` | CREATE | New coordinator class |
| `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/RideHistorySyncCoordinatorTests.swift` | CREATE | SDK tests (TDD — write first) |
| `decisions/0007-ride-history-sync-coordinator.md` | CREATE | ADR for new public API |
| `RoadFlare/RoadFlareCore/ViewModels/SyncCoordinator.swift` | MODIFY | Add `rideHistorySyncCoordinator`; wire in `configure()`; release in `teardown()` |
| `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift` | MODIFY | Replace `backupRideHistory()` body with coordinator delegation |
| `RidestrSDK/Sources/RidestrSDK/RoadFlare/SyncDomainTracker.swift` | MODIFY | Remove `rideHistory.onRidesChanged` wiring |
| `RoadFlare/RoadFlare/Views/History/HistoryTab.swift` | MODIFY | Replace `rideCoordinator?.backupRideHistory()` with coordinator call |

**Not changed:** `RoadflareDomainService.swift` (existing `publishRideHistoryBackup` is reused), `Package.swift` (auto-discovers sources), `RideHistoryRepository.swift` (no changes needed — `onRidesChanged` callback stays in the struct for future use by other callers).

---

## Implementation Steps

### Step 1: Write the ADR

- [ ] Create `decisions/0007-ride-history-sync-coordinator.md`
- Follow the structure from ADR-0006 (SyncDomainTracker)
- Cover: Context (two-path redundancy + startup-sync false-dirty), Decision, Rationale, Alternatives, Consequences, Affected Files
- ADR must be written BEFORE implementation (it clarifies the design boundary)

---

### Step 2: TDD — Write failing tests for `RideHistorySyncCoordinator`

Create `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/RideHistorySyncCoordinatorTests.swift` before the implementation file exists. All tests should fail to compile initially.

**Test cases to cover:**

#### Happy-path publish

- [ ] `publishAndMark_onSuccess_marksPublished` — create coordinator with a `FakeRelayManager` wired to succeed; call `publishAndMark(from: rideHistory)` with one ride; assert `syncStore.metadata(for: .rideHistory).isDirty == false` and `lastSuccessfulPublishAt > 0` after awaiting

#### Offline / failure path

- [ ] `publishAndMark_onFailure_marksDirty` — configure relay to throw; call `publishAndMark`; assert `syncStore.metadata(for: .rideHistory).isDirty == true`

#### Generation / clearAll

- [ ] `clearAll_invalidatesInFlightPublish` — start a publish Task, call `clearAll()` before it completes, assert that `markPublished` is NOT called on the store (generation mismatch causes Task to exit silently)
- [ ] `clearAll_afterPublish_doesNotDirtyStore` — full publish succeeds; call `clearAll()`; assert store is untouched (no regression)

#### Empty history

- [ ] `publishAndMark_emptyHistory_succeeds` — valid after deletion; assert publish is attempted even when `rideHistory.rides` is empty; on success, marks published

#### Content snapshot

- [ ] `publishAndMark_snapshotsRidesAtCallTime` — add a ride; call `publishAndMark`; add another ride before the Task completes; assert only the first ride's content was published (snapshot isolation)

**Test helper pattern** (model after `SyncDomainTrackerTests.swift` and `LocationSyncCoordinatorTests.swift`):

```swift
@Suite("RideHistorySyncCoordinator Tests")
struct RideHistorySyncCoordinatorTests {

    private struct TestKit {
        let rideHistory: RideHistoryRepository
        let syncStore: RoadflareSyncStateStore
        let relay: FakeRelayManager
        let coordinator: RideHistorySyncCoordinator
    }

    private func makeKit(keypair: NostrKeypair? = nil) async throws -> TestKit {
        let kp = try keypair ?? NostrKeypair.generate()
        let relay = FakeRelayManager()
        try await relay.connect(to: [URL(string: "wss://fake")!])
        let syncStore = RoadflareSyncStateStore(
            defaults: UserDefaults(suiteName: "rhsc_test_\(UUID().uuidString)")!,
            namespace: UUID().uuidString
        )
        let domainService = RoadflareDomainService(relayManager: relay, keypair: kp)
        let rideHistory = RideHistoryRepository(persistence: InMemoryRideHistoryPersistence())
        let coordinator = RideHistorySyncCoordinator(domainService: domainService, syncStore: syncStore)
        return TestKit(rideHistory: rideHistory, syncStore: syncStore, relay: relay, coordinator: coordinator)
    }

    private func makeEntry(id: String = UUID().uuidString) -> RideHistoryEntry {
        RideHistoryEntry(
            id: id, date: .now, counterpartyPubkey: "driver",
            pickupGeohash: "abc", dropoffGeohash: "def",
            pickup: Location(latitude: 40, longitude: -74),
            destination: Location(latitude: 41, longitude: -73),
            fare: 12.50, paymentMethod: "zelle"
        )
    }
}
```

Note: Tests that need to wait for async Task completion should either use `FakeRelayManager` with a controlled continuation or use `Task.yield()` + a small `Task.sleep`. Check how `LocationSyncCoordinatorTests` handles async Task completion in the existing test suite.

---

### Step 3: Implement `RideHistorySyncCoordinator` in the SDK

- [ ] Create `RidestrSDK/Sources/RidestrSDK/RoadFlare/RideHistorySyncCoordinator.swift` with the interface defined above
- All tests from Step 2 should now pass
- The class uses `@unchecked Sendable` + `NSLock` per CLAUDE.md concurrency conventions
- Generation counter uses wrapping addition (`&+=`) to match `ProfileBackupCoordinator`

---

### Step 4: Update `SyncCoordinator.swift` to delegate to the coordinator

- [ ] Add `private(set) var rideHistorySyncCoordinator: RideHistorySyncCoordinator?` to the owned state section
- [ ] In `configure(syncStore:domainService:)`, after creating `profileBackupCoordinator`, add:
  ```swift
  self.rideHistorySyncCoordinator = RideHistorySyncCoordinator(
      domainService: domainService, syncStore: syncStore
  )
  ```
- [ ] In `teardown(clearPersistedState:)`, after `profileBackupCoordinator?.clearAll()`, add:
  ```swift
  rideHistorySyncCoordinator?.clearAll()
  rideHistorySyncCoordinator = nil
  ```

No change is needed to `performStartupSync()` or `flushPendingSyncPublishes()` — they use `service.publishRideHistoryAndMark(from: rideHistory, syncStore: syncStore)` directly, which is correct for those paths.

---

### Step 5: Update `SyncDomainTracker.swift` — remove `rideHistory.onRidesChanged` wiring

The `onRidesChanged → markDirty(.rideHistory)` callback is now redundant. The coordinator's `catch { markDirty }` is the sole dirty-setter for mutation-triggered publish failures.

- [ ] In `wireCallbacks()`, remove:
  ```swift
  rideHistory.onRidesChanged = { [weak store] in
      store?.markDirty(.rideHistory)
  }
  ```
- [ ] In `_detachUnchecked()`, remove the `rideHistory.onRidesChanged = nil` line (it is now a no-op since `wireCallbacks` no longer sets it, but removing it keeps the code clean)
- [ ] Update the `SyncDomainTracker` class-level doc comment to reflect that `.rideHistory` is no longer wired here

**Important:** `SyncDomainTracker` still holds the `rideHistory: RideHistoryRepository` property — it is passed in `init` for the `detach()` nil-assignment defensive cleanup. Whether to keep or remove the property from `init` is a judgment call:
  - Keep it (and just stop setting `onRidesChanged`): minimal change, still nils the callback in `detach()` as a defensive no-op.
  - Remove it from `init`: cleaner but breaks any callers that already pass it by position. Removing it requires updating `SyncCoordinator.wireTrackingCallbacks()` call site.
  
  **Recommended:** keep the `rideHistory` parameter in `init` for now to avoid a breaking change to the `SyncDomainTracker` public API. Just stop wiring `onRidesChanged`. If the property becomes truly unused after detach cleanup is updated, remove it in a follow-up.

---

### Step 6: Update `RideCoordinator.swift` — replace `backupRideHistory()`

The `backupRideHistory()` method currently holds the active-publish logic. After this change, it becomes a thin bridge to the coordinator (or is removed entirely if the call sites are updated directly).

Option A (thin bridge — lower risk, easier to search/replace later):
- [ ] Replace `backupRideHistory()` body with:
  ```swift
  public func backupRideHistory() {
      syncCoordinator?.rideHistorySyncCoordinator?.publishAndMark(from: rideHistory)
  }
  ```
  This requires `RideCoordinator` to hold a reference to `SyncCoordinator`. Check if it already does; if not, inject it.

Option B (remove method, update call sites directly):
- [ ] Remove `backupRideHistory()` entirely
- [ ] In `recordRideHistory()`, replace `backupRideHistory()` with the coordinator call directly
- [ ] In `HistoryTab.swift`, replace `appState.rideCoordinator?.backupRideHistory()` with the coordinator call

**Recommended:** Option B for cleaner deletion of the old path. The call sites are well-known (2 locations).

**If Option B:**
- [ ] In `recordRideHistory()` (RideCoordinator.swift, after `rideHistory.addRide(entry)`):
  ```swift
  // Previously: backupRideHistory()
  // Now call via SyncCoordinator — need access to it here.
  ```
  Note: `RideCoordinator` does not currently hold a `SyncCoordinator` reference. It holds `roadflareDomainService` and `roadflareSyncStore` directly. One approach: keep `backupRideHistory()` as a public method that takes an explicit coordinator parameter, or have `AppState` call the coordinator after `rideHistory.addRide`. Review `AppState.swift` to determine the cleanest injection path before coding.

- [ ] In `HistoryTab.swift` (`onDelete` closure):
  ```swift
  appState.rideHistory.removeRide(id: ride.id)
  appState.syncCoordinator.rideHistorySyncCoordinator?.publishAndMark(from: appState.rideHistory)
  ```

---

### Step 7: Verify build and tests

- [ ] Run `xcodebuild` on the full Xcode project (not `swift test` alone):
  ```bash
  xcodebuild -project RoadFlare/RoadFlare.xcodeproj \
    -scheme RoadFlare \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    build 2>&1 | tail -20
  ```
  (Per CLAUDE.md: "Always use xcodebuild on the full Xcode project, not just swift test in the SDK package. The SDK's SPM tests miss concurrency errors that only surface in the app target.")
- [ ] Run SDK tests:
  ```bash
  xcodebuild test \
    -scheme RidestrSDK \
    -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30
  ```
- [ ] Run app tests:
  ```bash
  xcodebuild test \
    -project RoadFlare/RoadFlare.xcodeproj \
    -scheme RoadFlareTests \
    -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30
  ```

---

### Step 8: Clean up dead code in SyncCoordinator and RideCoordinator

After tests pass:

- [ ] Confirm `rideHistory` property in `SyncCoordinator.init` is still needed (it is, for `performStartupSync` and `flushPendingSyncPublishes` — no change needed here)
- [ ] If `backupRideHistory()` was removed from `RideCoordinator`, verify no callers remain (`grep -r backupRideHistory`)
- [ ] Remove `roadflareDomainService` and `roadflareSyncStore` from `RideCoordinator.init` if they are no longer used after moving publish logic to the coordinator. Verify all usages before removing — `LocationCoordinator` also receives these as pass-through parameters.
- [ ] Update `SyncDomainTracker` doc comment if the rideHistory parameter is still in `init` but no longer wired

---

## Test Strategy

### New SDK tests (`RideHistorySyncCoordinatorTests.swift`)

Model after `SyncDomainTrackerTests.swift` (simple, synchronous-style tests using `@MainActor @Suite`) and `LocationSyncCoordinatorTests.swift` (async tests using `FakeRelayManager`).

Tests to write (6 minimum, ordered by TDD priority):

| # | Test name | What it verifies |
|---|-----------|-----------------|
| 1 | `publishAndMark_onSuccess_marksPublished` | Happy path: relay succeeds → `markPublished` called |
| 2 | `publishAndMark_onFailure_marksDirty` | Offline path: relay throws → `markDirty` called |
| 3 | `publishAndMark_emptyHistory_succeeds` | Deletion case: empty rides array is published (not skipped) |
| 4 | `clearAll_invalidatesInFlightPublish_noMarkPublished` | Generation guard: `clearAll` before Task completes → no store mutation |
| 5 | `publishAndMark_snapshotsRidesAtCallTime` | Content isolation: late `addRide` does not affect in-flight publish content |
| 6 | `clearAll_doesNotAffectCompletedPublish` | Regression: completed publish is not undone by subsequent `clearAll` |

### Existing tests to update

- `SyncDomainTrackerTests.swift` — the `onRidesChanged_marksRideHistoryDirty` test verifies the wiring being removed. This test must be **deleted** (not just skipped) since it tests behavior that is intentionally removed. Note the deletion in the PR.
- `RoadFlareTests` (app test target) — check for any tests that call `backupRideHistory()` directly; update to call through the coordinator.

---

## Concurrency Notes

Per CLAUDE.md conventions:

- `RideHistorySyncCoordinator` uses `@unchecked Sendable` + `NSLock` (not actors), matching `ProfileBackupCoordinator` and `SyncDomainTracker`.
- The publish Task is fire-and-forget (no `await` at the call site). This matches the current `backupRideHistory()` pattern — callers are `@MainActor` and should not block on publish.
- The generation counter uses `&+=` (wrapping addition) to prevent overflow, matching `ProfileBackupCoordinator`.
- `syncStoreRef` is `weak var` — same as `ProfileBackupCoordinator` — to prevent the coordinator retaining the store after `teardown()` releases it.
- Rides are snapshot from `rideHistory.rides` at call time on `@MainActor`, so the Task closure captures a value type snapshot (`[RideHistoryEntry]`) — no shared mutable state crossing the Task boundary.
- `RideHistoryRepository.rides` is an `@Observable` `@MainActor`-isolated property; reading it from a `@MainActor` caller before spawning the Task is safe.

---

## Prerequisite Check

Issue #29 (SyncDomainTracker extraction) is listed as a prerequisite in the issue. As of main at `09f70bf`, `SyncDomainTracker.swift` already exists in `RidestrSDK/Sources/RidestrSDK/RoadFlare/SyncDomainTracker.swift` — the prerequisite is satisfied. Verify with `git log --oneline main | head -5` before starting.
