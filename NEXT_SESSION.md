# Next session — P2 #8 (GitHub Action wrapper)

P0/P1 from the external review, P2 #6 (repo topics), and P2 #7 (`install.sh`) are done. The one remaining P2 item is the GitHub Action wrapper — the bigger growth lever.

## Status snapshot

- Branch `main`, working tree clean. Latest commit `d04a4eb`.
- **`v0.3.2` is tagged and pushed** — annotated tag at `d04a4eb`, the first tagged release. It contains `fixbuddy.sh`, `fixbuddy-wizard.sh`, `install.sh`, and `SHA256SUMS`.
- `install.sh` (P2 #7) shipped: `curl | bash` installer, pure bash, macOS (bash 3.2) + Linux/WSL2. Pins to `DEFAULT_REF="v0.3.2"`. README Quick Start leads with the one-liner. Verified end-to-end against the live tag — checksum path works.
- `SHA256SUMS` at repo root holds hashes of `fixbuddy.sh` + `fixbuddy-wizard.sh`. **Regenerate it (`shasum -a 256 fixbuddy.sh fixbuddy-wizard.sh > SHA256SUMS`) whenever either script changes, before cutting a new tag**, or `install.sh` checksum verification will fail closed.
- Repo topics live on GitHub: `ai`, `automation`, `bash`, `claude`, `codex`, `devops`, `github-actions`, `issue-automation`.
- Definition-of-Done gate from `~/.claude/CLAUDE.md` still applies: static checks (`bash -n` + `shellcheck`), then Codex reviewer + Claude reviewer must both return `VERDICT: PASS` with zero CRITICAL/WARN. (Note: last `install.sh` session, `codex exec` worked fine — the prior 0% CPU hang did not recur. If it hangs again, use the OpenCode fallback documented in CLAUDE.md.)

---

## #8 — GitHub Action wrapper

**Goal:** consumers can drop fixbuddy into their workflow with a single `uses:` line.

### Deliverables

1. `action.yml` at repo root (composite action — keep it pure bash, no Docker — preserves the "single-file tool" property).
2. `.github/workflows/action-smoke.yml` — a smoke test that runs the action against this repo's own issues in dry-run mode, gated on a manual `workflow_dispatch` trigger so it doesn't fire on every push.
3. README section: "Use in GitHub Actions" with a copy-pasteable workflow snippet.
4. A `v1` floating ref pointing at the cut release tag, so consumers can `uses: Codevena/fixbuddy@v1` and get automatic minor-version updates.

### `action.yml` shape

```yaml
name: fixbuddy
description: Turn GitHub issues into reviewed PRs using two AI coding agents
author: Codevena
branding:
  icon: git-pull-request
  color: purple
inputs:
  repo:
    description: "owner/repo to process (defaults to ${{ github.repository }})"
    required: false
  project-path:
    description: "Local checkout path"
    required: false
    default: "."
  fix-agent:
    description: "claude | codex | opencode | gemini"
    required: false
    default: "claude"
  review-agent:
    description: "claude | codex | opencode | gemini"
    required: false
    default: "codex"
  severity:
    description: "Filter by severity:<level> label"
    required: false
  label:
    description: "Filter by label (comma-separated for multiple)"
    required: false
  max:
    description: "Max issues per run"
    required: false
    default: "5"
  base-branch:
    description: "PR base branch (auto-detect if unset)"
    required: false
  auto-merge:
    description: "Request auto-merge after review approval"
    required: false
    default: "true"
  dry-run:
    description: "List targets only, no changes"
    required: false
    default: "false"
  github-token:
    description: "Token with contents:write, pull-requests:write, issues:write"
    required: false
    default: ${{ github.token }}
runs:
  using: composite
  steps:
    - shell: bash
      env:
        GH_TOKEN: ${{ inputs.github-token }}
      run: |
        set -euo pipefail
        cmd=("${{ github.action_path }}/fixbuddy.sh"
          --repo "${{ inputs.repo || github.repository }}"
          --project "${{ inputs.project-path }}"
          --fix-agent "${{ inputs.fix-agent }}"
          --review-agent "${{ inputs.review-agent }}"
          --max "${{ inputs.max }}"
          --yes)
        [ -n "${{ inputs.severity }}" ]    && cmd+=(--severity "${{ inputs.severity }}")
        [ -n "${{ inputs.base-branch }}" ] && cmd+=(--base "${{ inputs.base-branch }}")
        [ "${{ inputs.auto-merge }}" = "false" ] && cmd+=(--no-auto-merge)
        [ "${{ inputs.dry-run }}" = "true" ]     && cmd+=(--dry-run)
        # Comma-split labels → multiple --label flags
        if [ -n "${{ inputs.label }}" ]; then
          IFS=',' read -ra labels <<< "${{ inputs.label }}"
          for l in "${labels[@]}"; do
            cmd+=(--label "$(echo "$l" | xargs)")
          done
        fi
        "${cmd[@]}"
```

### Hard problems to resolve before merging

1. **Agent CLIs are not on GitHub-hosted runners.** `claude`, `codex`, `opencode`, `gemini` are not pre-installed on `ubuntu-latest`. The action has three options:
   - (a) Document the prerequisite: users must add a setup step in their workflow that installs the CLI before invoking the action. Cleanest, keeps the action small.
   - (b) Add an `install-agent: true` input that the action handles. Adds complexity, brittle (each CLI has a different install path).
   - (c) Provide a sibling `Codevena/fixbuddy-setup` action that installs CLIs. Splits the surface area sensibly.

   **Recommend (a) for v1.** Document clearly in README and add `## Prerequisites in CI` block. Users typically pin agent CLIs to specific versions anyway.

2. **API keys / credentials.** Anthropic / OpenAI keys must come from `secrets`. The action does NOT read them directly — agent CLIs read their own env vars (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`). The action's job is to make sure those env vars are exported. Document this in README: users set env on the step or workflow level, the action inherits them.

3. **`GITHUB_TOKEN` permissions.** Default `github.token` has limited scopes. The action needs `contents: write`, `pull-requests: write`, `issues: write`. Document this in README with the exact `permissions:` block. If a user passes an empty `github-token`, fail fast with a clear error.

4. **Working-tree dirtiness.** `fixbuddy.sh` aborts on a dirty worktree (deliberate safety). Fresh CI checkouts are always clean, so this is fine in practice — but the action should NOT do `actions/checkout@v4` itself; the consumer's workflow handles that. Document this in README.

5. **Log surfacing.** `fixbuddy.sh` writes logs to `~/.fixbuddy/runs/...`. In CI those vanish when the runner shuts down. The action should:
   - At end of run, copy logs to `${{ github.workspace }}/fixbuddy-logs/` so consumers can `actions/upload-artifact` them.
   - OR add an `upload-logs: true` input that does the artifact upload itself.

   **Recommend (a)** — keeps the action's surface area small, lets consumers choose whether to ship logs.

6. **PR comments and issue updates are CI-side.** This is fine — `gh` calls go through `GH_TOKEN` and CI is a normal authenticated client. No special handling needed.

### Smoke workflow

`.github/workflows/action-smoke.yml`:

```yaml
name: fixbuddy action smoke test
on:
  workflow_dispatch:
  pull_request:
    paths:
      - 'action.yml'
      - 'fixbuddy.sh'
      - 'fixbuddy-wizard.sh'
jobs:
  dry-run:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      issues: read
      pull-requests: read
    steps:
      - uses: actions/checkout@v4
      - name: Run fixbuddy (dry-run)
        uses: ./
        with:
          dry-run: "true"
          max: "1"
        # No agent CLI is needed in dry-run — fixbuddy short-circuits before any agent call.
```

The smoke test is intentionally minimal. It catches regressions in the action wrapper (input parsing, command construction, exit codes) without needing real API keys.

### Release process for #8

Once `action.yml` lands and the smoke test passes:

1. Regenerate `SHA256SUMS` if `fixbuddy.sh` / `fixbuddy-wizard.sh` changed, bump `install.sh` `DEFAULT_REF` and the README one-liner to the new tag.
2. Cut `v0.4.0` release tag.
3. Create floating `v1` ref: `git tag -f v1 v0.4.0 && git push origin v1 --force` (this is the one place a force-push is correct — floating major refs are explicitly designed to move).
4. Update README to show `uses: Codevena/fixbuddy@v1`.
5. Verify in a fresh test repo: drop a workflow that calls the action, dispatch it manually, confirm it runs.

### Verification before commit

For each file:
- `shellcheck` any inline bash in `action.yml` (extract and validate separately if needed)
- For workflow YAMLs, run `gh workflow view` or rely on GitHub's parser on push
- Run the full code-quality gate from CLAUDE.md (Codex + Claude reviewers)

---

## Useful references

- `fixbuddy.sh` top-of-file comment block: canonical CLI option list. If `action.yml` inputs drift from CLI flags, fix the script's CLI surface first, then the action.
- `fixbuddy-wizard.sh`: friendly-prompt wrapper. Its agent-choice copy is a good source for `action.yml` input descriptions.
- `install.sh`: the curl-pipe installer shipped in #7 — useful reference for the project's bash style and the DoD gate workflow.
- `SECURITY.md`: already documents the trust model. README's Action section should reference it and remind users that CI agents run with whatever token permissions they're handed.
- Repo topics are now: `ai, automation, bash, claude, codex, devops, github-actions, issue-automation` — adjust if the Action wrapper changes the positioning enough to warrant it.
