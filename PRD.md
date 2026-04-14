# RoadFlare iOS — Product Requirements Document

**Version**: 2.1
**Date**: 2026-03-17
**Status**: Draft — Design decisions finalized, protocol details from Android deep-dive incorporated

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Product Vision & Goals](#2-product-vision--goals)
3. [Platform & Technology Stack](#3-platform--technology-stack)
4. [App & SDK Architecture Overview](#4-app--sdk-architecture-overview)
5. [Core Protocol: Nostr Integration](#5-core-protocol-nostr-integration)
6. [Payment System (v1: Fiat Only)](#6-payment-system-v1-fiat-only)
7. [RoadFlare: Trusted Driver Network](#7-roadflare-trusted-driver-network)
8. [RoadFlare Rider App — Feature Specification](#8-roadflare-rider-app--feature-specification)
9. [Drivestr App — Feature Specification (Future)](#9-drivestr-app--feature-specification-future)
10. [RidestrSDK — Public Swift Package](#10-ridestrsdk--public-swift-package)
11. [RidestrUI — Optional Companion Components](#11-ridestrui--optional-companion-components)
12. [Data Models](#12-data-models)
13. [State Machines](#13-state-machines)
14. [Screens & Navigation](#14-screens--navigation)
15. [Location & Routing](#15-location--routing)
16. [Security & Privacy](#16-security--privacy)
17. [iOS-Specific Considerations](#17-ios-specific-considerations)
18. [Testing Strategy](#18-testing-strategy)
19. [Phased Delivery Plan](#19-phased-delivery-plan)
20. [Future Roadmap](#20-future-roadmap)
21. [Design Decisions Log](#21-design-decisions-log)
22. [Appendix: Nostr Event Reference](#appendix-a-nostr-event-kind-reference)
23. [Appendix: Android-to-iOS Mapping](#appendix-b-android-to-ios-technology-mapping)

---

## 1. Executive Summary

RoadFlare iOS is a native iOS app for riders to request rides from their personal network of trusted drivers. It is part of the broader Ridestr decentralized rideshare protocol, built on Nostr.

### What We're Building for iOS v1

- **RoadFlare** (rider app) — find and request rides from trusted drivers you know
- **RidestrSDK** — public Swift Package implementing the Ridestr/Nostr rideshare protocol, usable by any developer
- **RidestrUI** — optional companion package with drop-in SwiftUI components for complex protocol flows

### What We're NOT Building for iOS v1

- Ridestr Rider (general public ride offers / broadcast requests)
- Drivestr iOS (driver app — the existing Android driver app is in active use)
- Bitcoin/Cashu/Lightning payments (deferred to future roadmap)

### The RoadFlare Concept

RoadFlare enables riders to build personal networks of trusted drivers. Unlike traditional rideshare where a platform assigns you a stranger, RoadFlare is for **repeat rides from drivers you already know and trust**. Drivers broadcast their encrypted location to approved followers. Riders see which of their drivers are nearby and available, then request a ride directly. Payment happens peer-to-peer via fiat methods (Zelle, Venmo, Cash App, etc.) or cash.

There are **no public ride offers or broadcast requests** in the RoadFlare app. Every ride is between a rider and a driver who have an established trust relationship.

### Key Differentiators

| Aspect | Traditional (Uber/Lyft) | RoadFlare |
|--------|------------------------|-----------|
| Architecture | Centralized servers | Decentralized Nostr relays |
| Identity | Email/phone accounts | Nostr keypairs (self-sovereign) |
| Payments | Credit card via platform | Peer-to-peer fiat (Zelle, Venmo, cash, etc.) |
| Platform fee | 25-40% | Zero |
| Driver discovery | Algorithm-assigned stranger | Your personal trusted network |
| Privacy | Platform sees everything | Encrypted comms, progressive location reveal |
| Trust model | Platform-mediated ratings | Personal relationships |

### Interoperability

The iOS RoadFlare rider app is fully interoperable with the existing Android Drivestr (driver) app. A rider on iOS can request rides from a driver on Android — they communicate over the same Nostr relays using the same event protocol.

---

## 2. Product Vision & Goals

### Vision

Give riders a personal, trusted alternative to corporate rideshare — no middleman, no platform fees, no strangers. Just you and drivers you know.

### Goals for iOS v1.0

1. **Nostr protocol compatibility** — interoperate with Android driver app on the same relay network
2. **RoadFlare feature parity** — trusted driver networks with encrypted location broadcasting
3. **Fiat payment coordination** — rider and driver agree on payment method (Zelle, Venmo, Cash App, PayPal, cash)
4. **Native iOS experience** — SwiftUI, MapKit for geocoding/routing, proper background handling
5. **Public SDK** — `RidestrSDK` as a versioned Swift Package any developer can use to build on the protocol

### Non-Goals for v1.0

- Bitcoin/Cashu/Lightning payments
- Public ride offers or broadcast requests (Ridestr Rider functionality)
- iOS driver app (Drivestr)
- CarPlay, iPad, watchOS
- Hosted servers or paid API dependencies

---

## 3. Platform & Technology Stack

### Minimum Requirements

| Requirement | Value | Rationale |
|------------|-------|-----------|
| iOS version | 17.0+ | @Observable, modern SwiftUI Map, SwiftData |
| Xcode | 16.0+ | Swift 6, structured concurrency |
| Device | iPhone only | Rideshare is phone-centric |

### Technology Choices

| Layer | Technology | Rationale |
|-------|-----------|-----------|
| **Language** | Swift 6 | Strict concurrency, modern async/await |
| **UI Framework** | SwiftUI | Declarative, rapid iteration |
| **Concurrency** | Swift Concurrency (async/await, actors) | Direct analog to Kotlin coroutines |
| **Networking** | URLSession + URLSessionWebSocketTask | Native WebSocket for Nostr relays |
| **Maps** | MapKit (SwiftUI) | Free, no API key, native |
| **Location** | CoreLocation | Standard iOS location services |
| **Routing** | MapKit Directions (MKDirections) | Free, no setup, network-required |
| **Cryptography** | rust-nostr (built-in) + CryptoKit | NIP-01 signing, NIP-44 encryption via rust-nostr |
| **Storage** | SwiftData + Keychain | Structured data + secure key storage |
| **QR Scanning** | AVFoundation / VisionKit | Native camera + code scanning |
| **Notifications** | UserNotifications | Local notifications (with optional APNs bridge support) |
| **Build** | SPM (Swift Package Manager) | Standard, no CocoaPods/Carthage |

### Key Dependencies (Swift Packages)

| Package | Purpose | Notes |
|---------|---------|-------|
| `nostr-sdk-swift` (rust-nostr) | Nostr protocol: relay management, event signing, NIP-44, NIP-19 | Rust core via UniFFI XCFramework, 60+ NIPs, MIT license |
| `CryptoKit` (system) | SHA256, HKDF, supplementary crypto | System framework, no dependency |

**Why rust-nostr over pure-Swift alternatives:** 4,500+ commits, 614 stars, 36 releases, shared across Python/JS/Kotlin/Swift bindings — far more battle-tested than nostr-sdk-ios (~50 stars, quiet since Feb 2025). The UniFFI API is wrapped behind our own RidestrSDK surface, so the non-Swifty feel stays hidden. For security-critical signing and encryption, reliability wins over API elegance.

**What rust-nostr provides (that we don't need to build):**
- Relay pool management (connect, publish, subscribe, EOSE)
- NIP-01 event signing (Schnorr/secp256k1)
- NIP-44 encryption/decryption
- NIP-19 bech32 encoding (nsec/npub)
- NIP-40 expiration tag handling
- NIP-09 event deletion
- Event signature verification

**What we still build ourselves in RidestrSDK:**
- Custom event kinds (3173–3188, 30011–30182) — parsing, construction, content formats
- RoadFlare key management and rotation logic
- Ride state machine
- Fare calculation
- Profile sync orchestration
- All business logic

### Zero Infrastructure Policy

v1 requires **no servers, no API keys, no paid services**. Everything runs on:
- Public Nostr relays (free)
- MapKit (free, no key)
- CoreLocation + CLGeocoder (free)
- Peer-to-peer fiat payments (outside the app)

---

## 4. App & SDK Architecture Overview

### Package Structure

```
roadflare-ios/
├── RidestrSDK/                         # Public Swift Package
│   ├── Package.swift                   # Published to SPM registry
│   ├── Sources/RidestrSDK/
│   │   ├── Nostr/                      # Protocol, relays, events, encryption
│   │   ├── RoadFlare/                  # Key management, broadcasting, followers
│   │   ├── Ride/                       # State machines, ride lifecycle
│   │   ├── Location/                   # Geocoding, geohash
│   │   ├── Payment/                    # Fiat method coordination (v1), Cashu (future)
│   │   ├── Storage/                    # Keychain, preferences
│   │   ├── Sync/                       # Profile sync, history backup
│   │   └── Models/                     # All shared data types
│   └── Tests/
├── RidestrUI/                          # Optional companion Swift Package
│   ├── Package.swift
│   └── Sources/RidestrUI/
│       ├── RideStatusCard.swift        # Drop-in ride stage display
│       ├── PINExchangeView.swift       # PIN display (rider) / entry (driver)
│       └── FareEstimateView.swift      # Route-based fare display
├── RoadFlare/                          # iOS app target (rider)
│   ├── RoadFlareApp.swift
│   ├── ViewModels/
│   ├── Views/
│   ├── Services/
│   └── Resources/
└── roadflare-ios.xcodeproj
```

### Relationship

```
┌────────────────────┐
│   RoadFlare App    │  (iOS rider app — your product)
│   (com.roadflare)  │
└────────┬───────────┘
         │ depends on
    ┌────▼────┐  ┌──────────┐
    │RidestrUI│  │          │
    │(optional│──│RidestrSDK│  (public Swift Package — the platform)
    │  views) │  │          │
    └─────────┘  └──────────┘
                       ▲
                       │ any third-party dev can also depend on this
                  ┌────┴─────────┐
                  │ Other Apps   │
                  │ built on the │
                  │ Ridestr      │
                  │ protocol     │
                  └──────────────┘
```

---

## 5. Core Protocol: Nostr Integration

### 5.1 Nostr Fundamentals

The app communicates exclusively through Nostr, an open protocol where:
- **Identity** = a secp256k1 keypair (no accounts, no servers)
- **Events** = signed JSON objects published to relays
- **Relays** = WebSocket servers that store and forward events
- **Subscriptions** = filtered queries for events matching criteria

### 5.2 Relay Management

**RelayManager** — manages connections to multiple Nostr relays.

Requirements:
- Maintain persistent WebSocket connections to 3+ relays (configurable, max 10)
- Automatic reconnection with exponential backoff (5s base, 60s max)
- Publish events to all connected relays (redundancy)
- Subscribe with NIP-01 filters (kinds, authors, tags, since)
- Handle EOSE (End-Of-Stored-Events) to distinguish historical from live events
- Connection health monitoring and relay switching
- NIP-01 signature verification on all received events (drop invalid)
- Generation-based stale message filtering (increment generation on reconnect, discard messages from previous connections)
- Bounded message queue (capacity 256, drop if full — prevents memory bloat under burst traffic)
- Automatic resubscription of all active subscriptions on reconnect
- Stale subscription cleanup (auto-close subscriptions older than 30 minutes)

**Key Timeouts (from Android implementation):**
- Connection timeout: 10,000ms
- Read timeout: 30,000ms
- Write timeout: 30,000ms
- `awaitConnected()` default: 15,000ms
- EOSE timeout for data fetches: 8,000ms
- EOSE timeout for quick queries: 3,000–5,000ms
- Reconnect delay: 5,000ms × attempts, capped at 60,000ms

Default relays:
```
wss://relay.damus.io
wss://nos.lol
wss://relay.primal.net
```

### 5.3 Key Management

**KeyManager** — secure storage and operations for Nostr keypairs.

Requirements:
- Generate new Nostr keypair (secp256k1)
- Import existing key via `nsec` (NIP-19 bech32 encoding)
- Export key as `nsec` / `npub`
- Store private key in iOS Keychain (kSecAttrAccessibleAfterFirstUnlock)
- NIP-01 event signing (Schnorr signature over SHA256 of serialized event)
- NIP-44 encryption/decryption (conversation key derivation, ChaCha20-Poly1305)

Note: v1 does not require a separate wallet keypair (no Cashu). Only identity key and RoadFlare key.

Import formats accepted: `nsec1...` (NIP-19 bech32) or 64-character hex private key.

### 5.4 Event Types

All events follow NIP-01 structure:

```json
{
  "id": "<sha256 of serialized event>",
  "pubkey": "<hex public key>",
  "created_at": "<unix timestamp>",
  "kind": <integer>,
  "tags": [["tag", "value"], ...],
  "content": "<string, often NIP-44 encrypted>",
  "sig": "<schnorr signature>"
}
```

See [Appendix A](#appendix-a-nostr-event-kind-reference) for the complete event kind reference.

### 5.5 NostrService (Facade)

High-level service abstracting raw Nostr operations. For v1, delegates to:

- **RideshareDomainService** — ride offer, acceptance, confirmation, state updates, cancellation, chat
- **RoadflareDomainService** — location broadcasts, key sharing, follower notifications
- **ProfileBackupService** — unified profile, ride history sync

Key methods for the RoadFlare rider app:

```swift
// RoadFlare-specific ride lifecycle
publishRoadflareOffer(to:pickup:destination:fare:paymentMethod:) async throws -> EventID
publishRideConfirmation(to:acceptanceEventId:pin:) async throws -> EventID
publishRiderState(driverPubKey:stage:action:data:) async throws -> EventID
publishCancellation(to:rideEventId:reason:) async throws -> EventID
publishChatMessage(to:rideEventId:message:) async throws -> EventID

// RoadFlare network
subscribeToRoadflareLocations(driverPubKeys:) -> AsyncStream<RoadflareLocation>
subscribeToKeyShares() -> AsyncStream<RoadflareKeyShareData>
publishKeyAcknowledgement(to:keyVersion:status:) async throws -> EventID
publishFollowedDriversList(drivers:) async throws -> EventID  // Kind 30011 with p-tags

// Subscriptions for active ride
subscribeToDriverState(driverPubKey:confirmationEventId:) -> AsyncStream<DriverRideState>
subscribeToCancellations(counterpartyPubKey:) -> AsyncStream<CancellationEvent>
subscribeToChat(counterpartyPubKey:rideEventId:) -> AsyncStream<ChatMessage>

// Profile
publishUnifiedProfile(locations:settings:) async throws -> EventID
publishRideHistoryBackup(entries:) async throws -> EventID
fetchUnifiedProfile() async throws -> UnifiedProfile?
fetchRideHistory() async throws -> [RideHistoryEntry]
```

---

## 6. Payment System (v1: Fiat Only)

### 6.1 Overview

v1 uses **peer-to-peer fiat payment methods only**. No money flows through the app. The app coordinates which payment method both parties agree on, then the actual payment happens outside the app (e.g., rider sends a Zelle payment to the driver's phone number).

### 6.2 Supported Payment Methods

| Method | ID | Description |
|--------|----|-------------|
| Zelle | `zelle` | Bank-to-bank transfer |
| PayPal | `paypal` | PayPal P2P payment |
| Cash App | `cash_app` | Cash App transfer |
| Venmo | `venmo` | Venmo transfer |
| Strike | `strike` | Strike payment |
| Cash | `cash` | Physical cash at pickup/dropoff |

### 6.3 Payment Flow

1. **Rider profile** stores all fiat payment methods they have available (ordered by preference)
2. **Ride offer includes rider's full payment method list** — the rider does NOT know what the driver accepts
3. **Driver sees rider's methods** and checks for a common one before accepting:
   - If a common method exists → driver accepts normally
   - If NO common method → driver sees a warning showing the rider's list, must explicitly confirm they have one in common before accepting
4. **At ride completion**: app displays payment instructions (e.g., "Send $12.50 via Zelle to driver")
5. **No escrow**: trust is the escrow — these are drivers you know

Key distinction: payment method negotiation happens **on the driver side**, not the rider side. The rider simply advertises what they have.

### 6.4 Fare Calculation

**FareCalculator** — computes ride cost based on MapKit route distance.

Two sources of fare config:

**RemoteConfigManager (Kind 30182, admin-published from hardcoded pubkey):**
Admin pubkey: `da790ba18e63ae79b16e172907301906957a45f38ef0c9f219d0f016eaf16128`
- fareRateUsdPerMile: $0.50 (default)
- minimumFareUsd: $1.50 (default)
- roadflareFareRateUsdPerMile: $0.40 (default)
- roadflareMinimumFareUsd: $1.00 (default)

**RoadFlare UI-level defaults (used in DriverNetworkTab):**
- Base fare: $2.50
- Rate: $1.50/mile
- Minimum fare: $5.00
- Formula: `max(BASE + (totalMiles × RATE), MINIMUM)`

The RemoteConfig values are fetched on startup (EOSE-aware query with 8s timeout, cached locally for offline fallback). The UI-level defaults are used when RemoteConfig is unavailable.

Display: USD only (v1)

The fare is an **estimate and suggestion**, not an enforced price. Since payments are P2P fiat, the rider and driver can agree on any amount. The app provides the estimate as a reference.

### 6.5 Future: Cashu/Bitcoin Integration

The SDK will be architected with a `PaymentProvider` protocol so that Cashu HTLC escrow can be added as an alternative payment backend in a future release without changing the ride lifecycle. The protocol, state machines, and event kinds already support `cashu` and `lightning` payment methods — they're just not implemented in v1.

---

## 7. RoadFlare: Trusted Driver Network

### 7.1 Concept

Riders build personal networks of trusted drivers. Drivers broadcast their encrypted location to approved followers at regular intervals (~2 minutes). Riders see which of their drivers are nearby and available, then request a ride directly.

**Key distinction**: There are no public ride offers. Every ride is between parties with an established trust relationship (rider follows driver, driver has approved the follower).

### 7.2 Key Management

**RoadflareKeyManager** — manages a dedicated keypair for location encryption.

Two keypairs in v1 (no wallet key needed without Cashu):
- **Identity key**: Signs Nostr events, public identity
- **RoadFlare key**: Encrypts/decrypts location broadcasts

Requirements:
- Generate RoadFlare keypair (secp256k1), increment version number on each generation
- Share private key with approved followers (via NIP-44 encrypted DM, Kind 3186, 5-min expiry)
- Key rotation when a follower is removed or muted (revoke access — old key can no longer decrypt new broadcasts)
- Track key version numbers for rotation
- Track `keyUpdatedAt` timestamp (published in Kind 30012 as a public tag, enabling stale key detection without decryption)
- Acknowledgement flow: follower confirms receipt (Kind 3188, status "received" or "stale")
- On startup: call `ensureFollowersHaveCurrentKey()` to send keys to any approved followers missing the current version

**Key rotation algorithm:**
1. Generate new keypair with incremented version
2. Update `keyUpdatedAt` timestamp in repository
3. Publish updated state to Kind 30012 (encrypted to self, but `key_version` and `key_updated_at` in public tags)
4. For each active follower (approved AND not muted): send new key via Kind 3186
5. Mark each follower with new `keyVersionSent`
6. Muted/removed followers retain old key — cannot decrypt new broadcasts

### 7.3 Location Broadcasting (Driver-Side, SDK Only for v1)

The SDK implements `RoadflareLocationBroadcaster` for completeness and third-party use. The RoadFlare rider app only *consumes* these broadcasts — broadcasting is done by the Android driver app.

Requirements:
- Publish Kind 30014 events every ~2 minutes when driver is online (BROADCAST_INTERVAL = 120s, MIN_INTERVAL = 60s)
- Content encrypted to the RoadFlare public key (NOT the driver's identity key)
- Include: latitude, longitude, status (online/on_ride/offline), key_version, timestamp
- Use NIP-40 expiration tags: 5 minutes (ROADFLARE_LOCATION_MINUTES)
- Broadcast only when: has RoadFlare key AND has active followers (approved + current key + not muted) AND has location

**Encryption model (ECDH commutativity):**
```
Driver encrypts:   nip44Encrypt(content, roadflare_pubkey)    → ECDH(driver_priv, roadflare_pub)
Follower decrypts: nip44Decrypt(ciphertext, driver_pubkey)    → ECDH(roadflare_priv, driver_pub)
These are equal:   ECDH(A_priv, B_pub) == ECDH(B_priv, A_pub)
```
This is critical: the driver encrypts using their identity private key and the RoadFlare public key. Followers decrypt using the shared RoadFlare private key and the driver's identity public key. The ECDH shared secret is the same in both cases.

### 7.4 Follower Management

**Rider side (FollowedDriversRepository)** — this is what the RoadFlare app implements:
- Maintain list of followed drivers
- Store each driver's RoadFlare private key and key version
- Persist in Kind 30011 (encrypted to self, but **driver pubkeys in public p-tags** for discovery)
- Support driver notes/nicknames
- Add drivers by npub, QR code, or deep link
- Remove drivers (unfollow)
- Cache driver names from Nostr profiles (persisted for instant display on startup)
- In-memory location cache (ephemeral, not persisted — 5-min broadcast TTL)

**Driver side (DriverRoadflareRepository)** — in the SDK for completeness, used by Android driver app:
- Discover followers via **p-tag queries on Kind 30011** (driver queries for their own pubkey in riders' p-tags)
- Maintain list of approved followers (pubkeys)
- Mute/unmute followers (triggers key rotation)
- Approve/deny follow requests
- Persist follower list in Kind 30012 (encrypted to self)

**Follower discovery model:**
Kind 3187 (follow notification) is **deprecated**. Drivers discover new followers by querying relay for Kind 30011 events that contain their pubkey in a p-tag. This is more reliable than ephemeral notifications.

**Stale key detection (rider side):**
1. Fetch driver's Kind 30012 event, extract `key_updated_at` tag (public, no decryption needed)
2. Compare to stored `roadflareKey.keyUpdatedAt`
3. If mismatch → publish Kind 3188 with status="stale" to request refresh
4. Rate-limited to 1 refresh request per hour per driver

### 7.5 RoadFlare Ride Flow

1. Rider opens app → sees list/status of trusted drivers (decrypted Kind 30014 locations)
2. Rider selects online driver(s) and sets pickup/destination addresses
3. App calculates fare estimate via MapKit route
4. Rider selects payment method (fiat)
5. **Batch offer sending**: offers sent to up to 3 drivers at a time, sorted by distance (closest first), with 15-second delay between batches
6. Each offer: Kind 3173 with `["t", "roadflare"]` tag, NIP-44 encrypted to driver, 15-min expiry
7. **First driver to accept (Kind 3174) wins** — auto-confirm fires immediately (CAS guard). Any subsequent acceptances are silently ignored; those drivers' acceptance events expire naturally via NIP-40 (10-min expiry). The driver app also has its own timeout during the acceptance handshake.
8. **Auto-confirm** fires immediately on acceptance:
   - CAS guard ensures single confirmation (atomic boolean)
   - Generate 4-digit PIN: `format("%04d", random(0...9999))`
   - For RoadFlare rides: precise pickup is sent immediately (not gated by distance)
   - Publish Kind 3175 confirmation
   - Subscribe to driver state (Kind 30180), chat (Kind 3178), cancellation (Kind 3179)
9. Driver en route → arrives at pickup (Kind 30180 status updates)
10. Rider shows 4-digit PIN to driver verbally/visually
11. Driver enters PIN → driver publishes PIN in Kind 30180 (encrypted) → rider verifies
    - **Max 3 attempts** — auto-cancel on 3rd failure (brute force protection)
    - On success: rider publishes Kind 30181 with pin_verify: true
    - **1100ms delay** (NIP-33 timestamp ordering between state publishes)
    - Rider reveals precise destination (Kind 30181 LocationReveal)
12. Ride in progress → driver completes ride (Kind 30180 status=completed)
13. App shows payment instructions ("Send $X via Zelle to driver")
14. Rider pays driver outside the app
15. **Background NIP-09 cleanup**: all ride events deleted from relays (non-blocking)

### 7.6 Deep Links & Sharing

- URL scheme: `roadflare://driver/{npub}` — follow a driver
- Share sheet: generate QR code or text link for a driver's npub
- Import: scan QR code or tap link to add a driver
- Shareable driver lists (Kind 30013) — share your trusted network with friends

---

## 8. RoadFlare Rider App — Feature Specification

### 8.1 Onboarding

1. **Welcome screen** — "Your personal driver network" — brief explanation
2. **Key setup** — generate new Nostr keypair OR import existing `nsec`
3. **Profile creation** — name, optional profile picture
4. **Add your first driver** — by npub, QR code, or link
5. **Payment setup** — select which fiat payment methods you use (Zelle, Venmo, etc.)
6. **Relay configuration** (optional, advanced) — add/remove relays

### 8.2 Main Tab Bar

| Tab | Icon | Screen | Purpose |
|-----|------|--------|---------|
| Drivers | person.2 | DriverNetworkTab | View/manage your trusted drivers |
| Ride | car | RideTab | Request a ride from an available driver |
| History | clock | HistoryTab | Past rides |
| Settings | gear | SettingsTab | Profile, relays, preferences |

Note: No Wallet tab in v1 (fiat payments only, no in-app wallet).

### 8.3 Drivers Tab

**DriverNetworkTab** — your personal driver network.

#### Driver List View
- List of all followed drivers
- Each row shows: name, profile picture, online status indicator (green/yellow/gray)
- Online status derived from decrypted Kind 30014 broadcasts:
  - Green: `online` (broadcasting within last 5 minutes)
  - Yellow: `on_ride` (currently on a ride with someone else)
  - Gray: `offline` or no recent broadcast
- Tap driver → DriverDetailView
- Pull to refresh (re-subscribe to RoadFlare locations)

#### Add Driver
- **By npub**: paste or type a Nostr public key (accepts `npub1...` bech32 or 64-char hex)
- **By QR code**: scan a QR code containing an npub
- **By link**: open a `roadflare://driver/{npub}` deep link
- On add: publish updated Kind 30011 with driver's pubkey in p-tags (driver discovers via p-tag query)
- Status: "Waiting for approval" until driver shares key (Kind 3186)
- Duplicate detection: check against existing followed drivers before adding

#### Driver Detail View
- Driver profile (name, picture, bio)
- Vehicle info (if available from their profile)
- Online status and approximate location (city/neighborhood level from geohash)
- Personal notes field (stored locally)
- "Request Ride" button (if driver is online)
- "Remove Driver" action

### 8.4 Ride Tab

**RideTab** — request a ride from an available driver.

#### Idle State (No Active Ride)
- List of currently online drivers (sorted by proximity if location available)
- "Request Ride" flow:

1. **Select driver** — tap an online driver from the list
2. **Set pickup** — current location (auto-detected) or search address
   - Address autocomplete via MKLocalSearchCompleter
   - Saved locations (Home, Work, custom) for quick selection
3. **Set destination** — search address or saved location
4. **Fare estimate** — calculated via MapKit MKDirections route distance × rate
5. **Payment method** — select from your configured methods, filtered to those the driver also accepts
6. **Confirm & send offer** — publishes Kind 3173 with `roadflare` tag

#### Waiting for Acceptance
- Show "Waiting for [driver name] to accept..."
- Cancel button
- **Timeout**: 15 seconds for single-driver offers, then prompt "Boost fare or keep waiting?"
- If sending to multiple drivers (batch): first acceptance wins, remaining offers expire naturally (15-min NIP-40 expiry)

#### Active Ride (after acceptance)

Display adapts to current ride stage:

| Stage | Display |
|-------|---------|
| DRIVER_ACCEPTED | Driver info, vehicle, estimated arrival. Auto-confirm fires. |
| RIDE_CONFIRMED | "Driver confirmed — on their way" |
| DRIVER_EN_ROUTE | Status card showing driver is en route |
| DRIVER_ARRIVED | **PIN prominently displayed** — show this to your driver |
| IN_PROGRESS | Ride underway, destination revealed to driver |
| COMPLETED | "Ride complete!" + payment instructions |

Note: No live map tracking of driver location (keeps relay traffic low, matches Android behavior). Status updates come from driver's Kind 30180 state events.

#### Chat
- Floating chat button during active ride
- NIP-44 encrypted messages (Kind 3178)
- Simple message list with text input
- Available from DRIVER_ACCEPTED through COMPLETED

#### Cancellation
- Available at any stage before COMPLETED
- Publishes Kind 3179 with reason, 24-hour expiry
- Reason options: "Changed plans", "Taking too long", "Other"
- **Safety warning**: If PIN has been verified (future Cashu: preimage shared), show warning dialog: "The driver may still claim payment" — user must explicitly confirm
- After cancellation: save cancelled ride to history, then background NIP-09 deletion of all ride events
- Returns to idle state

#### Chat Reliability
- 15-second periodic chat subscription refresh (handles relay unreliability)
- Chat available from DRIVER_ACCEPTED through COMPLETED
- Kind 3178, NIP-44 encrypted, 8-hour expiry

### 8.5 History Tab

- List of past rides: date, driver name, pickup → destination, fare, payment method
- Tap for detail view
- Backed up via Kind 30174 (encrypted to self)
- Restored on new device via key import

### 8.6 Settings Tab

- **Profile**: edit name, profile picture (Kind 0 metadata event)
- **Payment Methods**: configure which fiat methods you use, set preference order (priority-ordered list, e.g., ["zelle", "venmo", "cash"])
- **Saved Locations**: manage Home, Work, custom addresses (max 15 recents, pinned favorites, 50m duplicate threshold)
- **Display**: distance units (miles/km)
- **Notifications**: sound toggle, vibration toggle
- **Relays**: add/remove Nostr relays (max 10, auto-prepend `wss://`)
- **Key Management**: view npub, export nsec, import nsec
- **Data Sync**: manual sync trigger (pull profile data from Nostr)
- **About**: version, licenses
- **Logout**: clear all local data, remove keys (16 cleanup operations — see LogoutManager in ANDROID_DEEP_DIVE.md)

---

## 9. Drivestr App — Feature Specification (Future)

The iOS driver app is deferred. The existing Android Drivestr app serves as the driver client. This section is a placeholder for future planning.

When built, it would include:
- Availability toggle (OFFLINE / ROADFLARE_ONLY)
- RoadFlare follower management
- Ride acceptance, navigation, PIN entry, completion
- Earnings tracking
- Vehicle management

The `RidestrSDK` includes all driver-side protocol logic so a third-party developer could also build a driver app using the SDK.

---

## 10. RidestrSDK — Public Swift Package

### 10.1 Purpose

A versioned, documented Swift Package that implements the complete Ridestr/Nostr rideshare protocol. Any developer can `import RidestrSDK` and build rider or driver experiences on the protocol.

### 10.2 Public API Surface

#### Nostr Layer

```swift
// Identity
public struct NostrKeypair { ... }
public class KeyManager {
    public func generate() -> NostrKeypair
    public func importNsec(_ nsec: String) throws -> NostrKeypair
    public func exportNsec() -> String
    public func exportNpub() -> String
}

// Relay connections
public actor RelayManager {
    public func connect(to relays: [URL]) async
    public func disconnect() async
    public func publish(_ event: NostrEvent) async throws -> String
    public func subscribe(filter: NostrFilter) -> AsyncStream<NostrEvent>
    public func unsubscribe(_ id: SubscriptionID) async
    public var connectionState: AsyncStream<RelayConnectionState> { get }
}

// Event construction & parsing
public struct NostrEvent: Codable, Identifiable, Sendable { ... }
public struct NostrFilter: Codable, Sendable { ... }
public enum EventSigner {
    public static func sign(event: UnsignedEvent, privateKey: Data) throws -> NostrEvent
    public static func verify(event: NostrEvent) -> Bool
}
public enum NIP44 {
    public static func encrypt(plaintext: String, privateKey: Data, publicKey: Data) throws -> String
    public static func decrypt(ciphertext: String, privateKey: Data, publicKey: Data) throws -> String
}
```

#### Ride Protocol Layer

```swift
// High-level ride operations
public actor RideService {
    // RoadFlare offers (no public/broadcast offers in v1)
    public func sendRoadflareOffer(to driverPubKey: String, pickup: Location, destination: Location,
                                    fare: FareEstimate, paymentMethod: PaymentMethod) async throws -> EventID

    public func confirmRide(acceptanceEventId: String, pin: String) async throws -> EventID
    public func cancelRide(counterpartyPubKey: String, rideEventId: String, reason: String) async throws -> EventID
    public func sendChat(to: String, rideEventId: String, message: String) async throws -> EventID
    public func updateRiderState(driverPubKey: String, stage: RiderStage, action: RiderAction?, data: [String: String]?) async throws -> EventID

    // Subscriptions
    public func subscribeToDriverState(driverPubKey: String, confirmationEventId: String) -> AsyncStream<DriverRideState>
    public func subscribeToCancellations(counterpartyPubKey: String) -> AsyncStream<CancellationEvent>
    public func subscribeToChat(counterpartyPubKey: String, rideEventId: String) -> AsyncStream<ChatMessage>
}

// State machine
public class RideStateMachine: Observable {
    public var stage: RiderStage { get }
    public var pin: String? { get }
    public var driverInfo: DriverInfo? { get }
    public var fareEstimate: FareEstimate? { get }

    public func transition(to stage: RiderStage, event: NostrEvent?) throws
    public func reset()
}
```

#### RoadFlare Layer

```swift
public actor RoadflareService {
    // Following drivers
    public func followDriver(npub: String) async throws
    public func unfollowDriver(npub: String) async throws
    public func getFollowedDrivers() -> [FollowedDriver]

    // Receiving locations
    public func subscribeToLocations(driverPubKeys: [String]) -> AsyncStream<(String, RoadflareLocation)>
    public func decryptLocation(event: NostrEvent, privateKey: Data) throws -> RoadflareLocation

    // Key management (for driver-side, SDK completeness)
    public func generateRoadflareKey() -> RoadflareKey
    public func rotateKey() async throws -> RoadflareKey
    public func shareKey(with followerPubKey: String) async throws

    // Broadcasting (for driver-side, SDK completeness)
    public func startBroadcasting(interval: TimeInterval) async
    public func stopBroadcasting() async
}
```

#### Location & Fare Layer

```swift
public struct Geohash {
    public init(latitude: Double, longitude: Double, precision: Int = 5)
    public init(hash: String)
    public var hash: String { get }
    public func toLocation() -> Location
    public func neighbors() -> [Geohash]
}

public class FareCalculator {
    public func estimate(from pickup: Location, to destination: Location) async throws -> FareEstimate
}

public struct FareEstimate {
    public let distanceMiles: Double
    public let fareUSD: Decimal
    public let routeSummary: String?
}
```

#### Storage Layer

```swift
public class KeychainStorage {
    public func save(key: Data, for identifier: String) throws
    public func load(for identifier: String) throws -> Data?
    public func delete(for identifier: String) throws
}

public actor ProfileSync {
    public func pushProfile(_ profile: UnifiedProfile) async throws
    public func pullProfile() async throws -> UnifiedProfile?
    public func pushRideHistory(_ entries: [RideHistoryEntry]) async throws
    public func pullRideHistory() async throws -> [RideHistoryEntry]
}
```

### 10.3 Design Principles

1. **Protocol-first**: All public types use Swift protocols for testability
2. **Actor isolation**: Shared mutable state protected by actors
3. **AsyncStream**: All event subscriptions return AsyncStream for structured concurrency
4. **Sendable**: All public types conform to Sendable for safe cross-actor use
5. **No UI**: Zero UIKit/SwiftUI imports — pure logic
6. **Minimal dependencies**: Only `nostr-sdk-swift` (rust-nostr) and system frameworks
7. **Semantic versioning**: Breaking changes = major version bump

### 10.4 Error Handling

```swift
public enum RidestrError: Error, Sendable {
    case relayConnectionFailed(URL, underlying: Error)
    case relayTimeout
    case eventSigningFailed
    case encryptionFailed
    case decryptionFailed
    case invalidKey(String)
    case invalidEvent(String)
    case invalidGeohash(String)
    case rideStateMachineViolation(from: String, to: String)
    case routeCalculationFailed(underlying: Error)
    case geocodingFailed(underlying: Error)
    case keychainError(OSStatus)
    case profileSyncFailed(underlying: Error)
}
```

---

## 11. RidestrUI — Optional Companion Components

### 11.1 Purpose

Drop-in SwiftUI components for protocol flows where getting the UI/logic coupling wrong breaks the ride lifecycle. Developers can customize appearance via ViewModifiers and environment values but the flow logic is encapsulated.

### 11.2 Components

#### RideStatusCard

Displays the current ride stage with appropriate actions and information.

```swift
public struct RideStatusCard: View {
    public init(stateMachine: RideStateMachine)

    // Customization via environment
    // .ridestrAccentColor(.blue)
    // .ridestrCardStyle(.compact)
}
```

Renders differently per stage:
- **Waiting**: "Waiting for [driver]..." with cancel button
- **Accepted**: Driver info, vehicle, "On their way"
- **Arrived**: Large PIN display with instructions
- **In Progress**: "Ride in progress" with destination
- **Completed**: Fare summary + payment method instructions

#### PINExchangeView

Rider side: displays the 4-digit PIN prominently for the driver to see.
Driver side: PIN entry keypad with verification callback.

```swift
// Rider (display)
public struct PINDisplayView: View {
    public init(pin: String)
}

// Driver (entry) — for future Drivestr app or third-party driver apps
public struct PINEntryView: View {
    public init(onSubmit: (String) -> Void)
}
```

#### FareEstimateView

Shows route-based fare estimate with payment method.

```swift
public struct FareEstimateView: View {
    public init(estimate: FareEstimate, paymentMethod: PaymentMethod)
}
```

### 11.3 Customization

```swift
// Environment-based theming
extension EnvironmentValues {
    var ridestrAccentColor: Color
    var ridestrCardCornerRadius: CGFloat
    var ridestrFontStyle: RidestrFontStyle  // .system, .rounded, .monospaced
}
```

---

## 12. Data Models

### 12.1 Core Models

```swift
// MARK: - Identity

public struct NostrKeypair: Sendable {
    public let privateKey: Data     // 32 bytes
    public let publicKey: Data      // 32 bytes (x-only)
    public var npub: String         // NIP-19 bech32
    public var nsec: String         // NIP-19 bech32
}

// MARK: - Events

public struct NostrEvent: Codable, Identifiable, Sendable {
    public let id: String           // SHA256 hex
    public let pubkey: String       // hex
    public let createdAt: Int       // unix timestamp
    public let kind: Int
    public let tags: [[String]]
    public let content: String
    public let sig: String          // Schnorr signature hex
}

// MARK: - Fare

/// Fiat-denominated fare. Non-nil on fiat-payment offers (ADR-0008).
/// Serializes flat to JSON as `fare_fiat_amount` + `fare_fiat_currency` (mandatory pair).
public struct FiatFare: Equatable, Sendable {
    public let amount: String    // decimal string, e.g. "12.50"
    public let currency: String  // ISO 4217, e.g. "USD"
}

// MARK: - Ride

public struct RideOffer: Codable, Sendable {
    public let approxPickup: Location       // 2-decimal precision (~1km)
    public let destination: Location         // 2-decimal precision (~1km)
    public let destinationGeohash: String   // for settlement verification
    public let estimatedFare: Decimal       // USD (wire: sats in fare_estimate)
    /// Authoritative fiat fare. Non-nil when fiatPaymentMethods is non-empty.
    /// Drivers MUST display fiatFare.amount for fiat rides instead of converting estimatedFare.
    public let fiatFare: FiatFare?
    public let pickupRouteKm: Double?       // pre-calculated driver→pickup
    public let pickupRouteMin: Double?
    public let rideRouteKm: Double?         // pickup→destination
    public let rideRouteMin: Double?
    public let paymentMethod: PaymentMethod
    public let fiatPaymentMethods: [String] // e.g., ["zelle", "venmo"]
    public let isRoadflare: Bool            // always true in RoadFlare app
}

public struct RideAcceptance: Codable, Sendable {
    public let offerEventId: String
    public let status: String               // "accepted"
    public let walletPubKey: String?        // for future Cashu P2PK
    public let paymentMethod: PaymentMethod?
    public let mintUrl: String?             // driver's Cashu mint (future)
}

public struct RideConfirmation: Codable, Sendable {
    public let acceptanceEventId: String
    public let precisePickup: Location      // exact pickup coordinates
    // Future Cashu fields:
    // public let paymentHash: String?
    // public let escrowToken: String?
}

public struct DriverRideState: Codable, Sendable {
    public let currentStatus: String        // "en_route_pickup", "arrived", "in_progress", "completed", "cancelled"
    public let history: [DriverRideAction]  // consolidated history array
}

public enum DriverRideAction: Codable, Sendable {
    case status(status: String, approxLocation: Location?, finalFare: Decimal?, at: Int)
    case pinSubmit(pinEncrypted: String, at: Int)
    // Future Cashu: case settlement(proof: String, amount: Int, at: Int)
}

public struct RiderRideState: Codable, Sendable {
    public let currentPhase: String         // "awaiting_driver", "awaiting_pin", "verified", "in_ride"
    public let history: [RiderRideAction]   // consolidated history array
}

public enum RiderRideAction: Codable, Sendable {
    case locationReveal(locationType: String, locationEncrypted: String, at: Int)  // "pickup" or "destination"
    case pinVerify(status: String, attempt: Int, at: Int)                          // "verified" or "rejected"
    // Future Cashu: case preimageShare(preimageEncrypted: String, at: Int)
}

// MARK: - Location

public struct Location: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public var address: String?
}

// MARK: - User Profile

public struct UserProfile: Codable, Sendable {
    public let pubkey: String
    public var name: String?
    public var picture: String?     // URL
    public var bio: String?
}

// MARK: - Vehicle

public struct Vehicle: Codable, Identifiable, Sendable {
    public let id: String           // UUID
    public var make: String
    public var model: String
    public var year: Int?
    public var color: String?
    public var licensePlate: String?
    public var vehicleType: VehicleType
}

public enum VehicleType: String, Codable, Sendable {
    case sedan, suv, van, truck, other
}

// MARK: - Payment

public enum PaymentMethod: String, Codable, Sendable, CaseIterable {
    case zelle, paypal, cashApp = "cash_app", venmo, strike, cash
    // Future: case cashu, lightning
}

// MARK: - RoadFlare

public struct RoadflareKey: Sendable {
    public let privateKey: Data     // 32 bytes
    public let publicKey: Data      // 32 bytes
    public let version: Int
    public let createdAt: Date
}

public struct RoadflareFollower: Codable, Identifiable, Sendable {
    public let id: String           // pubkey
    public let pubkey: String
    public var name: String?
    public var isApproved: Bool
    public var isMuted: Bool
    public var keyVersionSent: Int?
}

public struct RoadflareLocation: Codable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let status: RoadflareStatus
    public let keyVersion: Int
    public let timestamp: Int       // unix
}

public enum RoadflareStatus: String, Codable, Sendable {
    case online, onRide = "on_ride", offline
}

public struct FollowedDriver: Codable, Identifiable, Sendable {
    public let id: String           // pubkey
    public let pubkey: String
    public var addedAt: Int         // unix timestamp
    public var name: String?
    public var roadflarePrivateKey: Data?
    public var roadflarePublicKey: Data?
    public var keyVersion: Int?
    public var keyUpdatedAt: Int?   // for stale key detection
    public var notes: String?
    public var lastKnownLocation: RoadflareLocation?
}

// MARK: - Saved Location

public struct SavedLocation: Codable, Identifiable, Sendable {
    public let id: String           // UUID
    public let latitude: Double
    public let longitude: Double
    public var displayName: String
    public var addressLine: String
    public var locality: String?
    public var isPinned: Bool       // true = favorite, false = recent
    public var nickname: String?    // user-assigned label (e.g., "Home")
    public var timestampMs: Int     // last used
}
// MAX_RECENTS = 15, DUPLICATE_THRESHOLD_METERS = 50.0

// MARK: - History

public struct RideHistoryEntry: Codable, Identifiable, Sendable {
    public let id: String               // rideId (confirmationEventId)
    public let date: Date
    public let role: String             // "rider" (always for this app)
    public let status: String           // "completed" or "cancelled"
    public let counterpartyPubkey: String
    public let counterpartyName: String?
    public let pickupGeohash: String    // 6-char for backup privacy
    public let dropoffGeohash: String
    public let pickup: Location         // exact (riders store precise coords)
    public let destination: Location
    public let fare: Decimal            // USD
    public let paymentMethod: PaymentMethod
    public let distance: Double?        // miles
    public let duration: Int?           // minutes
    public let vehicleMake: String?
    public let vehicleModel: String?
    public let appOrigin: String        // "roadflare"
}
// MAX_RIDES = 500

// MARK: - State History

public struct StateHistoryEntry: Codable, Sendable {
    public let stage: String
    public let timestamp: Int
    public let data: [String: String]?
}

// MARK: - Fare

public struct FareEstimate: Sendable {
    public let distanceMiles: Double
    public let fareUSD: Decimal
    public let routeSummary: String?
}
```

### 12.2 Enumerations

```swift
public enum RiderStage: String, Codable, Sendable {
    case idle
    case waitingForAcceptance
    case driverAccepted
    case rideConfirmed
    case driverArrived
    case inProgress
    case completed
}

public enum DriverStage: String, Codable, Sendable {
    case offline
    case roadflareOnly
    case available
    case rideAccepted
    case enRouteToPickup
    case arrivedAtPickup
    case inRide
    case rideCompleted
}

public enum RiderAction: String, Codable, Sendable {
    case pinSubmitted = "pin_submitted"
    case locationRevealed = "location_revealed"
}
```

Note: `broadcastingRequest` rider stage removed (no broadcast offers in RoadFlare). `preimageShared` and `paymentProofSent` rider actions removed (no Cashu in v1).

---

## 13. State Machines

### 13.1 RoadFlare Rider State Machine

```
                    ┌──────────┐
                    │   IDLE   │
                    └────┬─────┘
                         │ sendRoadflareOffer()
                    ┌────▼──────────────────┐
                    │ WAITING_FOR_ACCEPTANCE │
                    └────┬──────────────────┘
                         │ receive Kind 3174 (acceptance)
                    ┌────▼──────────────┐
                    │ DRIVER_ACCEPTED    │
                    │ (auto-confirm +   │
                    │  send PIN)        │
                    └────┬──────────────┘
                         │ confirmation sent (Kind 3175)
                    ┌────▼──────────────┐
                    │ RIDE_CONFIRMED     │
                    └────┬──────────────┘
                         │ driver state = arrived (Kind 30180)
                    ┌────▼──────────────┐
                    │ DRIVER_ARRIVED     │
                    │ (show PIN to      │
                    │  driver)          │
                    └────┬──────────────┘
                         │ driver verifies PIN
                    ┌────▼──────────────┐
                    │ IN_PROGRESS        │
                    │ (destination       │
                    │  revealed)         │
                    └────┬──────────────┘
                         │ driver state = completed (Kind 30180)
                    ┌────▼──────────────┐
                    │ COMPLETED          │
                    │ (show payment      │
                    │  instructions)     │
                    └────┬──────────────┘
                         │ dismiss
                    ┌────▼─────┐
                    │   IDLE   │
                    └──────────┘

  ※ Cancellation (Kind 3179) at any stage → IDLE
```

### 13.2 AtoB Pattern (Critical Design)

The driver is the **single source of truth** for post-confirmation ride state. The rider's UI stage is **derived from the driver's status updates** (Kind 30180), not set independently. This prevents state divergence between the two apps.

| Driver publishes status | Rider transitions to |
|------------------------|---------------------|
| "en_route_pickup" | RIDE_CONFIRMED |
| "arrived" | DRIVER_ARRIVED |
| "in_progress" | IN_PROGRESS |
| "completed" | COMPLETED |
| "cancelled" | IDLE (via cancellation handling) |

### 13.3 Subscription Lifecycle

| Rider Stage | Active Subscriptions |
|-------------|---------------------|
| IDLE | RoadFlare locations (Kind 30014) |
| WAITING_FOR_ACCEPTANCE | + Acceptance (Kind 3174) |
| DRIVER_ACCEPTED → COMPLETED | + Driver state (Kind 30180), Chat (Kind 3178), Cancellation (Kind 3179) |
| COMPLETED | All ride subscriptions closed |

All ride subscriptions must be closed before starting a new ride to prevent stale callbacks.

### 13.4 NIP-33 Ordering

When publishing multiple rider state actions (Kind 30181) in sequence — e.g., PinVerify → LocationReveal — insert a **1100ms delay** between publishes. This ensures distinct `created_at` timestamps on the parameterized replaceable event, so relays correctly identify the latest version.

### 13.5 Event Deduplication

To prevent stale state from old rides:
- Track `processedDriverStateEventIds` — ignore state events from previous rides
- Track `processedCancellationEventIds` — prevent duplicate cancellation handling
- Validate `confirmationEventId` matches current ride before processing state updates
- Reject out-of-order RoadFlare location events (compare `createdAt` timestamps)

---

## 14. Screens & Navigation

### 14.1 RoadFlare App Navigation

```
TabView
├── DriversTab
│   ├── DriverListView (followed drivers with status indicators)
│   ├── DriverDetailView (profile, vehicle, notes, "Request Ride")
│   ├── AddDriverSheet
│   │   ├── ScanQRView
│   │   ├── EnterNpubView
│   │   └── ImportFromLinkView
│   └── ShareDriverListSheet
├── RideTab
│   ├── OnlineDriversListView (online drivers, sorted by proximity)
│   ├── RideRequestFlow
│   │   ├── LocationSearchSheet (pickup/destination)
│   │   ├── FareEstimateView
│   │   └── PaymentMethodPicker
│   ├── ActiveRideView
│   │   ├── RideStatusCard (from RidestrUI)
│   │   ├── PINDisplayView (from RidestrUI, when DRIVER_ARRIVED)
│   │   ├── ChatSheet
│   │   ├── PaymentInstructionsView (when COMPLETED)
│   │   └── CancelRideSheet
│   └── RideCompletedView
├── HistoryTab
│   ├── RideHistoryListView
│   └── RideDetailView
└── SettingsTab
    ├── ProfileEditView
    ├── PaymentMethodsView (configure fiat methods + preference order)
    ├── SavedLocationsView
    ├── RelayConfigView
    ├── KeyManagementView (view npub, export/import nsec)
    ├── NotificationSettingsView
    └── LogoutView
```

### 14.2 Screen Design Principles

- **List-centric** (not map-centric): Driver list with status indicators is the primary interface. No live map tracking — matches Android behavior and avoids relay spam.
- **Bottom sheet pattern**: Ride request, driver details, and chat slide up from bottom
- **Minimal chrome**: Large touch targets, clear CTAs, minimal text
- **Status-aware**: Active ride status always visible (persistent card at top of Ride tab)
- **Dark mode**: Full support from day one
- **Dynamic Type**: Support all accessibility text sizes
- **Haptics**: Feedback on ride accepted, driver arrived, PIN verified, ride completed

---

## 15. Location & Routing

### 15.1 CoreLocation Integration

**RoadFlare Rider needs only "When In Use" location** — used to:
- Auto-fill pickup location
- Sort drivers by proximity (if their broadcast includes location)

No "Always" location needed for the rider app.

### 15.2 Geocoding

- Forward geocoding: address → coordinate (CLGeocoder)
- Reverse geocoding: coordinate → address
- Autocomplete: MKLocalSearchCompleter for address search

### 15.3 Routing

MapKit Directions (MKDirections) for:
- Route distance calculation (for fare estimate)
- ETA estimate
- No map polyline display needed (no map tracking view in v1)

### 15.4 Progressive Location Reveal

**For RoadFlare rides**, precise pickup is shared immediately at confirmation (since these are trusted drivers). For general Ridestr rides (future), the progressive reveal is distance-gated.

| Stage | Pickup Shared With Driver | Destination Shared With Driver |
|-------|--------------------------|-------------------------------|
| Offer | ~1km approximate (2-decimal lat/lon) | ~1km approximate |
| Confirmation (RoadFlare) | **Precise immediately** | Hidden |
| Confirmation (general, future) | Precise only if driver < 1 mile (~1.6km) | Hidden |
| Driver < 1 mile | Precise (Kind 30181 LocationReveal) | Hidden |
| PIN Verified | Precise | **Precise** (Kind 30181 LocationReveal) |

Location reveal actions are published as part of the rider's Kind 30181 state event, NIP-44 encrypted to the driver.

### 15.5 Geohash

Implemented in RidestrSDK:
- Encode: (lat, lon, precision) → string (e.g., "9q8yy")
- Decode: string → (center lat, center lon)
- Neighbor calculation (center + 8 surrounding cells)
- Near-edge detection (auto-expand search area when location is near a geohash boundary)

**Precision levels used:**
| Precision | Size | Usage |
|-----------|------|-------|
| 3 chars | ~156km | Expanded driver search |
| 4 chars | ~39km | Normal driver search (+ neighbors = ~72mi × 36mi coverage) |
| 5 chars | ~4.9km | Ride location tags |
| 6 chars | ~1.2km | History storage (privacy) |
| 7 chars | ~153m | Settlement verification |

**Approximate location**: Rounding lat/lon to 2 decimal places gives ~1km precision (used for offer pickup/destination).

---

## 16. Security & Privacy

### 16.1 Key Storage

| Key | Storage | Access |
|-----|---------|--------|
| Nostr identity key | Keychain (kSecAttrAccessibleAfterFirstUnlock) | App only |
| RoadFlare key | Keychain (separate item) | App only |
| Followed drivers + keys | SwiftData (encrypted at rest by iOS) | App only |
| Ride history | SwiftData | App only |

### 16.2 Encryption

- **NIP-44**: All ride event content encrypted (ECDH + HKDF + ChaCha20-Poly1305)
- **Event signing**: NIP-01 Schnorr signatures on all events
- **RoadFlare broadcasts**: Encrypted to RoadFlare public key

### 16.3 iCloud Backup Exclusions

Exclude from backup:
- Keychain items (default behavior with correct attributes)
- SwiftData database files (`isExcludedFromBackup = true`)

### 16.4 Privacy Principles

1. **No tracking**: No analytics, telemetry, or crash reporting
2. **No PII on relays**: All personal data NIP-44 encrypted
3. **Progressive reveal**: Location precision increases with ride stage
4. **Key separation**: Identity key and RoadFlare key are independent
5. **Expiring events**: NIP-40 expiration on transient events
6. **No servers**: Zero infrastructure = zero data collection

---

## 17. iOS-Specific Considerations

### 17.1 Background Execution

The rider app has **minimal background requirements** compared to a driver app:
- Rider is actively using the phone during ride request and ride
- Only gap: rider locks phone while waiting for acceptance

Approach:
- **Foreground**: Full relay connections, real-time event processing
- **Background (brief)**: URLSessionWebSocketTask keeps socket alive briefly after backgrounding
- **Suspended**: Missed events are recovered via EOSE replay on foregrounding (relay stores events)
- **Optional APNs**: App supports receiving push notifications from an external bridge service if one is configured, but does not require it

### 17.2 Notifications

| Notification | Trigger | Priority |
|-------------|---------|----------|
| Ride accepted | Kind 3174 received | Time Sensitive |
| Driver arrived | Kind 30180 stage=arrived | Time Sensitive |
| New chat message | Kind 3178 received | Active |
| Ride completed | Kind 30180 stage=completed | Default |
| RoadFlare key received | Kind 3186 received | Default |

Implementation: Local notifications fired when processing Nostr events. If app is foregrounded, show in-app alert instead.

Optional APNs bridge support: The app can register for and handle remote notifications from a push bridge service. The bridge URL is configurable in settings. The app does not ship with or require a bridge.

### 17.3 State Preservation

- Active ride state serialized to disk on every stage transition
- On app relaunch during active ride: restore state, re-subscribe to driver state events
- EOSE ensures we catch up on any events missed while suspended
- Handle edge case: "ride completed while app was killed" — detect on relaunch via relay query

### 17.4 Permissions

| Permission | Usage String | When Requested |
|-----------|-------------|----------------|
| Location When In Use | "Used to set your pickup location" | First ride request |
| Camera | "Scan QR codes to add drivers" | First QR scan attempt |
| Notifications | "Get notified when your driver accepts or arrives" | After first ride request |

### 17.5 Deep Links

URL scheme: `roadflare://`
- `roadflare://driver/{npub}` — add/view driver
- `roadflare://share/{event_id}` — import shared driver list

### 17.6 Accessibility

- VoiceOver labels on all interactive elements
- Dynamic Type support
- Sufficient color contrast (WCAG AA)
- Haptic feedback on key events
- Reduced Motion support

---

## 18. Testing Strategy

### 18.1 Unit Tests (RidestrSDK)

| Test Suite | Count (Target) | Covers |
|-----------|----------------|--------|
| EventSigningTests | 15+ | NIP-01 signing, ID computation, verification |
| NIP44EncryptionTests | 20+ | Key derivation, encrypt/decrypt roundtrip, cross-platform vectors |
| NIP19Tests | 10+ | npub/nsec encoding/decoding |
| RelayManagerTests | 15+ | Connection, reconnection, subscription, EOSE |
| GeohashTests | 10+ | Encode, decode, neighbors, edge cases |
| RideStateMachineTests | 20+ | All stage transitions, invalid transitions, cancellation |
| RoadflareKeyTests | 10+ | Generation, rotation, versioning |
| FareCalculatorTests | 10+ | Distance × rate, minimums, edge cases |
| ProfileSyncTests | 10+ | Push/pull roundtrip, encrypted events |
| PaymentMethodTests | 5+ | Method matching, preference ordering |

**Total target: 125+ SDK unit tests**

### 18.2 Test Doubles

```swift
// FakeRelayManager — mock WebSocket
class FakeRelayManager: RelayManagerProtocol {
    var publishedEvents: [NostrEvent] = []
    var subscriptionResponses: [NostrFilter: [NostrEvent]] = [:]
}

// FakeLocationService — mock CoreLocation
class FakeLocationService: LocationServiceProtocol {
    var currentLocation: CLLocation?
}

// FakeKeychainStorage — in-memory keychain
class FakeKeychainStorage: KeychainStorageProtocol {
    var store: [String: Data] = [:]
}
```

### 18.3 Integration Tests

- Event signing compatibility with Android (test vectors)
- NIP-44 encryption compatibility with Android (test vectors)
- Relay connection to real test relay
- Geohash compatibility with Android implementation

### 18.4 UI Tests (RoadFlare App)

- Onboarding flow
- Add driver flow (npub entry)
- Ride request flow (select driver, set locations, send offer)
- Active ride lifecycle (mock driver responses)

---

## 19. Phased Delivery Plan

### Phase 1: SDK Foundation (Weeks 1-3)

**Goal**: Core Nostr infrastructure in RidestrSDK.

- [ ] Xcode project setup (RidestrSDK package + RoadFlare app target)
- [ ] NostrKeypair, KeyManager (generate, import/export nsec/npub)
- [ ] Keychain storage
- [ ] NIP-01 event signing (Schnorr via secp256k1-swift)
- [ ] NIP-44 encryption/decryption
- [ ] NIP-19 bech32 encoding/decoding
- [ ] NostrEvent model and serialization
- [ ] NostrFilter model
- [ ] RelayManager (WebSocket, publish, subscribe, EOSE, reconnection)
- [ ] Geohash encoding/decoding
- [ ] All rideshare event kind constants
- [ ] Unit tests: 50+

### Phase 2: RoadFlare Protocol (Weeks 4-6)

**Goal**: RoadFlare-specific protocol logic in SDK.

- [ ] RoadflareKeyManager (generate, rotation, versioning)
- [ ] RoadflareLocation decryption
- [ ] FollowedDriversRepository (local + Kind 30011 sync with public p-tags)
- [ ] Follower discovery via p-tag queries on Kind 30011 (NOT deprecated Kind 3187)
- [ ] Key share handling (Kind 3186 receive + Kind 3188 acknowledgement)
- [ ] Stale key detection (compare keyUpdatedAt against Kind 30012 public tag)
- [ ] RoadFlare location subscription (Kind 30014)
- [ ] RideService — sendRoadflareOffer, confirmRide, cancelRide, sendChat
- [ ] RiderRideStateMachine (7 stages)
- [ ] Driver state event parsing (Kind 30180)
- [ ] Cancellation event parsing (Kind 3179)
- [ ] Chat event handling (Kind 3178)
- [ ] Event deduplication logic
- [ ] Unit tests: 40+

### Phase 3: Location & Fare (Weeks 7-8)

**Goal**: MapKit integration, fare calculation.

- [ ] GeocodingService (CLGeocoder, MKLocalSearchCompleter)
- [ ] RoutingService (MKDirections for distance/ETA)
- [ ] FareCalculator (distance × rate, minimum fare)
- [ ] Progressive location reveal logic
- [ ] RemoteConfigManager (Kind 30182 parsing)
- [ ] Payment method matching (rider preference × driver accepted)
- [ ] Unit tests: 15+

### Phase 4: RoadFlare App UI (Weeks 9-13)

**Goal**: Functional RoadFlare rider app.

- [ ] Onboarding flow (welcome, key setup, profile, add first driver, payment methods)
- [ ] Drivers tab (list, detail, add via npub/QR, remove, share)
- [ ] Ride tab — idle state (online drivers list)
- [ ] Ride tab — request flow (select driver, set locations, fare estimate, send offer)
- [ ] Ride tab — active ride (status card, PIN display, chat, cancel)
- [ ] Ride tab — completed (payment instructions)
- [ ] History tab
- [ ] Settings tab (profile, payment methods, saved locations, relays, keys, logout)
- [ ] Local notifications (ride accepted, driver arrived, chat message)
- [ ] State preservation (persist/restore active ride)
- [ ] QR code scanning (AVFoundation)
- [ ] Deep links (roadflare:// URL scheme)
- [ ] Dark mode
- [ ] Accessibility (VoiceOver, Dynamic Type)

### Phase 5: RidestrUI Components (Weeks 14-15)

**Goal**: Extracted, customizable UI components.

- [ ] RideStatusCard (stage-aware display)
- [ ] PINDisplayView / PINEntryView
- [ ] FareEstimateView
- [ ] Environment-based theming
- [ ] Documentation and usage examples

### Phase 6: Sync & Polish (Weeks 16-18)

**Goal**: Cross-device sync, hardening.

- [ ] ProfileSyncManager (Kind 30177 — saved locations, settings)
- [ ] Ride history backup/restore (Kind 30174)
- [ ] LogoutManager
- [ ] Optional APNs bridge support (receive remote notifications)
- [ ] Edge case handling (ride completed while backgrounded, stale events, relay failures)
- [ ] Performance profiling
- [ ] UI polish and animation
- [ ] TestFlight distribution

### Phase 7: Cross-Platform Testing (Weeks 19-20)

**Goal**: Verify iOS rider ↔ Android driver interoperability.

- [ ] Event signing compatibility
- [ ] NIP-44 encryption compatibility
- [ ] Full ride lifecycle: iOS rider sends offer → Android driver accepts → ride completes
- [ ] RoadFlare: key sharing across platforms
- [ ] RoadFlare: location broadcast decryption across platforms
- [ ] Profile sync across platforms
- [ ] Bug fixes from interop testing

---

## 20. Future Roadmap

Items deferred from v1, in rough priority order:

### v1.x (Near-term)

1. **Drivestr iOS** — native iOS driver app
2. **Cashu wallet integration** — add `cashu` payment method with HTLC escrow
3. **NIP-60 wallet sync** — cross-device proof synchronization
4. **Lightning payments** — HODL invoice bridge for cross-mint rides
5. **Live Activity** — iOS Live Activity for active ride status on lock screen

### v2.x (Medium-term)

6. **Ridestr Rider** — general public ride offers and broadcast requests
7. **Rating system** — ride feedback and driver ratings
8. **Dispute resolution** — framework for handling ride disputes
9. **Valhalla routing** — offline routing for fare calculation without network
10. **Push notification bridge** — lightweight relay-to-APNs server (open source)

### v3.x (Long-term)

11. **iPad support** — optimized layouts
12. **CarPlay** — driver navigation integration
13. **watchOS** — ride status on Apple Watch
14. **Widget** — home screen widget showing driver availability

---

## 21. Design Decisions Log

All design decisions made during PRD development:

| # | Decision | Choice | Rationale |
|---|----------|--------|-----------|
| 1 | Repo structure | Mono-repo | One workspace, shared SDK, mirrors Android structure |
| 2 | Routing engine | MapKit Directions (v1) | Free, no setup, Valhalla deferred |
| 3 | Local storage | SwiftData | Modern, iOS 17+ target makes this viable |
| 4 | iOS target | iOS 17+ | ~90% of active iPhones, enables modern APIs |
| 5 | Bitcoin/Cashu | Deferred entirely from v1 | Focus on fiat P2P payments for RoadFlare |
| 6 | Apple Pay | Not included | Apple Pay is merchant-based, not P2P — doesn't fit |
| 7 | SDK model | RidestrSDK (public) + RidestrUI (optional companion) | SDK is protocol-only, UI package has drop-in components for complex flows |
| 8 | Apps to build | RoadFlare rider only (v1), Drivestr iOS later | Android driver app exists and is in use |
| 9 | Background notifications | Support APNs bridge, fallback to foreground-only | No server commitment, but plumbing is there |
| 10 | Distribution | TestFlight first, App Store when ready | No crypto = fewer review issues |
| 11 | Naming | SDK: RidestrSDK/RidestrUI, App: "RoadFlare", Future driver: TBD | Protocol name for SDK, product name for app |
| 12 | Public ride offers | Not in RoadFlare app | RoadFlare is exclusively for trusted driver networks |
| 13 | Map / live tracking | No live driver tracking on map | Avoids relay spam, matches Android behavior, no API costs |
| 14 | Nostr library | rust-nostr (nostr-sdk-swift) | 4,500+ commits, 60+ NIPs, battle-tested Rust core — reliability over API elegance |

---

## Appendix A: Nostr Event Kind Reference

### Events Used by RoadFlare Rider (v1)

| Kind | Name | Type | Expiry | Direction |
|------|------|------|--------|-----------|
| 3173 | Ride Offer | Regular | 15 min | Rider → Driver |
| 3174 | Ride Acceptance | Regular | 10 min | Driver → Rider |
| 3175 | Ride Confirmation | Regular | 8 hours | Rider → Driver |
| 3178 | Chat Message | Regular | 8 hours | Both |
| 3179 | Cancellation | Regular | 24 hours | Either |
| 3186 | RoadFlare Key Share | Regular | 5 min | Driver → Rider |
| 3188 | Key Acknowledgement | Regular | 5 min | Rider → Driver |
| 30011 | Followed Drivers List | Replaceable | None | Self → Self |
| 30014 | RoadFlare Location | Replaceable | 5 min | Driver → Followers |
| 30174 | Ride History Backup | Replaceable | None | Self → Self |
| 30177 | Unified Profile | Replaceable | None | Self → Self |
| 30180 | Driver Ride State | Replaceable | 8 hours | Driver → Rider |
| 30181 | Rider Ride State | Replaceable | 8 hours | Rider → Driver |
| 30182 | Remote Config | Replaceable | None | Admin → All |

Note: Kind 3187 (Follow Notification) is **deprecated** — follower discovery uses p-tag queries on Kind 30011 instead.

### Exact Event Content Formats

**Kind 3173 — Ride Offer (RoadFlare, NIP-44 encrypted to driver):**
```json
{
  "fare_estimate": 50000.0,
  "fare_fiat_amount": "12.50",
  "fare_fiat_currency": "USD",
  "destination": {"lat": 40.123, "lon": -74.456},
  "approx_pickup": {"lat": 40.124, "lon": -74.457},
  "pickup_route_km": 0.5,
  "pickup_route_min": 3.0,
  "ride_route_km": 15.2,
  "ride_route_min": 22.0,
  "destination_geohash": "djq12",
  "payment_method": "zelle",
  "fiat_payment_methods": ["zelle", "venmo", "cash"]
}
```
`fare_fiat_amount` and `fare_fiat_currency` are optional. Both present or both absent (mandatory pair). Up-to-date clients MUST use `fare_fiat_amount` as the display value for fiat rides; older clients fall back to converting `fare_estimate` (sats) using their local BTC price. See ADR-0008.
Tags: `["e", "<driver_availability_event_id>"]`, `["p", "<driver_pubkey>"]`, `["t", "rideshare"]`, `["t", "roadflare"]`, `["expiration", "<unix>"]`

**Kind 3174 — Ride Acceptance (NIP-44 encrypted to rider):**
```json
{
  "status": "accepted",
  "wallet_pubkey": "<driver_wallet_hex>",
  "payment_method": "zelle",
  "mint_url": "<optional>"
}
```
Tags: `["e", "<offer_event_id>"]`, `["p", "<rider_pubkey>"]`, `["t", "rideshare"]`, `["expiration", "<unix>"]`

Note: `wallet_pubkey` is for future Cashu P2PK. For v1 fiat-only, it may be empty or the driver's identity pubkey.

**Kind 3175 — Ride Confirmation (NIP-44 encrypted to driver):**
```json
{
  "precise_pickup": {"lat": 40.12345, "lon": -74.45678}
}
```
Tags: `["e", "<acceptance_event_id>"]`, `["p", "<driver_pubkey>"]`, `["t", "rideshare"]`, `["expiration", "<unix>"]`

Note: `payment_hash` and `escrow_token` fields are present in the protocol for Cashu but omitted in v1.

**Kind 30180 — Driver Ride State (NIP-44 encrypted, replaceable, d-tag = confirmationEventId):**
```json
{
  "current_status": "en_route_pickup",
  "history": [
    {"type": "status", "status": "en_route_pickup", "at": 1234567890},
    {"type": "status", "status": "arrived", "at": 1234567920},
    {"type": "pin_submit", "pin_encrypted": "<nip44_ciphertext>", "at": 1234567950}
  ]
}
```
Status values: `en_route_pickup`, `arrived`, `in_progress`, `completed`, `cancelled`

**Kind 30181 — Rider Ride State (NIP-44 encrypted, replaceable, d-tag = confirmationEventId):**
```json
{
  "current_phase": "verified",
  "history": [
    {"type": "location_reveal", "location_type": "pickup", "location_encrypted": "<nip44>", "at": 1234567890},
    {"type": "pin_verify", "status": "verified", "attempt": 1, "at": 1234567950},
    {"type": "location_reveal", "location_type": "destination", "location_encrypted": "<nip44>", "at": 1234567952}
  ]
}
```

**Kind 30014 — RoadFlare Location (encrypted to RoadFlare pubkey, d-tag = "roadflare-location"):**
```json
{
  "lat": 40.12345,
  "lon": -74.45678,
  "timestamp": 1234567890,
  "status": "online",
  "onRide": false
}
```
Tags: `["d", "roadflare-location"]`, `["status", "online"]`, `["key_version", "2"]`, `["expiration", "<unix>"]`

**Kind 30011 — Followed Drivers List (NIP-44 encrypted to self, d-tag = "roadflare-drivers"):**
```json
{
  "drivers": [
    {
      "pubkey": "<hex>",
      "addedAt": 1234567890,
      "note": "Toyota Camry, airport runs",
      "roadflareKey": {
        "privateKey": "<hex>",
        "publicKey": "<hex>",
        "version": 2,
        "keyUpdatedAt": 1234567890
      }
    }
  ],
  "updated_at": 1234567890
}
```
Tags: `["d", "roadflare-drivers"]`, `["t", "roadflare"]`, `["p", "<driver1_pubkey>"]`, `["p", "<driver2_pubkey>"]`

**IMPORTANT**: Driver pubkeys are in **public p-tags** (not encrypted). This enables drivers to discover followers via relay queries. Sensitive data (keys, notes) is in the encrypted content.

**Kind 3186 — Key Share (NIP-44 encrypted to follower):**
```json
{
  "roadflareKey": {
    "privateKey": "<hex>",
    "publicKey": "<hex>",
    "version": 2,
    "keyUpdatedAt": 1234567890
  },
  "keyUpdatedAt": 1234567890,
  "driverPubKey": "<hex>"
}
```

**Kind 3188 — Key Acknowledgement (NIP-44 encrypted to driver):**
```json
{
  "keyVersion": 2,
  "keyUpdatedAt": 1234567890,
  "status": "received",
  "riderPubKey": "<hex>"
}
```
Status: `"received"` (normal) or `"stale"` (request refresh)

### Events in SDK but NOT Used by RoadFlare v1

| Kind | Name | Purpose |
|------|------|---------|
| 30012 | Driver RoadFlare State | Driver-side follower/key management |
| 30013 | Shareable Driver List | Public driver list sharing |
| 30173 | Driver Availability | General driver availability broadcast |
| 7375 | NIP-60 Proof Storage | Cashu wallet sync (future) |
| 17375 | NIP-60 Pending Proof | Cashu operations (future) |
| 7376 | NIP-60 Proof History | Cashu transaction log (future) |

### Common Tags

| Tag | Purpose | Example |
|-----|---------|---------|
| `p` | Recipient pubkey | `["p", "<hex>"]` |
| `d` | Replaceable event identifier | `["d", "roadflare-location"]` |
| `e` | Referenced event ID | `["e", "<event_id>"]` |
| `g` | Geohash | `["g", "9q8yy"]` |
| `t` | Hashtag (topic) | `["t", "rideshare"]`, `["t", "roadflare"]` |
| `expiration` | NIP-40 auto-expiry | `["expiration", "1710000000"]` |
| `status` | RoadFlare status | `["status", "online"]` |
| `key_version` | RoadFlare key version | `["key_version", "3"]` |
| `key_updated_at` | Key rotation timestamp | `["key_updated_at", "1710000000"]` |
| `transition` | State chain integrity | `["transition", "<last_transition_id>"]` |

### D-Tags for Replaceable Events

| Kind | d-tag value |
|------|-------------|
| 30011 | `"roadflare-drivers"` |
| 30012 | `"roadflare-state"` |
| 30014 | `"roadflare-location"` |
| 30174 | `"rideshare-history"` |
| 30177 | `"rideshare-profile"` |
| 30180 | `<confirmationEventId>` (one per ride) |
| 30181 | `<confirmationEventId>` (one per ride) |
| 30182 | `"ridestr-admin-config"` |

### Cross-Reference: Full Protocol Documentation

For the complete Android implementation details including every method signature, exact JSON structures, coroutine patterns, error handling, and all 181 payment test specifications, see **ANDROID_DEEP_DIVE.md** in this directory.

---

## Appendix B: Android-to-iOS Technology Mapping

| Android | iOS Equivalent |
|---------|---------------|
| Kotlin | Swift 6 |
| Jetpack Compose | SwiftUI |
| Kotlin Coroutines | Swift Concurrency (async/await, actors) |
| StateFlow | @Observable (iOS 17) |
| viewModelScope | Task with .task {} view modifier |
| EncryptedSharedPreferences | Keychain Services |
| SharedPreferences | UserDefaults |
| Room / SQLite | SwiftData |
| Google Play Services Location | CoreLocation |
| Foreground Service | Background Modes + BGTaskScheduler |
| Quartz (Nostr lib) | rust-nostr via nostr-sdk-swift (UniFFI bindings) |
| cdk-kotlin (Cashu) | Deferred (future: custom or cdk-swift) |
| Valhalla Mobile | Deferred (v1: MapKit Directions) |
| ML Kit + CameraX | VisionKit / AVFoundation |
| Robolectric / MockK | XCTest + Swift protocols |
| build.gradle.kts | Package.swift + Xcode project |
