# Contributing

Issues and pull requests are welcome.

## Before opening a PR

- See [README.md](README.md) for the build command.
- Build the full Xcode project (not just `swift test`) — concurrency errors only surface in the app target.
- For substantive changes (new public API, concurrency-model shifts, module boundary moves, anything touching >3 files), read the existing ADRs under `decisions/` first and consider whether your change warrants a new one. Template: `decisions/0000-template.md`.
- Keep commit messages focused on the **why** of the change, not just the what.

## Reporting issues

Open an issue describing the problem, what you expected, what happened, and the steps to reproduce. Logs or screenshots help.

## Security issues

Don't file public issues for vulnerabilities — see [SECURITY.md](SECURITY.md).
