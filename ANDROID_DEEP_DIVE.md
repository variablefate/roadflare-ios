# Android Codebase Deep-Dive Reference

Comprehensive analysis of the Ridestr Android codebase for iOS porting.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Nostr Protocol Layer](#2-nostr-protocol-layer)
3. [RoadFlare System](#3-roadflare-system)
4. [Ride Lifecycle & State Machines](#4-ride-lifecycle--state-machines)
5. [Payment System](#5-payment-system)
6. [Data Models & Storage](#6-data-models--storage)
7. [UI Screens & Navigation](#7-ui-screens--navigation)
8. [Configuration & Settings](#8-configuration--settings)
9. [Profile Sync & Backup](#9-profile-sync--backup)
10. [Constants & Magic Numbers](#10-constants--magic-numbers)

---

## 1. Architecture Overview

### Module Structure
```
ridestr/
├── common/          (~124 .kt files, ~65% of codebase)
│   ├── nostr/       Relay management, event signing, encryption, domain services
│   ├── payment/     Cashu backend, wallet, HTLC, NIP-60
│   ├── roadflare/   Key management, location broadcasting
│   ├── data/        Repositories (vehicles, locations, history, drivers)
│   ├── routing/     Valhalla offline routing
│   ├── settings/    SettingsManager, RemoteConfigManager
│   ├── sync/        ProfileSyncManager
│   ├── ui/          Shared composables (chat, fare display, settings components)
│   └── util/        FareCalculator, geocoding, extensions
├── rider-app/       (15 .kt files) Ridestr Rider
├── drivestr/        (17 .kt files) Drivestr Driver
└── roadflare-rider/ (21 .kt files) RoadFlare Rider
```

### Key Design Patterns
- **Facade**: NostrService delegates to RideshareDomainService, RoadflareDomainService, ProfileBackupService
- **State Machine**: RiderViewModel (8 stages), DriverViewModel (7 stages)
- **Repository**: SharedPreferences-backed with StateFlow
- **Singleton**: All repositories and services use `getInstance(context)`
- **AtoB Pattern**: Driver is source of truth for post-confirmation state; rider UI derives from driver status

---

## 2. Nostr Protocol Layer

### Relay Management

**RelayManager** manages multi-relay WebSocket connections.

**Constants:**
- CONNECT_TIMEOUT_MS = 10,000
- READ_TIMEOUT_MS = 30,000
- WRITE_TIMEOUT_MS = 30,000
- RECONNECT_DELAY_MS = 5,000 (exponential backoff, max 60,000)
- Bounded message channel capacity: 256

**Default Relays:**
```
wss://relay.damus.io
wss://nos.lol
wss://relay.primal.net
```

**RelayConnection features:**
- Generation-based stale message filtering (prevents race conditions during reconnect)
- Bounded message channel (capacity 256, drops if full)
- NIP-01 signature verification on all received events
- Automatic resubscription of all active subscriptions on reconnect
- Republish pending events on reconnect

**SubscriptionManager:**
- Thread-safe registry with synchronized lock
- Two models: singular (one ID per key) and group (multiple IDs per entity)
- Auto-closes previous subscription when setting new one for same key
- Stale subscription cleanup (30-minute max age, rideshare kinds only)

### Key Management

**KeyManager** stores keys in EncryptedSharedPreferences (AES-256-GCM).

Stored values:
- `nostr_private_key` (hex)
- `profile_completed` (boolean)
- `user_mode` (RIDER/DRIVER)

Fallback: Regular SharedPreferences if EncryptedSharedPreferences fails (emulators, rooted devices).

Import formats: `nsec1...` (bech32) or 64-char hex.

### NIP-44 Encryption

Uses the Quartz library's `signer.nip44Encrypt(plaintext, recipientPubKey)` and `signer.nip44Decrypt(ciphertext, senderPubKey)`.

Encryption targets vary by event:
- **Ride events (3173, 3175, 3178, 3179, 30180, 30181)**: Encrypted to counterparty
- **Backup events (30011, 30012, 30174, 30177)**: Encrypted to self
- **RoadFlare location (30014)**: Encrypted to RoadFlare public key (NOT identity key)
- **Key share (3186)**: Encrypted to follower's identity key
- **Key ack (3188)**: Encrypted to driver's identity key

### Domain Services

#### RideshareDomainService (940 lines)

**Driver Availability (Kind 30173):**
```
broadcastAvailability(location, status, vehicle, mintUrl, paymentMethods)
```
- Parameterized replaceable, d-tag: "rideshare-availability"
- Content: approx_location (2-decimal precision ~1km), status, vehicle info, payment methods
- Tags: geohash at precision 3,4,5 (omitted in ROADFLARE_ONLY mode)
- Expiration: 30 minutes

**Geohash search strategy:**
- Normal: precision 4 + 8 neighbors (~72mi × 36mi)
- Expanded: precision 3 + 8 neighbors (~300mi × 150mi)
- Near-edge detection auto-expands search area

**Ride Offer (Kind 3173):**

Two modes:
1. **Direct offer** (NIP-44 encrypted to driver):
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
     "fiat_payment_methods": ["zelle", "paypal"]
   }
   ```
   `fare_fiat_amount` + `fare_fiat_currency` are optional flat fields (ADR-0008). Present when `payment_method` resolves to a fiat rail (not `"bitcoin"`); absent for bitcoin-native rides. Note: a non-empty `fiat_payment_methods` list is not sufficient — if `payment_method` is `"bitcoin"` these fields will be absent even when `fiat_payment_methods` contains fiat entries. Up-to-date drivers MUST display `fare_fiat_amount` directly for fiat rides rather than converting `fare_estimate` (sats) via local BTC price.
   Tags: `e` (driver availability event), `p` (driver pubkey), `t` ("rideshare"), expiration (15 min)

2. **Broadcast offer** (unencrypted, public):
   ```json
   {
     "fare_estimate": 2500.0,
     "pickup_area": {"lat": 40.124, "lon": -74.457},
     "destination_area": {"lat": 40.789, "lon": -73.456},
     "route_distance_km": 15.2,
     "route_duration_min": 22.0,
     "mint_url": "https://mint.example.com",
     "payment_method": "cashu"
   }
   ```
   Tags: `g` (geohash precision 3-5), `t` ("rideshare", "ride-request"), expiration (15 min)

**RoadFlare offer**: Same as direct offer + `["t", "roadflare"]` tag.

**Ride Acceptance (Kind 3174):**
```json
{
  "status": "accepted",
  "wallet_pubkey": "driver_wallet_hex",
  "escrow_type": "cashu_nut14",
  "mint_url": "https://driver_mint.com",
  "payment_method": "cashu"
}
```
Tags: `e` (offer event), `p` (rider pubkey), `t` ("rideshare"), expiration (10 min)

**Ride Confirmation (Kind 3175):**
NIP-44 encrypted to driver:
```json
{
  "precise_pickup": {"lat": 40.12345, "lon": -74.45678},
  "payment_hash": "64_char_hex",
  "escrow_token": "cashuA_token"
}
```
Tags: `e` (acceptance event), `p` (driver pubkey), `t` ("rideshare"), expiration (8 hours)

**Driver Ride State (Kind 30180):**
Parameterized replaceable, d-tag = confirmationEventId.

Status values: "en_route_pickup", "arrived", "in_progress", "completed", "cancelled"

Action types in history array:
- **Status**: status, approx_location, final_fare, invoice
- **PinSubmit**: pin_encrypted (NIP-44 to rider)
- **Settlement**: settlement_proof, settled_amount
- **DepositInvoiceShare**: invoice (BOLT11), amount

**Rider Ride State (Kind 30181):**
Parameterized replaceable, d-tag = confirmationEventId.

Phase values: "awaiting_driver", "awaiting_pin", "verified", "in_ride"

Action types in history array:
- **LocationReveal**: location_type ("pickup"/"destination"), location_encrypted
- **PinVerify**: status ("verified"/"rejected"), attempt count
- **PreimageShare**: preimage_encrypted, escrow_token_encrypted
- **BridgeComplete**: preimage_encrypted, amount, fees

**Chat (Kind 3178):**
NIP-44 encrypted. Content: `{"message": "text"}`. Expiration: 8 hours.

**Cancellation (Kind 3179):**
Plain JSON with reason. Tags: `p`, `e` (confirmationEventId), `t`, expiration (24 hours).

#### RoadflareDomainService (739 lines)

See [Section 3: RoadFlare System](#3-roadflare-system).

#### ProfileBackupService (550 lines)

See [Section 9: Profile Sync & Backup](#9-profile-sync--backup).

---

## 3. RoadFlare System

### Key Management (RoadflareKeyManager, 358 lines)

Manages a **separate** RoadFlare keypair (distinct from identity key).

**Key methods:**
- `generateNewKey()` — new secp256k1 keypair, increments version
- `rotateKey(signer)` — generates new key, publishes Kind 30012, sends to all non-muted followers
- `sendKeyToFollower(signer, pubkey, key, keyUpdatedAt)` — Kind 3186 with 5-min expiry
- `approveFollower(signer, pubkey)` — gets/generates key → sends key → marks approved → publishes state
- `handleRemoveFollower(signer, pubkey)` — removes + triggers key rotation
- `handleMuteFollower(signer, pubkey, reason)` — adds to muted + triggers key rotation
- `ensureFollowersHaveCurrentKey(signer)` — called on startup

**Key rotation algorithm:**
1. Generate new keypair with incremented version
2. Update keyUpdatedAt timestamp
3. Publish updated state to Kind 30012
4. For each active follower (approved AND !muted): send new key via Kind 3186
5. Mark each follower with new keyVersionSent
6. Muted/removed followers retain old key — cannot decrypt new broadcasts

### Location Broadcasting (RoadflareLocationBroadcaster, 221 lines)

**Constants:**
- BROADCAST_INTERVAL_MS = 120,000 (2 minutes)
- MIN_BROADCAST_INTERVAL_MS = 60,000 (1 minute, spam prevention)

**Broadcast conditions (all must be true):**
1. Has RoadFlare key
2. Has active followers (approved + has current key + not muted)
3. Has current location

**Location event (Kind 30014):**
- Encrypted to RoadFlare public key (NOT identity key)
- Followers decrypt with shared private key
- Content: `{ "lat": double, "lon": double, "timestamp": long, "status": "online|on_ride" }`
- Tags: `d` ("roadflare-location"), `status`, `key_version`, `expiration` (5 min)

**Encryption model (ECDH commutativity):**
```
Driver encrypts:  nip44Encrypt(content, roadflare_pubkey)    → ECDH(driver_priv, roadflare_pub)
Follower decrypts: nip44Decrypt(ciphertext, driver_pubkey)   → ECDH(roadflare_priv, driver_pub)
These are equal because ECDH(A_priv, B_pub) == ECDH(B_priv, A_pub)
```

### Follower Management

**Driver side (DriverRoadflareRepository, 406 lines):**

Storage: SharedPreferences "roadflare_driver_state"

State structure:
```json
{
  "roadflareKey": { "privateKey": "hex", "publicKey": "hex", "version": int, "createdAt": long },
  "followers": [{ "pubkey": "hex", "name": "str", "addedAt": long, "approved": bool, "keyVersionSent": int }],
  "muted": [{ "pubkey": "hex", "mutedAt": long, "reason": "str" }],
  "keyUpdatedAt": long,
  "lastBroadcastAt": long,
  "updatedAt": long
}
```

Key methods:
- `getActiveFollowerPubkeys()` — approved AND keyVersionSent == currentVersion AND !muted
- `getFollowersNeedingKey()` — approved AND keyVersionSent < currentVersion AND !muted
- `muteRider(pubkey, reason)` — triggers key rotation (caller invokes)

**Rider side (FollowedDriversRepository, 298 lines):**

Storage: SharedPreferences "roadflare_followed_drivers" + in-memory location cache

Key methods:
- `addDriver(driver)` — adds or updates
- `updateDriverKey(pubkey, key)` — when receiving Kind 3186
- `updateDriverLocation(pubkey, lat, lon, status, timestamp, keyVersion)` — in-memory only
- `cacheDriverName(pubkey, name)` — persisted to SharedPrefs for instant startup display

### Follower Discovery (replacing deprecated Kind 3187)

Drivers now discover followers via **p-tag queries on Kind 30011**:
- Rider publishes Kind 30011 with `["p", "driver_pubkey"]` tags (PUBLIC)
- Driver queries Kind 30011 events with their pubkey in p-tags
- Returns list of rider pubkeys who follow them

### Complete Follow Flow

```
Rider adds driver:
  → FollowedDriversRepository.addDriver()
  → Publish Kind 30011 with ["p", "driver_pubkey"] tag

Driver discovers follower:
  → Query Kind 30011 p-tags
  → addPendingFollower(riderPubkey)

Driver approves:
  → Get or generate RoadFlare key
  → Send key via Kind 3186 (5-min expiry, NIP-44 encrypted to rider)
  → Mark approved=true, keyVersionSent=version
  → Publish Kind 30012 (state backup)

Rider receives key:
  → Parse and decrypt Kind 3186
  → Store in FollowedDriver.roadflareKey
  → Publish Kind 3188 acknowledgement

Rider decrypts locations:
  → Subscribe to Kind 30014 from followed drivers
  → Decrypt using roadflarePrivKey + driverPubKey
  → Update in-memory location cache
```

### Stale Key Detection

1. Rider fetches driver's Kind 30012 `key_updated_at` tag (public, no decryption needed)
2. Compares to stored `roadflareKey.keyUpdatedAt`
3. If mismatch → publish Kind 3188 with status="stale"
4. Driver sends fresh key via Kind 3186

### RoadFlare Ride Flow (RideSessionManager, 346 lines)

**Batch offer sending:**
- BATCH_SIZE = 3 drivers at a time
- BATCH_DELAY_MS = 15,000 (15 seconds between batches)
- Drivers sorted by distance (closest first)
- Each offer: Kind 3173 with `["t", "roadflare"]` tag

---

## 4. Ride Lifecycle & State Machines

### Rider State Machine

**Stages:**
```
IDLE
 → WAITING_FOR_ACCEPTANCE (direct offer sent)
 → BROADCASTING_REQUEST (broadcast sent)
   → DRIVER_ACCEPTED (acceptance received, auto-confirm fires)
     → RIDE_CONFIRMED (confirmation sent)
       → DRIVER_ARRIVED (driver status = arrived)
         → IN_PROGRESS (PIN verified, destination revealed)
           → COMPLETED (driver status = completed)
             → IDLE
```

Cancellation returns to IDLE from any stage.

### Driver State Machine

**Stages:**
```
OFFLINE
 → ROADFLARE_ONLY (accepts roadflare offers only)
 → AVAILABLE (accepts all offers)
   → RIDE_ACCEPTED (offer accepted)
     → EN_ROUTE_TO_PICKUP (confirmation received)
       → ARRIVED_AT_PICKUP (driver publishes arrived)
         → IN_RIDE (PIN verified)
           → RIDE_COMPLETED (ride finished, HTLC claimed)
             → OFFLINE (or previous availability state)
```

### Auto-Confirm Logic (Rider)

Triggered automatically when acceptance (Kind 3174) is received:

1. **CAS guard**: `confirmationInFlight.compareAndSet(false, true)` — ensures single confirmation
2. **PIN generation**: `String.format("%04d", Random.nextInt(10000))` — "0000" to "9999"
3. **Proximity check**: `pickup.isWithinMile(driverLocation)` (1.6 km)
4. **Location decision**: If RoadFlare OR driver within 1 mile → send precise pickup; otherwise approximate
5. **HTLC locking** (SAME_MINT only): `walletService.lockForRide(amount, hash, driverP2pkKey, expiry=900s, preimage)`
6. **Publish Kind 3175**: with paymentHash + escrowToken
7. **Subscribe to**: driver state (Kind 30180), chat (Kind 3178), cancellation (Kind 3179)

### PIN Verification Flow

1. **Driver enters PIN** at pickup → publishes Kind 30180 with PinSubmit action (PIN encrypted via NIP-44)
2. **Rider decrypts** and compares to local PIN
3. **If correct**:
   - Publish Kind 30181 PinVerify (verified=true)
   - Delay 1100ms (NIP-33 timestamp ordering)
   - Share preimage (Kind 30181 PreimageShare) OR execute bridge payment
   - Delay 1100ms
   - Reveal precise destination (Kind 30181 LocationReveal)
4. **If wrong**: Publish PinVerify (verified=false, attempt=N)
5. **MAX_PIN_ATTEMPTS = 3**: Auto-cancel on 3rd failure (brute force protection)

### Progressive Location Reveal

| Stage | Pickup Shared | Destination Shared |
|-------|--------------|-------------------|
| Offer | ~1km approximate (2-decimal lat/lon) | ~1km approximate |
| Confirmation | Precise if driver < 1 mile OR RoadFlare; otherwise approximate | Hidden |
| Driver < 1 mile | Precise (via Kind 30181 LocationReveal) | Hidden |
| PIN Verified | Precise | Precise (via Kind 30181 LocationReveal) |

### Event Deduplication

```kotlin
processedDriverStateEventIds: MutableSet<String>   // Rider side
processedCancellationEventIds: MutableSet<String>   // Both sides
```

Every event validates: `event.confirmationEventId == currentState.confirmationEventId`

### Subscription Lifecycle by Stage

**Rider:**
| Stage | Active Subscriptions |
|-------|---------------------|
| IDLE | Driver availability (Kind 30173) |
| WAITING | + Acceptance (Kind 3174), driver availability deletion (Kind 5) |
| BROADCASTING | + Acceptance (Kind 3174) |
| DRIVER_ACCEPTED+ | + Driver state (Kind 30180), chat (Kind 3178), cancellation (Kind 3179) |
| COMPLETED | All closed |

**Driver:**
| Stage | Active Subscriptions |
|-------|---------------------|
| OFFLINE | None |
| ROADFLARE_ONLY | RoadFlare offers (Kind 3173 + roadflare tag) |
| AVAILABLE | All offers (Kind 3173), broadcast requests, deletion (Kind 5) |
| RIDE_ACCEPTED | + Confirmation (Kind 3175) |
| EN_ROUTE+ | + Rider state (Kind 30181), chat (Kind 3178), cancellation (Kind 3179) |
| COMPLETED | All closed |

### Timeout Handling

- **Direct offer acceptance**: 15 seconds → show "Boost or keep waiting"
- **Broadcast acceptance**: 2 minutes → show "Boost or keep waiting"
- **Confirmation wait** (driver side): 30 seconds
- **PIN verification wait** (driver side): 30 seconds
- **Bridge payment poll**: every 30 seconds for up to 10 minutes

### NIP-09 Event Cleanup

After ride completion or cancellation, all ride events are deleted in background:
- Offers, acceptances, confirmations, state events, chat messages
- Non-blocking background job
- Prevents relay bloat

### Cancellation Safety

If `preimageShared || pinVerified`:
- Show warning dialog: "Driver may still claim payment"
- User must explicitly confirm cancellation
Otherwise: Cancel immediately

---

## 5. Payment System

### Architecture (5 layers)

1. **CashuBackend** (~2000 lines) — mint API operations
2. **CashuTokenCodec** — cashuA token encoding/decoding
3. **WalletService** (~1500 lines) — orchestration
4. **Nip60WalletSync** — cross-device proof sync via Nostr
5. **WalletStorage** — local encrypted persistence

### Key Separation

Two separate keypairs:
- **Identity key**: Signs Nostr events (public identity)
- **Wallet key**: Signs Cashu proofs for P2PK (payment operations)

WalletKeyManager also generates BIP-39 mnemonic for cdk-kotlin wallet seeding.

### HTLC Flow (NUT-14)

**Secret format:**
```json
["HTLC", {
  "nonce": "<random_hex>",
  "data": "<payment_hash_64hex>",
  "tags": [
    ["pubkeys", "<driver_wallet_pubkey>"],
    ["locktime", "<unix_timestamp>"],
    ["refund", "<rider_pubkey>"]
  ]
}]
```

**Claim witness format:**
```json
{
  "preimage": "<preimage_hex>",
  "signatures": ["<schnorr_sig_per_proof>"]
}
```

**Complete flow:**
1. Rider generates 32-byte preimage → SHA256 → paymentHash
2. Rider sends offer (Kind 3173) — **NO paymentHash yet** (deferred)
3. Driver accepts (Kind 3174) — includes `wallet_pubkey`
4. Rider locks HTLC: `lockForRide(amount, paymentHash, driverWalletPubKey, expiry=900s)`
5. Rider confirms (Kind 3175) — includes paymentHash + escrowToken
6. PIN verified → rider shares preimage via Kind 30181 (NIP-44 encrypted to driver)
7. Driver claims: signs each proof with wallet key Schnorr signature + preimage

### Proof State Verification (NUT-07)

Before any swap:
1. Call `/v1/checkstate` with Y values of proofs
2. SPENT → delete from NIP-60 + local, re-select proofs
3. PENDING → wait or skip
4. UNSPENT → proceed

### NIP-60 Wallet Sync

| Kind | Purpose |
|------|---------|
| 17375 | Wallet metadata (replaceable) |
| 7375 | Unspent proofs (encrypted to self) |
| 7376 | Spending history |

**Publish-before-delete invariant:** Always publish new proofs to NIP-60 BEFORE deleting old proofs locally.

### Payment Methods

```kotlin
enum PaymentMethod {
    CASHU("cashu", "Bitcoin (Cashu)"),
    LIGHTNING("lightning", "Lightning"),
    FIAT_CASH("fiat_cash", "Cash"),
    ZELLE("zelle", "Zelle"),
    PAYPAL("paypal", "PayPal"),
    CASH_APP("cash_app", "Cash App"),
    VENMO("venmo", "Venmo"),
    CASH("cash", "Cash"),
    STRIKE("strike", "Strike")
}
```

**Payment path determination:**
- SAME_MINT: Both use same Cashu mint → zero-fee HTLC swap
- CROSS_MINT: Different mints → Lightning bridge (HODL invoice)
- FIAT_CASH: Cash payment, no digital escrow
- NO_PAYMENT: Wallet not connected

**Method negotiation:** `findBestCommonFiatMethod(riderMethods, driverMethods)` — first common method wins.

### Fare Calculation

Source: RemoteConfigManager (Kind 30182 from admin pubkey)

**Defaults:**
- fareRateUsdPerMile: $0.50
- minimumFareUsd: $1.50
- roadflareFareRateUsdPerMile: $0.40
- roadflareMinimumFareUsd: $1.00

**RoadFlare DriverNetworkTab defaults (UI-level):**
- Base fare: $2.50
- Minimum fare: $5.00
- Rate: $1.50/mile
- Formula: max(BASE + (totalMiles × RATE), MINIMUM)

### Test Infrastructure (181 tests)

| Suite | Count | Coverage |
|-------|-------|---------|
| PaymentCryptoTest | 23 | Preimage/hash generation |
| CashuCryptoTest | 30 | hashToCurve, NUT-13, BIP-39 |
| CashuTokenCodecTest | 30 | Token encoding/decoding |
| HtlcResultTest | 23 | Sealed class exhaustiveness |
| CashuBackendErrorTest | 32 | Error mapping with FakeMintApi |
| FakeNip60StoreTest | 32 | Mock NIP-60 behavior |
| ProofConservationTest | 10 | Publish-before-delete invariant |

Test doubles: FakeMintApi (queued responses), FakeNip60Store (call log verification), CashuBackend.setTestState()

---

## 6. Data Models & Storage

### All Repositories

| Repository | Storage | Singleton |
|-----------|---------|-----------|
| VehicleRepository | SharedPrefs "ridestr_vehicles" | Yes |
| SavedLocationRepository | SharedPrefs "ridestr_saved_locations" | Yes |
| RideHistoryRepository | SharedPrefs "ridestr_ride_history" | Yes |
| FollowedDriversRepository | SharedPrefs "roadflare_followed_drivers" + in-memory locations | Yes |
| DriverRoadflareRepository | SharedPrefs "roadflare_driver_state" | Yes |

### Core Data Classes

**Vehicle:**
```kotlin
data class Vehicle(
    id: String = UUID, make: String, model: String, year: Int,
    color: String, licensePlate: String = "", isPrimary: Boolean = false
)
```

**SavedLocation:**
```kotlin
data class SavedLocation(
    id: String = UUID, lat: Double, lon: Double, displayName: String,
    addressLine: String, locality: String?, isPinned: Boolean = false,
    timestampMs: Long, nickname: String? = null
)
// MAX_RECENTS = 15, DUPLICATE_THRESHOLD_METERS = 50.0
```

**RideHistoryEntry:**
```kotlin
data class RideHistoryEntry(
    rideId: String, role: String, status: String, timestamp: Long,
    pickupGeohash: String,  // 6-char (~1.2km) for drivers
    dropoffGeohash: String,
    pickupLat/Lon: Double?,  // Exact coords for riders only
    pickupAddress: String?, dropoffAddress: String?,
    distanceMiles: Double, durationMinutes: Int, fareSats: Long,
    tipSats: Long = 0, paymentMethod: String = "cashu",
    counterpartyPubKey: String, counterpartyFirstName: String?,
    vehicleMake: String?, vehicleModel: String?,
    appOrigin: String  // "ridestr" or "drivestr"
)
// MAX_RIDES = 500, CLEAR_GRACE_PERIOD_MS = 30,000
```

**FollowedDriver:**
```kotlin
data class FollowedDriver(
    pubkey: String, addedAt: Long, note: String?,
    roadflareKey: RoadflareKey?  // null until driver approves
)
data class RoadflareKey(privateKey: String, publicKey: String, version: Int, keyUpdatedAt: Long)
```

**Location:**
```kotlin
data class Location(lat: Double, lon: Double, addressLabel: String?)
// approximate() → rounds to 2 decimals (~1km)
// distanceToKm(other) → Haversine formula
// isWithinMile(other) → < 1.6km
```

**Geohash precisions:**
- 3 chars: ~156km (state/province search)
- 4 chars: ~39km (regional, BASE PRECISION for search)
- 5 chars: ~4.9km (city, RIDE PRECISION)
- 6 chars: ~1.2km (history storage)
- 7 chars: ~153m (settlement verification)

### Backup Exclusions (backup_rules.xml)

All excluded from Android cloud backup (recoverable from Nostr):
- ridestr_secure_keys.xml, ridestr_wallet_keys.xml, ridestr_wallet_storage.xml
- ridestr_settings.xml, ridestr_ride_history.xml, ridestr_saved_locations.xml
- ridestr_vehicles.xml, roadflare_followed_drivers.xml, roadflare_driver_state.xml
- tile_discovery_cache.xml, profile_picture_prefs.xml, remote_config.xml

---

## 7. UI Screens & Navigation

### Navigation Pattern

All three apps use **conditional composable rendering** (no Jetpack Navigation):

```kotlin
when (authState) {
    LOGGED_OUT -> OnboardingScreen(...)
    PROFILE_INCOMPLETE -> ProfileSetupScreen(...)
    READY -> MainTabs(...)
}
```

### Rider App (rider-app) Screens

| Tab | Screen | Key Features |
|-----|--------|-------------|
| Ride | RiderModeScreen | Location search, fare estimate, driver list, active ride card, chat |
| RoadFlare | RoadflareTab | Followed drivers with status, add driver, stale key detection |
| Wallet | WalletScreen | Balance, diagnostics, deposit/withdraw |
| History | HistoryScreen | Stats summary, ride list, currency toggle |
| Settings | SettingsScreen | Currency, distance, notifications, relays, sync |

**RiderModeScreen** is the most complex (~38KB):
- IDLE: LocationSearchField with autocomplete, FareEstimateView, available drivers list
- WAITING: Ride info card with driver info
- ACTIVE: Status card adapting to stage, PIN display, chat button
- COMPLETED: Fare summary, tip option

### Driver App (drivestr) Screens

| Tab | Screen | Key Features |
|-----|--------|-------------|
| Drive | DriverModeScreen | Availability toggle, vehicle picker, offers list, active ride |
| RoadFlare | RoadflareTab | QR code card, follower management (approve/decline/mute) |
| Wallet | WalletScreen | Balance, earnings summary |
| Vehicles | VehiclesScreen | Add/edit/remove vehicles, primary selection |
| Settings | SettingsScreen | Same as rider |

### RoadFlare Rider App (roadflare-rider) Screens

| Tab | Screen | Key Features |
|-----|--------|-------------|
| Ride | RideTab | Location search, online drivers, fare estimate, "Send RoadFlare" |
| Drivers | DriverNetworkTab | Followed drivers with status, add by QR/npub |
| History | HistoryScreen | Same as rider |
| Settings | SettingsScreen | Same as rider |

**RideTab stages:**
IDLE → REQUESTING → CHOOSING_DRIVER → MATCHED → DRIVER_EN_ROUTE → DRIVER_ARRIVED → IN_RIDE → COMPLETED

### Shared UI Components (common module)

- **ChatView/ChatBottomSheet**: Message list, text input, sender differentiation
- **ActiveRideCard**: Generic ride status card with animated transitions
- **FareDisplay**: Clickable currency toggle (SATS ↔ USD)
- **LocationSearchField**: Autocomplete geocoding, saved locations
- **SlideToConfirm**: Gesture-based payment confirmation
- **SettingsComponents**: SettingsSwitchRow, SettingsNavigationRow, SettingsActionRow
- **ProfilePictureEditor**: Camera/gallery picker with crop
- **RideDetailScreen**: Full ride history detail view
- **KeySetupScreen/BackupReminderScreen**: Onboarding key management

### Android Services

| App | Service | Type | Purpose |
|-----|---------|------|---------|
| rider-app | RiderActiveService | location\|dataSync | Background ride monitoring |
| drivestr | DriverOnlineService | location\|dataSync | Background availability broadcasting |
| drivestr | RoadflareListenerService | dataSync | Listen for followers when offline |
| roadflare-rider | RiderActiveService | location\|dataSync | Background ride monitoring |

### Permissions (all apps)

INTERNET, ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION, FOREGROUND_SERVICE, FOREGROUND_SERVICE_LOCATION, FOREGROUND_SERVICE_DATA_SYNC, POST_NOTIFICATIONS, VIBRATE, REQUEST_IGNORE_BATTERY_OPTIMIZATIONS

---

## 8. Configuration & Settings

### SettingsManager

Storage: SharedPreferences "ridestr_settings"

**All settings (reactive StateFlows):**

| Category | Setting | Default |
|----------|---------|---------|
| Display | displayCurrency | USD |
| Display | distanceUnit | MILES |
| Notifications | notificationSoundEnabled | true |
| Notifications | notificationVibrationEnabled | true |
| Navigation | autoOpenNavigation | true |
| Location | useGpsForPickup | true |
| Vehicles | alwaysAskVehicle | true |
| Vehicles | activeVehicleId | null |
| Debug | useGeocodingSearch | true |
| Debug | useManualDriverLocation | false |
| Debug | manualDriverLat/Lon | 36.1699, -115.1398 (Las Vegas) |
| Onboarding | onboardingCompleted | false |
| Tiles | tilesSetupCompleted | false |
| Wallet | walletSetupCompleted | false |
| Wallet | walletSetupSkipped | false |
| Wallet | alwaysShowWalletDiagnostics | false |
| Payment | paymentMethods | ["cashu"] |
| Payment | defaultPaymentMethod | "cashu" |
| Payment | mintUrl | null |
| RoadFlare | roadflarePaymentMethods | [] |
| RoadFlare | ignoreFollowNotifications | false |
| RoadFlare | roadflareAlertsEnabled | true |
| Relays | customRelays | null (uses defaults) |
| Favorites | favoriteLnAddresses | [] |
| Driver | driverOnlineStatus | null |

**Relay limits:** Max 10 relays. Auto-prepend `wss://`.

### RemoteConfigManager

Source: Kind 30182 from hardcoded admin pubkey.

**AdminConfig defaults:**
```kotlin
fareRateUsdPerMile = 0.50
minimumFareUsd = 1.50
roadflareFareRateUsdPerMile = 0.40
roadflareMinimumFareUsd = 1.00
recommendedMints = [default mint list]
```

Fetch strategy: Await relay (10s) → subscribe Kind 30182 → EOSE (8s) → cache → fallback to cached/defaults.

---

## 9. Profile Sync & Backup

### ProfileSyncManager

**Sync priority order:**
1. Wallet (Kind 7375) — priority 0
2. Unified Profile (Kind 30177) — priority 1 (vehicles, locations, settings)
3. Ride History (Kind 30174) — priority 2

**Key methods:**
- `onKeyImported(includeWallet)` — connect + sync all FROM Nostr
- `backupAll()` — backup all syncables TO Nostr
- `clearAllData()` — clear all local data

**SyncableProfileData interface:** kind, dTag, syncOrder, fetchFromNostr(), publishToNostr(), clearLocalData()

### Backed Up Event Kinds

| Kind | d-tag | Content | Encryption |
|------|-------|---------|-----------|
| 30177 | "rideshare-profile" | Vehicles + saved locations + settings | NIP-44 to self |
| 30174 | "rideshare-history" | Ride history + stats | NIP-44 to self |
| 30011 | "roadflare-drivers" | Followed drivers + keys | NIP-44 to self (keys in content), p-tags public |
| 30012 | "roadflare-state" | Driver RoadFlare state | NIP-44 to self |

### LogoutManager — 16 Cleanup Operations

1. Stop relay connections
2. Clear identity key
3. Clear settings + StateFlows
4. Clear wallet storage + database
5. Clear wallet key
6. Clear RideHistoryRepository
7. Clear SavedLocationRepository
8. Clear VehicleRepository
9. Clear FollowedDriversRepository
10. Clear DriverRoadflareRepository
11. Clear ridestr_ride_state SharedPrefs
12. Clear drivestr_ride_state SharedPrefs
13. Clear tile discovery cache
14. Clear remote config cache
15. Clear profile picture metadata
16. Reset ProfileSyncManager singleton

---

## 10. Constants & Magic Numbers

### Timeouts
| Constant | Value | Context |
|----------|-------|---------|
| awaitConnected | 15,000ms | Relay connection |
| EOSE timeout (fetch) | 8,000ms | Data fetching |
| EOSE timeout (query) | 3,000-5,000ms | Quick queries |
| Reconnect delay | 5,000ms base, max 60,000ms | Exponential backoff |
| Direct offer acceptance | 15,000ms | Before "boost" prompt |
| Broadcast acceptance | 120,000ms | Before "boost" prompt |
| Confirmation wait | 30,000ms | Driver waits for rider |
| PIN verification wait | 30,000ms | Driver waits for rider |
| Bridge payment poll | 30,000ms interval, 10 min max | Cross-mint payment |
| Chat refresh | 15,000ms | Periodic subscription refresh |
| Stale driver cleanup | 30,000ms | Periodic cleanup |
| Availability broadcast | 300,000ms (5 min) | Driver app |
| RoadFlare broadcast | 120,000ms (2 min) | RoadFlare broadcast |
| RoadFlare min interval | 60,000ms (1 min) | Spam prevention |
| Stale subscription age | 1,800,000ms (30 min) | Auto-cleanup |

### Event Expirations
| Event | Expiry |
|-------|--------|
| Driver availability (30173) | 30 minutes |
| Ride offer (3173) | 15 minutes |
| Ride acceptance (3174) | 10 minutes |
| Ride confirmation (3175) | 8 hours |
| Driver/Rider state (30180/30181) | 8 hours |
| Chat (3178) | 8 hours |
| Cancellation (3179) | 24 hours |
| RoadFlare location (30014) | 5 minutes |
| Key share (3186) | 5 minutes |
| Key ack (3188) | 5 minutes |
| Shareable driver list (30013) | 30 days |

### Ride Constants
| Constant | Value |
|----------|-------|
| PIN format | 4 digits (0000-9999) |
| MAX_PIN_ATTEMPTS | 3 |
| HTLC expiry | 900 seconds (15 min) |
| Preimage length | 32 bytes (64 hex chars) |
| Progressive reveal threshold | 1.6 km (~1 mile) |
| Location approximate precision | 2 decimal places (~1km) |
| History geohash precision | 6 chars (~1.2km) |
| RoadFlare batch size | 3 drivers |
| RoadFlare batch delay | 15,000ms |
| Cross-mint fee buffer | 2% |
| Message channel capacity | 256 |
| Max relays | 10 |
| Max recent locations | 15 |
| Max ride history | 500 |
| Max favorite LN addresses | 10 |
| Clear grace period | 30,000ms |
| Duplicate location threshold | 50 meters |

### NIP-33 Ordering Delay
When publishing multiple rider state actions that must be ordered (e.g., PinVerify → PreimageShare → LocationReveal), a **1100ms delay** is inserted between publishes to ensure distinct `created_at` timestamps on the parameterized replaceable event (NIP-33).
