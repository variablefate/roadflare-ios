# Releasing roadflare-ios

This file is the canonical release runbook for this repo. It's written so a Claude Code session can pick it up cold and execute correctly — the human operator should not need to memorize commands.

**Default workflow:** ask Claude to do it. Manual commands are kept here as a fallback for when Claude isn't around or when something goes sideways.

## The two version numbers

- **`MARKETING_VERSION`** — what users see on the App Store (e.g. `1.0.1`). Bump only when starting a new public release. Lives in `RoadFlare/RoadFlare.xcodeproj/project.pbxproj` (8 occurrences across Debug/Release × app/test targets).
- **`CURRENT_PROJECT_VERSION`** — Apple's per-upload integer. Must be unique and monotonically increasing for every upload to App Store Connect (TestFlight included). Bump immediately before each archive.

Tagging convention: `v<marketing>-build<number>`, e.g. `v1.0.1-build3`. Tag the commit *after* a successful App Store Connect upload so the tag points at the exact code that was uploaded.

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
> 4. Commit on a clean main with message `chore(release): build N`.
> 5. Tell me the exact `git tag` command to run *after* I confirm the upload to App Store Connect succeeded.

(Tag-after-upload, not tag-before-upload, so a failed upload doesn't leave a stale tag pointing at code that never shipped.)

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
# Replace 1 with the current build number, 2 with the next
sed -i '' 's/CURRENT_PROJECT_VERSION = 1;/CURRENT_PROJECT_VERSION = 2;/g' \
  RoadFlare/RoadFlare.xcodeproj/project.pbxproj
git add RoadFlare/RoadFlare.xcodeproj/project.pbxproj
git commit -m "chore(release): build 2"
git push origin main
```

### Tag a successful upload

```bash
# Run after App Store Connect confirms the upload was accepted
git tag v1.0.1-build2
git push origin v1.0.1-build2
```

## Anchoring history (one-time, for current production build)

The build that uploaded to App Store Connect at **2026-04-16 20:25 PT** has not been tagged. To anchor it retroactively (find the most plausible commit ancestor, likely `8b591b7` or a slightly later commit on `main`):

```bash
# List candidate commits around the upload time
git log --before="2026-04-16T20:25:00-07:00" --after="2026-04-16T13:00:00-07:00" --oneline

# Pick the most likely sha and tag it
git tag v1.0-build1 <sha>
git push origin v1.0-build1
```

This is a one-time anchor — once tagged, future "what's shipped vs what's pending" queries work cleanly via `git log v1.0-build1..main`.

## Versioning state at the time this file was written

- Most recent App Store upload: **2026-04-16 20:25 PT**
- That upload's build settings: `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`
- **Current marketing version on `main`: `1.0.1`** (bumped in this commit; reflects the next-shipping release, not the live App Store version)
- Current build number on `main`: still `1` — bump immediately before next archive (next number is at minimum `2`; cross-check App Store Connect for any TestFlight uploads that may have occupied higher numbers)
- No git tags exist yet. The "anchoring history" step above creates the first one.

## Why this file exists

See [#74](https://github.com/variablefate/roadflare-ios/issues/74). Without versioning + tagging discipline, "is fix X in production?" cannot be answered from the repo alone — every diagnostic loop requires cross-referencing App Store Connect timestamps. With this discipline in place, the answer is one `git` command.
