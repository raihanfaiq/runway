# Left-pane PR list + slower terminal scroll — design

Date: 2026-06-26

Two changes to Runway:

1. Replace the (unused) Notes scratchpad in the left pane with a live list of the
   user's open pull requests across the three VISKA-IO repos — the same data the
   `update-lists` skill produces, but rendered natively and refreshed on a timer.
2. Slow down terminal scrolling, which feels too fast.

## Mission 1 — Live PR list

### Scope (fixed, matching the `update-lists` skill)
- Repos: `VISKA-IO/monorepo`, `VISKA-IO/upsell-pos`, `VISKA-IO/upsell-kiosk`.
- Author: `raihanfaiq`.
- Read-only. Uses the existing `GH.run([...])` bridge (the authenticated `gh` CLI,
  off the main thread) — the same mechanism `GitHubFeed` already uses.

### Data flow
A new `@MainActor @Observable` singleton `PRStore` (mirrors `GitHubFeed`):
- `startPolling()` refreshes every **90s**; a manual refresh button forces it.
- Per refresh, per repo:
  - `gh search prs --repo <r> --author raihanfaiq --state open --sort updated
    --json number,title,isDraft,url --limit 50`
  - then per PR: `gh pr view <n> --repo <r> --json number,title,isDraft,
    mergeable,mergeStateStatus,additions,deletions,changedFiles,updatedAt,
    reviewDecision,statusCheckRollup`
  - PR-detail calls fan out concurrently (TaskGroup). Search + detail fetching
    live in `nonisolated static` helpers returning `Sendable` values, so nothing
    non-Sendable crosses an actor boundary (Swift 6 strict concurrency).
- On `gh` failure it surfaces `GitHubFeed.ghHint`; a PR whose detail call fails
  still shows from its search stub with a `checking` status (never silently dropped).

### Derived status (the native "suggestion")
One `PRStatus` per PR, derived from the live fields:
- `draft`     — isDraft → "draft"
- `ciFailing` — any required check FAILURE/TIMED_OUT/CANCELLED/ACTION_REQUIRED → "CI"
- `rebase`    — mergeStateStatus DIRTY/BEHIND, or mergeable CONFLICTING → "rebase"
- `review`    — mergeStateStatus BLOCKED, or reviewDecision REVIEW_REQUIRED/
                CHANGES_REQUESTED → "review"
- `checking`  — mergeable/mergeStateStatus UNKNOWN, or CI pending → "checking"
- `ready`     — CLEAN + MERGEABLE → "ready"

Each status maps to a label, an SF Symbol, and a color drawn from the existing
terminal palette (green/amber/red/blue/grey).

### View
`PRListView` (in the new `PullRequests.swift`), embedded by `LeftPane` where
`notesSection` was:
- Header: "PULL REQUESTS", a count, a spinner while loading, a refresh button.
- Grouped by repo (fixed order); within a group, ordered ready → rebase → CI →
  review → checking → draft (quick wins first, matching the skill's easiest-first).
- **Detailed** rows: `#num  title    <status chip>` and a subline
  `+adds −dels · N files · 2h`. Whole row is a button → opens the PR in the browser.
- States: first-load skeleton; empty → "No open PRs 🎉"; error → `gh` hint.

### Integration
- `LeftPane.body`: `notesSection` → `PRListView()`. The agent list keeps its
  50%-height cap so the PR list gets the leftover space and scrolls internally.
- `applicationDidFinishLaunching`: add `PRStore.shared.startPolling()`.
- `Workspace.notes` and its persistence are left intact (no UI) — nothing is lost.

## Mission 2 — Slower terminal scroll

Ghostty exposes `mouse-scroll-multiplier` with two components — `precision`
(trackpad, default 1) and `discrete` (mouse wheel, default 3). Add one line to the
Runway terminal theme written by `TerminalTheme.installTheme()`:

```
mouse-scroll-multiplier = precision:0.5,discrete:1.5
```

Roughly halves both. The theme file is regenerated at launch and loaded into the
Ghostty config, so it takes effect on the next launch (no hot-apply). Easy to tune.

## Non-goals
- No write actions (merge/close/comment) from the panel.
- No re-implementation of the skill's full Tier 1–5 analysis — the panel shows a
  glanceable per-PR status, not the deep tiering.
- Repos/author stay hardcoded to the skill's scope (not yet configurable).
