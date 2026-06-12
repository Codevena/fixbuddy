# Next session

v0.6.0 is implemented on branch `feat/agy-agent-v0.6.0`: the retired `gemini`
agent is replaced by `agy` (Antigravity CLI — Gemini CLI shuts down 2026-06-18)
and a deterministic offline integration test suite landed.

## Status snapshot

- Branch `feat/agy-agent-v0.6.0`, all work committed; awaiting merge to `main`
  and the release tag.
- Spec: `docs/superpowers/specs/2026-06-12-agy-agent-and-integration-tests-design.md`
  (includes the locally verified agy CLI behavior: no read-only mode, `--sandbox`
  semantics, `--print-timeout` default 5m with **exit code 0** on timeout).
- Plan: `docs/superpowers/plans/2026-06-12-agy-agent-and-integration-tests.md`.
- Tests: `tests/integration.sh` — 9 scenarios against stubbed `gh`/agent CLIs and
  a local bare-repo origin. Runs in CI (`integration` job) alongside shellcheck.
- Audit history moved to `docs/audit/2026-06-10-findings.md` (all 18 findings
  fixed in v0.5.0).

## Release checklist (v0.6.0)

Version bumps, CHANGELOG, and `SHA256SUMS` are already done on the branch. After
merge to `main`:

1. `git tag v0.6.0 && git push origin v0.6.0`
2. `git tag -f v1 v0.6.0 && git push origin v1 --force` (floating major ref for
   `uses: Codevena/fixbuddy@v1`)
3. Verify the CI + action-smoke workflows are green on `main`.

Remember for future releases: regenerate `SHA256SUMS`
(`shasum -a 256 fixbuddy.sh fixbuddy-wizard.sh > SHA256SUMS`) whenever either
script changes, before tagging — `install.sh` verifies checksums fail-closed.

## What's next (README Roadmap)

- Optional notifications for run summaries
- Explicit resume mode for interrupted runs

Pick one and run it through the brainstorm → plan → DoD-gate flow.
