# Fixbuddy

**A Bash orchestrator that turns GitHub issues into reviewed pull requests using two AI coding agents.**

[![CI](https://github.com/Codevena/fixbuddy/actions/workflows/ci.yml/badge.svg)](https://github.com/Codevena/fixbuddy/actions/workflows/ci.yml)
[![version](https://img.shields.io/github/v/tag/Codevena/fixbuddy?label=version)](https://github.com/Codevena/fixbuddy/tags)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![shell](https://img.shields.io/badge/shell-bash-black.svg)](fixbuddy.sh)
[![agents](https://img.shields.io/badge/agents-claude%20%7C%20codex%20%7C%20opencode%20%7C%20agy-purple.svg)](#supported-agents)

fixbuddy reads open GitHub issues, asks one agent to verify and fix each issue, asks a second agent to review the committed diff, then opens a pull request. If enabled, it requests auto-merge after review approval.

The goal is controlled automation: one issue per branch, one issue per PR, explicit labels for every outcome, and full logs for every agent call.

<p align="center">
  <img src="docs/demo.gif" alt="fixbuddy turning a GitHub issue into a reviewed, merged pull request" width="820">
</p>

<sub>The branch, commit, diff, and push above are real; the AI agents and GitHub calls are stubbed for a deterministic, offline recording — see <a href="docs/demo">docs/demo</a>.</sub>

## Why fixbuddy

Most AI issue-fixers let a single agent write a fix and, at best, review its own work. fixbuddy splits the job across **two different agents from two different vendors**: by default `claude` writes the fix and `codex` reviews the committed diff with a fresh context. The fixer never approves its own work.

It needs no cloud service, no Docker, and no separate API-key broker — it drives the AI coding CLIs you already have installed (`claude`, `codex`, `opencode`, `agy`), so it runs on the subscriptions you already pay for. The orchestrator is ~1,200 lines of readable Bash.

|  | fixbuddy | Copilot coding agent | claude-code-action | OpenHands resolver |
|---|---|---|---|---|
| Fix **and** review | two agents, cross-vendor (fixer ≠ reviewer) | one vendor | one vendor | one agent |
| Choice of agent | claude · codex · opencode · agy | Copilot's models | Claude only | bring your own LLM |
| Where it runs | your machine **or** a GitHub Action | GitHub cloud | GitHub Action | local / Docker |
| Infra required | bash · git · gh · jq | none (hosted) | GitHub Actions | Docker + API keys |
| Cost | your existing CLI subscriptions | paid Copilot (premium requests) | API / subscription | your API + compute |
| Sandbox isolation | no — runs on the host ([documented](#safety-model)) | yes (Actions runner) | yes (Actions runner) | yes (Docker) |
| Footprint | ~1,200 lines of Bash you can read | hosted SaaS | action + runtime | full framework |

**When _not_ to reach for fixbuddy:** if you need a managed sandbox or compliance guarantees, want a one-click GitHub-native experience, or run against issues from untrusted contributors — use one of the tools above. fixbuddy deliberately trades isolation for a small, transparent, local-first tool (see [Safety Model](#safety-model)). It fits a solo developer or small team batch-fixing well-scoped issues in their **own** repositories.

## How It Works

```text
VERIFY -> FIX -> REVIEW -> PUSH/PR -> optional auto-merge
   |       |        |
   |       |        +-- rejected: retry, then label fix:rejected
   |       +----------- blocked: label fix:blocked
   +------------------- false positive: close issue
```

1. **Verify**: the fix agent checks whether the issue is still real.
2. **Fix**: the fix agent creates a local commit on `fix/issue-N`.
3. **Review**: the review agent reviews the committed diff and runs project checks.
4. **PR**: fixbuddy pushes the branch and opens a PR.
5. **Merge handling**: if auto-merge is enabled, fixbuddy requests it. `fix:applied` is added only when GitHub reports the PR as merged. Open PRs are labeled `fix:pr-open` to avoid duplicate work.

## Quick Start

Install with the one-liner (macOS and Linux, including WSL2):

```bash
curl -fsSL https://raw.githubusercontent.com/Codevena/fixbuddy/v0.6.0/install.sh | bash
```

This downloads the pinned `v0.6.0` scripts into `~/.local/bin` (or `/usr/local/bin`), makes them executable, and prints a PATH hint if needed. Override the location with `| bash -s -- --prefix /custom/bin` or track the latest commit with `--ref main`.

**Prefer to read before you run?** The installer is short — inspect it first, then run it:

```bash
curl -fsSL https://raw.githubusercontent.com/Codevena/fixbuddy/v0.6.0/install.sh -o install.sh
less install.sh        # read it
bash install.sh        # then run it
```

The installer verifies each downloaded script against the pinned `SHA256SUMS` (download integrity — see [Safety Model](#safety-model)).

Then run:

```bash
fixbuddy-wizard.sh
```

### Developer install

To modify the scripts, clone the repository instead:

```bash
git clone <your-fork-or-upstream-url> fixbuddy
cd fixbuddy
chmod +x fixbuddy.sh fixbuddy-wizard.sh
./fixbuddy-wizard.sh
```

Direct usage:

```bash
./fixbuddy.sh \
  --repo owner/repo \
  --project ~/code/repo \
  --severity high \
  --fix-agent claude \
  --review-agent codex \
  --max 10 \
  --yes
```

Start with `--dry-run` or `--max 1` on a new repository.

## Requirements

- `bash`
- `git`
- [`gh`](https://cli.github.com) authenticated with access to the target repository
- [`jq`](https://jqlang.github.io/jq/)
- At least one supported agent CLI

Both `--fix-agent` and `--review-agent` must be installed. They may point to the same CLI, but using different agents gives a more independent review.

## Supported Agents

| Agent | Invocation | Notes |
| --- | --- | --- |
| `claude` | `claude --dangerously-skip-permissions -p -` | Full tool access. |
| `codex` | `codex exec --dangerously-bypass-approvals-and-sandbox` | Full tool access. |
| `opencode` | `opencode run --dangerously-skip-permissions` | Full tool access. |
| `agy` | `agy --dangerously-skip-permissions --add-dir <project> -p ...` | Antigravity CLI (Gemini's successor). Verify/review add `--sandbox` (terminal restrictions — not read-only). |

These agent invocations are intentionally powerful. Run fixbuddy only against repositories and issue content you trust.

## Options

| Flag | Description | Default |
| --- | --- | --- |
| `--repo <owner/repo>` | Target GitHub repository | required |
| `--project <path>` | Local checkout of the target repository | required |
| `--label <name>` | Include only issues with this label. Repeatable | none |
| `--severity <level>` | Include issues labeled `severity:<level>` | none |
| `--max <n>` | Maximum issues to process in this run | unlimited |
| `--fix-agent <agent>` | `claude`, `codex`, `opencode`, or `agy` | `claude` |
| `--review-agent <agent>` | `claude`, `codex`, `opencode`, or `agy` | `codex` |
| `--max-retries <n>` | Retry count after review rejection | `1` |
| `--agent-timeout <secs>` | Wall-clock timeout per agent call | `1200` |
| `--crash-abort <n>` | Abort after consecutive agent crashes | `3` |
| `--base <branch>` | PR base branch | auto-detect |
| `--issue <N>` | Process only this issue number. Repeatable; dedup filters and `--label`/`--severity` still apply. Warns for requested numbers that are not found, closed, or already labeled non-actionable | none |
| `--check-cmd <cmd>` | Shell command to run as a test gate after each fix commit and before review. Repeatable. A non-zero exit is treated as a review rejection: output is fed back to the fix agent and the attempt is retried; if the retry budget is exhausted the issue is labeled `fix:rejected`. Because review and PR are only reached after all checks pass, checks also gate auto-merge. Commands run in `$PROJECT` and are operator-trusted (same trust level as CLI flags) | none |
| `--auto-merge` | Enable auto-merge, overriding a config `auto_merge = false` | off |
| `--no-auto-merge` | Open PRs without requesting auto-merge | off |
| `--skip-label <label>` | Skip issues with this label | `fix:applied` |
| `--dry-run` | List issues that would be processed, with the planned config, without making any changes (no labels created, no issues edited) | off |
| `-y`, `--yes` | Skip confirmation | off |

## Configuration file

fixbuddy reads `key = value` config files (blank lines and `#` comments ignored) from two locations, applied in precedence order from lowest to highest:

1. `~/.fixbuddy/config` — global defaults applied to every run
2. `./.fixbuddy.conf` — per-project config in the current working directory (the common case is running fixbuddy from the repo root)
3. CLI flags — always win over any config value

**Format example:**

```ini
# .fixbuddy.conf
repo        = owner/repo
project     = /home/user/code/repo
fix_agent   = claude
review_agent = codex
max         = 10
severity    = high
auto_merge  = true
label       = bug
check_cmd   = pnpm test
check_cmd   = pnpm typecheck
```

**Allowlisted keys** (unknown keys warn and are ignored):

| Key | Equivalent flag | Notes |
| --- | --- | --- |
| `repo` | `--repo` | |
| `project` | `--project` | |
| `fix_agent` | `--fix-agent` | |
| `review_agent` | `--review-agent` | |
| `max` | `--max` | |
| `max_retries` | `--max-retries` | |
| `agent_timeout` | `--agent-timeout` | |
| `crash_abort` | `--crash-abort` | |
| `base` | `--base` | |
| `severity` | `--severity` | |
| `skip_label` | `--skip-label` | |
| `auto_merge` | `--auto-merge` / `--no-auto-merge` | accepts `true` or `false` |
| `label` | `--label` | additive (see below) |
| `check_cmd` | `--check-cmd` | additive (see below) |

**Scalar keys** (all keys except `label` and `check_cmd`): CLI value wins; last writer wins across config files (project overrides global).

**Additive keys** (`label`, `check_cmd`): config entries and CLI entries are combined, not replaced. A config `label = bug` plus `--label security` on the CLI results in an AND filter for both labels. There is no way to remove a config-provided label or check command from the CLI.

**Security note:** config files are operator-controlled and parsed without `eval` or `source`. Values are assigned as plain strings, so a config containing shell metacharacters (e.g. `$(...)`) cannot execute code. `check_cmd` entries are run by fixbuddy itself, consistent with the same operator-trust model as CLI flags — only issue *content* is treated as untrusted input.

**Wizard:** running `fixbuddy-wizard.sh` offers to save the collected settings to `./.fixbuddy.conf` at the end. The absolute path written is printed, and a warning is shown if the current directory differs from `--project`, since fixbuddy reads the project config from wherever it is launched.

## Labels

fixbuddy creates and manages these labels:

- `fix:applied`: the PR was confirmed as merged.
- `fix:pr-open`: fixbuddy opened a PR that has not merged yet.
- `fix:blocked`: an agent could not proceed, crashed, or timed out.
- `fix:false-positive`: verification found the issue is stale or invalid.
- `fix:rejected`: the reviewer rejected all fix attempts.

`fix:blocked` issues are eligible for future runs. `fix:applied`, `fix:pr-open`, `fix:false-positive`, and `fix:rejected` are skipped by default.

## Safety Model

- fixbuddy refuses to start if the target checkout has a dirty working tree.
- Each issue gets a fresh `fix/issue-N` branch.
- Files written during the verify stage (read-only by contract, but no agent CLI enforces that) are stashed before the fix branch is created.
- The fix agent is instructed to stage only relevant files and to avoid generated artifacts.
- The review agent receives the committed diff and must reject unrelated changes.
- If the reviewer creates commits, the branch is reset to the reviewed commit — only the reviewed commit is ever pushed.
- Push happens only after review approval.
- `fix:applied` is added only after GitHub reports that the PR is merged.
- Cleanup stashes uncommitted agent output before deleting temporary branches.

This is automation with shell access, not a sandbox boundary. Treat issue text, repository code, and agent tools as trusted inputs.

## Logs

Each run writes logs to:

```text
~/.fixbuddy/runs/<UTC-timestamp>-<pid>/
```

Useful markers:

- `[fixbuddy-watchdog]`: an agent exceeded `--agent-timeout`.
- `[fixbuddy-crash]`: an agent exited without a `DONE-*` marker.
- `===== RUN_AGENT`: start of an agent call.
- `===== END`: end of an agent call and return code.

## Examples

Preview targets (no writes at all — no labels created, no issues edited):

```bash
./fixbuddy.sh --repo owner/repo --project ~/code/repo --severity high --dry-run
```

Fix specific issues only:

```bash
./fixbuddy.sh --repo owner/repo --project ~/code/repo --issue 42 --issue 57
```

Add a test gate so fixes are never reviewed unless all checks pass:

```bash
./fixbuddy.sh --repo owner/repo --project ~/code/repo \
  --check-cmd 'pnpm test' --check-cmd 'pnpm typecheck' \
  --fix-agent claude --review-agent codex
```

Open PRs but do not request auto-merge:

```bash
./fixbuddy.sh --repo owner/repo --project ~/code/repo \
  --fix-agent claude --review-agent codex \
  --no-auto-merge --max 5
```

Use one agent for both roles:

```bash
./fixbuddy.sh --repo owner/repo --project ~/code/repo \
  --fix-agent claude --review-agent claude --max 3
```

Use agy (Antigravity CLI) as a cross-vendor reviewer:

```bash
./fixbuddy.sh --repo owner/repo --project ~/code/repo \
  --fix-agent claude --review-agent agy
```

## Use in GitHub Actions

fixbuddy ships a composite action, so you can run the pipeline from a workflow with a single `uses:` line.

```yaml
name: fixbuddy
on:
  workflow_dispatch:
  schedule:
    - cron: '0 6 * * 1'   # every Monday 06:00 UTC

jobs:
  fix:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
      issues: write
    env:
      ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
      OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
    steps:
      - uses: actions/checkout@v4

      # Prerequisites in CI — runners do not ship the agent CLIs. See the note below.
      - name: Install agent CLIs
        run: |
          npm install -g @anthropic-ai/claude-code
          npm install -g @openai/codex

      - uses: Codevena/fixbuddy@v1
        with:
          severity: high
          max: "5"
          fix-agent: claude
          review-agent: codex

      - name: Upload run logs
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: fixbuddy-logs
          path: fixbuddy-logs/
          if-no-files-found: ignore
```

### Permissions

The action drives `gh` with the workflow token, which needs more than the default read-only scopes. Set this exact block on the job (or workflow):

```yaml
permissions:
  contents: write        # push fix/issue-N branches
  pull-requests: write   # open PRs, request auto-merge
  issues: write          # manage fix:* labels
```

If `github-token` is empty the action fails fast with a clear error. Pass a different token through the `github-token` input when you need broader scope (for example a PAT for cross-repo runs).

### Prerequisites in CI

GitHub-hosted runners do **not** ship the agent CLIs (`claude`, `codex`, `opencode`, `agy`). Install whichever ones you pass to `fix-agent` / `review-agent` in a step *before* the `Codevena/fixbuddy` step — pinning them to a known version is recommended. Consult each agent's own documentation for the current install command. Note that `agy` has no npm package — install it with the vendor script: `curl -fsSL https://antigravity.google/cli/install.sh | bash`.

The action does not read API keys itself; each agent CLI reads its own environment variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and so on). Provide them from `secrets` at the job or workflow level, as shown above.

The action does **not** run `actions/checkout` for you — your workflow controls the checkout. fixbuddy refuses to run against a dirty working tree, but a fresh CI checkout is always clean, so this is a non-issue in practice.

A `dry-run: "true"` input lists target issues (with the planned config) without invoking any agent and without making any changes — useful for a first run, and it needs no API keys or agent CLIs at all.

### Logs

The action copies each run's logs into `fixbuddy-logs/` in the workspace. Add an `actions/upload-artifact` step (see the snippet) to keep them after the runner is torn down.

### Inputs

| Input | Maps to | Default |
| --- | --- | --- |
| `repo` | `--repo` | current repository |
| `project-path` | `--project` | `.` |
| `fix-agent` | `--fix-agent` | `claude` |
| `review-agent` | `--review-agent` | `codex` |
| `severity` | `--severity` | none |
| `label` | `--label` (comma-separated, becomes repeated flags) | none |
| `max` | `--max` | `5` |
| `base-branch` | `--base` | auto-detect |
| `auto-merge` | `--no-auto-merge` when `false`; `--auto-merge` when `true` | `true` |
| `dry-run` | `--dry-run` when `true` — lists targets, makes no changes | `false` |
| `github-token` | `GH_TOKEN` for `gh` | `${{ github.token }}` |

Running fixbuddy in CI gives AI agents repository write access through whatever token you hand them. Read [SECURITY.md](SECURITY.md) before enabling this on a repository that matters.

## FAQ

**Does fixbuddy touch the base branch directly?**
No. It works on `fix/issue-N` branches and opens PRs against the base branch.

**What happens when auto-merge is requested but checks are still running?**
The PR remains open with `fix:pr-open`. GitHub will merge it later if branch protection and checks allow it.

**What happens if CI fails?**
The PR stays open. The issue keeps `fix:pr-open`, so a later fixbuddy run does not create a duplicate PR.

**Can I use fixbuddy in GitHub Actions?**
Yes — use the composite action with `uses: Codevena/fixbuddy@v1`. See [Use in GitHub Actions](#use-in-github-actions) for the workflow snippet, required `permissions:` block, and CI prerequisites.

**Does it support Windows?**
Native Windows is not tested. WSL2 is the recommended Windows environment.

## Roadmap

- Optional notifications for run summaries
- Explicit resume mode for interrupted runs (interrupting a run cleans up the in-progress branch; the issue is retried automatically on the next run)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
