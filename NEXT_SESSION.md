# Next session

v0.7.0 is implemented on branch `feat/notify-cmd-v0.7.0`: the `--notify-cmd`
run-summary notification hook (additive config key `notify_cmd`), plus the
roadmap cleanup — explicit resume mode is intentionally not built (the label
system already resumes interrupted runs; documented in a new FAQ entry).

## Status snapshot

- Branch `feat/notify-cmd-v0.7.0`, awaiting DoD gate / merge / tag.
- Spec: `docs/superpowers/specs/2026-06-12-notify-cmd-design.md`
- Plan: `docs/superpowers/plans/2026-06-12-notify-cmd.md`
- Tests: `tests/integration.sh` — 19 offline scenarios, runs in CI.
- v0.6.0 (agy migration + read-only-stage guards) is released and tagged.

## Release checklist (per release)

1. Bump `VERSION` in `fixbuddy.sh` (+ header), wizard header/banner,
   `install.sh` `DEFAULT_REF`, README one-liners; update `CHANGELOG.md`.
2. Regenerate `SHA256SUMS` (`shasum -a 256 fixbuddy.sh fixbuddy-wizard.sh >
   SHA256SUMS`) — `install.sh` verifies fail-closed.
3. Merge via PR; then `git tag vX.Y.Z && git push origin vX.Y.Z` and
   `git tag -f v1 vX.Y.Z && git push origin v1 --force`.
4. `gh release create vX.Y.Z` ("Latest" should track the newest tag) and
   smoke-test the install one-liner against the fresh tag.

## What's next

The README roadmap is empty — pick new goals next session. Ideas raised but
not committed: notify-cmd input for the GitHub Action, log retention/pruning
for `~/.fixbuddy/runs`, more agents as they appear.
