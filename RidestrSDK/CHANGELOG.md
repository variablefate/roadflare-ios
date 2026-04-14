# Changelog

All notable changes to RidestrSDK are documented here.

## [Unreleased]

### Added

- **`FiatFare` struct** — fiat-denominated fare (`amount: String`, `currency: String`), serializes flat to JSON as `fare_fiat_amount` + `fare_fiat_currency` (mandatory pair, ADR-0008)
- **`fiatFare: FiatFare?` on `RideOfferContent`** — authoritative display value for fiat rides; non-nil when `fiatPaymentMethods` is non-empty. Clients MUST prefer `fiatFare.amount` over converting `fareEstimate` (sats) to avoid display drift from BTC price movement

### Fixed

- **`BitcoinPriceService.usdToSats()`** — rounds to nearest satoshi (`Int(sats.rounded())`) instead of truncating (`Int(sats)`), eliminating systematic undercount of up to 1 sat

## [0.2.0] - 2026-03-19

### Added

#### State Machine
- **Formal transition table** (`RideTransition`, `RideTransitions`) with 14 rider-specific transitions
- **Typed events** (`RideEvent`) with associated values for all rider actions
- **Named guards** (`RideGuards`) with registry, evaluation, and diagnostic `explainFailure()`
- **Immutable context** (`RideContext`) with value-semantic `with*()` copy methods
- **`processEvent()`** as canonical entry point returning `TransitionResult`
- **`receiveDriverStateEvent()`** for AtoB pattern (driver is source of truth)
- **Timestamp-based deduplication** preventing state regression from out-of-order events
- **`.enRoute` stage** distinguishing "driver confirmed" from "driver on the way"
- **`StateMachineDelegate`** protocol for observing transitions
- **`canTransition(event:)`** for UI to query available actions

#### Error Handling
- **Nested error domains**: `.relay(...)`, `.crypto(...)`, `.ride(...)`, `.keychain(...)`, `.location(...)`, `.profile(...)`
- Backward-compatible deprecated factory methods for migration

#### Data Safety
- **Schema versioning** (`schemaVersion: Int?`) on `FollowedDriversContent`, `RideHistoryEntry`, `SavedLocation`
- **Expiration checks** on all event parsers (acceptance, driver state, chat, cancellation, key share)
- **Input validation** on all `RideshareEventBuilder` methods (pubkey format, event ID non-empty)
- Silent `?? "{}"` fallbacks replaced with proper error throwing

#### Observability
- **`RidestrLogger`** with injectable `@Sendable` handler and 4 log levels (debug, info, warning, error)
- State machine transition logging at debug level
- Relay error logging, retry attempt logging
- KeyManager diagnostic logging (distinguishes "no key" / "corrupted" / "parse failed")

#### Reliability
- **`publishWithRetry()`** protocol extension with exponential backoff (1s, 2s, 4s)
- **Thread-safe `FollowedDriversRepository`** with NSLock on all mutations and reads
- **Geohash precision clamping** (min 1, max 12) preventing unbounded computation
- **FareCalculator input validation** clamping negative/NaN/infinity to zero

#### Developer Experience
- **Type aliases**: `PublicKeyHex`, `EventID`, `ConfirmationEventID`
- **Protocol conformances**: `Equatable`/`Hashable`/`Codable` on `FareEstimate`, `RouteResult`, `GeocodingResult`, `Vehicle`, `RoadflareKey`, `FollowedDriver`, `RideHistoryEntry`, `SavedLocation`
- **`LocationConstants`**: Named constants for earth radius, km/miles conversion
- **Debug assertions** on coordinate bounds, fare config values
- **Mock implementations**: `HaversineRoutingService`, `StubGeocodingService`
- **`validatePubkey()`** public helper for input validation
- **Comprehensive doc comments** on `RelayManagerProtocol`, `RideStateMachine`, `RideshareEventBuilder`, `NostrFilter`
- **README.md** with Quick Start, architecture diagrams, state machine diagram
- **NIP19 hex validation**: `allSatisfy(\.isHexDigit)` before expensive parse

### Changed
- `RideStateMachine.init` now takes `riderPubkey: PublicKeyHex` parameter
- `RoadflareKey` equality compares by `publicKeyHex + version` only (excludes private key)
- `FollowedDriver` equality and hashing by `pubkey` (identity-based)
- `RideHistoryEntry` and `SavedLocation` hashing by `id`
- Version bumped from 0.1.0 to 0.2.0

### Deprecated
- `startRide()`, `handleAcceptance()`, `recordConfirmation()`, `handleDriverStateUpdate()`, `recordPinVerification()`, `handleCancellation()`, `transition(to:)` — use `processEvent()` / `receiveDriverStateEvent()` instead

### Removed
- Flat error factory methods (`RidestrError.invalidKey(...)`, `.relayNotConnected`, etc.) — all 58 call sites migrated to nested domains (`.crypto(.invalidKey(...))`, `.relay(.notConnected)`, etc.)

### Fixed
- `handleDriverStateUpdate()` bypassing `isValidTransition()` — now routed through formal AtoB pattern
- Context fields (`precisePickupShared`, `preciseDestinationShared`, `riderStateHistory`) diverging from context struct — consolidated as context projections
- `isPinBruteForce` guard relying on caller-provided attempt number — now uses `context.pinAttempts + 1`
- Force unwrap in `publishWithRetry` — replaced with safe `?? RidestrError.relay(.timeout)`

## [0.1.0] - 2026-03-17

### Added
- Initial SDK implementation
- Nostr relay management via rust-nostr
- NIP-44 encryption/decryption
- Event signing and verification
- Ride offer, acceptance, confirmation, cancellation builders
- Driver ride state parser (Kind 30180)
- Rider ride state builder (Kind 30181)
- Chat message builder/parser (Kind 3178)
- RoadFlare key share/ack (Kind 3186/3188)
- RoadFlare location parser (Kind 30014)
- Followed drivers list (Kind 30011)
- Geohash encoding/decoding
- Fare calculator with remote config
- Progressive reveal for pickup/destination
- Keychain storage for identity keys
- 449 tests across 35 suites
- Full Android interop verified via fixture tests
