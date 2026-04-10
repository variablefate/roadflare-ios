# ADR-0005: Extract App Logic into RoadFlareCore Framework for Non-Hosted Unit Tests

**Status:** Active
**Created:** 2026-04-09
**Tags:** architecture, module-boundary, testing, framework

## Context

`RoadFlareTests` is an app-hosted test bundle (`IsAppHostedTestBundle = true`).
All tested symbols (`AppState`, `RideCoordinator`, `AppLogger`, etc.) resolve through
the `RoadFlare.app` executable. Removing `TEST_HOST`/`BUNDLE_LOADER` causes link
failures because the symbols have no importable module.

This couples unit tests to the app's startup lifecycle even for pure service/VM tests,
requires a simulator app-host even for logic tests, and prevents running tests
independently of the app product.

## Decision

Create a new dynamic Xcode framework target `RoadFlareCore` that owns all
non-`@main` app logic: `Services/` and `ViewModels/`. The `RoadFlare` app embeds
and imports it. `RoadFlareTests` links it directly with no `TEST_HOST`.

## Rationale

A framework target is the lowest-friction solution: it integrates with the existing
Xcode project without a new `Package.swift`, naturally expresses the module boundary
the tests need, and keeps the existing file layout mostly intact (files move within
the same Xcode project, not across repository boundaries).

Keeping `Views/` in the app target avoids touching the entire UI layer for a
testability fix — the problematic symbols are all in `Services/` and `ViewModels/`.

## Alternatives Considered

- **Local Swift package for app logic** — Rejected for first pass: requires a new
  `Package.swift`, adds project complexity, and the move across package boundaries is
  higher friction. Valid future evolution but not the minimal fix.
- **Keep app-hosted testing, add startup guard** — Rejected: this is the status quo
  and the symptom the issue explicitly wants eliminated. Startup guards are band-aids
  that hide the real coupling.
- **Move only the directly-tested symbols** — Rejected: creates a partial module with
  unclear boundaries. Moving the entire `Services/` and `ViewModels/` layers gives a
  clean, understandable split.

## Consequences

- All types in `RoadFlareCore` used by the app must be `public`.
- `RoadFlare` app embeds `RoadFlareCore.framework`.
- `RoadFlareTests` no longer appears nested under `RoadFlare.app/PlugIns/`.
- `.xctestrun` for `RoadFlareTests` will no longer contain `IsAppHostedTestBundle = true`.
- Test fixtures and bundled resources used by RoadFlareTests must live in RoadFlareCore (or be loaded explicitly by path), not the RoadFlare app's Assets.xcassets, since the test bundle is no longer app-hosted.
- `Views/` still lives in the app target and uses `import RoadFlareCore`.
- Future addition: consider promoting `RoadFlareCore` to a local SPM package once
  the framework split is stable and the boundary is well-understood.

## Affected Files

- `RoadFlare/RoadFlare.xcodeproj/project.pbxproj`
- `RoadFlare/RoadFlare/Services/*.swift` (moved to `RoadFlare/RoadFlareCore/Services/`)
- `RoadFlare/RoadFlare/ViewModels/*.swift` (moved to `RoadFlare/RoadFlareCore/ViewModels/`)
- `RoadFlare/RoadFlare/RoadFlareApp.swift`
- `RoadFlare/RoadFlare/Views/**/*.swift` (import added)
- `RoadFlare/RoadFlareTests/*.swift`
- `scripts/pre-push-checks.sh`
