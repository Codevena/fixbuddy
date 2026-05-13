# Next session — P2 #7 (install.sh) and #8 (GitHub Action wrapper)

P0/P1 from the external review and P2 #6 (repo topics) are done. The two remaining P2 items both ship distribution: a `curl | bash` installer and a GitHub Action wrapper.

They are **independent** — #7 stands alone, #8 stands alone. Pick either or do both. #7 is the quick win, #8 is the bigger growth lever.

## Status snapshot

- Branch `main`, working tree clean.
- Both scripts pass `bash -n` and `shellcheck` cleanly.
- Repo topics live on GitHub: `ai`, `automation`, `bash`, `claude`, `codex`, `devops`, `github-actions`, `issue-automation`.
- No release tag exists yet. The script declares `VERSION="0.3.2"` in its header. **#7 and #8 both want a tag to pin to** — cut one before merging either feature.
- Definition-of-Done gate from `~/.claude/CLAUDE.md` still applies: static checks (`bash -n` + `shellcheck`), then OpenCode reviewer + Claude reviewer must both return `VERDICT: PASS` with zero CRITICAL/WARN. (Last session, `codex exec` hung at 0% CPU — the eval-newline-serialization bug — so OpenCode was used. Same fallback applies here.)

---

## #7 — `install.sh` for `curl | bash` distribution

**Goal:** one-liner install for users who already have `gh`, `jq`, `bash`.

### Deliverables

1. New file `install.sh` at repo root, pure bash, macOS + Linux compatible (no GNU-isms — assume only POSIX-ish `mktemp`, `chmod`, `mkdir`, `curl`, `uname`).
2. README updates:
   - Add the one-liner to the Quick Start section, **above** the `git clone` instructions (curl is the easier path for users who aren't planning to modify the script).
   - Keep the git-clone path as the "developer" install.

### Behavior

The script must:

1. **Detect destination.** Prefer `~/.local/bin` if it exists OR if `~/.local/bin` is in `$PATH`. Otherwise fall back to `/usr/local/bin`. If `/usr/local/bin` is not writable, re-exec with `sudo` (after explicit confirm: `Install to /usr/local/bin requires sudo. Continue? [y/N]`). Allow `--prefix PATH` to override.
2. **Pin to a release tag.** Default install ref is the latest released tag (`gh release view --json tagName --jq .tagName` is the cleanest probe, but the installer cannot assume `gh` exists on the user's machine — so fetch `https://api.github.com/repos/Codevena/fixbuddy/releases/latest` and `jq` the tag, OR hard-code a `DEFAULT_REF` constant in the installer and bump it per release). Allow `--ref TAG` override; `--ref main` for the bleeding edge.
3. **Download and validate.** Curl the two scripts (`fixbuddy.sh`, `fixbuddy-wizard.sh`) into `mktemp -d`. Validate each starts with `#!/usr/bin/env bash` before installing (rejects HTML error pages, partial downloads). If a `SHA256SUMS` exists at the same tag, verify hashes against it; if not, warn but continue.
4. **Install atomically.** `mv` into destination only after both files are downloaded + validated, so a partial failure doesn't leave a half-installed state.
5. **`chmod +x` both files.**
6. **Confirm and hint.** Print `Installed fixbuddy <VERSION> to <DEST>.` and `Run: fixbuddy-wizard.sh` (or `fixbuddy-wizard` if symlinked sans extension — decide whether to install with or without `.sh` suffix; without is friendlier on `$PATH` but breaks parity with the repo layout. Keep the `.sh` suffix unless the user wants otherwise).

### Edge cases to handle

- `curl` not installed → fail with a clear message naming `curl` as the missing prereq. `wget` is a possible fallback but adds complexity; ship with `curl` only.
- Destination on `$PATH` check: if the chosen destination isn't in `$PATH`, print a one-liner to add it to the user's shell rc.
- Re-install: don't refuse to overwrite — print "Updating from <old> to <new>" and proceed.
- `~/.local/bin` exists but isn't on `$PATH` → still pick it (it's the conventional XDG location), but warn.
- Test on macOS (zsh default) AND Linux (bash) before merging. WSL2 is "Linux."

### Verification before commit

```bash
shellcheck install.sh
bash -n install.sh
# Smoke test in a temp directory:
mkdir -p /tmp/install-test/bin
PATH=/tmp/install-test/bin:$PATH ./install.sh --prefix /tmp/install-test/bin --ref main
/tmp/install-test/bin/fixbuddy.sh --version
```

### Things to think hard about

- **Tag pinning.** The cleanest path is: cut `v0.3.2` as the first release tag, hard-code `DEFAULT_REF="v0.3.2"` in the installer, and bump it on every release. The dynamic-API-lookup alternative adds a network round-trip and a `jq` dependency just to discover the tag — not worth it for v1 of the installer.
- **Don't ship a one-liner that points at `main`.** That's how users get broken installs the day after a bad commit lands. The README one-liner must point at a tag.
- **No `--dangerously-skip-permissions`-style flags in the installer.** Keep the installer boring; the agent scripts are the powerful piece.

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

1. Cut `v0.4.0` release tag.
2. Create floating `v1` ref: `git tag -f v1 v0.4.0 && git push origin v1 --force` (this is the one place a force-push is correct — floating major refs are explicitly designed to move).
3. Update README to show `uses: Codevena/fixbuddy@v1`.
4. Verify in a fresh test repo: drop a workflow that calls the action, dispatch it manually, confirm it runs.

### Verification before commit

For each file:
- `shellcheck` any inline bash in `action.yml` (extract and validate separately if needed)
- For workflow YAMLs, run `gh workflow view` or rely on GitHub's parser on push
- Run the full code-quality gate from CLAUDE.md (OpenCode + Claude reviewers)

---

## Suggested ordering

1. **First:** cut a `v0.3.2` release tag from current `main` (`8e11650`). Both #7 and #8 depend on having a tag to pin to.
2. **Then:** #7 (`install.sh`) — independent quick win, gets the curl-pipe path live.
3. **Then:** #8 (Action wrapper) — bigger, but unlocks viral distribution.

If only doing one in this session: **#7**. It's contained, ships value immediately, and gives you a tagged release in passing.

---

## Useful references

- `fixbuddy.sh` top-of-file comment block: canonical CLI option list. If `action.yml` inputs drift from CLI flags, fix the script's CLI surface first, then the action.
- `fixbuddy-wizard.sh`: friendly-prompt wrapper. Its agent-choice copy is a good source for `action.yml` input descriptions.
- `SECURITY.md`: already documents the trust model. README's Action section should reference it and remind users that CI agents run with whatever token permissions they're handed.
- Repo topics are now: `ai, automation, bash, claude, codex, devops, github-actions, issue-automation` — adjust if the Action wrapper changes the positioning enough to warrant it.
