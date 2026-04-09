# ADR-0004: Migrate RideStatePersistence to SDK-based RideStateRepository

**Status:** Active
**Created:** 2026-04-09
**Tags:** refactor, sdk, architecture, persistence, repository-pattern

## Context

`RideStatePersistence` was an app-side struct that mixed iOS-specific storage (UserDefaults + JSON encoding) with domain logic that belongs in the SDK: stage-specific expiration windows, idle/completed stage filtering, legacy PIN timestamp migration, and protocol constants. This meant any Ridestr client would need to reimplement the "is this ride state still valid?" decision independently, creating divergence risk between platforms.

Additionally, `PasskeyManager` contained an inline Nostr key derivation formula (SHA-256 of symmetric key material to secp256k1 private key) that is protocol-level cryptography, not iOS platform logic.

## Decision

Follow the proven UserSettingsRepository pattern (ADR-0002):

- **`PersistedRideState`** (SDK): 28-field Codable struct defining the canonical persistence contract both platforms agree on.
- **`RideStateRepository`** (SDK): Owns all validation — expiration by stage (120s/30s/8h windows from `RideConstants`/`EventExpiration`), unknown/corrupt stage rejection, idle/completed filtering, and legacy `processedPinTimestamps` → `processedPinActionKeys` migration.
- **`RideStatePersistence`** (SDK protocol): Abstract storage interface — `saveRaw`/`loadRaw`/`clear`.
- **`RideStateRestorationPolicy`** (SDK): Stage-age expiration windows computed from protocol constants.
- **`InMemoryRideStatePersistence`** (SDK): Test double.
- **`UserDefaultsRideStatePersistence`** (app): Thin 27-line iOS implementation — pure storage, zero domain logic.
- **`NostrKeypair.deriveFromSymmetricKey()`** (SDK): Extracted from PasskeyManager so app developers don't need to understand SHA-256/secp256k1 internals.

`RideCoordinator` accepts a `RideStatePersistence` via init and constructs `RideStateRepository` internally, deriving the restoration policy from its `stageTimeouts` parameter. `AppState` owns the stored `UserDefaultsRideStatePersistence` handle directly for identity replacement safety (works when coordinator is nil during key generation/import).

## Rationale

The SDK is the single authority on "is this ride state valid for restoration?" — the same rule that drove ADR-0002. Expiration windows are protocol constants (offer visibility, confirmation timeout, ride confirmation expiry), not iOS-specific values. Legacy data format migration is protocol versioning. The app should never see expired, corrupt, or legacy-format data.

Key derivation belongs in the SDK because a developer building on Ridestr should be able to derive a Nostr keypair from key material without understanding the underlying cryptography.

## Alternatives Considered

- **Keep domain logic app-side, extract only the struct** — rejected because expiration windows are protocol semantics that Android must implement identically. Moving them to SDK codifies the contract.
- **Have AppState construct RideStateRepository and inject it into coordinator** — rejected because the coordinator's `stageTimeouts` parameter must influence the restoration policy, and only the coordinator knows its timeouts. The coordinator constructs the repo internally from the injected persistence.
- **Move key derivation to a standalone NostrPasskey package** — deferred because the `nostr-passkey` package exists but isn't production-ready (build issues, unverified tests — see nostr-passkey #1-3). The SDK provides a minimal utility now; the package can be adopted later.

## Consequences

- SDK-level tests cover all expiration/migration/validation logic without iOS dependencies (21 new tests).
- App tests use `InMemoryRideStatePersistence` instead of real UserDefaults for coordinator tests — faster, more isolated.
- `RideStatePersistence.save(session:...)` convenience method no longer exists; callers construct `PersistedRideState` explicitly. Tests use a `makePersistedState()` helper.
- Existing persisted data in UserDefaults is fully backward-compatible — same key, same JSON shape, same field names.
- Enables future Kotlin Multiplatform shared layer (#30) since the persistence contract is now SDK-defined.

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/Ride/PersistedRideState.swift` (NEW)
- `RidestrSDK/Sources/RidestrSDK/Ride/RideStateRepository.swift` (NEW)
- `RidestrSDK/Sources/RidestrSDK/Nostr/NostrKeypair.swift` (MODIFIED)
- `RidestrSDK/Tests/RidestrSDKTests/Ride/RideStateRepositoryTests.swift` (NEW)
- `RidestrSDK/Tests/RidestrSDKTests/Nostr/NostrKeypairTests.swift` (MODIFIED)
- `RoadFlare/RoadFlare/Services/RideStatePersistence.swift` (REWRITTEN)
- `RoadFlare/RoadFlare/ViewModels/RideCoordinator.swift` (MODIFIED)
- `RoadFlare/RoadFlare/ViewModels/AppState.swift` (MODIFIED)
- `RoadFlare/RoadFlare/Services/PasskeyManager.swift` (MODIFIED)
- `RoadFlare/RoadFlareTests/RoadFlareTests.swift` (MODIFIED)
- `RoadFlare/RoadFlareTests/RideCoordinatorTests.swift` (MODIFIED)
