# `--notify-cmd` Notifications (v0.7.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Operator-trusted notification hook (`--notify-cmd` / config `notify_cmd`) fired once with the run summary, for unattended runs.

**Architecture:** Mirrors the existing `--check-cmd` pattern (additive flag+config key, shell-eval, operator trust). A new `run_notifications` function is called right after the Summary block; it pipes a text summary to each command with `FIXBUDDY_*` env vars exported. TDD against the existing offline integration harness — no new stubs needed, notify commands are plain shell.

**Tech Stack:** Bash 3.2-compatible, no new dependencies.

Spec: `docs/superpowers/specs/2026-06-12-notify-cmd-design.md`

---

### Task 1: Failing integration tests

**Files:**
- Modify: `tests/integration.sh` (five new test functions before the Runner section; extend `TESTS`)

- [ ] **Step 1: Add the test functions**

Insert before `# ---------------- Runner ----------------`:

```bash
test_notify_cmd_receives_summary() {
  # Notify commands run in the LAUNCH directory ($TMP) and get the summary as
  # FIXBUDDY_* env vars plus human-readable text on stdin. Both commands run.
  SCENARIO=happy; make_fixture
  run_fixbuddy --auto-merge \
    --notify-cmd 'env | grep ^FIXBUDDY_ | sort > notify-env.txt; cat > notify-stdin.txt' \
    --notify-cmd 'echo second > notify-second.txt'
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_substr "$TMP/notify-env.txt" "FIXBUDDY_REPO=acme/app"
  assert_substr "$TMP/notify-env.txt" "FIXBUDDY_PROCESSED=1"
  assert_substr "$TMP/notify-env.txt" "FIXBUDDY_PR_OPENED=1"
  assert_substr "$TMP/notify-env.txt" "FIXBUDDY_MERGED=0"
  assert_substr "$TMP/notify-env.txt" "FIXBUDDY_BLOCKED=0"
  assert_substr "$TMP/notify-env.txt" "FIXBUDDY_ABORTED=false"
  assert_substr "$TMP/notify-stdin.txt" "PRs opened: 1"
  [ -f "$TMP/notify-second.txt" ] || fail "second notify command did not run"
}

test_notify_failure_does_not_break_run() {
  SCENARIO=happy; make_fixture
  run_fixbuddy --auto-merge --notify-cmd 'exit 7' \
    --notify-cmd 'echo ran > notify-after-fail.txt'
  [ "$RC" -eq 0 ] || fail "notify failure changed the exit code (rc=$RC)"
  assert_grep "$RUNLOG" 'notify command failed \(exit 7\)'
  [ -f "$TMP/notify-after-fail.txt" ] || fail "subsequent notify command did not run"
}

test_notify_reports_blocked() {
  # One crash (below the abort threshold): BLOCKED=1, ABORTED=false.
  SCENARIO=crash; make_fixture
  run_fixbuddy --auto-merge --notify-cmd 'env | grep ^FIXBUDDY_ > notify-env.txt'
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_substr "$TMP/notify-env.txt" "FIXBUDDY_BLOCKED=1"
  assert_substr "$TMP/notify-env.txt" "FIXBUDDY_ABORTED=false"
}

test_notify_cmd_from_config() {
  # notify_cmd is an additive config key, read from the launch dir like the
  # other config keys.
  SCENARIO=happy; make_fixture
  printf 'notify_cmd = echo config-notify > notify-config.txt\n' > "$TMP/.fixbuddy.conf"
  run_fixbuddy --auto-merge
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  [ -f "$TMP/notify-config.txt" ] || fail "config notify_cmd did not run"
}

test_notify_skipped_on_dry_run() {
  SCENARIO=happy; make_fixture
  run_fixbuddy --dry-run --notify-cmd 'echo nope > notify-dry.txt'
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  [ ! -f "$TMP/notify-dry.txt" ] || fail "notify fired during --dry-run"
}
```

- [ ] **Step 2: Extend the test list**

```bash
TESTS=(test_happy_path test_false_positive test_review_reject test_check_gate
       test_dry_run_read_only test_crash_labels_blocked
       test_agy_full_pipeline test_gemini_rejected_with_migration_hint
       test_agy_internal_timeout_is_blocked
       test_verify_residue_is_stashed test_verify_commit_is_discarded
       test_verify_residue_cleaned_on_early_return
       test_reviewer_commit_is_discarded test_reviewer_residue_cleaned_before_retry
       test_notify_cmd_receives_summary test_notify_failure_does_not_break_run
       test_notify_reports_blocked test_notify_cmd_from_config
       test_notify_skipped_on_dry_run)
```

- [ ] **Step 3: Run to verify the new tests fail**

Run: `tests/integration.sh 2>&1 | grep -E "^(FAIL|[0-9]+ passed)"`
Expected: 14 passed; the four non-dry-run notify tests fail with "Unknown arg: --notify-cmd" effects (exit 2) or missing files; `test_notify_skipped_on_dry_run` also fails (exit 2 on the unknown flag).

- [ ] **Step 4: Commit**

```bash
git add tests/integration.sh
git commit -m "test: notify-cmd scenarios (env/stdin, failure isolation, config, dry-run)"
```

---

### Task 2: Implement `--notify-cmd` in fixbuddy.sh

**Files:**
- Modify: `fixbuddy.sh` — header comment (~line 30-47), help sed range (line 174), defaults (line 57), config parser (line 144), arg parsing (line 164), after `run_checks` (~line 630), counters init (~line 870), crash-abort branch (~line 1303), after the Summary block (~line 1325)

- [ ] **Step 1: Header comment + help range**

After the 4-line `--check-cmd` block in the header, insert:

```text
#   --notify-cmd <cmd>        Run-summary notification hook (repeatable). Runs in the
#                             LAUNCH directory after the final summary (also after a
#                             crash-abort); gets FIXBUDDY_* env vars + a text summary
#                             on stdin. OPERATOR-TRUSTED and run via the shell.
```

Update the config comment line to mention the new additive key:
`...label and check_cmd are` → `...label, check_cmd, and notify_cmd are`.

The header grew by 4 lines: change line 174 `-h|--help) sed -n '2,47p' "$0"; exit 0 ;;` → `sed -n '2,51p'`.

- [ ] **Step 2: Globals, config key, flag**

- Line 57 area, after `CHECK_CMDS=()`: add `NOTIFY_CMDS=()`.
- Config parser, after `check_cmd) CHECK_CMDS+=("$value") ;;`: add
  `notify_cmd) NOTIFY_CMDS+=("$value") ;;`
- Arg parsing, after `--check-cmd) ...`: add
  `--notify-cmd) NOTIFY_CMDS+=("$2"); shift 2 ;;`

- [ ] **Step 3: `run_notifications` function**

Insert directly after the `run_checks` function:

```bash
# Run the operator-supplied --notify-cmd hook(s) with the final run summary.
# Commands are trusted (CLI/config level, like --check-cmd) and run via the
# shell in the LAUNCH directory — not $PROJECT; notifications are about the
# run, not the checkout. Each command gets the summary as FIXBUDDY_* env vars
# plus a human-readable text on stdin. A failure warns and never changes
# fixbuddy's exit code; the remaining commands still run. Output is appended
# to $log_root/notify.log.
run_notifications() {
  [ "${#NOTIFY_CMDS[@]}" -gt 0 ] || return 0
  local summary cmd rc abort_note=""
  if [ "$aborted" = "true" ]; then
    abort_note="Batch ABORTED after consecutive agent crashes.
"
  fi
  summary="fixbuddy v$VERSION run on $REPO
Processed: $processed | Merged: $merged | PRs opened: $opened
False positives: $fp | Blocked: $blocked | Rejected: $rejected
${abort_note}Logs: $log_root"
  for cmd in "${NOTIFY_CMDS[@]}"; do
    printf '%s\n' "$summary" | (
      export FIXBUDDY_REPO="$REPO" FIXBUDDY_PROCESSED="$processed" \
        FIXBUDDY_MERGED="$merged" FIXBUDDY_PR_OPENED="$opened" \
        FIXBUDDY_FALSE_POSITIVES="$fp" FIXBUDDY_BLOCKED="$blocked" \
        FIXBUDDY_REJECTED="$rejected" FIXBUDDY_ABORTED="$aborted" \
        FIXBUDDY_LOG_DIR="$log_root" FIXBUDDY_VERSION="$VERSION"
      eval "$cmd"
    ) >>"$log_root/notify.log" 2>&1
    rc=$?
    [ "$rc" -ne 0 ] && warn "notify command failed (exit $rc): $cmd"
  done
  return 0
}
```

- [ ] **Step 4: `aborted` state**

- Counters init block (`processed=0 ... rejected=0` before `process_issue`): add `aborted=false`.
- In the crash-abort branch (the `if [ "$CONSECUTIVE_CRASHES" -ge ...` block), add `aborted=true` immediately before `break`.

- [ ] **Step 5: Fire after the Summary**

After the final `info "Logs: $log_root"` of the Summary block, append:

```bash
run_notifications
```

(Dry-run, empty-queue, and Ctrl-C paths exit before this line, so they never notify — by design.)

- [ ] **Step 6: Run tests**

Run: `bash -n fixbuddy.sh && shellcheck fixbuddy.sh tests/integration.sh && tests/integration.sh 2>&1 | grep -E "^(FAIL|[0-9]+ passed)"`
Expected: `19 passed, 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add fixbuddy.sh
git commit -m "feat: --notify-cmd run-summary notification hook"
```

---

### Task 3: Documentation

**Files:**
- Modify: `README.md` (options table, config tables + example, Examples, FAQ, Roadmap), `CHANGELOG.md`

- [ ] **Step 1: README options table**

After the `--check-cmd` row:

```markdown
| `--notify-cmd <cmd>` | Run-summary notification hook. Repeatable. Runs in the **launch** directory after the final summary (also after a crash-abort), receiving `FIXBUDDY_*` env vars (counts, `FIXBUDDY_ABORTED`, `FIXBUDDY_LOG_DIR`) and a human-readable summary on stdin. A failure warns but never changes the exit code. Not fired for `--dry-run`, empty queues, or Ctrl-C. Operator-trusted (same trust level as CLI flags) | none |
```

- [ ] **Step 2: README config docs**

- Allowlist table, after the `check_cmd` row: `| notify_cmd | --notify-cmd | additive (see below) |`
- Additive-keys paragraph: `**Additive keys** (\`label\`, \`check_cmd\`)` → `**Additive keys** (\`label\`, \`check_cmd\`, \`notify_cmd\`)`
- Format example block: add `notify_cmd  = curl -s -d @- ntfy.sh/my-topic` after the `check_cmd` lines.

- [ ] **Step 3: README example + FAQ + roadmap**

Examples section, new entry:

```markdown
Get a push notification when an unattended batch finishes (anything that reads stdin works — ntfy, Slack webhook, `mail`):

​```bash
./fixbuddy.sh --repo owner/repo --project ~/code/repo --max 10 \
  --notify-cmd 'curl -s -d @- ntfy.sh/my-fixbuddy-topic'
​```
```

FAQ, after the "What happens if CI fails?" entry:

```markdown
**What happens if I interrupt a run (Ctrl-C)?**
The in-flight agent is stopped and the local branch is cleaned up; no label is set, so the issue simply stays in the queue. There is no separate resume mode because the labels already provide it: the next run picks up where the last one stopped (`fix:blocked` re-queues automatically, `fix:pr-open` prevents duplicate PRs).
```

Delete the `## Roadmap` section (both items are resolved: notifications ship here; resume mode is covered by the FAQ above).

- [ ] **Step 4: CHANGELOG**

Insert above the `## [0.6.0]` entry:

```markdown
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
```

And add the compare link above the 0.6.0 link:
`[0.7.0]: https://github.com/Codevena/fixbuddy/compare/v0.6.0...v0.7.0`

- [ ] **Step 5: Verify and commit**

Run: `grep -n "notify" README.md | head; tests/integration.sh >/dev/null && echo OK`
Expected: rows present; suite still green.

```bash
git add README.md CHANGELOG.md
git commit -m "docs: document --notify-cmd, retire roadmap (resume covered by FAQ)"
```

---

### Task 4: Release housekeeping (v0.7.0)

**Files:**
- Modify: `fixbuddy.sh:2,50`, `fixbuddy-wizard.sh:2,35`, `install.sh` (5×), `README.md` (one-liners + pinned-version sentence), `SHA256SUMS`, `NEXT_SESSION.md`

- [ ] **Step 1: Version bumps v0.6.0 → v0.7.0**

```bash
sed -i '' 's/fixbuddy v0\.6\.0 — two-agent pipeline/fixbuddy v0.7.0 — two-agent pipeline/; s/^VERSION="0\.6\.0"/VERSION="0.7.0"/' fixbuddy.sh
sed -i '' 's/fixbuddy-wizard\.sh v0\.6\.0/fixbuddy-wizard.sh v0.7.0/; s/fixbuddy wizard v0\.6\.0/fixbuddy wizard v0.7.0/' fixbuddy-wizard.sh
sed -i '' 's/v0\.6\.0/v0.7.0/g' install.sh
```

README: replace both `raw.githubusercontent.com/Codevena/fixbuddy/v0.6.0/install.sh` URLs and the "pinned `v0.6.0` scripts" sentence with v0.7.0.

- [ ] **Step 2: SHA256SUMS + NEXT_SESSION**

```bash
shasum -a 256 fixbuddy.sh fixbuddy-wizard.sh > SHA256SUMS
```

Update `NEXT_SESSION.md`: status = v0.7.0 on branch awaiting merge/tag; release checklist unchanged; "What's next" = roadmap is empty — next session picks new goals (ideas: agy in the GitHub Action docs, more agents, log retention).

- [ ] **Step 3: Full verification + commit**

Run: `bash -n fixbuddy.sh && bash -n fixbuddy-wizard.sh && bash -n install.sh && shellcheck fixbuddy.sh fixbuddy-wizard.sh install.sh tests/integration.sh tests/stubs/agent tests/stubs/gh && tests/integration.sh 2>&1 | tail -2`
Expected: all clean, `19 passed, 0 failed`.

```bash
git add -A
git commit -m "release: v0.7.0 (version bumps, SHA256SUMS, housekeeping)"
```

---

### Task 5: Definition-of-Done review pipeline

Per `~/.claude/CLAUDE.md`; reviewers review the branch diff (`git diff main...HEAD`).

- [ ] **Step 1: Static checks green** (done in Task 4 Step 3).
- [ ] **Step 2: Codex Agent A** — prompt via `.review/codex-prompt.txt`; run `codex exec "$(<.review/codex-prompt.txt)" </dev/null` FOREGROUND, single short command, generous timeout. Findings → `.review/codex-a-findings.md`.
- [ ] **Step 3: Claude Agent A** — code-reviewer subagent, findings → `.review/claude-a-findings.md`.
- [ ] **Step 4: Gate** — both `VERDICT: PASS`; on FAIL fix everything and re-run all reviewers.
- [ ] **Step 5: `rm -rf .review/`**, push + PR only after user approval.
