# Next session

All P0/P1 review items and the full P2 backlog (#6 repo topics, #7 `install.sh`, #8 GitHub Action wrapper) are done.

## Status snapshot

- Branch `main`, working tree clean.
- **`v0.4.0` is tagged and pushed**, with a floating **`v1`** ref pointing at it. Consumers use `uses: Codevena/fixbuddy@v1`.
- `action.yml` (composite action, pure bash) + `.github/workflows/action-smoke.yml` (dry-run smoke test) shipped in #8. README has a "Use in GitHub Actions" section.
- `fixbuddy.sh` `--dry-run` skips the agent-CLI presence check (agent-name validation still runs) so the smoke test works on bare runners.
- `install.sh` pins `DEFAULT_REF="v0.4.0"`; README Quick Start one-liner points at `v0.4.0`.
- `SHA256SUMS` holds hashes of `fixbuddy.sh` + `fixbuddy-wizard.sh`. **Regenerate it (`shasum -a 256 fixbuddy.sh fixbuddy-wizard.sh > SHA256SUMS`) whenever either script changes, before cutting a new tag** — `install.sh` verifies checksums and fails closed.
- When cutting a new release: bump `VERSION` in `fixbuddy.sh`, the header comment, `install.sh` `DEFAULT_REF`, the README one-liner; regenerate `SHA256SUMS`; tag `vX.Y.Z`; then `git tag -f v1 vX.Y.Z && git push origin v1 --force` to move the floating major ref.
- Definition-of-Done gate from `~/.claude/CLAUDE.md` still applies. Note from #8: `codex exec` hung at 0% CPU again — the OpenCode fallback (`opencode run --dangerously-skip-permissions "$(<file)"`) worked. Write reviewer prompts with the Write tool, not Bash heredocs.

## What's next

P2 is complete. Remaining work lives in the README **Roadmap**:

- Config file support
- More deterministic integration tests with mocked CLIs
- Optional notifications for run summaries
- Explicit resume mode for interrupted runs

Pick one and run it through the brainstorm → plan → DoD-gate flow. Verify the action-smoke workflow went green on GitHub after the v0.4.0 push.
