# Next session — P2 from the external review

Picks up where commit "fix: harden agent prompts, unstick PR labels, block oversized diffs" left off. P0 and P1 from the external review are done; the items below are P2 distribution work that the previous session deliberately deferred.

## Status snapshot

- Branch `main`, working tree clean after the P0+P1 commit.
- `fixbuddy.sh` and `fixbuddy-wizard.sh` pass `bash -n` and `shellcheck` cleanly.
- Code-quality gate (OpenCode + Claude reviewer) passed on the P0+P1 changes.
- Note: in the previous session `codex exec` hung at 0% CPU with the multi-line prompt heredoc — likely the eval-newline-serialization bug documented in `~/.claude/CLAUDE.md`. OpenCode was used as the fallback per CLAUDE.md and worked fine.

## P2 work to do (in priority order)

### #6 — GitHub repository topics

Lowest-effort, biggest immediate discoverability win. Single command:

```bash
gh repo edit Codevena/fixbuddy \
  --add-topic github-actions \
  --add-topic automation \
  --add-topic ai \
  --add-topic claude \
  --add-topic codex \
  --add-topic bash \
  --add-topic devops \
  --add-topic issue-automation
```

After running, verify with `gh repo view Codevena/fixbuddy --json repositoryTopics`. Confirm the user wants these specific topics (or any additions) before executing — pushing topics is visible publicly.

### #7 — `install.sh` for `curl | bash` distribution

A one-liner install path. Should:

1. Detect the install location:
   - `~/.local/bin` if it exists and is on `$PATH`
   - else `/usr/local/bin` (will need `sudo` on most systems — prompt or detect)
2. Download `fixbuddy.sh` and `fixbuddy-wizard.sh` (curl from `raw.githubusercontent.com/Codevena/fixbuddy/main/`)
3. `chmod +x` both
4. Pin to a release tag (introduce `VERSION` reading from the script header or a `RELEASE` env var) — never install untagged `main` by default
5. Print success + post-install hint: `Run: fixbuddy-wizard.sh`

Things to think about:
- macOS + Linux compatibility (no GNU-isms in the installer itself).
- Verify the downloads — at minimum check the script header line (`#!/usr/bin/env bash`) before chmod+exec; ideally checksum against a published `SHA256SUMS` once releases exist.
- README quick-start should be updated to show the one-liner alongside the git clone path.

Add to README:

```bash
curl -sSL https://raw.githubusercontent.com/Codevena/fixbuddy/main/install.sh | bash
```

### #8 — GitHub Action wrapper (biggest growth lever)

This is the killer distribution channel — every consumer becomes a referral. Roughly:

1. Add `action.yml` at the repo root (composite action — keep it pure bash, no Docker, so it stays a single-file tool):
   ```yaml
   name: fixbuddy
   description: Turn GitHub issues into reviewed PRs using two AI coding agents
   inputs:
     repo:          { required: true,  description: "owner/repo to process" }
     project-path:  { required: false, default: ".", description: "Local checkout path" }
     fix-agent:     { required: false, default: "claude" }
     review-agent:  { required: false, default: "codex" }
     severity:      { required: false }
     max:           { required: false, default: "5" }
     base-branch:   { required: false }
     auto-merge:    { required: false, default: "true" }
   runs:
     using: composite
     steps:
       - run: ${{ github.action_path }}/fixbuddy.sh ...
         shell: bash
         env:
           GH_TOKEN: ${{ inputs.github-token || github.token }}
   ```

2. Open questions to resolve before shipping:
   - **Agent CLIs in CI runners.** GitHub-hosted runners do not have `claude` / `codex` / `opencode` / `gemini` pre-installed. The action will need to either (a) require users to set up the agent CLI in a prior step, or (b) bundle a setup step. Document the prerequisite block in `action.yml`'s description.
   - **Credentials.** Anthropic/OpenAI API keys must come from secrets. Decide whether the action accepts `anthropic-api-key` / `openai-api-key` inputs or expects env vars.
   - **Permissions.** The `GITHUB_TOKEN` provided by Actions needs `contents: write`, `pull-requests: write`, `issues: write`. Document in README. Pin a `permissions:` block in the example workflow.
   - **Dirty-tree check.** Fresh CI checkouts are always clean; fine.
   - **Logs.** `~/.fixbuddy/runs/...` lives in the runner's home — surface them by uploading as a workflow artifact in the example workflow.

3. Add a test workflow at `.github/workflows/action-smoke.yml` that runs the action in dry-run mode against the repo itself. This catches regressions in the wrapper.

4. Document a usage example in README:
   ```yaml
   - uses: Codevena/fixbuddy@v1
     with:
       repo: ${{ github.repository }}
       fix-agent: claude
       review-agent: codex
       severity: high
       max: 5
   ```

5. Cut a `v1` tag + `v1` floating ref once the action is verified end-to-end.

## Things to verify before committing P2 work

- Run the same Definition-of-Done gate as the P0/P1 work: `bash -n`, `shellcheck`, then OpenCode reviewer + Claude reviewer.
- If `install.sh` is added, run `shellcheck` on it.
- Test `install.sh` end-to-end in a clean macOS user dir before merging.
- For the Action: test the smoke workflow on a feature branch before merging — GitHub Actions runs aren't always reproducible locally.

## Pointer — useful references in the codebase

- `fixbuddy.sh` top-of-file comment block has the canonical CLI option list. If `action.yml` inputs drift from CLI flags, fix the script first, then the action.
- `fixbuddy-wizard.sh` is a friendlier-prompt wrapper; the Action does not need its logic but its agent-choice copy is a good source for `action.yml` input descriptions.
- `SECURITY.md` already documents the trust model; the Action README section should reference it and remind users that agents in CI run with whatever token permissions you give them.
