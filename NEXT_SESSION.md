# Next session

**v0.6.0 is released** (2026-06-12): the retired `gemini` agent was replaced by
`agy` (Antigravity CLI — Gemini CLI shuts down 2026-06-18), the read-only
pipeline stages got deterministic guards, and an offline integration test suite
landed. PR #9, merged to `main`.

## Status snapshot

- `main` is at the v0.6.0 merge; tags `v0.6.0` and floating `v1` both point at
  it. GitHub release published; CI green; install one-liner verified end-to-end
  against the fresh tag (checksums OK, `fixbuddy.sh --version` → 0.6.0).
- Spec: `docs/superpowers/specs/2026-06-12-agy-agent-and-integration-tests-design.md`
  (includes verified agy CLI facts: no read-only mode, `--sandbox` = terminal
  restrictions only, `--print-timeout` default 5m with **exit code 0** on timeout).
- Plan: `docs/superpowers/plans/2026-06-12-agy-agent-and-integration-tests.md`.
- Tests: `tests/integration.sh` — 14 offline scenarios (stub `gh`/agent CLIs,
  local bare-repo origin, real git pushes). Runs as the CI `integration` job.
- Audit history: `docs/audit/2026-06-10-findings.md` (all 18 findings fixed).

## Release checklist (for the NEXT release)

1. Bump `VERSION` in `fixbuddy.sh` (+ header), wizard header/banner,
   `install.sh` `DEFAULT_REF`, README one-liners; update `CHANGELOG.md`.
2. Regenerate `SHA256SUMS` (`shasum -a 256 fixbuddy.sh fixbuddy-wizard.sh >
   SHA256SUMS`) — `install.sh` verifies fail-closed.
3. Merge via PR; then `git tag vX.Y.Z && git push origin vX.Y.Z` and
   `git tag -f v1 vX.Y.Z && git push origin v1 --force`.
4. `gh release create vX.Y.Z` (the repo has release pages; "Latest" should
   track the newest tag). Smoke-test the install one-liner against the tag.

## What's next (README Roadmap)

- Optional notifications for run summaries
- Explicit resume mode for interrupted runs

Pick one and run it through the brainstorm → plan → DoD-gate flow.
