# RoadFlare iOS

Rider-side iOS client for [Ridestr](https://github.com/variablefate/ridestr), a decentralized rideshare protocol built on [Nostr](https://github.com/nostr-protocol/nostr). Pairs with the Ridestr Android driver app.

**iOS 17+ | Swift 6.0 | SwiftUI**

## Repo layout

- `RoadFlare/` — iOS app target (SwiftUI, persistence, platform glue).
- `RidestrSDK/` — protocol SDK Swift Package (Nostr events, state machines, cross-platform domain logic). Has its own [README](RidestrSDK/README.md).
- `RidestrUI/` — reusable SwiftUI components shared by app screens.
- `decisions/` — Architecture Decision Records. **Read before designing new public API, changing concurrency models, or shifting module boundaries.** Template at `decisions/0000-template.md`.
- `Branding/` — generated icon assets and app-store copy.

## Building

Open `RoadFlare/RoadFlare.xcodeproj` in Xcode 16+ and run the `RoadFlare` scheme. Or from the command line:

```bash
xcodebuild -project RoadFlare/RoadFlare.xcodeproj \
  -scheme RoadFlare \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

The SDK package builds standalone via `swift test` inside `RidestrSDK/`, but the canonical build is always the full Xcode project — SwiftPM-only tests miss concurrency errors that only surface in the app target.

## Contributing

Issues and PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the short version.

## Releasing

See [RELEASING.md](RELEASING.md) for the App Store release runbook.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability disclosure.

## License

MIT with a no-altcoin addendum. See [LICENSE](LICENSE).
