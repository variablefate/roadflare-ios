# ADR-0012: `roadflared:` Custom URL Scheme for Driver Deep Links

**Status:** Active
**Created:** 2026-04-27
**Tags:** architecture, app-routing, deep-link

## Context

RoadFlare 1.0 shipped on the App Store on 2026-04-20. The marketing site at
`roadflare.app` serves driver share pages at `/share/d/<npub>` with a "Add
to RoadFlare" CTA. Until this work landed, that button used `nostr:<npub>`,
which the iOS app did not register as a URL handler — tapping the button
either errored in Safari or dispatched to an unrelated Nostr client.

We need a way for share-link recipients to tap a button on
`roadflare.app/share/d/<npub>` and land directly in the Add Driver flow with
the npub and display name pre-filled. Universal Links
(`https://roadflare.app/share/...`) are the long-term solution and are
tracked in [#63](https://github.com/variablefate/roadflare-ios/issues/63),
but require an Associated Domains entitlement, AASA `applinks` updates, and
out-of-band testing — too much for the immediate ship.

A custom URL scheme is enough today: simpler to register, no domain wiring,
and explicit about which app a link is targeting.

## Decision

Register `roadflared:` as a custom URL scheme handled by RoadFlare iOS.
The shape is opaque-URI style mirroring the existing `nostr:` URI the parser
already accepts:

```
roadflared:<npub>[?name=<URL-encoded display name>]
```

Routing pattern: **app-level `.onOpenURL` → `AppState` intent property →
view observation**.

1. `RoadFlareApp` attaches `.onOpenURL { url in appState.handleIncomingURL(url) }`
   to the root scene.
2. `AppState.handleIncomingURL(_:)` parses the URL via the existing
   `DriverQRCodeParser`, populates `pendingDriverDeepLink`, and switches
   `selectedTab = 1` (drivers tab).
3. `DriversTab` observes `appState.pendingDriverDeepLink` via `.onChange` and
   on first `.task`, captures the value into local state, and presents
   `AddDriverSheet(prefill:)` with the parsed payload. On dismiss, both
   `pendingDriverDeepLink` and the local prefill are cleared.
4. `AddDriverSheet` accepts an optional `prefill: ParsedDriverQRCode?` init
   param; when set, it seeds `lookupDraft` and auto-triggers profile lookup
   on first `.task`, skipping the scan/paste step.

Two-app partitioning: `roadflared:` is for the rider app (this app);
`roadflarer:` is reserved for a future iOS driver app. The rider app
deliberately does NOT register `roadflarer:`, so rider-share URLs from
`roadflare.app/share/r/<npub>` will route to a future driver app once one
exists. This keeps the deep-link surfaces partitioned by recipient app
without any in-app switching logic.

## Rationale

- **`AppState` ownership of the intent** matches the existing pattern for
  `requestRideDriverPubkey` / `selectedTab`: external triggers write to
  `AppState`, the relevant tab observes and presents. Consistent with
  ADR-0011's "AppState as single facade for view data."
- **`pendingDriverDeepLink` as state, not a one-shot callback** survives
  cold-start: `.onOpenURL` can fire before `DriversTab` has even mounted.
  The state-based model lets the view consume the intent on first `.task`
  whenever it does mount, regardless of timing.
- **Reuse `DriverQRCodeParser`** rather than introducing a parallel parser:
  the input shape (`<scheme>:<npub>?name=...`) is identical to `nostr:`,
  and the parser was already structured around opaque-URI style. Adding a
  `parseRoadflaredURI` arm is one new private function.
- **Custom scheme over Universal Links — for now** because the fallback UX
  diverges:
  - Custom scheme installed → opens the app; not installed → "Safari cannot
    open" error.
  - Universal Links installed → opens the app; not installed → falls back to
    the share page itself, which already has the App Store button.
  Universal Links are strictly better long-term, but require Associated
  Domains entitlement + AASA changes + test-on-real-device cycles that are
  out of scope for this release. Tracked in [#63](https://github.com/variablefate/roadflare-ios/issues/63).
- **Two schemes, not one with a path** (`roadflared:` for driver,
  `roadflarer:` for rider) so that when a driver app exists, each app
  registers its own scheme without coordinating which one handles a given
  URL. The OS dispatches by scheme.

## Alternatives Considered

- **Universal Links only** — rejected for this release: requires AASA
  changes on the site, Associated Domains entitlement on the app, and
  real-device test cycles. Tracked in #63 as the long-term path.
- **`roadflare:` single scheme with path-based driver-vs-rider routing**
  (e.g. `roadflare://d/<npub>`) — rejected: when a future driver app
  launches, both apps would claim the same scheme and the OS would
  arbitrarily pick one. Two schemes avoid this entirely.
- **Pass `prefill` via a new `AppState` setter, not an init param** —
  rejected: `AddDriverSheet` already uses `lookupDraft` as its input model;
  threading the prefill through the same model via init is consistent with
  how `DriverShareSheet(pubkey:driverName:pictureURL:)` is constructed.
- **Drop the URL scheme on the floor when `authState != .ready`** — not done:
  the intent is held in `AppState` for the duration of the session. If the
  user is in onboarding when a `roadflared:` URL arrives, the intent
  persists and `DriversTab.task` will consume it the first time the user
  reaches the main tab view post-onboarding. This is desirable — losing the
  deep link silently after onboarding would be a bad UX.

## Consequences

- **Site PR [variablefate/roadflare-site#4](https://github.com/variablefate/roadflare-site/pull/4)**
  unblocks once an App Store build with this code ships. Merging that PR
  restores the "Add to RoadFlare" button on driver share pages, pointing to
  `roadflared:<npub>?name=...`.
- **Future Drivestr / driver app** can register `roadflarer:` independently
  and merge the matching site PR
  ([variablefate/roadflare-site#5](https://github.com/variablefate/roadflare-site/pull/5))
  with no coordination needed against this app.
- **`AddDriverSheet`'s `init()` zero-arg call site is preserved** — the
  prefill param has a default of `nil`. Existing call site in `DriversTab`
  (the "Add New Driver" button) keeps working unchanged.
- **`DriverQRCodeParser` now documents `roadflared:`** as a first-class
  accepted input. The parser is also still safe to use on QR-scanned strings
  (which use `nostr:` per NIP-21) — the new arm is checked before the
  existing `nostr:` arm but both have explicit prefix gates.
- **Universal Links migration (#63) becomes mostly additive**: the
  `roadflared:` flow can stay as the in-app-only scheme, and Universal Links
  via `https://roadflare.app/share/...` would route through the same
  `AppState.handleIncomingURL` (the parser already handles
  `https://roadflare.app/share/d/<npub>` strings).

## Affected Files

- `RoadFlare/RoadFlare/Info.plist` — `CFBundleURLTypes` entry for `roadflared`
- `RoadFlare/RoadFlareCore/Services/DriverQRCodeParser.swift` — `parseRoadflaredURI` arm + doc comment
- `RoadFlare/RoadFlareTests/DriverQRCodeParserTests.swift` — `roadflared:` test cases
- `RoadFlare/RoadFlareCore/ViewModels/AppState.swift` — `pendingDriverDeepLink`, `handleIncomingURL(_:)`
- `RoadFlare/RoadFlareTests/AppState/HandleIncomingURLTests.swift` — `handleIncomingURL` tests
- `RoadFlare/RoadFlare/RoadFlareApp.swift` — `.onOpenURL` modifier
- `RoadFlare/RoadFlare/Views/Drivers/DriversTab.swift` — `pendingDriverDeepLink` observer + sheet wiring
- `RoadFlare/RoadFlare/Views/Drivers/AddDriverSheet.swift` — `prefill:` init param + auto-resolve `.task`
