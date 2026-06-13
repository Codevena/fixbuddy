# Next session

**v0.7.1 is on branch `feat/action-notify-cmd-v0.7.1`** (2026-06-13), awaiting
merge/tag: the GitHub Action gains a `notify-cmd` input (newline-separated —
shell commands may contain commas). Released earlier: v0.7.0 (`--notify-cmd`
hook, 2026-06-12) and v0.6.0 (agy migration + read-only-stage guards).

## Status snapshot

- DoD gate passed (Codex PASS + Claude PASS); 20/20 integration tests; the
  action-smoke workflow exercises the new input on the PR.
- Specs/plans: `docs/superpowers/specs/` + `docs/superpowers/plans/`
  (2026-06-12 agy + notify-cmd documents).
- Tests: `tests/integration.sh` — 20 offline scenarios, runs in CI.
- The README roadmap is intentionally empty: notifications shipped, resume
  mode is covered by the label system (see README FAQ).

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
