# CLAUDE.md

Project-specific guidance for roadflare-ios. For GitNexus tool usage, see the root `CLAUDE.md` (gitignored, auto-generated).

## First-time setup

Run once per machine to install GitNexus MCP server, hooks, skills, and generate the root `CLAUDE.md` / `AGENTS.md`:

```bash
npx -y gitnexus@1.5.3 setup
npx -y gitnexus@1.5.3 analyze
```

The repo's `.githooks/post-commit` auto-reindexes after every terminal commit.

## Architecture Decision Records (ADRs)

ADRs live in `decisions/` at the repo root, numbered `NNNN-slug.md`. The template is `decisions/0000-template.md`.

**Read existing ADRs before:**
- Designing new public API surface (SDK or app)
- Changing concurrency/isolation models
- Shifting module boundaries (app ↔ SDK)
- Patterns that will touch >3 files

**Write a new ADR when** you make a decision a future reader would want justified — new public API, concurrency model change, module boundary shift, pattern touching >3 files. **Don't write one for:** bug fixes, internal single-file refactors, test additions, doc updates.

Keep ADRs focused: Context (what forced the decision) → Decision (what was chosen) → Rationale (why it beats alternatives) → Alternatives Considered → Consequences → Affected Files. Link the ADR in the PR description that implements it.

## Project Conventions

- **SDK vs app split:** Business rules with Nostr protocol semantics live in `RidestrSDK/`. iOS-specific persistence, UI, and platform glue live in `RoadFlare/`. Sync domain logic (publish + state machines + resolution) belongs in the SDK.
- **Build verification:** Always use `xcodebuild` on the full Xcode project, not just `swift test` in the SDK package. The SDK's SPM tests miss concurrency errors that only surface in the app target.
- **Concurrency:** SDK repos that need callbacks use `@unchecked Sendable` + `NSLock`. Publish state machines use atomic single-lock exits and a generation counter to invalidate crossed sessions after `clearAll()`.
