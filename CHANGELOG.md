# Changelog

All notable changes to fixbuddy are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project aims to follow
[Semantic Versioning](https://semver.org/).

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

[0.5.0]: https://github.com/Codevena/fixbuddy/compare/v0.4.0...v0.5.0
