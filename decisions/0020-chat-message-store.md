# ADR-0020: ChatMessageStore — SDK-side chat message-list state

**Status:** Active
**Created:** 2026-05-11
**Tags:** refactor, architecture, ridestr-sdk, chat, coordinator-boundary

## Context

ADR-0018 (coordinator boundary review) concluded that `ChatCoordinator`'s
*subscription lifetime* belongs in `RoadFlareCore` while its *message-list
state machine* (dedup by event id, timestamp+id sort, 500-message FIFO cap,
unread counting gated by a subscription cutoff) is platform-neutral and a
candidate for SDK extraction — but deferred the work to "when a driver-side
consumer exists." Issue #111 (driver-side iOS planning, filed 2026-05-11) is
that trigger. Issue #60 tracked the extraction itself.

The Nostr protocol surface (Kind 3178 in-ride chat) is unchanged: a rider
and a driver bound to the same ride confirmation publish encrypted text
events between two known pubkeys. The constraint is that an iOS driver app
sharing the same SDK must consume the same store without paying for any
rider-specific assumption, and must remain wire-compatible with the
existing Ridestr/Drivestr Kind 3178 stream produced by `RideshareEventBuilder`
and parsed by `RideshareEventParser`.

This ADR captures the design decisions made when extracting the type — the
big-picture deferral was already justified in ADR-0018, but the
implementation-level choices (concurrency model, append API shape, capacity
plumbing, default cutoff) belong here so a future reader does not have to
infer them from git blame.

## Decision

Introduce `RidestrSDK/Sources/RidestrSDK/RoadFlare/ChatMessageStore.swift` as
the SDK-side owner of in-ride chat message-list state. The public surface is:

```swift
public struct ChatMessage: Hashable, Sendable {
    public let id: String         // event id; dedup key
    public let text: String       // decrypted plaintext
    public let isMine: Bool       // caller determines (event.pubkey == self)
    public let timestamp: Int     // event.createdAt (Unix seconds)
}

public enum ChatMessageAppendOutcome: Equatable, Sendable {
    case duplicate
    case inserted(incrementedUnread: Bool)
}

@Observable
public final class ChatMessageStore: @unchecked Sendable {
    public static let defaultCapacity = 500
    public init(capacity: Int = ChatMessageStore.defaultCapacity)
    public func setUnreadCutoff(_ timestamp: Int)
    @discardableResult
    public func append(_ message: ChatMessage) -> ChatMessageAppendOutcome
    public func markRead()
    public func reset()                  // preserves cutoff
    public private(set) var messages: [ChatMessage]
    public private(set) var unreadCount: Int
    public let capacity: Int
}
```

Specific decisions captured:

1. **Concurrency model:** `@unchecked Sendable` + `NSLock` + `@Observable`.
2. **Dedup key:** event id only.
3. **Sort:** ascending `timestamp`, tiebreak ascending `id` — deterministic.
4. **Capacity:** init parameter with default `500`. FIFO eviction (drop
   `removeFirst()` after sort).
5. **Append API:** returns `enum AppendOutcome { duplicate, inserted(incrementedUnread:) }`.
6. **Unread cutoff:** caller-supplied via `setUnreadCutoff(_:)`, defaults to
   `0`, inclusive check (`timestamp >= cutoff`).
7. **`reset()` semantics:** clears messages, message-id set, and
   `unreadCount` — preserves `unreadCutoff`.
8. **Field set on `ChatMessage`:** `id`, `text`, `isMine`, `timestamp` — no
   `senderPubkey`.
9. **`ChatCoordinator` keeps its rider-framing parameter names**
   (`driverPubkey`) and stays in `RoadFlareCore` per ADR-0018. The driver
   iOS app will build its own coordinator atop the same SDK store.

## Rationale

**Concurrency — `@unchecked Sendable` + `NSLock` + `@Observable`.** The
sibling SDK repos in `RidestrSDK/RoadFlare/` (`UserSettingsRepository`,
`FollowedDriversRepository`, `SavedLocationsRepository`) all use this
pattern, and `.claude/CLAUDE.md` codifies it ("SDK repos that need callbacks
use `@unchecked Sendable` + `NSLock`"). The store therefore does not pin
itself to `@MainActor`, leaving room for future non-UI consumers (background
sync, server-side replays, tests) without re-architecting. `@MainActor`
would have been a simpler drop-in for the existing rider `ChatCoordinator`
but conflicts with sibling-repo convention. `actor` was rejected because
Swift's `@Observable` does not compose cleanly with `actor` — SwiftUI
consumers would need an `AsyncStream` or a separate observable projection,
which adds meaningful complexity for no current benefit.

**Dedup by event id.** Nostr events are uniquely identified by their id
(SHA-256 over a canonical serialization). Two events with identical ids
have identical content by construction. Pubkey/timestamp collisions are not
deduplication keys — they would either over-dedupe (different events from
the same pubkey at the same second) or under-dedupe. The legacy coordinator
keyed dedup on event id, and this matches.

**Sort by timestamp then id.** The protocol's `created_at` is the canonical
order. Ties happen — multiple events can share a second — so an explicit
tiebreak is required to keep the list deterministic across out-of-order
arrivals. Lexicographic id ascending is the chosen tiebreak (cheap, total
order, identical to the legacy coordinator).

**Capacity as init parameter with default 500.** The 500 magic number lived
in the legacy coordinator with no explicit justification beyond "enough
chat history for a single ride." Threading it through an init parameter
costs essentially nothing, lets tests exercise the boundary with small
capacities (`capacity: 2` and `capacity: 5` in the test suite), and gives
future consumers a config knob without forcing a refactor.

**Append outcome enum.** `Bool` would have told callers *whether* a message
was inserted but not whether it bumped the unread counter — and the
coordinator's haptic decision needs to know both. The enum bundles the two
signals atomically without polling the counter or recomputing the cutoff
check externally.

**Default cutoff of 0.** This makes "no cutoff set" equivalent to "every
remote message is unread," which is the safe default for a fresh store
that hasn't yet been told when its subscription session started. The
single subscription-managing caller (`ChatCoordinator.subscribeToChat`)
sets the cutoff synchronously before any events can flow in, so the
default is unreachable in normal use. Documented inline.

**`reset()` preserves cutoff.** The legacy coordinator's `reset()` cleared
messages and unread but left `subscriptionStartTime` alone — and that
was intentional, because `reset()` runs on terminal session events
(`sessionDidReachTerminal`) while a fresh subscription cutoff is supplied
separately when `subscribeToChat` runs for the next ride. Preserving this
matches legacy and avoids a "stale cutoff after reset" footgun where the
cutoff would silently revert to 0 (the unread-everything default) the
moment a ride ended.

**No `senderPubkey` on `ChatMessage`.** Kind 3178 in-ride chat is a
2-party encrypted channel between a rider and a driver, scoped to a single
`confirmationEventId`. The two participant pubkeys are known to the
coordinator at subscription time (they are the `counterpartyPubkey` and
`myPubkey` arguments to `NostrFilter.chatMessages`). `isMine` therefore
fully disambiguates sender: "me" = local pubkey, "not me" = the known
counterparty. Adding `senderPubkey` would be redundant for the 2-party
case. The driver iOS app's UI layer will resolve the counterparty's
display name and avatar through the same `FollowedDriversRepository` /
profile lookup machinery it already uses for the ride header — not from
the message struct.

**Protocol compatibility.** The store consumes already-parsed
`ChatMessage` values; parsing, decryption, and `event.pubkey == myPubkey`
determination all stay in the SDK's `RideshareEventParser` /
`RideshareEventBuilder` (which an Android Drivestr peer interoperates with
bit-for-bit). No protocol-surface changes are introduced.

**Rider-framing parameter names on `ChatCoordinator`.** This coordinator
is the rider's app-layer adapter. Per ADR-0018 it stays in `RoadFlareCore`
and is not shared infrastructure — only the SDK store is. The driver iOS
app will write a sibling `DriverChatCoordinator` (or whatever
generalization makes sense at the time) that consumes `ChatMessageStore`
directly. Renaming `driverPubkey` to `counterpartyPubkey` was deferred
because it would touch many existing rider callers for zero functional
gain and the driver coordinator will not call this type at all.

## Alternatives Considered

- **`@MainActor` class.** Simpler binding to SwiftUI; matches the existing
  `ChatCoordinator`. Rejected because it conflicts with the sibling-repo
  convention codified in CLAUDE.md and pins future non-UI consumers.

- **`actor`.** Strongest isolation. Rejected because `@Observable` does
  not compose cleanly with `actor`; SwiftUI consumers would have to bridge
  through `AsyncStream` or a projection class.

- **Hardcoded `static let capacity = 500`, no init parameter.** Less new
  public surface. Rejected because the parameter cost is one line and the
  test-seam value (running boundary tests with `capacity: 2` instead of
  pushing 501 messages) was outsized.

- **`@discardableResult func append(_:) -> Bool`.** Simpler. Rejected
  because the coordinator's haptic decision needs to know whether the
  message also bumped unread; `Bool` would have forced callers to poll
  `unreadCount` deltas, which is brittle.

- **Construct with cutoff in init, no `setUnreadCutoff(_:)`.** Removes
  the default-0 footgun. Rejected because the subscription-managing caller
  needs to re-set the cutoff per subscription session (not per store
  lifetime); a settable cutoff is the right shape.

- **Reset cutoff in `reset()`.** Symmetric. Rejected because terminal-session
  resets happen before the next subscription's cutoff is known, and
  leaving the cutoff at 0 between rides would cause replayed history on
  the next subscribe to inflate the badge until the new cutoff lands.

- **Add `senderPubkey: String` to `ChatMessage` for driver-app readiness.**
  Rejected for now: in 2-party chat the sender is `me | counterparty`,
  both pubkeys are known to the coordinator, and the UI layer already
  resolves profiles by pubkey through other paths. Easy to add later if
  group chat or third-party display ever materializes.

- **Generalize `ChatCoordinator` to be role-symmetric** (rename
  `driverPubkey` to `counterpartyPubkey`). Rejected — the coordinator
  stays rider-only per ADR-0018; the driver app builds its own. Renaming
  would touch many rider call sites for no driver benefit.

## Consequences

- A future driver iOS app gets `ChatMessageStore` for free: same dedup,
  sort, cap, and unread semantics as the rider, with no rider-specific
  types or assumptions. The driver coordinator owns its own subscription
  lifetime + haptic feedback (or push, when that lands) and delegates
  message-list state to the store.
- The legacy edge case where the unread badge increments for a message
  that was immediately evicted by the capacity cap is preserved and
  locked in by tests. Revisit if product calls for stricter unread/visible
  invariants.
- `ChatCoordinator.store` is internal (not `public`) so the test seam in
  `RideCoordinatorTests` works in-module. If the driver coordinator is
  ever extracted into a separate module, the seam needs revisiting (move
  the store to `public`, or change the access path).
- Kind 3178 wire format is unchanged. Ridestr / Drivestr peers continue
  to interoperate.
- 859 SDK tests pass, plus 21 new in `ChatMessageStoreTests`. Full Xcode
  project builds and `RoadFlareTests` scheme passes.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/RoadFlare/ChatMessageStore.swift` (new)
- `RidestrSDK/Tests/RidestrSDKTests/RoadFlare/ChatMessageStoreTests.swift` (new)
- `RoadFlare/RoadFlareCore/ViewModels/ChatCoordinator.swift` (delegates to store)
- `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift` (forwarder type)
- `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift` (test-seed migration)
