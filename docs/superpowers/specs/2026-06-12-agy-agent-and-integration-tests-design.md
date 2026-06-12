# Design: agy agent (gemini replacement) + integration tests — v0.6.0

Date: 2026-06-12. Status: approved scope (user chose: replace gemini entirely;
ship agy support plus deterministic integration tests).

## Background and research

Google retires the Gemini CLI on **2026-06-18** for all non-Enterprise users
([transition announcement](https://developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli/)).
The successor is the **Antigravity CLI**, binary `agy` — a closed-source Go
binary installed via `curl -fsSL https://antigravity.google/cli/install.sh | bash`
(no npm package).

Behavior verified locally against the installed `agy` (2026-06-12):

| Aspect | gemini (old) | agy (new) |
| --- | --- | --- |
| Non-interactive call | `gemini -p "<prompt>" --approval-mode <mode> --output-format text` | `agy [flags] -p "<prompt>"` — no `--output-format` flag |
| Read-only mode | `--approval-mode plan` | **none** — `--sandbox` enables "terminal restrictions" but still allows workspace file writes and benign shell commands |
| Workspace | implicit CWD | `--add-dir <dir>` (repeatable) adds directories to the workspace |
| Internal timeout | none | `--print-timeout`, default **5m** (Go duration syntax, e.g. `1260s`) |
| Exit code on its internal timeout | n/a | **0** (!) with `Error: timed out waiting for response` on output |
| Permission prompts in print mode | n/a | workspace reads/writes/shell ran without prompting in tests; `--dangerously-skip-permissions` auto-approves everything |

Two of these are correctness traps for fixbuddy:

1. agy's default 5-minute print timeout fires **before** fixbuddy's 20-minute
   watchdog, and
2. agy exits **0** on that timeout, so `run_agent`'s crash classifier would see
   rc=0 with no `DONE-*` marker → the issue would be labeled `fix:needs-human`
   (never retried) instead of `fix:blocked` (auto-requeue) for what is a
   transient condition.

## Decisions

- **gemini is removed, not deprecated.** `agy` replaces it in the supported
  agent set (`claude | codex | opencode | agy`). A user passing `gemini` gets a
  targeted error explaining the retirement and pointing at `agy`, instead of a
  generic "unsupported agent".
- **v0.6.0** (breaking change for `fix_agent = gemini` configs, documented in
  the changelog).

## Component changes

### fixbuddy.sh

- Header comment, agent validation list, and CLI presence check: `gemini` →
  `agy`. The validation `case` gets an explicit `gemini)` arm that errors with
  a migration message (Gemini CLI retired 2026-06-18 → install Antigravity CLI,
  use `agy`).
- The "gemini as fix-agent is experimental" warning block is removed — agy is a
  full coding agent and is treated like opencode.
- `run_agent`:
  - `gem_mode` (plan/yolo) logic is removed.
  - New invocation, flags before the prompt:

    ```bash
    agy)
      agy_args=(--dangerously-skip-permissions --add-dir "$PROJECT"
                --print-timeout "$((AGENT_TIMEOUT+60))s")
      case "$stage" in verify|review) agy_args+=(--sandbox) ;; esac
      env -u GH_TOKEN -u GITHUB_TOKEN agy "${agy_args[@]}" -p "$prompt" \
        </dev/null >"$outfile" 2>&1 &
      ;;
    ```

    `--print-timeout` sits 60s above the watchdog so the watchdog always fires
    first and classifies rc=124 correctly. `--sandbox` on verify/review is
    defense-in-depth replacing the old plan mode (and is documented honestly as
    NOT read-only). `--add-dir "$PROJECT"` is required because fixbuddy launches
    agents from the operator's CWD, not from the project.
  - Belt-and-braces timeout reclassification after the watchdog marker check,
    scoped to agy: rc=0 plus a `^Error: timed out waiting for response` line in
    the output → rc=124.

### fixbuddy-wizard.sh

- Agent lists (`claude codex opencode gemini` ×3) → `claude codex opencode agy`.
- gemini-specific labels/notes removed; reviewer note for agy mentions the
  sandbox. Banner/header bumped to v0.6.0.

### action.yml / README.md

- Input descriptions and docs: `claude | codex | opencode | agy`.
- README: badge, "Why fixbuddy" CLI list + comparison row, Supported Agents
  table (agy invocation incl. sandbox note), the "Gemini as a read-only
  reviewer" example becomes an agy cross-vendor-reviewer example, CI
  prerequisites note that agy installs via the curl script (no npm), config
  example unchanged keys. A short migration note (gemini → agy) in the
  changelog section of the README is NOT needed; CHANGELOG.md carries it.

### Integration tests (new)

`tests/integration.sh` — pure Bash, zero new dependencies, deterministic and
offline. Reuses the proven approach of `docs/demo/bin/{agent,gh}`:

- **Fixture**: a temp dir holding a bare repo (`origin.git`) plus a working
  clone as `$PROJECT`, so branch creation, commits, and `git push` are real.
- **Stub `gh`**: first on `PATH`; serves canned JSON for `issue list/view`,
  `pr list/view`, `repo view`; records every mutating call (`label create`,
  `issue edit/comment/close`, `pr create/merge`) to a mutation log the
  assertions read.
- **Stub agents** (`claude`, `codex`, `agy` — one script, behavior switched on
  `$0` and scenario env var): parse the stage from the prompt (verify / fix /
  review), emit the scenario's `DONE-*` markers, and for the fix stage create a
  real commit in `$PROJECT`. The agy stub also asserts it received the expected
  agy-specific flags (`--add-dir`, `--print-timeout`, sandbox on verify/review).
- **Scenarios**:
  1. happy path → PR created, auto-merge requested, `fix:pr-open` label
  2. false positive → issue closed + `fix:false-positive`
  3. review rejected (all attempts) → `fix:rejected`, branch cleaned up
  4. `--check-cmd` failure → treated as rejection, feedback fed back
  5. `--dry-run` → zero mutations recorded
  6. agent crash (rc=1, no marker) → `fix:blocked` (auto-requeue path)
- **CI**: new `integration` job in `.github/workflows/ci.yml` running the
  suite on ubuntu-latest.

### Release housekeeping

- Version bumps: `fixbuddy.sh` (`VERSION` + header), wizard (header + banner),
  `install.sh` `DEFAULT_REF="v0.6.0"`, README quick-start one-liner.
- Regenerate `SHA256SUMS`.
- `CHANGELOG.md`: v0.6.0 entry — Added (agy agent, integration tests),
  Removed/**Breaking** (gemini agent; migration note for configs), Changed
  (docs).
- `findings.md` → `docs/audit/2026-06-10-findings.md`; `NEXT_SESSION.md`
  updated to the post-v0.6.0 state.
- Tagging (`v0.6.0`, floating `v1`) and pushing happen only after explicit user
  approval, per workflow rules.

## Error handling

- agy missing at runtime → existing presence-check error path (exit 2).
- agy internal timeout → reclassified rc=124 → `fix:blocked` + auto-requeue
  (same semantics as a watchdog kill).
- `gemini` passed via flag or config → exit 2 with migration message (config
  files share the same validation, so stale configs fail fast and clearly).

## Testing

- `bash -n` + `shellcheck` (plain severity, mirroring CI) for both scripts and
  the new test files.
- `tests/integration.sh` green locally and in CI.
- One real smoke check of the agy invocation shape against the installed CLI
  (already performed during research; re-verified after implementation).
- Full Definition-of-Done review pipeline (Codex ×2, Claude ×2) before commit.
