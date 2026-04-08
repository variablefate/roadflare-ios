# Churn Hotspots Skill — Design Spec

## Purpose

A Claude Code skill that combines git churn statistics with GitNexus graph impact data to produce a ranked list of refactor targets. Surfaces files that are both frequently overhauled (high churn) and widely depended on (high impact) — god objects and architectural bottlenecks.

Replaces the two-step workflow of running churn analysis then manually querying GitNexus impact. One command, one ranked list.

## Invocation

**Skill name:** `churn-hotspots`

**Slash command:** `/churn-hotspots` or `/churn-hotspots RidestrSDK/`

**Auto-trigger phrases:**
- "What should I refactor next?"
- "Find hotspots"
- "Show me churn"
- "What files are most painful?"
- "Where should I focus refactoring?"
- "Find refactor targets"

## Output

**Summary (always shown):**

A ranked table printed to the terminal:

```
Rank  File                          Churn   Impact  Hotspot  
────  ────────────────────────────  ──────  ──────  ───────  
  1   Views/Ride/RideTab.swift       1480     47    69,560   
  2   Services/RideCoordinator.swift   820     31    25,420   
  3   Models/RiderSession.swift        540     22    11,880   
  ...
```

Plus a one-line recommendation for the #1 target.

**Detailed report (on request):**

For each top file, print:
- Churn breakdown: N commits, avg M lines/commit over the window
- Impact breakdown: X direct callers, Y d2 dependents, Z execution flows
- Co-change partners: files that frequently change alongside this one
- Suggested action: extract, decompose, or stabilize interface

## Scoring

### Churn Score (per file)

Computed from `git log --numstat` over the last N commits (default: 100).

```
churn_score = commit_count * avg_lines_changed_per_commit
```

Where `avg_lines_changed_per_commit` = total lines added+deleted across all commits / commit_count.

This adapts to development pace — during slow periods, the commit window stretches back further in time. During sprints, it captures the recent burst. A file with 15 commits averaging 40 lines each (score: 600) outranks one with 15 commits averaging 3 lines each (score: 45).

### Impact Score (per file)

Computed from GitNexus graph queries on the file's exported symbols.

```
impact_score = (direct_callers * 3) + (d2_dependents * 1) + (process_count * 2)
```

- **direct_callers (d=1, weight 3):** Symbols that directly call/import from this file. These WILL break on interface changes. Weighted highest.
- **d2_dependents (d=2, weight 1):** Symbols two hops away. LIKELY affected. Lower weight because the dependency is indirect.
- **process_count (weight 2):** Number of GitNexus execution flows this file participates in. Captures cross-cutting importance that caller count alone misses.

For files with multiple exported symbols, aggregate across all symbols (deduplicated).

### Combined Hotspot Score

```
hotspot_score = churn_score * impact_score
```

Multiplication ensures both signals must be high. A frequently-changed leaf file (high churn, zero impact) scores 0. A highly-connected stable file (zero churn, high impact) scores 0. Only files that are both painful AND risky surface.

## Workflow

### Step 1: Git Churn Analysis

Run `git log --numstat -N` (where N = commit window) and aggregate per-file:
- Count of commits touching the file
- Total lines added + deleted
- Compute `avg_lines_changed_per_commit`
- Compute `churn_score`

Filter out:
- Test files (`*Tests*`, `*Test*`, `*Spec*`)
- Generated files (`.gitnexus/`, `.build/`, `DerivedData/`)
- Config/metadata (`*.json`, `*.plist`, `*.xcodeproj/**`, `*.md`)
- Files that no longer exist on the current branch

Sort by churn_score descending. Take top 20 for impact analysis (querying every file would be slow).

### Step 2: GitNexus Impact Analysis

For each of the top 20 churn files, query GitNexus:

1. Use `gitnexus_impact({target: "<filename>", direction: "upstream"})` to get direct callers and d2 dependents.
2. Use `gitnexus_context({name: "<primary symbol>"})` for process participation count.
3. Aggregate across all symbols exported by the file (deduplicate callers).

Compute `impact_score` per file.

### Step 3: Combine and Rank

Compute `hotspot_score = churn_score * impact_score` for each file. Sort descending. Present top N results (default: 10).

### Step 4: Present Results

Print the summary table. For the #1 target, print a one-line recommendation based on the score profile:
- High churn + high callers → "Consider extracting focused components to reduce change surface"
- High churn + high process count → "This file is a cross-cutting concern — consider stabilizing its interface"
- High churn + mixed → "Review for single-responsibility violations"

If the user requests detail, print the full breakdown for each ranked file.

## Parameters

| Parameter | Default | Override | Description |
|-----------|---------|----------|-------------|
| Commit window | 100 | first positional arg or `commits:50` | Number of recent commits to analyze |
| Directory filter | whole repo | path argument, e.g., `/churn-hotspots RidestrSDK/` | Scope analysis to a subdirectory |
| Top N | 10 | `top:20` | Number of results to show |

## File Structure

```
~/.claude/skills/churn-hotspots/
├── SKILL.md              (~1,500 words) — Trigger metadata, workflow, output format
└── references/
    └── scoring.md        (~500 words) — Detailed scoring formula, weight rationale, tuning guide
```

No scripts needed — the skill orchestrates git commands and GitNexus MCP tools directly.

## Edge Cases

- **Empty churn window:** If fewer than 5 commits exist in the window, warn and suggest widening.
- **GitNexus index stale:** Check freshness first. If stale, prompt to run `npx gitnexus analyze` before proceeding.
- **File not in graph:** Some high-churn files (xibs, plists) won't have GitNexus nodes. Give them impact_score = 0 and note they were skipped in the detail view.
- **New files:** Files that didn't exist at the start of the commit window get full churn credit — they're high-change by definition.

## Weight Tuning

The weights (3/1/2 for callers/d2/processes) are initial values. After running on real data, they can be tuned in `references/scoring.md` without changing the skill logic. The multiplication-based formula means relative ranking is stable under small weight changes.

## Not in Scope

- **Automated scheduling** — The skill runs on-demand. A `/schedule` wrapper can be added later if periodic reports are wanted.
- **Historical trending** — No tracking of how hotspot scores change over time. Each run is a fresh snapshot.
- **Auto-fix suggestions** — The skill identifies targets, not solutions. Decomposition strategy is a separate design task per target.
- **Cross-repo analysis** — Single repo only.
