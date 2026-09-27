# Next session

## Local v0.9.2 release candidate — 2026-09-27 (not pushed)

Branch `fix/closed-merged-issue-label` contains product commit `cc55978` and
the prepared single-file v0.9.2 release. After a human merges a FixBuddy PR,
the next write run inspects GitHub's **latest issue-closure event** and changes
`fix:pr-open` to `fix:applied` only when its closer is a merged same-repository
`fix/issue-N` PR. Historical merges, fork PRs, unclear API results and dry-run
cannot relabel the issue. A controlled run of local `0.9.2-dev` against the
private synthetic fixture changed its closed issue to `fix:applied` with no
agent call or new PR. The published and locally installed version is still
v0.9.1; the private fixture and remote fix branch remain.

Causal RED/GREEN cases, final offline integration **62/62**, terminal UI
**17/17**, ShellCheck, Actionlint, syntax, deterministic bundle and SHA256
checks passed. An independent post-review found two false-attribution WARNs;
both were reproduced and fixed. The final delta review passed with
0 CRITICAL/WARN. The untracked `review-todo.md` remains user-owned.

Next: Markus reviews the local release candidate and decides whether to push,
merge and publish v0.9.2. Inspect CodeRabbit on that next PR; do not restart
the four older pending bot reviews. A private launch-test outline is in the
Brain; no public post has been made. ScoutBuddy is under development in a
separate session.

## Published v0.9.1 and live Issue→PR smoke — 2026-09-27

An initial authorized run in a **private synthetic test repository** reached a
passing fix check and Codex approval, but Codex stdout repeated
`DONE-APPROVED` in its transcript. FixBuddy v0.9.0 failed closed, labeled the
issue `fix:rejected` and opened no PR. The adapter fix in `21db76b` now uses
Codex's canonical `--output-last-message` for decisions while retaining raw
output in the log; missing final messages, nonzero exits and timeouts stay
blocked. Keep private repository and issue identifiers in the private Brain
note, not in this public repository.

PR #15 merged as `b20e89a` after its Shell, integration and Action-smoke checks
passed. CI on the merge commit passed too (`36324802963`). Annotated tag
`v0.9.1` and floating Action tag `v1` both resolve to `b20e89a`. The public
non-draft, non-prerelease GitHub Release is latest and attaches the single
`fixbuddy` executable plus `SHA256SUMS`; downloaded assets match the tagged
tree byte-for-byte. The pinned public installer installed one matching file
both in a temporary prefix and at `~/.local/bin/fixbuddy`, which reports
`fixbuddy 0.9.1`.

The separately authorized second live run used the **publicly installed
v0.9.1** against the same private synthetic issue. After removing the old
`fix:rejected` label, its dry-run selected exactly that issue with auto-merge
off. Claude verified and fixed it, the Python check passed, Codex approved,
and FixBuddy opened one private PR. The PR has one commit and changes only the
intended `src/calc.py` line; the Python test passed on the fetched PR commit.
Markus then authorized its merge. GitHub merged it as `8b392ce` and closed the
issue; the Python test passes on the merged `main` commit. The issue initially
kept a stale `fix:pr-open` label because FixBuddy's reconciliation read only
open issues. A later controlled run with the local repair replaced that label
with `fix:applied` without invoking an agent or creating a PR. The local test
checkout remained clean. No further provider retry occurred.

Offline verification: causal RED and focused GREEN 9/9, integration 54/54,
TUI 17/17, ShellCheck, Actionlint, syntax, bundle/SHA256 checks, manual
Gitleaks scan of the three release commits, and independent post-review with
0 CRITICAL/WARN. CodeRabbit posted no findings on public PRs #12, #13, #15
and #16, but their optional checks are still pending; check the next FixBuddy
PR for a completed result. The untracked `review-todo.md` is user-owned and
unchanged.

## Published v0.9.0 — 2026-09-27

PR #13 merged to `main` as `7799e3e` after Shell, integration and Action-smoke
checks passed. CI on the merge commit (`36316858413`) passed too. Annotated tag
`v0.9.0` and the floating Action tag `v1` both resolve to that exact commit;
the public GitHub Release is non-draft, non-prerelease and marked latest. It
attaches the single `fixbuddy` executable and `SHA256SUMS`. Downloaded assets
match the tagged workspace bytes. The pinned public installer fetched and
checksum-verified one executable into a temporary prefix; it reported
`fixbuddy 0.9.0`. `~/.local/bin/fixbuddy` is updated to the same version.

The bundled command opens the account-wide repo/open-issue dashboard; `--wizard`
and direct flags retain the existing pipeline. The demo mode was removed. The
release passed 49/49 offline integration cases, 17/17 UI tests, ShellCheck,
Actionlint, bundle and SHA256 checks, and independent release review with 0
CRITICAL/WARN. The offline demo reached a real local branch push and stubbed
PR/merge calls. VHS 0.12.0 on this Mac did not export a GIF even from a minimal
tape, so the existing GIF remains and the generator now fails visibly and
restores it. No live paid agent or real issue-to-PR run was performed.

`pd` reports 0 open findings and now attributes the historical audit to
2026-08-30 at `73e723b6f5ad` (HEAD differs, correctly). The untracked
`review-todo.md` remains outside the product commits. The three previously
installed v0.8.0 executables matched the published hashes and were moved to
`~/.local/share/fixbuddy/legacy-v0.8.0/`; only `fixbuddy` remains in
`~/.local/bin`. CodeRabbit's optional review on PR #13 was still pending at
last check; inspect any later findings. The real agent/PR smoke still needs a
separate controlled test issue and provider-cost authorization.

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
