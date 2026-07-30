# Next session

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

1. Bump `VERSION` in `fixbuddy.sh` (+ header), wizard header/banner,
   `install.sh` `DEFAULT_REF`, README one-liners; update `CHANGELOG.md`.
2. Regenerate `SHA256SUMS` (`shasum -a 256 fixbuddy.sh fixbuddy-wizard.sh >
   SHA256SUMS`) — `install.sh` verifies fail-closed.
3. Merge via PR; then `git tag vX.Y.Z && git push origin vX.Y.Z` and
   `git tag -f v1 vX.Y.Z && git push origin v1 --force`.
4. `gh release create vX.Y.Z` and smoke-test the install one-liner.

## Idea backlog (not committed)

- Log retention/pruning for `~/.fixbuddy/runs`
- New agents as they appear (validation list + run_agent case + wizard + docs)
- The `--help` sed range (`2,51p`) must be adjusted whenever header lines are
  added — candidate for a less brittle help mechanism
