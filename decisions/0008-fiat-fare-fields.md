# ADR-0008: Fiat Fare Fields in Kind 3173 Ride Offer Events

**Status:** Accepted
**Date:** 2026-04-13

## Context

Ride offers (Kind 3173) encode the fare in satoshis (`fare_estimate`). The rider
converts USD → sats using their local BTC price at offer-creation time. The driver
receives the event later and converts sats → USD using their local BTC price at that
moment. BTC price movement between the two points causes visible display drift (e.g.,
rider offered $12.50, driver sees $12.38).

Additionally, `BitcoinPriceService.usdToSats()` uses `Int(sats)` to truncate the
result rather than rounding — causing the published sats amount to be systematically
low by up to 1 sat.

## Decision

1. Add two optional, flat-encoded JSON fields to Kind 3173 content:
   - `fare_fiat_amount`: decimal string (e.g., `"12.50"`)
   - `fare_fiat_currency`: ISO 4217 code (e.g., `"USD"`)

2. Model as a `FiatFare` struct in Swift. The struct is not `Codable` itself;
   `RideOfferContent` handles the flat encoding/decoding in custom `encode(to:)`
   and `init(from:)`. Both fields must be present or both absent — a partial pair
   decodes to `nil`.

3. For fiat rides, `fiatFare` is the authoritative source of truth for display.
   `fareEstimate` (sats) is retained for backward compatibility with older clients.

4. Fix truncation: `Int(sats)` → `Int(sats.rounded())` in `usdToSats()`.

5. `BitcoinPriceService` stays in the app layer. SDK consumers pick their own
   currency and conversion APIs.

## Rationale

**Flat JSON** avoids a nested-object schema change that would require a coordinated
Android migration. Optional top-level keys are ignored by older parsers.

**Mandatory pair (both or neither)** prevents partial state where `amount` exists
without `currency` (or vice versa), which would require defensive null-checks at
every display site.

**`FiatFare` struct** provides type safety at the Swift layer while keeping the
wire format flat. Alternatives (two separate `String?` properties on `RideOfferContent`)
lose the "always together" invariant.

**Sats retained** (`fareEstimate`) so older clients that don't parse `fiatFare`
continue to work. The drift for those clients is ≤1–2% at current BTC volatility
— acceptable backward-compat trade-off.

**App-layer `BitcoinPriceService`** because SDK consumers will want their own
currency (EUR, GBP) and price APIs (CoinGecko, Coinbase, self-hosted). The SDK
should not hardcode USD or any specific price service.

## Alternatives Considered

- **Nested `fiat_fare` object** `{ "amount": "12.50", "currency": "USD" }`:
  Rejected — requires Android to migrate their parser to handle a new key rather
  than two flat optional strings. Flat fields are backward-compat no-ops for older
  parsers.

- **Remove `fareEstimate` sats field**: Rejected — breaks older clients that only
  know sats.

- **SDK-layer conversion**: Rejected — SDK consumers want their own price API and
  currency preferences.

- **Leave `Int(sats)` truncation unfixed**: Rejected — systematic rounding-down
  means the published sats amount is always slightly less than the intended fare.

## Consequences

- SDK consumers that display fare for fiat rides MUST check `fiatFare` first before
  converting `fareEstimate` from sats. This is documented in `RideOfferContent`.
- Android must add parsing for the two optional fields in `RideOfferEvent.kt` and
  update `DriverModeScreen.kt` display logic (see issue #31 plan for guidance).
- Older iOS and Android clients silently display sats-converted USD (acceptable drift).

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/Models/RideModels.swift`
- `RoadFlare/RoadFlareCore/ViewModels/RideCoordinator.swift`
- `RoadFlare/RoadFlareCore/Services/BitcoinPriceService.swift`
- Android: `common/.../nostr/events/RideOfferEvent.kt` (guidance, not iOS scope)
- Android: `drivestr/.../ui/screens/DriverModeScreen.kt` (guidance, not iOS scope)
