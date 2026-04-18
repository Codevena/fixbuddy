# fixbuddy

**Drain your GitHub issue backlog with two AI agents reviewing each other's work.**

[![version](https://img.shields.io/badge/version-0.3.1-blue.svg)](https://github.com/Codevena/fixbuddy/releases)
[![license](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![shell](https://img.shields.io/badge/shell-bash-black.svg)](fixbuddy.sh)
[![agents](https://img.shields.io/badge/agents-claude%20%7C%20codex%20%7C%20opencode%20%7C%20gemini-purple.svg)](#supported-agents)

fixbuddy reads open issues in a GitHub repo, fixes them on per-issue branches, and opens PRs — but **every fix is reviewed by an independent second AI agent** before it's allowed to merge. No single-agent blind spots. No silent "LGTM" on broken code. No "retry budget burned because codex crashed" nonsense.

Built as a real orchestrator, not a demo: in one 6-hour autonomous pre-launch pass, fixbuddy merged **43 PRs** across **7 consecutive batches** on a mid-sized Next.js codebase — with zero watchdog kills and full recovery from mid-batch rate-limit crashes.

---

## Why

AI coding assistants have gotten great at writing code. They're still terrible at reviewing their own work — same model, same blind spots, same hallucinations. If you've ever shipped a Claude-written PR that looked fine and broke production, you know.

fixbuddy's answer: **adversarial pairing**. Agent A proposes, Agent B audits. Fresh context. Different prompts. Ideally a different model family. The reviewer must actually **run** `lint + typecheck + build + test` before it's allowed to approve.

It also solves the other painful problem: **agent failures used to destroy your run**. Rate limits, MCP transport drops, watchdog timeouts — every one of these used to look like a "silent reject" and burn retry budget. fixbuddy detects crashes explicitly (rc=125), labels the issue `fix:blocked`, and **auto-requeues it on the next run**. You rerun with one command. Done.

---

## Pipeline (per issue)

```
┌─────────┐   ┌─────────┐   ┌──────────┐   ┌──────────┐
│ VERIFY  │──▶│   FIX   │──▶│  REVIEW  │──▶│ PUSH/PR  │
│ (agent) │   │ (agent) │   │ (agent B)│   │  merge   │
└────┬────┘   └────┬────┘   └─────┬────┘   └──────────┘
     │             │              │
     ▼             ▼              ▼
   close       blocked      rejected → retry (1×)
   issue       (requeue)           │
                                   ▼
                           retry budget exhausted
                           → label + comment
```

1. **VERIFY** — Fix-agent reads the issue, inspects the code. Emits `DONE-PROCEED`, `DONE-FALSE-POSITIVE` (auto-closes stale findings), or `DONE-BLOCKED` (needs a human).
2. **FIX** — Fix-agent creates branch `fix/issue-N`, implements the patch, runs repo checks, local commit.
3. **REVIEW** — Review-agent audits the diff with fresh context. Must run lint / typecheck / build / tests. `DONE-APPROVED` or `DONE-REJECTED: <reason>`.
4. **RETRY** — On rejection, fix-agent gets a second shot with the reviewer's feedback injected into the prompt.
5. **PUSH** — Only after approval: push the branch, create a PR with `Closes #N`, enable auto-merge. CI gates regressions.

---

## Quick start

### Option 1: interactive wizard (recommended)

```bash
git clone https://github.com/Codevena/fixbuddy ~/fixbuddy
chmod +x ~/fixbuddy/fixbuddy.sh ~/fixbuddy/fixbuddy-wizard.sh
cd ~/fixbuddy
./fixbuddy-wizard.sh
```

The wizard checks prereqs, asks seven questions (repo, project path, severity, mode, batch size, fix-agent, reviewer), shows you the exact command it's about to run, and launches. That's the entire onboarding.

### Option 2: direct

```bash
./fixbuddy.sh \
  --repo your-org/your-repo \
  --project ~/code/your-repo \
  --severity high \
  --fix-agent claude \
  --review-agent codex \
  --max 10 \
  --yes
```

---

## Prerequisites

- [`gh`](https://cli.github.com) authenticated (`gh auth login`)
- [`jq`](https://stedolan.github.io/jq/)
- `git`
- **At least one** agent CLI — both `--fix-agent` and `--review-agent` must be installed (defaults are `claude` + `codex` for adversarial cross-agent review). If only one agent is available, pass it for both (e.g. `--fix-agent claude --review-agent claude`). Supported: [`claude`](https://claude.com/claude-code), [`codex`](https://developers.openai.com/codex/cli), [`opencode`](https://opencode.ai/), [`gemini`](https://geminicli.com/).
- A local git clone of the target repo with a **clean working tree**. fixbuddy refuses to run on dirty trees — it commits on per-issue branches and can't safely share the worktree with WIP.

---

## Features

- **Multi-agent, mix-and-match.** Fix with claude, review with codex. Or any combination — opencode, gemini, same-agent, whatever.
- **Gemini runs read-only** when used as verify/review (via `--approval-mode plan`). It can look, not touch. Makes it a cheap, safe second-opinion reviewer.
- **Agent-crash detection.** Rate limits, MCP transport drops, watchdog timeouts all become explicit `rc=125` → issue labeled `fix:blocked` → auto-requeues on next run. No retry budget wasted on crashes.
- **Wall-clock watchdog.** Any agent that exceeds `--agent-timeout` (default 20 min) gets `TERM` + 5s + `KILL`. No more 7-hour hangs.
- **Consecutive-crash abort.** After N crashes in a row (default 3), the batch stops with a clear fallback hint. Saves you from chewing quota on an unreachable provider.
- **Stash-based cleanup.** Crash-recovery uses `git stash` instead of `reset --hard` — any user WIP stays recoverable via `git stash list`.
- **Pre-flight dirty-tree refusal.** Won't silently merge your WIP into a fix branch.
- **Reviewer must run tests.** The review prompt explicitly requires `lint + typecheck + build + test` — a diff that compiles but misses the point is a REJECT.
- **Scoped to one issue per PR.** `fix/issue-N` branch, single PR, `Closes #N`. Nothing bundled. Nothing sneaky.
- **Full transparency.** Every prompt, every agent response, every decision logged at `~/.fixbuddy/runs/<timestamp>-<pid>/issue-<N>.log`.
- **Four labels, human-readable.** `fix:applied`, `fix:false-positive`, `fix:blocked`, `fix:rejected`. You always know what happened.

---

## Supported agents

| Agent | Invocation | Notes |
|-------|-----------|-------|
| `claude` | `claude --dangerously-skip-permissions -p -` | Reliable fixer and reviewer. Good first choice for both roles. |
| `codex` | `codex exec --dangerously-bypass-approvals-and-sandbox` | Different blind spots from claude — strong cross-agent reviewer. |
| `opencode` | `opencode run --dangerously-skip-permissions` | Open-source, multi-model backend. Behaves like claude/codex. |
| `gemini` | `gemini -p ... --approval-mode {plan\|yolo}` | Runs **read-only** (`plan`) as verify/review agent; `yolo` only when used as fix-agent. Warned when picked as fix-agent — it's experimental there. Best as a cheap, fast second-opinion reviewer. |

---

## All options

| Flag | Description | Default |
|------|-------------|---------|
| `--repo <owner/repo>` | Target repo | **required** |
| `--project <path>` | Local checkout | **required** |
| `--label <name>` | Filter issues (repeatable) | none |
| `--severity <level>` | Filter by `severity:<level>` label | none |
| `--max <n>` | Cap issues per run | unlimited |
| `--fix-agent <agent>` | `claude` \| `codex` \| `opencode` \| `gemini` | `claude` |
| `--review-agent <agent>` | `claude` \| `codex` \| `opencode` \| `gemini` | `codex` |
| `--max-retries <n>` | Fix retries on reviewer reject | 1 (→ 2 total attempts) |
| `--agent-timeout <secs>` | Wall-clock timeout per agent invocation | 1200 (20 min) |
| `--crash-abort <n>` | Abort batch after N consecutive agent crashes | 3 |
| `--base <branch>` | PR base | auto-detect |
| `--no-auto-merge` | Create PR, don't auto-merge | auto-merge on |
| `--skip-label <lbl>` | Skip issues with this label | `fix:applied` |
| `--dry-run` | List targets, don't execute | off |
| `-y`, `--yes` | Skip confirmation | off |

---

## Recipes

**Most paranoid** — cross-agent review, no auto-merge:
```bash
./fixbuddy.sh --repo X/Y --project ~/repo \
  --fix-agent claude --review-agent codex \
  --no-auto-merge --max 5
```

**Fast single-agent** — both stages use claude:
```bash
./fixbuddy.sh --repo X/Y --project ~/repo \
  --fix-agent claude --review-agent claude --max 10
```

**Target one audit lens** (e.g. security findings only):
```bash
./fixbuddy.sh --repo X/Y --project ~/repo \
  --label "audit:security/auth-session"
```

**Autonomous pre-launch drain** — no `--max`:
```bash
./fixbuddy.sh --repo X/Y --project ~/repo \
  --severity high --fix-agent claude --review-agent codex --yes
```

**Cheap second-opinion review** — gemini as read-only reviewer:
```bash
./fixbuddy.sh --repo X/Y --project ~/repo \
  --fix-agent claude --review-agent gemini
```

---

## Labels

fixbuddy manages four labels on your issues automatically:

- `fix:applied` — PR from fixbuddy was merged. Excluded from future runs.
- `fix:false-positive` — verify phase found the issue stale (already fixed / wrong evidence). Issue auto-closed with reasoning.
- `fix:blocked` — agent hit a decision it couldn't make autonomously, **or** an agent crashed / timed out. **Blocked issues auto-requeue on the next run.**
- `fix:rejected` — all retry attempts failed review. Needs human attention.

---

## Safety guarantees

- Each fix lives on its own `fix/issue-N` branch.
- Push happens **only** after the independent reviewer approves.
- Auto-merge waits for CI if branch protection requires checks.
- Never force-pushes, never amends, never touches the base branch directly.
- Reviewer must RUN lint/build/test — approving a broken build is a prompt failure, not a silent pass.
- Retry budget caps runaway loops (default: 1 retry → 2 total attempts per issue).
- Pre-flight refuses to run on a dirty worktree — you never lose WIP to a silent carry-over.
- Crash cleanup uses `git stash` so nothing is ever hard-reset or cleaned away.

---

## Crash handling

Agents fail. Codex hits a usage limit mid-review. The Anthropic API blips. MCP transport drops. Before v0.3 these looked like silent rejects and burned retry budget. Now:

- `run_agent` detects **nonzero exit with no `DONE-*` marker** → returns `rc=125`.
- The `--agent-timeout` watchdog uses `rc=124` (GNU `timeout` convention).
- Either code triggers `handle_agent_crash`: label `fix:blocked`, comment the failure class, stash-cleanup the fix branch, increment a consecutive-crash counter. No retry budget consumed.
- Blocked issues **auto-requeue** on the next run.
- After `--crash-abort` crashes in a row (default 3), the batch aborts with a fallback hint (e.g. "switch `--review-agent`").

Operational flow: run → some issues get blocked → wait for quota recovery or switch reviewer → rerun the same command → blocked issues pick up where they left off.

---

## Logs

Every run: `~/.fixbuddy/runs/<UTC-timestamp>-<pid>/issue-<N>.log` — full prompts and agent outputs per phase. Search for:

- `[fixbuddy-watchdog]` — a wall-clock timeout kill
- `[fixbuddy-crash]` — a detected agent crash (no DONE marker)
- `===== RUN_AGENT: <agent> [<stage>]` — entry point of each agent call
- `===== END <agent> (rc=<n>) =====` — exit point with return code

---

## Cost / budget notes

Each issue = 2–4 agent calls (1 verify, 1–2 fix, 1–2 review) × iterative agent sessions with shell access. A realistic batch of 10 audit issues consumes roughly **45–90 minutes of wall-clock time** and a non-trivial chunk of a Claude Max or Codex Plus monthly quota.

Start with `--max 1` to calibrate on your repo, then scale to `--max 10` batches for autonomous runs.

---

## FAQ

**Why two agents? Why can't one do both roles?**
Single-agent self-review is unreliable — same training, same blind spots, same hallucinations. A reviewer with a fresh context and (ideally) a different model family catches mistakes the writer missed. fixbuddy enforces that separation.

**What if both agents are wrong?**
The reviewer must **run** tests — `lint + typecheck + build + test`. A fix that passes tests and lint is already past the most common failure modes. If both agents conspire to ship something subtly wrong, your CI and eventually your users catch it. This is defense-in-depth, not magic.

**Does fixbuddy modify my main branch?**
Never. Every change is on `fix/issue-N`. PRs target the base branch; merges go through normal CI + branch protection.

**What happens if CI fails?**
The PR stays open. `fix:applied` is added only after the PR lands. Failed CI = human follow-up.

**Can I use it in GitHub Actions?**
Yes — run it in a workflow with a cron trigger and seed it with `--yes`. You'll need the four CLIs available in the runner image and appropriate auth. CI is a first-class scenario; the script exits with meaningful codes.

**How does it handle merge conflicts?**
It doesn't. If the target branch has moved such that the fix can't auto-merge, the PR stays open and `fix:applied` isn't added. Rerun later or resolve manually.

**Can I target only specific issue labels?**
Yes — `--label` is repeatable and `--severity` adds `severity:<level>`. Combine them freely.

**What about Windows?**
Haven't tested. It's pure bash + `git` + `gh` + `jq` + one of the agent CLIs. Should work in WSL2; native Windows PowerShell is unlikely.

---

## Roadmap

- Per-issue diff size budget (skip massive refactors automatically)
- Optional Slack / Discord webhook for run summaries
- Config file (`~/.fixbuddy.yml`) as an alternative to CLI flags
- `--resume` flag to explicitly continue a specific run
- GitHub Action wrapper

PRs welcome for any of these.

---

## Contributing

The entire orchestrator is ~650 lines of bash. Easy to read, easy to fork.

1. Fork, clone, branch.
2. `bash -n fixbuddy.sh` must pass.
3. If you touch `run_agent` or `process_issue`, trace the three paths (happy / crash / retry) in your PR description.
4. Open a PR with a clear description of the problem and the fix.

Bug reports: open an issue with a log snippet from `~/.fixbuddy/runs/`.

---

## Credits

Built out of frustration with single-agent AI coding loops. Inspired by:

- Pair programming's core insight that a second pair of eyes catches what the first misses.
- Unix's long tradition of small, sharp tools composed via CLI.
- Every pre-launch audit that produced more findings than a human could ever triage.

---

## License

MIT — see [LICENSE](LICENSE).
