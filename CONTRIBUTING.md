# Contributing

Issues and pull requests are welcome.

## Before opening a PR

- See [README.md](README.md) for the build command.
- Build the full Xcode project (not just `swift test`) — concurrency errors only surface in the app target.
- For substantive changes (new public API, concurrency-model shifts, module boundary moves, anything touching >3 files), read the existing ADRs under `decisions/` first and consider whether your change warrants a new one. Template: `decisions/0000-template.md`.
- Keep commit messages focused on the **why** of the change, not just the what.

## Reporting issues

Open an issue describing the problem, what you expected, what happened, and the steps to reproduce. Logs or screenshots help.

## Code signing for local builds

`RoadFlare.xcodeproj` commits a `DEVELOPMENT_TEAM` value — that's the maintainer's Apple Developer Team ID, not a secret (every signed iOS binary exposes it). For your own local builds you have two options:

- **GUI path:** open Xcode → select the `RoadFlare` target → Signing & Capabilities → set Team to your account. Xcode will rewrite `project.pbxproj` with your Team ID. Don't commit that change.
- **xcconfig path (recommended for forks):** create an untracked `Local.xcconfig` next to the project with `DEVELOPMENT_TEAM = YOURTEAMID`, then set the project's base configuration to that file in Xcode's Info tab. This keeps your team ID out of `project.pbxproj` entirely.

## Security issues

Don't file public issues for vulnerabilities — see [SECURITY.md](SECURITY.md).
