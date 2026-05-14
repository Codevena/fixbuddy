# Fixbuddy

**A Bash orchestrator that turns GitHub issues into reviewed pull requests using two AI coding agents.**

[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![shell](https://img.shields.io/badge/shell-bash-black.svg)](fixbuddy.sh)
[![agents](https://img.shields.io/badge/agents-claude%20%7C%20codex%20%7C%20opencode%20%7C%20gemini-purple.svg)](#supported-agents)

fixbuddy reads open GitHub issues, asks one agent to verify and fix each issue, asks a second agent to review the committed diff, then opens a pull request. If enabled, it requests auto-merge after review approval.

The goal is controlled automation: one issue per branch, one issue per PR, explicit labels for every outcome, and full logs for every agent call.

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
curl -fsSL https://raw.githubusercontent.com/Codevena/fixbuddy/v0.4.0/install.sh | bash
```

This downloads the pinned `v0.4.0` scripts into `~/.local/bin` (or `/usr/local/bin`), makes them executable, and prints a PATH hint if needed. Override the location with `| bash -s -- --prefix /custom/bin` or track the latest commit with `--ref main`.

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
| `gemini` | `gemini -p ... --approval-mode {plan\|yolo}` | Read-only style `plan` mode for verify/review; `yolo` for fix. |

These agent invocations are intentionally powerful. Run fixbuddy only against repositories and issue content you trust.

## Options

| Flag | Description | Default |
| --- | --- | --- |
| `--repo <owner/repo>` | Target GitHub repository | required |
| `--project <path>` | Local checkout of the target repository | required |
| `--label <name>` | Include only issues with this label. Repeatable | none |
| `--severity <level>` | Include issues labeled `severity:<level>` | none |
| `--max <n>` | Maximum issues to process in this run | unlimited |
| `--fix-agent <agent>` | `claude`, `codex`, `opencode`, or `gemini` | `claude` |
| `--review-agent <agent>` | `claude`, `codex`, `opencode`, or `gemini` | `codex` |
| `--max-retries <n>` | Retry count after review rejection | `1` |
| `--agent-timeout <secs>` | Wall-clock timeout per agent call | `1200` |
| `--crash-abort <n>` | Abort after consecutive agent crashes | `3` |
| `--base <branch>` | PR base branch | auto-detect |
| `--no-auto-merge` | Open PRs without requesting auto-merge | off |
| `--skip-label <label>` | Skip issues with this label | `fix:applied` |
| `--dry-run` | List target issues without changing anything | off |
| `-y`, `--yes` | Skip confirmation | off |

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
- The fix agent is instructed to stage only relevant files and to avoid generated artifacts.
- The review agent receives the committed diff and must reject unrelated changes.
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

Preview targets:

```bash
./fixbuddy.sh --repo owner/repo --project ~/code/repo --severity high --dry-run
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

Use Gemini as a read-only reviewer:

```bash
./fixbuddy.sh --repo owner/repo --project ~/code/repo \
  --fix-agent claude --review-agent gemini
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

GitHub-hosted runners do **not** ship the agent CLIs (`claude`, `codex`, `opencode`, `gemini`). Install whichever ones you pass to `fix-agent` / `review-agent` in a step *before* the `Codevena/fixbuddy` step — pinning them to a known version is recommended. Consult each agent's own documentation for the current install command.

The action does not read API keys itself; each agent CLI reads its own environment variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, and so on). Provide them from `secrets` at the job or workflow level, as shown above.

The action does **not** run `actions/checkout` for you — your workflow controls the checkout. fixbuddy refuses to run against a dirty working tree, but a fresh CI checkout is always clean, so this is a non-issue in practice.

A `dry-run: "true"` input lists target issues without invoking any agent — useful for a first run, and it needs no API keys or agent CLIs at all.

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
| `auto-merge` | `--no-auto-merge` when `false` | `true` |
| `dry-run` | `--dry-run` when `true` | `false` |
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

- Config file support
- More deterministic integration tests with mocked CLIs
- Optional notifications for run summaries
- Explicit resume mode for interrupted runs

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
