# Next session

## Unreleased single-file candidate — 2026-09-27

Local product commit `93b7b3a` contains a one-file `fixbuddy` command assembled from
`src/core.sh`, `src/tui.py` and `src/wizard.sh` by `scripts/build.py`. Running
it interactively opens an account-wide GitHub repository and open-issue view;
`--wizard` and direct CLI flags retain the existing pipeline. The demo has
been removed. `install.sh --local` installs only `fixbuddy`; the default
published v0.8.0 installation path remains available. The Action points at
the bundled command. A run now checks the selected repository against both
origin fetch and push destinations before any writes.

This is a verified local candidate, not a published release. The final bundle
passed 48/48 offline integration and 17/17 UI tests, ShellCheck, Actionlint,
bundle and SHA256 checks; independent delta review found 0 CRITICAL/WARN. A
read-only account inventory returned 114 repositories, 25 open issues and 0
unknown. `bash install.sh --local` installed the candidate at
`~/.local/bin/fixbuddy` and its checksum matched. `pd` still reports 0 open
audit findings but an unknown review date/commit. Do not push or publish
without an explicit current-task instruction; after publication verify CI and
the public installer. No real agent write/PR smoke was performed. The untracked
`review-todo.md` belongs to Markus and remains outside the product commit.

## Published v0.8.0 — 2026-09-27

PR #12 was merged to `main` as `f17d847`; its required Shell checks,
integration job, and Action dry-run smoke passed. The `main` CI on that merge
commit also passed (`36310626815`). Annotated tag `v0.8.0` and floating Action
tag `v1` both resolve to `f17d847`. The non-draft, non-prerelease GitHub Release
is published and marked latest; a fresh Marketplace response shows v0.8.0.

The public pinned installer was fetched from `v0.8.0` and installed with
`--with-tui` into a temporary prefix and then `~/.local/bin`; SHA256 checks
matched all three scripts. The installed CLI prints `fixbuddy 0.8.0`; the
installed TUI demo rendered and exited in an 80x24 PTY. A live read-only JSON
dry-run against `Codevena/fixbuddy` returned base `main`, auto-merge `false`,
and 0 actionable issues. Local `pd` reports `Audit: ● 0 offene Befunde` from
the still-untracked `review-todo.md`. No billable agent run or live issue→PR
pipeline was performed; use a controlled test issue in an owned repository for
that separate smoke.

The sections below are historical pre-release snapshots. CodeRabbit's optional
PR review was still pending at the last check after merge; inspect any eventual
findings before additional product changes.

## Historical local state — 2026-09-27 (`0765617`, before publication)

The seven logic findings in the 2026-08-30 `review-todo.md` are addressed in
local commit `0765617`. The Bash pipeline checks branch/base state, fetches the
base before verification, uses an exact final review verdict, pages through all
issues, replaces stale remote branches only under a lease, pushes the reviewed
SHA, and retains the remote branch if PR creation fails. Auto-merge defaults to
off. The Action copies only its own run logs. An optional Python 3 terminal UI
provides queue, setup, issue detail, run activity, and a read-only demo.

Final local evidence on the candidate: 43/43 offline integration scenarios,
10/10 TUI tests including narrow/wide PTY renders, Bash syntax, ShellCheck,
Action workflow/YAML parsing, and three SHA256 checks passed. Independent plan
review and post-implementation delta review ended with no open CRITICAL/WARN.
The local commit was additionally scanned with redacted Gitleaks (no findings);
this repo's configured hooks directory had no pre-commit hook.

`pd zeig --kurz --repo .` reports `Audit: ● 0 offene Befunde`. The local
`review-todo.md` carries `erledigt 0765617` for all seven rows and remains
untracked, intentionally outside the product commit. No live GitHub write,
agent-provider run, push, tag, release, install, or deployment was performed.
The pinned v0.7.1 installer still installs its two existing scripts; the UI is
available from the source checkout and through the updated installer's
`--with-tui` option once this code exists at the chosen published ref.

**Next executable step:** review the local commit and `review-todo.md`, then
decide whether to publish the candidate. Pushing or releasing requires an
explicit instruction; after publication, verify CI and the installer against
the published ref. The older snapshot below describes the prior v0.7.1 state.

### Follow-up 2026-09-27 — full Fix Buddy wordmark

The TUI header now spells out `FIX BUDDY`. Commit `380c30d` adds a five-row
violet-to-pink block wordmark at normal widths and a compact mark on narrow
terminals. The 10 TUI tests (including 40- and 120-column PTYs), the focused
TUI installer smoke, SHA256 checks, and staged Gitleaks scan passed. Local
`main` remains ahead of `origin/main`; there has still been no push,
release, or installation. The untracked `review-todo.md` remains untouched by
this visual follow-up.

**v0.7.1 is released** (2026-06-13): the GitHub Action gains a `notify-cmd`
input (newline-separated — shell commands may contain commas). PR #11.
Released earlier: v0.7.0 (`--notify-cmd` hook) and v0.6.0 (agy migration +
read-only-stage guards), both 2026-06-12.

## Status snapshot

- `main` is at the v0.7.1 merge; tags `v0.7.1` and floating `v1` point at it.
  GitHub release published; CI green; install one-liner smoke-tested against
  the fresh tag. The action-smoke workflow exercises the notify-cmd input on
  every PR that touches the action.
- Tests: `tests/integration.sh` — 20 offline scenarios, runs in CI.
- Specs/plans: `docs/superpowers/specs/` + `docs/superpowers/plans/`
  (2026-06-12 agy + notify-cmd documents).
- Tests: `tests/integration.sh` — 20 offline scenarios, runs in CI.
- The README roadmap is intentionally empty: notifications shipped, resume
  mode is covered by the label system (see README FAQ).
- **Unreleased on `main` (2026-07-30):** `action.yml` description rewritten for
  Marketplace search ("pull requests" spelled out, agents named). It only
  reaches the listing with the next release — fold it into that CHANGELOG
  entry; do NOT cut a release just for it. Measured: Marketplace search does
  index the description, but ranking buries listings with 0 stars (`coding`
  → 79 results, fixbuddy on page 4), so the payoff is limited to rare terms
  (`agy` 0 competitors, `opencode` 6). Distribution has to come from outside.

## Release checklist (per release)

1. Bump `VERSION` in `src/core.sh` (+ header), wizard header/banner,
   `install.sh` `DEFAULT_REF`, README install instructions; update `CHANGELOG.md`.
2. Run `python3 scripts/build.py`, then regenerate `SHA256SUMS` for the single
   `fixbuddy` file. The installer verifies the published checksum fail-closed.
3. Merge via PR; then `git tag vX.Y.Z && git push origin vX.Y.Z` and
   `git tag -f v1 vX.Y.Z && git push origin v1 --force`.
4. `gh release create vX.Y.Z` and smoke-test the install one-liner.

## Idea backlog (not committed)

- Log retention/pruning for `~/.fixbuddy/runs`
- New agents as they appear (validation list + run_agent case + wizard + docs)
- Help is embedded by `scripts/build.py`; update the `src/core.sh` header and
  regenerate the bundle when adding options.
