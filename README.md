# fixbuddy v0.3.1

Autonomous GitHub issue fixer with **two-agent self-review pipeline** — so humans don't need to review every PR.

## Quick start (beginner wizard)

```bash
./fixbuddy-wizard.sh
```

The wizard asks a few questions (repo, project path, severity, mode, batch size, reviewer), validates prerequisites, shows the exact command it will run, and launches fixbuddy. Start there if you've never used fixbuddy before.

## Pipeline per issue

```
┌─────────┐   ┌─────────┐   ┌──────────┐   ┌──────────┐
│ VERIFY  │──▶│   FIX   │──▶│  REVIEW  │──▶│ PUSH/PR  │
│ (fixA)  │   │ (fixA)  │   │ (revA)   │   │  merge   │
└────┬────┘   └────┬────┘   └─────┬────┘   └──────────┘
     │             │              │
     ▼             ▼              ▼
   close       blocked      rejected → retry (1×)
   issue                         │
                                 ▼
                             give up + label
```

1. **VERIFY** — fix-agent reads the issue, checks the code. Emits `DONE-PROCEED`, `DONE-FALSE-POSITIVE` (auto-closes issue), or `DONE-BLOCKED`.
2. **FIX** — fix-agent creates branch `fix/issue-N`, implements fix, runs lint/build/test, local commit.
3. **REVIEW** — *independent* review-agent (fresh context, optionally different model) audits the diff. Can `DONE-APPROVED` or `DONE-REJECTED: <reason>`.
4. **RETRY** — on rejection, fix-agent gets a 2nd shot with reviewer feedback.
5. **PUSH** — on approval: push branch, create PR with `Closes #N`, enable auto-merge (CI gates regressions).

## Install

```bash
git clone <this> ~/fixbuddy
chmod +x ~/fixbuddy/fixbuddy.sh ~/fixbuddy/fixbuddy-wizard.sh
```

## Prerequisites

- `gh` authenticated (`gh auth login`)
- `jq`
- Agent CLIs — both `--fix-agent` and `--review-agent` must be installed (defaults: `claude` + `codex` for cross-agent review). If only one agent is installed, pass it for both (e.g. `--fix-agent claude --review-agent claude`). Supported: `claude`, `codex`, `opencode`, `gemini`.
- Local git clone of target repo with a **clean working tree** (fixbuddy refuses to run on a dirty tree — commit or stash your WIP first)

## Usage

```bash
./fixbuddy.sh \
  --repo OWNER/REPO \
  --project ~/path/to/repo \
  --severity critical \
  --max 1
```

## All options

| Flag | Description | Default |
|------|-------------|---------|
| `--repo <owner/repo>` | Target repo | **required** |
| `--project <path>` | Local checkout | **required** |
| `--label <name>` | Filter issues (repeatable) | none |
| `--severity <level>` | Filter by `severity:<level>` label | none |
| `--max <n>` | Cap processed issues | unlimited |
| `--fix-agent <agent>` | `claude` \| `codex` \| `opencode` \| `gemini` | `claude` |
| `--review-agent <agent>` | `claude` \| `codex` \| `opencode` \| `gemini` | `codex` |
| `--max-retries <n>` | Retries on review reject | 1 (→ 2 total attempts) |
| `--agent-timeout <secs>` | Wall-clock timeout per agent invocation | 1200 (20 min) |
| `--crash-abort <n>` | Abort batch after N consecutive agent crashes | 3 |
| `--base <branch>` | PR base | auto-detect |
| `--no-auto-merge` | Create PR, don't auto-merge | auto-merge on |
| `--skip-label <lbl>` | Skip issues with this label | `fix:applied` |
| `--dry-run` | List only | off |
| `-y`, `--yes` | Skip confirmation | off |

## Labels managed

- `fix:applied` — fix merged via fixbuddy
- `fix:blocked` — agent hit a decision it can't make, **or** an agent crashed / timed out (usage-limit, transport error, watchdog). Blocked issues auto-requeue on the next run.
- `fix:false-positive` — verify-phase rejected as not-a-bug
- `fix:rejected` — all retry attempts failed review

## Safety guarantees

- Each fix lives on its own branch (`fix/issue-N`)
- Push only happens AFTER independent review approves
- Auto-merge waits for CI if branch protection requires checks
- Never force-push, never amend, never touch base branch directly
- Reviewer must RUN lint/build/test — approving a broken build is a prompt failure, not a silent one
- Retry budget caps runaway loops

## Supported agents

| Agent | Invocation | Notes |
|-------|-----------|-------|
| `claude` | `claude --dangerously-skip-permissions -p -` | Reliable fixer & reviewer. First choice. |
| `codex` | `codex exec --dangerously-bypass-approvals-and-sandbox` | Different blind spots from claude — great cross-agent reviewer. |
| `opencode` | `opencode run --dangerously-skip-permissions` | Newer, multi-model backend. Treat like claude/codex. |
| `gemini` | `gemini -p … --approval-mode {plan\|yolo}` | Runs **read-only** (`plan`) as verify/review agent; `yolo` only when used as fix-agent. Warned as fix-agent — it's an experimental choice. Best used as a cheap second-opinion reviewer. |

## Tuning the pipeline

**More paranoid** — reviewer on different agent + no auto-merge:
```bash
./fixbuddy.sh --repo X/Y --project ~/repo \
  --fix-agent claude --review-agent codex \
  --no-auto-merge --max 5
```

**Faster (single-agent)** — both phases use claude:
```bash
./fixbuddy.sh --repo X/Y --project ~/repo \
  --fix-agent claude --review-agent claude --max 10
```

**Target one specific lens**:
```bash
./fixbuddy.sh --repo X/Y --project ~/repo \
  --label "audit:security/auth-session"
```

## Crash handling (v0.3)

Agents can fail for transient reasons — codex hits a usage limit mid-review, an MCP transport drops, the network blips. Before v0.3 these surfaced as empty-reason rejects and consumed retry budget. Now:

- `run_agent` detects a nonzero exit with **no `DONE-*` marker** and returns `rc=125`.
- The `--agent-timeout` watchdog still uses `rc=124` (GNU `timeout` convention).
- Either value triggers `handle_agent_crash`: the issue gets labeled `fix:blocked`, a comment explains the failure class, the fix branch is cleaned up, and no retry budget is wasted.
- Issues with `fix:blocked` **auto-requeue on the next run** (the label does not exclude them from the queue).
- After `--crash-abort` consecutive crashes (default 3), the batch aborts with a fallback suggestion (e.g. switch `--review-agent`).

The operational flow becomes: run → some issues get blocked → wait for quota recovery (or switch reviewer) → rerun → blocked issues come back through the pipeline automatically. No label juggling needed.

## Running autonomously

For a hands-off pre-launch pass, drop `--max` and let fixbuddy drain the queue:

```bash
./fixbuddy.sh \
  --repo OWNER/REPO --project ~/path/to/repo \
  --severity high \
  --fix-agent claude --review-agent codex \
  --yes
```

If the reviewer hits a usage limit, the batch aborts after 3 crashes in a row with instructions to either wait for recovery or switch to `--review-agent claude`. Rerun with the same command — blocked issues pick up where they left off.

## Logs

Each run: `~/.fixbuddy/runs/<timestamp>-<pid>/issue-<N>.log` — full prompts + agent outputs per phase. Watchdog kills are tagged `[fixbuddy-watchdog]`, agent crashes `[fixbuddy-crash]`.

## Cost / budget notes

Each issue = 2–4 agent calls (1 verify, 1–2 fix, 1–2 review) × iterative Claude/Codex sessions with shell access. A CRITICAL batch of 10 issues can easily consume 30-60 minutes of agent wall-time and non-trivial session budget on Claude Max or Codex Plus.

Use `--max 1` initially to calibrate on your repo.
