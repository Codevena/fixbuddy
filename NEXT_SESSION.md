# Next session

**v0.7.0 is released** (2026-06-12): `--notify-cmd` run-summary notification
hook (additive config key `notify_cmd`). PR #10, merged to `main`. Earlier the
same day, v0.6.0 shipped the agy migration (Gemini CLI successor) and the
read-only-stage guards.

## Status snapshot

- `main` is at the v0.7.0 merge; tags `v0.7.0` and floating `v1` point at it.
  GitHub release published; CI green; install one-liner smoke-tested against
  the fresh tag (checksums OK, `--version` → 0.7.0, `--help` shows notify-cmd).
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

- `notify-cmd` input for the GitHub Action wrapper
- Log retention/pruning for `~/.fixbuddy/runs`
- New agents as they appear (validation list + run_agent case + wizard + docs)
- The `--help` sed range (`2,51p`) must be adjusted whenever header lines are
  added — candidate for a less brittle help mechanism
