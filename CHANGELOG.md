# Changelog

All notable changes to fixbuddy are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project aims to follow
[Semantic Versioning](https://semver.org/).

## [0.7.1] - 2026-06-13

### Added
- **GitHub Action input `notify-cmd`** — exposes `--notify-cmd` to workflows.
  One command per line (newline-separated, NOT comma-separated: shell commands
  may legitimately contain commas; use a YAML block scalar for multiple). The
  action-smoke workflow exercises the wiring on every PR.

## [0.7.0] - 2026-06-12

### Added
- **`--notify-cmd <cmd>`** (repeatable) and additive config key `notify_cmd` —
  a run-summary notification hook for unattended runs. Commands run in the
  launch directory after the final summary (including after a crash-abort),
  receive `FIXBUDDY_*` env vars (counts, `FIXBUDDY_ABORTED`, log dir) plus a
  human-readable summary on stdin, and are operator-trusted (same model as
  `--check-cmd`). A failing command warns but never changes fixbuddy's exit
  code. Not fired for `--dry-run`, empty queues, or Ctrl-C.

### Changed
- README Roadmap retired: notifications shipped here, and explicit resume mode
  is intentionally not built — the label system already resumes interrupted
  runs (documented in a new FAQ entry).

## [0.6.0] - 2026-06-12

Google retires the Gemini CLI on 2026-06-18; its successor is the Antigravity
CLI (`agy`). fixbuddy v0.6.0 swaps the agent and gains an offline integration
test suite.

### Added
- **`agy` agent** (Antigravity CLI) as fix or review agent. Invocation details
  that matter: `--add-dir <project>` (agents launch from the operator's CWD),
  `--print-timeout` pinned 60s above `--agent-timeout` so fixbuddy's watchdog
  classifies timeouts (agy itself exits 0 on its internal timeout — fixbuddy
  also detects that output and treats it as `fix:blocked`/auto-requeue), and
  `--sandbox` on verify/review as defense in depth (agy has no read-only mode).
- **Integration tests** (`tests/integration.sh`) — deterministic, offline,
  zero new dependencies: stub `gh`/agent CLIs plus a local bare repo as
  `origin`, covering happy path, false positive, review rejection, check gate,
  dry-run read-only, and crash classification. Run in CI.

### Removed (breaking)
- **`gemini` agent.** Passing `gemini` (flag or config) now exits with a
  migration message. Replace `fix_agent`/`review_agent` values with `agy`.
  Note: agy in verify/review runs sandboxed but NOT read-only — the old
  `--approval-mode plan` has no equivalent in the Antigravity CLI.

### Security & robustness
- The two read-only-by-contract stages are now guarded deterministically (no
  agent CLI offers an enforced read-only mode): after **every** verify outcome
  (proceed, false positive, blocked, crash) worktree files the verify agent
  wrote are stashed and commits it created on the base branch are discarded,
  and the **review** branch is pinned to the reviewed commit — commits a
  reviewer creates are discarded, so only the reviewed commit is ever pushed.

## [0.5.0] - 2026-06-12

Security hardening from a full audit, plus five new features. No breaking changes
to existing flags.

### Added
- **`--issue N`** (repeatable) — fix specific issues, fetched directly via
  `gh issue view` (no 200-item list blind spot). Dedup filters and
  `--label`/`--severity` still apply; non-actionable numbers warn distinctly.
- **`--check-cmd 'CMD'`** (repeatable) — a deterministic test gate that runs in
  the project dir after the fix commit and before review. A non-zero exit is
  treated like a review rejection (retried with the output as feedback, then
  `fix:rejected` on exhaustion), so it also gates auto-merge. Output is capped.
- **Config files** — `~/.fixbuddy/config` then `./.fixbuddy.conf`, safe-parsed
  with no `eval`/`source`; CLI flags override. The wizard offers to write one.
- **`--auto-merge`** flag — explicit counterpart to `--no-auto-merge`, so a
  config `auto_merge = false` can be overridden from the CLI.
- **`fix:needs-human`** label — separates deterministic blockers (human needed)
  from `fix:blocked` (crash/timeout, auto-requeues).
- **Ctrl-C/abort handling** — an interrupted run kills the in-flight agent,
  cleans up the local branch, and resumes the issue on the next run.

### Changed
- **`--dry-run` is now fully read-only** — it previously created labels and ran
  the unstick scan before the dry-run check. It now mutates nothing and prints
  the planned config (including `--check-cmd` strings) and respects `--max`.
- CI uses `actions/checkout@v5` (Node 24); `main` has branch protection.

### Fixed (security & robustness)
- Auto-merge no longer falls back to an immediate squash that bypassed CI.
- Issue **titles** are sanitized and marked untrusted in agent prompts
  (prompt-injection vector); `GH_TOKEN`/`GITHUB_TOKEN` are stripped from agent
  environments; the review diff is wrapped in a sentinel block.
- Crash on stock macOS Bash 3.2 (empty array under `set -u`) fixed.
- BSD/macOS `sed` portability; numeric-option validation; fail-closed on `gh`
  errors; base-branch auto-detect works in GitHub Actions; `gh auth setup-git`
  so a custom `github-token` reaches `git push`.
- Reviewer feedback is no longer truncated to its first line; watchdog timeout
  classification fixed; stale `fix:blocked`/`fix:rejected` labels are removed at
  success endpoints.

## [0.4.0] and earlier

Predate this changelog. See the git history and the `v0.4.0` / `v0.3.2` tags.

[0.7.1]: https://github.com/Codevena/fixbuddy/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/Codevena/fixbuddy/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/Codevena/fixbuddy/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Codevena/fixbuddy/compare/v0.4.0...v0.5.0
