# ADR-0009: Kind 3189 Driver Ping Request with HMAC Auth

**Date:** 2026-04-14
**Status:** Accepted
**Issue:** #4 — Ping feature to notify offline drivers

## Context

The trusted-driver ridesharing model has a cold-start deadlock: drivers won't run the app unless they have customers, and riders can't get rides unless drivers are online. Riders need a way to nudge a specific offline driver they trust.

The existing Kind 3187 (`followNotification`) handles follow announcements and is still active in drivestr. Routing availability nudges through 3187 would mix two different intents on a single subscription stream, and would require adding an HMAC auth mechanism to a protocol that predates the HMAC design — breaking backward compatibility with existing 3187 consumers on both platforms.

## Decision

Introduce **Kind 3189 `driverPingRequest`** — a dedicated event kind for rider-to-driver availability nudges.

**Why a new kind (not extend Kind 3187):**
- **Different semantics**: Kind 3187 is a follow-announcement; Kind 3189 is an availability nudge. Conflating them would pollute the drivestr Kind 3187 subscription stream with a different intent.
- **No HMAC path on 3187**: Kind 3187 carries no `auth` tag in its protocol definition. Adding HMAC validation to 3187 events would break backward compatibility with existing 3187 consumers on both platforms.
- **Distinct handling path**: Kind 3189 belongs in the drivestr foreground-service listener alongside ride offers and key material events, where HMAC validation is cheap and the RoadFlare key is already in scope. Kind 3187 has a separate handling path with different assumptions.

**Why HMAC auth (not just rely on NIP-44 sender identity):**
The driver app needs to verify the sender is a known follower before delivering a notification — anonymous pings from strangers must be rejected silently. Walking the Kind 30011 list on every ping is slow and relay-dependent. HMAC using the RoadFlare private key (which the rider holds after key share) proves follower status in O(1) without network I/O.

The RoadFlare key rotation mechanism provides natural revocation: when a driver rotates their key (e.g., after removing a muted follower), old HMAC proofs computed with the old key become invalid.

**Why a 5-minute time window (epoch / 300) for HMAC:**
Prevents replay attacks — a captured ping event cannot be replayed outside the ±1 bucket (~10–15 minute validity window). The 30-minute event expiry tag is an additional outer bound. The driver app checks `timeWindow`, `timeWindow - 1`, and `timeWindow + 1` to handle clock skew and window boundaries.

## Rationale Over Alternatives

| Alternative | Rejected because |
|---|---|
| Extend Kind 3187 with `action: "ping"` | Mixed semantics; no HMAC path without breaking existing 3187 consumers; wrong handling path in drivestr |
| NIP-04/44 DM (Kind 4) | Pollutes DM inbox; no semantic meaning for driver apps |
| Standard Nostr `["nip"]` zap-style signal | Not specific to rideshare; no auth proof |
| No auth (trust NIP-44 sender) | Any Nostr user could spam drivers with pings |
| Ephemeral Kind 20xxx | Not stored by relays — driver app must be live at the exact moment the event arrives; NIP-40 expiry tag is moot; deduplication across reconnects is impossible |
| Replaceable Kind 30xxx | Each new ping overwrites the previous one, collapsing the dedup window to a single event per rider-driver pair; a rapid double-tap would silently drop the first ping |

## Consequences

- **New SDK constant**: `EventKind.driverPingRequest = 3189`
- **New constants**: `EventExpiration.driverPingMinutes = 30`, `NostrTags.roadflarePingTag`, `NostrTags.auth`
- **New builder**: `RideshareEventBuilder.driverPingRequest(driverPubkey:riderName:roadflareKey:keypair:)`
- **Android requirement**: drivestr must add Kind 3189 subscription and HMAC validation. Protocol spec is in `ANDROID_DEEP_DIVE.md`.
- **Delivery caveat**: Event delivery only works when the driver app is foregrounded or recently backgrounded. A future server-side push bridge (FCM/APNs relay) can extend delivery to truly dormant apps by subscribing to Kind 3189 and forwarding via push token. The event kind design is forward-compatible with this.

**Graceful degradation.** The feature is inherently speculative: a rider pings an offline driver and hopes they come online. If the drivestr side is temporarily behind (older build, delayed deployment, missing notification permission), the pinged driver simply won't come online — indistinguishable from the normal "driver saw it and didn't bite" state. There is no broken UI state, no error toast, no user-visible regression. This property is what makes lockstep-but-not-synchronous shipping acceptable.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/Nostr/EventKind.swift`
- `RidestrSDK/Sources/RidestrSDK/Nostr/Constants.swift`
- `RidestrSDK/Sources/RidestrSDK/Nostr/RideshareEventBuilder.swift`
- `RoadFlare/RoadFlareCore/ViewModels/AppState.swift`
- `RoadFlare/RoadFlare/Views/Drivers/DriversTab.swift`
- `RoadFlare/RoadFlare/Views/Ride/RideRequestView.swift`
