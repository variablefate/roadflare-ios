# RideStatePersistence SDK Migration — Design Spec

## Purpose

Migrate ride state persistence domain logic from the iOS app layer to the SDK, following the proven UserSettingsRepository pattern. The SDK becomes the single authority on what constitutes valid persisted ride state, when state expires, and how legacy formats are normalized. The app retains only the iOS-specific UserDefaults storage implementation.

Additionally, extract the Nostr key derivation formula from PasskeyManager into the SDK as a protocol-level utility.

## Architecture

### What moves to SDK

**New SDK types (`RidestrSDK/Sources/RidestrSDK/Ride/`):**

1. **`PersistedRideState`** — The 24-field Codable struct defining the persistence contract. Moved from app's `RideStatePersistence`. This is the canonical shape that both platforms agree on.

2. **`RideStateRestorationPolicy`** — Stage-age expiration windows (was `RestorePolicy`). Defines how long each ride stage remains valid for restoration:
   - `waitingForAcceptance`: 120 seconds (offer visibility window)
   - `driverAccepted`: 30 seconds (confirmation timeout)
   - `postConfirmation`: 28,800 seconds (8 hours, ride confirmation expiry)
   
   Default policy computed from existing `RideConstants` and `EventExpiration` values already in SDK.

3. **`RideStatePersistence`** (protocol) — Abstract persistence interface:
   ```
   func saveRaw(_ state: PersistedRideState)
   func loadRaw() -> PersistedRideState?
   func clear()
   ```

4. **`RideStateRepository`** — SDK-owned class that wraps the protocol and owns all domain logic:
   - `save(_ state: PersistedRideState)` — delegates to `persistence.saveRaw()`
   - `load(policy:now:) -> PersistedRideState?` — calls `persistence.loadRaw()`, applies expiration check, rejects idle/completed, normalizes legacy fields, returns nil or validated state
   - `clear()` — delegates to `persistence.clear()`
   
   The SDK is the single authority on "is this state valid?". The app never sees expired or invalid data.

5. **`InMemoryRideStatePersistence`** — Test double (same pattern as `InMemoryUserSettingsPersistence`).

**Protocol constants that move:**
- `interopOfferVisibilitySeconds` (120) → co-located with `RideConstants`
- `interopConfirmationWaitSeconds` (30) → already references `RideConstants.confirmationTimeoutSeconds`
- Restore policy default → computed from `RideConstants` + `EventExpiration.rideConfirmationHours`

**Logic the SDK owns:**
- **Expiration decision**: `load()` returns nil for aged-out state. Stage-specific age windows applied inside the SDK's `RideStateRepository.load()`. The app never performs age arithmetic.
- **Stage filtering**: idle and completed stages rejected inside `load()`. These stages are never valid for restoration.
- **Legacy migration**: `processedPinTimestamps` (old format) → `processedPinActionKeys` (new format) normalization happens inside `load()`, transparent to the app. The conversion formula `"pin_submit:\(timestamp)"` moves to SDK.

**New SDK utility (`RidestrSDK/Sources/RidestrSDK/Nostr/`):**

6. **`NostrKeypair.deriveFromSymmetricKey(_:)`** — Static method on the existing `NostrKeypair` type. Extracts the 7-line key derivation formula from PasskeyManager: `SymmetricKey → SHA256 → hex → NostrKeypair`. This is Nostr protocol key derivation, not iOS platform logic.

### What stays in app

**`UserDefaultsRideStatePersistence`** — iOS implementation of the `RideStatePersistence` protocol:
- UserDefaults storage with JSON encoding/decoding
- Stores under key `"roadflare_active_ride_state"`
- Pure storage adapter — no domain logic, no expiration checks, no migration

**`RideCoordinator`** — Unchanged responsibility, updated types:
- `restoreRideState()` calls `rideStateRepository.load()` (was `RideStatePersistence.load()`)
- Still owns the orchestration: feeds loaded state into `session.restore()` AND populates UI properties
- `persistRideState()` constructs `PersistedRideState` from session + UI state, calls `rideStateRepository.save()`
- Receives `RideStateRepository` via init (injected, not static)

**`AppState`** — Calls `rideStateRepository.clear()` during identity replacement (was `RideStatePersistence.clear()`)

**`PasskeyManager`** — Keeps all WebAuthn/ASAuthorization infrastructure. Calls `NostrKeypair.deriveFromSymmetricKey()` instead of private `deriveNostrKey()`.

### Dependency flow

```
App Layer                          SDK Layer
─────────                          ─────────
UserDefaultsRideStatePersistence ──implements──> RideStatePersistence (protocol)
                                                        │
RideCoordinator ──uses──> RideStateRepository ──uses────┘
                                   │
                                   ├── load(): expiration + migration + validation
                                   ├── save(): delegates to persistence
                                   └── clear(): delegates to persistence

PasskeyManager ──calls──> NostrKeypair.deriveFromSymmetricKey()
```

## Data contract: PersistedRideState

24 fields, all Codable. This struct moves to SDK unchanged:

| Field | Type | Notes |
|-------|------|-------|
| stage | String | RiderStage raw value |
| offerEventId | String? | Kind 3173 event ID |
| acceptanceEventId | String? | Kind 3174 event ID |
| confirmationEventId | String? | Kind 3175 event ID |
| driverPubkey | String? | Driver hex pubkey |
| pin | String? | 4-digit PIN |
| pinVerified | Bool | |
| paymentMethodRaw | String? | Primary method |
| fiatPaymentMethodsRaw | [String] | Available methods |
| pickupLat, pickupLon, pickupAddress | Double?, Double?, String? | Pickup location |
| destLat, destLon, destAddress | Double?, Double?, String? | Destination location |
| fareUSD | String? | Decimal as string |
| fareDistanceMiles | Double? | |
| fareDurationMinutes | Double? | |
| savedAt | Int | Unix timestamp |
| processedPinActionKeys | [String]? | Dedup keys |
| processedPinTimestamps | [Int]? | Legacy (read-only, always written nil) |
| pinAttempts | Int? | |
| precisePickupShared | Bool? | |
| preciseDestinationShared | Bool? | |
| lastDriverStatus | String? | |
| lastDriverStateTimestamp | Int? | |
| lastDriverActionCount | Int? | |
| riderStateHistory | [RiderRideAction]? | |

## Expiration logic (SDK-owned)

```
func load(policy: RideStateRestorationPolicy = .default, now: Date = .now) -> PersistedRideState? {
    guard let raw = persistence.loadRaw() else { return nil }
    
    let age = Int(now.timeIntervalSince1970) - raw.savedAt
    let maxAge = policy.maxRestoreAge(for: raw.stage)
    
    guard age < maxAge else {
        persistence.clear()
        return nil
    }
    
    guard raw.stage != RiderStage.idle.rawValue,
          raw.stage != RiderStage.completed.rawValue else {
        persistence.clear()
        return nil
    }
    
    return raw.migrated()  // applies legacy field normalization
}
```

## Legacy migration (SDK-owned)

The `migrated()` method on `PersistedRideState` normalizes old formats:

```
func migrated() -> PersistedRideState {
    // Convert legacy processedPinTimestamps to processedPinActionKeys
    if processedPinActionKeys == nil, let timestamps = processedPinTimestamps {
        return copy(processedPinActionKeys: timestamps.map { "pin_submit:\($0)" })
    }
    return self
}
```

This runs inside `load()` so the app always receives normalized data.

## Key derivation (SDK-owned)

Move to `NostrKeypair`:

```swift
public static func deriveFromSymmetricKey(_ key: SymmetricKey) throws -> NostrKeypair {
    let rawBytes = key.withUnsafeBytes { Data($0) }
    let digest = SHA256.hash(data: rawBytes)
    let privateKeyHex = digest.compactMap { String(format: "%02x", $0) }.joined()
    return try NostrKeypair.fromHex(privateKeyHex)
}
```

PasskeyManager becomes: `return try NostrKeypair.deriveFromSymmetricKey(prfKey)`

## Test strategy

**SDK tests (new):**
- `RideStateRepositoryTests`:
  - Expiration by stage (waitingForAcceptance expires at 120s, driverAccepted at 30s, postConfirmation at 8h)
  - Idle/completed stage rejection
  - Legacy PIN timestamp migration
  - Round-trip through InMemoryRideStatePersistence
  - Custom policy overrides
  - Edge cases: exact boundary timestamps, nil raw data

- `NostrKeypairDerivationTests`:
  - Known-input → known-output for deriveFromSymmetricKey
  - Deterministic: same key → same keypair

**App tests (migrated):**
- `RideStatePersistenceTests` → renamed to `UserDefaultsRideStatePersistenceTests`
  - Still exercises UserDefaults round-trips
  - Uses real UserDefaults (not InMemory) — that's the point of app-level tests
  - Expiration tests move to SDK (they test domain logic, not UserDefaults)

- `RideCoordinatorTests` → updated to inject `InMemoryRideStatePersistence`
  - Existing tests preserved, just use injected persistence instead of static calls

## Files changed

| File | Change |
|------|--------|
| `RidestrSDK/.../Ride/PersistedRideState.swift` | NEW — Codable struct + migrated() |
| `RidestrSDK/.../Ride/RideStateRepository.swift` | NEW — Repository + protocol + InMemory + RestorationPolicy |
| `RidestrSDK/.../Nostr/NostrKeypair.swift` | MODIFY — Add deriveFromSymmetricKey() |
| `RidestrSDK/Tests/.../RideStateRepositoryTests.swift` | NEW — SDK-level expiration/migration tests |
| `RidestrSDK/Tests/.../NostrKeypairTests.swift` | MODIFY — Add derivation test |
| `RoadFlare/.../Services/RideStatePersistence.swift` | REWRITE — Thin UserDefaults wrapper implementing protocol |
| `RoadFlare/.../ViewModels/RideCoordinator.swift` | MODIFY — Use injected RideStateRepository |
| `RoadFlare/.../ViewModels/AppState.swift` | MODIFY — Create and inject RideStateRepository |
| `RoadFlare/.../Services/PasskeyManager.swift` | MODIFY — Call NostrKeypair.deriveFromSymmetricKey() |
| `RoadFlare/RoadFlareTests/RoadFlareTests.swift` | MODIFY — Migrate persistence tests |
| `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift` | MODIFY — Use injected persistence |

## Not in scope

- Changing the actual persisted data format (fields stay the same, just the code location changes)
- Changing the UserDefaults key (`"roadflare_active_ride_state"`)
- Bitcoin price conversion migration (deferred to #31)
- LocationCoordinator key sync extraction (#28)
- SyncCoordinator callback wiring (#29)
- Any Nostr event structure changes
