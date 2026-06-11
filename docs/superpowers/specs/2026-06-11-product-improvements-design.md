# fixbuddy Product Improvements — Design

Date: 2026-06-11
Status: Approved (design), pending implementation plan

Five independent improvements to `fixbuddy.sh` (and `fixbuddy-wizard.sh`), bundled into one
round. Each is small-to-medium and touches a distinct region of the script. All line numbers
reference the post-audit state of `fixbuddy.sh` (commit `5cadeb7` and later) and are
indicative — implementation re-locates the exact spots.

## Goals

1. Make `--dry-run` truly read-only (currently a bug: it mutates labels before the dry-run check).
2. Add `--issue N` to target specific issues.
3. Add `--check-cmd` for a deterministic test gate before review/push.
4. Add a Ctrl-C/abort trap that cleans up the in-flight branch so the next run resumes.
5. Add `.fixbuddy.conf` config files (safe-parsed) plus wizard integration.

## Non-Goals

- No GitLab/forge abstraction, no parallelism/worktrees, no cost tracking (separate future work).
- No change to the agent invocation, prompt builders, or the label state machine beyond what
  each feature below requires.

---

## 1. Read-only `--dry-run`

**Problem.** `$DRY_RUN` is only checked at `fixbuddy.sh:257`, but two mutating blocks run before
it: the control-label creation loop (`175-184`, `gh label create --force`) and the
fix:pr-open unstick scan (`186-221`, `gh issue edit --remove-label`). README/action.yml promise
"without changing anything". The issue fetch (`224-255`) is read-only.

**Design.**
- Wrap the label-creation block and the unstick scan in `if ! $DRY_RUN; then … fi`. Suppress
  their `info` lines ("Scanning for stuck…") under dry-run.
- Keep the read-only fetch where it is; the dry-run exit stays after the fetch.
- Improve the dry-run report (`257-262`):
  - Print the planned config (fix/review agent, base branch, auto-merge, check-cmds) the run
    *would* use — mirror the confirmation block at `264-273`.
  - Respect `--max`: if `MAX` is set, show that the run would stop after `MAX` issues; list the
    first `MAX` (or all when unset) instead of a silent `head -20`, and print the total
    actionable count explicitly so nothing is hidden.

**Error handling.** None new; fetch errors already fail closed (W4).

**Test.** Run `--dry-run` against a repo and assert no labels are created and no
`gh issue edit` is called (CI smoke test already runs dry-run on a runner with no agent CLIs).

---

## 2. `--issue N`

**Design.**
- New repeatable flag `--issue N` → `ISSUES+=("$2")`. Validate each value as a positive integer
  in the validation block (alongside the W3 numeric checks): non-numeric → `err` + exit 2.
- When `ISSUES` is non-empty, **fetch each requested issue directly** (`gh issue view N --repo
  "$REPO" --json number,title,labels,url,state,body`) instead of relying on the 200-item
  `gh issue list` page (`224`). This guarantees a requested issue outside the first list page is
  never silently missed (Codex NICE-TO-HAVE). Assemble these into the same JSON shape the loop
  consumes.
- The dedup filters (`fix:applied`, `fix:pr-open`, `fix:needs-human`, `fix:rejected`,
  `fix:false-positive`, umbrella/meta) **remain active** on the directly-fetched issues, and
  `--label`/`--severity` still apply as additional AND constraints.
- For each requested number, `warn` distinctly when it is not found (no such issue / not in
  `$REPO`), closed, or filtered out as non-actionable (already `fix:applied`, etc.), so a silent
  skip never looks like success.

**Test.** `--issue` + `--dry-run` lists only the requested, actionable issues and warns about
requested-but-skipped numbers.

---

## 3. `--check-cmd` (deterministic test gate)

**Design.**
- New repeatable flag `--check-cmd 'pnpm test'` → `CHECK_CMDS+=("$2")`.
- Helper `run_checks()`:
  - For each cmd: `( cd "$PROJECT" && eval "$cmd" ) >tmp 2>&1`; capture combined output.
  - Return non-zero on the first failing command; expose the failing command + its output to the
    caller (via stdout / a global). `eval` is acceptable: `--check-cmd` is operator-supplied
    (same trust level as any CLI flag), unlike attacker-controlled issue content. This is
    documented in the help text and the security note.
  - **Output cap:** tail the last ~200 lines / ~16 KB of combined output before handing it to the
    caller (mirrors the 500 KB diff cap at `755-760`), so a huge test log cannot bloat the fix
    prompt, the GitHub comment, or a shell variable (Codex IMPORTANT).
- **Integration point** (in `process_issue`, the fix→review retry loop). The loop increments
  `attempt` at its top (`686-687`) and the exhausted-budget reject path lives at `823-838`;
  `--check-cmd` must **reuse that exact machinery, not a parallel budget**. After the
  `DONE-FIX-APPLIED` marker check and the `commit_count` verification (`740-749`), and **before**
  the review block — i.e. before the diff capture / diff-cap / worktree stash and before
  `info "[#$num] REVIEW"` (`751-779`) so a failing local gate is never recorded as a review
  attempt (Codex IMPORTANT):
  - If `CHECK_CMDS` is non-empty, run `run_checks`.
  - On failure: set the **same** `feedback` variable the `DONE-REJECTED` branch uses (a labelled
    block: "Project checks failed:\n<cmd>\n<capped output>") and fall through into the identical
    reject/continue path — same `cleanup_branch`, same loop-continue, and on exhausted budget the
    same `fix:rejected` label + GitHub comment (`823-838`). No new budget counter is introduced.
  - On success: proceed to the review block / review agent.
- Because a PR is only opened after review approval, and review is only reached after checks
  pass, checks gate the PR and therefore auto-merge — no change needed in the merge path.
- The check output passed into the fix prompt is operator/tool output; it is embedded as
  `feedback`, which is already sanitized before reuse (W8 path), so no new injection surface.

**Error handling.** A missing check binary (e.g. `pnpm` absent) surfaces as a non-zero check →
treated as a failed check (retry/reject), with the error text in the feedback. Document that
check commands run in `$PROJECT`.

**Test.** With `--check-cmd false`, a fix is never reviewed/pushed and the issue ends
`fix:rejected` after the retry budget. With `--check-cmd true`, behavior is unchanged.

---

## 4. Ctrl-C / abort trap

**Problem.** No `trap` exists. Aborting during FIX leaves `$PROJECT` on `fix/issue-N` with a
dirty tree; the next run's preflight clean check then refuses to start.

**Design.**
- New globals (init empty/false near the other state vars ~`58`): `CURRENT_ISSUE`,
  `CURRENT_BRANCH`, `CURRENT_AGENT_PID`, `CURRENT_WATCH_PID`, `CURRENT_PUSHED=false`.
- `run_agent` sets `CURRENT_AGENT_PID=$agent_pid` / `CURRENT_WATCH_PID=$watch_pid` right after
  launch, and clears both (`=""`) after the final `wait`.
- `process_issue` sets `CURRENT_ISSUE` / `CURRENT_BRANCH` after the fix branch is created and
  clears them (and resets `CURRENT_PUSHED=false`) at **every** return path / loop end.
- **Push lifecycle (Codex IMPORTANT):** push/PR/labeling spans `843-925`. Set
  `CURRENT_PUSHED=true` immediately after `git push` succeeds. Once a branch is pushed, its
  remote branch + PR are durable and are reconciled next run by the `fix:pr-open`/unstick logic —
  so the trap must **not** delete a pushed branch.
- `on_interrupt()` handler, registered once via `trap on_interrupt INT TERM` after the helper
  functions are defined:
  1. **Disarm re-entrancy first:** `trap - INT TERM` so a second Ctrl-C cannot re-enter cleanup.
  2. `warn` that the run was interrupted and is cleaning up.
  3. **Kill, then `wait`, the children before any git op** (avoids racing an agent/git process
     that is still exiting): `pkill -P "$CURRENT_AGENT_PID"` then `kill "$CURRENT_AGENT_PID"`
     (guarded by non-empty), same for the watchdog PID, then `wait` on them. PID cleanup is
     **best-effort**: `$!` captures the pipeline's last process, not a process-group handle, so
     `pkill -P` + `kill` match the existing watchdog semantics rather than guaranteeing a full
     process-group sweep.
  4. If `CURRENT_BRANCH` is set **and `CURRENT_PUSHED` is false**:
     `cleanup_branch "$CURRENT_ISSUE" "$CURRENT_BRANCH" "interrupted"` (existing helper: stash
     dirty work → checkout base → `branch -D`). If already pushed, leave the local + remote branch
     intact. **No label is set in either case.**
  5. `exit 130`.
- No terminal label means the issue stays in the queue and is naturally retried next run (covers
  the "Explicit resume mode" roadmap item via consistent label state).

**Error handling.** `cleanup_branch` already swallows its own failures (`|| true`); the stash is
recoverable via `git stash list` as documented elsewhere. `exit 130` from a trap is safe here
because the script does not use `set -e` and already exits explicitly throughout
(validation/fetch failures).

**Test.** Hard to unit-test signals; verify by inspection + a manual SIGINT during a run leaves
`$PROJECT` clean on the base branch with the fix branch gone and no new label on the issue.

---

## 5. `.fixbuddy.conf` config files

**Design.**
- **Locations & precedence** (lowest to highest): built-in defaults → `~/.fixbuddy/config`
  (global) → `./.fixbuddy.conf` (current directory; the common case is `cd`-ing into the repo,
  so CWD == project root and the file is the repo's checked-in config) → CLI flags.
- **Loading order:** read global, then project config **before** the arg-parsing loop, populating
  the same global variables. Arg parsing then runs last, so CLI flags override config naturally.
  Scalars: last writer wins (CLI > project > global). Repeatable keys (`label`, `check_cmd`):
  additive (config entries + CLI entries combine).
- **Additive-key caveat (Codex IMPORTANT):** because `label`/`check_cmd` are additive, a config
  `label = bug` plus CLI `--label security` becomes an AND filter (`gh issue list --label bug
  --label security`), not an override — a user **cannot remove** a config-provided label or
  check from the CLI. This is intended but must be documented in the help text and the config
  section of the README.
- **Boolean override (Codex IMPORTANT):** today only `--no-auto-merge` exists. Add a matching
  `--auto-merge` flag (sets `AUTO_MERGE=true`) so a global `auto_merge = false` can be overridden
  back to true from the CLI, honouring "CLI wins" in both directions.
- **Safe parser** `load_config(file)`:
  - Skip blank lines and `#` comments. **Strip a trailing `\r`** from each line so CRLF
    (Windows-authored) configs parse cleanly. A non-comment, non-blank line **without `=`** →
    `warn "malformed config line in $file: <line>"` and skip (Codex IMPORTANT).
  - Split each line on the first `=`. Trim surrounding whitespace from key and value. Strip one
    optional layer of matching surrounding quotes from the value.
  - Map the key (lower_snake) against an explicit allowlist and assign to the corresponding
    variable. **No `source`, no `eval`** — values are only ever assigned as plain strings, so a
    malicious config cannot execute code (worst case: a known variable holds a string).
  - Unknown key → `warn "unknown config key '$k' in $file (ignored)"`.
  - Boolean keys (`auto_merge`) accept `true`/`false` only; anything else warns and is ignored.
- **Allowlisted keys → variables:** `repo→REPO`, `project→PROJECT`, `fix_agent→FIX_AGENT`,
  `review_agent→REVIEW_AGENT`, `max→MAX`, `max_retries→MAX_RETRIES`,
  `agent_timeout→AGENT_TIMEOUT`, `crash_abort→CRASH_ABORT_THRESHOLD`, `base→BASE_BRANCH`,
  `severity→SEVERITY`, `skip_label→SKIP_LABEL`, `auto_merge→AUTO_MERGE`,
  `label→LABELS+=` (repeatable), `check_cmd→CHECK_CMDS+=` (repeatable).
- Numeric/agent/auto_merge values still pass through the existing validation block, so a bad
  config value fails with the same clear error as a bad CLI value.
- **Security note (documented):** config files are operator-controlled and trusted at the same
  level as CLI flags. `check_cmd` from a config is executed by `run_checks`, consistent with the
  threat model where only *issue* content is untrusted.

**Wizard integration (`fixbuddy-wizard.sh`).**
- After the command preview, add a prompt: "Save these settings to ./.fixbuddy.conf? [y/N]".
  On yes, write the collected answers as `key = value` lines (only the keys the wizard gathered).
  Then print that the next run can be just `fixbuddy.sh` (which reads the config).
- **Location footgun (Codex IMPORTANT):** the wizard writes to `./.fixbuddy.conf` in the **CWD**,
  consistent with where fixbuddy reads the project config. Print the **absolute path** written,
  and if `CWD != PROJECT`, `warn` that the config lives in the launch directory ("run fixbuddy
  from here, or move `.fixbuddy.conf` to where you'll run it"). This keeps the simple CWD model
  while removing the silent-mismatch trap.
- **Quote on write:** values containing spaces or `#` (repo paths, project paths, check commands)
  must be written quoted in the parser's supported quoting form, so they round-trip correctly.
- Do not overwrite an existing `.fixbuddy.conf` without confirming.

**Test.** A `.fixbuddy.conf` setting `max = 5` is honored; `--max 3` on the CLI overrides it to 3
(CLI wins); an unknown key warns; a config with `source`-style content (e.g. `$(rm x)`) is stored
as a literal string and never executed.

---

## Cross-cutting

- **Help text / usage** (`sed -n '2,36p' "$0"` block at the top): document `--issue`,
  `--check-cmd`, `--auto-merge`, and `.fixbuddy.conf` precedence (incl. the additive-key caveat);
  note that `--check-cmd` runs operator-trusted commands in `$PROJECT`.
- **README**: add the new flags, the config-file section, and correct the dry-run wording.
- **Static gate**: every change must keep `bash -n` and `shellcheck -S warning` clean.
- **Ordering of work** (suggested): (1) dry-run read-only → (2) trap → (3) `--issue` →
  (4) `--check-cmd` → (5) config + wizard. Each is independently committable and testable.
