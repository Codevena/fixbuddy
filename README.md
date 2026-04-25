# Fixbuddy

**A Bash orchestrator that turns GitHub issues into reviewed pull requests using two AI coding agents.**

[![version](https://img.shields.io/badge/version-0.3.2-blue.svg)](#)
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

## FAQ

**Does fixbuddy touch the base branch directly?**
No. It works on `fix/issue-N` branches and opens PRs against the base branch.

**What happens when auto-merge is requested but checks are still running?**
The PR remains open with `fix:pr-open`. GitHub will merge it later if branch protection and checks allow it.

**What happens if CI fails?**
The PR stays open. The issue keeps `fix:pr-open`, so a later fixbuddy run does not create a duplicate PR.

**Can I use fixbuddy in GitHub Actions?**
Yes, but the runner must have `gh`, `jq`, `git`, and the selected agent CLIs installed and authenticated. Review the security model before giving agents repository write access in CI.

**Does it support Windows?**
Native Windows is not tested. WSL2 is the recommended Windows environment.

## Roadmap

- Config file support
- GitHub Action wrapper
- More deterministic integration tests with mocked CLIs
- Optional notifications for run summaries
- Explicit resume mode for interrupted runs

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
