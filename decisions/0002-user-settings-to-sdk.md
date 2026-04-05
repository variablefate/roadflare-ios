# ADR-0002: Migrate UserSettings to SDK-based UserSettingsRepository

**Status:** Active
**Created:** 2026-04-04
**Tags:** refactor, sdk, architecture, sync, repository-pattern

## Context

`UserSettings` was the last of four RoadFlare sync domains still living app-side. The other three (`FollowedDrivers`, `RideHistory`, `SavedLocations`) already had SDK repositories. This asymmetry meant publish wrappers that read settings had to stay app-side, blocking the goal of "maximum SDK protocol surface for sync."

## Decision

Create `UserSettingsRepository` in `RidestrSDK/Sources/RidestrSDK/RoadFlare/` following the exact sibling repository pattern:

- `@Observable @unchecked Sendable` class with `NSLock`-protected state
- `@Sendable` callback properties
- Persistence delegate protocol + `InMemory` persistence for tests

Direct property writes (`settings.profileName = name`) become method calls (`setProfileName(_:allowEmpty:)`). Legacy `UserDefaults` key migration (`user_payment_methods` + `user_custom_payment_methods` → `user_roadflare_payment_methods`) moves to a new app-side `UserDefaultsUserSettingsPersistence`.

## Rationale

Completes the 4-repo SDK sync domain pattern. Business rules (empty-name guard, payment method normalization, custom-method dedup) move into SDK where any RoadFlare client gets them for free. Unblocks ADR-0003's full scope: with `UserSettings` in SDK, `publishProfile` and `publishProfileBackup` wrappers can also move to SDK.

## Alternatives Considered

- **Keep UserSettings app-side and duplicate business rules if Android ever implements them** — rejected because the rules are Nostr-protocol-specific (Kind 0 name semantics, Kind 30177 payment methods).
- **Make UserSettingsRepository iOS-specific and not move it to SDK** — rejected because the point of the SDK is cross-platform protocol logic.
- **Split UserSettings into multiple repos (ProfileRepository + PaymentPreferencesRepository)** — rejected because the two are always synced together via Kind 0 + Kind 30177 and sharing a single snapshot + persistence lock is simpler.

## Consequences

- View layer must use method calls instead of property assignment (`settings.setProfileName` vs `settings.profileName =`).
- `@Bindable var settings: UserSettings` in `PaymentSetupView` became `let settings: UserSettingsRepository` (verified no `$settings.X` projections existed).
- Legacy `UserDefaults` migration keyed to iOS-specific keys stays in app-layer persistence — SDK repo sees only the unified snapshot type.
- Enables `SyncCoordinator.publishProfile` and `SyncCoordinator.publishProfileBackup` to move to SDK in a follow-up refactor (ADR-0003).

## Affected Files

- `RidestrSDK/Sources/RidestrSDK/RoadFlare/UserSettingsRepository.swift`
- `RoadFlare/RoadFlare/Services/UserDefaultsUserSettingsPersistence.swift`
- `RoadFlare/RoadFlare/ViewModels/AppState.swift`
- `RoadFlare/RoadFlare/ViewModels/SyncCoordinator.swift`
- `RoadFlare/RoadFlare/Views/Onboarding/PaymentSetupView.swift`
- `RoadFlare/RoadFlare/Views/Settings/SettingsTab.swift`
