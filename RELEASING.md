# Releasing roadflare-ios

This file is the canonical release runbook for this repo. It's written so a Claude Code session can pick it up cold and execute correctly — the human operator should not need to memorize commands.

**Default workflow:** ask Claude to do it. Manual commands are kept here as a fallback for when Claude isn't around or when something goes sideways.

## The two version numbers

- **`MARKETING_VERSION`** — what users see on the App Store (e.g. `1.0.1`). Bump only when starting a new public release. Lives in `RoadFlare/RoadFlare.xcodeproj/project.pbxproj` (8 occurrences across Debug/Release × app/test targets).
- **`CURRENT_PROJECT_VERSION`** — Apple's per-upload integer. Must be unique and monotonically increasing for every upload to App Store Connect (TestFlight included). Bump immediately before each archive.

Tagging convention: `v<marketing>-build<number>`, e.g. `v1.0.1-build3`. Tag the commit *after* a successful App Store Connect upload so the tag points at the exact code that was uploaded.

## Pre-archive checklist (read this before clicking Archive)

The build number bump must be a **committed and pushed** change on `main` before you archive. Bumping it in Xcode's UI at archive time and clicking Archive is the failure mode that left 1.0.2 untagged for weeks — the local edit never made it into git, so there was no SHA whose tree matched the shipped build.

Run these three commands from the repo root before archiving. If any of them fail the assertion, **stop and fix it** before archiving:

```bash
# 1. No uncommitted changes (especially to project.pbxproj).
git status --porcelain     # must print nothing

# 2. Your local main is in sync with origin/main (bump is pushed).
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" && echo OK

# 3. The committed build number is what you intend to ship.
git show HEAD:RoadFlare/RoadFlare.xcodeproj/project.pbxproj \
  | grep -m1 CURRENT_PROJECT_VERSION
```

If `git status` shows `project.pbxproj` modified, you bumped via Xcode's Identity panel without committing — that's the 1.0.2 mistake. Commit it (`chore(release): build N`), push, then archive.

## Ask-Claude prompt templates

Copy-paste these. They contain everything Claude needs.

### When starting a new release cycle (bumping marketing version)

> Claude, please bump the marketing version from X.Y.Z to A.B.C and commit. Read RELEASING.md first.

(Replace `X.Y.Z` with current, `A.B.C` with target. Semver: bump patch for bugfixes-only, minor for features, major for breaking changes.)

### When ready to archive and ship

> Claude, I'm about to archive in Xcode for App Store upload. Please:
> 1. Read RELEASING.md.
> 2. Find the highest existing build number across this repo and App Store Connect (I'll tell you what App Store Connect shows if you can't infer it from the repo) and pick the next integer above that.
> 3. Bump CURRENT_PROJECT_VERSION in `project.pbxproj` to that number across all 8 occurrences.
> 4. Commit on a clean main with message `chore(release): build N` and **push** to `origin/main`. The bump must be on origin before I archive.
> 5. Run the pre-archive checklist commands and confirm all three pass.
> 6. Tell me the exact `git tag` command to run *after* I confirm the upload to App Store Connect succeeded.

(Tag-after-upload, not tag-before-upload, so a failed upload doesn't leave a stale tag pointing at code that never shipped. But the bump-commit itself **must** be pushed before archive, not after — otherwise the shipped tree won't match any SHA in the repo.)

### When you've confirmed an upload succeeded

> Claude, App Store Connect accepted build N for version A.B.C uploaded at <timestamp>. Please tag the commit and push the tag.

Claude tags `v<A.B.C>-build<N>` at the commit that was just uploaded (current `HEAD` of `main` if no other commits have landed) and pushes the tag to `origin`.

### When you want to know "is fix X in production?"

> Claude, is commit `<sha>` (or PR #<num>) in the current production App Store build? Use the latest `v*-build*` tag as the production reference.

Claude runs `git tag --contains <sha>` and `git log --oneline <latest-tag>..main` to give a clear before/after answer.

## Manual fallback commands

In case Claude isn't around. Run from repo root.

### Bump marketing version

```bash
# Replace 1.0 with the current version, 1.0.1 with the target
sed -i '' 's/MARKETING_VERSION = 1.0;/MARKETING_VERSION = 1.0.1;/g' \
  RoadFlare/RoadFlare.xcodeproj/project.pbxproj
git add RoadFlare/RoadFlare.xcodeproj/project.pbxproj
git commit -m "chore(release): bump marketing version to 1.0.1"
```

### Bump build number (right before archive)

```bash
# Replace 3 with the current build number, 4 with the next, 1.0.2 with the current marketing version
sed -i '' 's/CURRENT_PROJECT_VERSION = 3;/CURRENT_PROJECT_VERSION = 4;/g' \
  RoadFlare/RoadFlare.xcodeproj/project.pbxproj
git add RoadFlare/RoadFlare.xcodeproj/project.pbxproj
git commit -m "chore(release): build 4 for 1.0.2"
git push origin main
```

### Tag a successful upload

```bash
# Run after App Store Connect confirms the upload was accepted.
# Use an annotated tag (-a -m) so the tag carries its own metadata.
git tag -a v1.0.2-build4 -m "Release 1.0.2 build 4"
git push origin v1.0.2-build4
```

## Anchoring history

Retroactive anchors that exist today (only create new retroactive tags if you also commit a backfill of the matching pbxproj state — the tag must point at a tree whose `CURRENT_PROJECT_VERSION` matches the shipped build):

- `v1.0.1-build2` — points at the `chore(release): build 2 for 1.0.1` commit.
- `v1.0.2-build3` — points at the `chore(release): build 3 for 1.0.2 (retroactive)` commit. The bump was applied locally at archive time and never committed; #74 backfilled the commit so the tag has a tree to point at.

The 1.0 build 1 ship (App Store upload at 2026-04-16 20:25 PT) was never tagged and is not worth anchoring now — its bump was `CURRENT_PROJECT_VERSION = 1`, which is the same value the repo had at HEAD at the time, so any nearby commit's tree matches. Use `git log --before=2026-04-16T20:25 main --oneline | head -1` if you ever need the closest SHA.

## Current versioning state

- **Latest App Store release:** `1.0.2` build `3` — tagged `v1.0.2-build3`.
- **Latest TestFlight upload:** same.
- **`MARKETING_VERSION` on `main`:** `1.0.2`.
- **`CURRENT_PROJECT_VERSION` on `main`:** `3`.
- **Next upload:** bump `CURRENT_PROJECT_VERSION` to `4` minimum. Bump `MARKETING_VERSION` only if starting a new public release cycle. Run the pre-archive checklist before clicking Archive.

## Why this file exists

See [#74](https://github.com/variablefate/roadflare-ios/issues/74). Without versioning + tagging discipline, "is fix X in production?" cannot be answered from the repo alone — every diagnostic loop requires cross-referencing App Store Connect timestamps. With this discipline in place, the answer is one `git` command.
