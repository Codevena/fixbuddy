# agy Agent + Integration Tests (v0.6.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the retired `gemini` agent with `agy` (Antigravity CLI) and add a deterministic, offline integration test suite, releasing as v0.6.0.

**Architecture:** A pure-Bash test harness (`tests/integration.sh`) runs `fixbuddy.sh` against stub CLIs (`gh`, `claude`, `codex`, `agy`) on a prefixed `PATH` and a local bare git repo as `origin`, so branches/commits/pushes are real while GitHub and agents are canned. The harness lands first (TDD), then the agy swap is driven by failing tests.

**Tech Stack:** Bash 3.2-compatible shell (matches existing scripts), git, jq, shellcheck. No new dependencies.

Spec: `docs/superpowers/specs/2026-06-12-agy-agent-and-integration-tests-design.md`

---

### Task 1: Test harness, stubs, happy-path scenario

**Files:**
- Create: `tests/stubs/agent` (+ symlinks `tests/stubs/claude`, `tests/stubs/codex`, `tests/stubs/agy`)
- Create: `tests/stubs/gh`
- Create: `tests/integration.sh`

- [ ] **Step 1: Create the agent stub**

Write `tests/stubs/agent`:

```bash
#!/usr/bin/env bash
# Deterministic test double for the agent CLIs, symlinked as claude/codex/agy.
# Behavior switches on the invoked name ($0) and $FIXBUDDY_TEST_SCENARIO. The
# pipeline stage is detected from the prompt text (mirrors docs/demo/bin/agent).
# Every invocation appends "<name>:<stage>" to $FIXBUDDY_TEST_STAGELOG; agy
# invocations additionally record their argv and GH_TOKEN visibility to
# $FIXBUDDY_TEST_AGYLOG so tests can assert on flags and env stripping.
set -u

name="$(basename "$0")"
scenario="${FIXBUDDY_TEST_SCENARIO:-happy}"

# claude/codex receive the prompt on stdin; agy receives it as the value after
# -p, with all other flags positioned before it.
prompt=""
flags=""
if [ "$name" = "agy" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      -p) prompt="${2:-}"; shift 2 ;;
      --add-dir|--print-timeout) flags="$flags $1=${2:-}"; shift 2 ;;
      *) flags="$flags $1"; shift ;;
    esac
  done
else
  prompt="$(cat)"
fi

stage="verify"
case "$prompt" in
  *"implementing a fix"*)               stage="fix" ;;
  *"independent senior code reviewer"*) stage="review" ;;
esac

[ -n "${FIXBUDDY_TEST_STAGELOG:-}" ] && echo "$name:$stage" >> "$FIXBUDDY_TEST_STAGELOG"
if [ "$name" = "agy" ] && [ -n "${FIXBUDDY_TEST_AGYLOG:-}" ]; then
  echo "stage=$stage gh_token=${GH_TOKEN:-unset} args=$flags" >> "$FIXBUDDY_TEST_AGYLOG"
fi

# The fix stage makes a REAL commit in the target project, parsed from the prompt.
project="$(printf '%s\n' "$prompt" | sed -n 's/^\*\*Working directory:\*\* //p' | head -1)"
do_fix_commit() {
  ( cd "$project" \
    && echo "fixed by $name" >> src/app.txt \
    && git add src/app.txt \
    && git commit -q -m "fix: correct app output

Closes #7" )
}

case "$scenario:$stage" in
  happy:verify|reject:verify|check:verify)
    echo "Reproduced the problem. The issue is real."
    echo "DONE-PROCEED" ;;
  happy:fix|reject:fix|check:fix)
    do_fix_commit
    echo "DONE-FIX-APPLIED" ;;
  happy:review)
    echo "Diff is correct, minimal, in scope."
    echo "DONE-APPROVED" ;;
  reject:review)
    echo "DONE-REJECTED: the fix lacks a regression test" ;;
  falsepos:verify)
    echo "DONE-FALSE-POSITIVE: the code already behaves correctly" ;;
  crash:verify)
    echo "transport error: connection reset"
    exit 1 ;;
  agytimeout:verify)
    echo "Error: timed out waiting for response"
    exit 0 ;;
  *)
    echo "DONE-BLOCKED: unexpected scenario '$scenario' at stage '$stage'"
    exit 0 ;;
esac
```

- [ ] **Step 2: Create the gh stub**

Write `tests/stubs/gh`:

```bash
#!/usr/bin/env bash
# Deterministic test double for the GitHub CLI. Read-only queries return canned
# JSON; every MUTATING call is appended verbatim to $FIXBUDDY_TEST_MUTLOG so
# tests can assert exactly what fixbuddy would have changed on GitHub.
set -u

mutate() {
  [ -n "${FIXBUDDY_TEST_MUTLOG:-}" ] && echo "$*" >> "$FIXBUDDY_TEST_MUTLOG"
  return 0
}

case "${1:-} ${2:-}" in
  "label create")  mutate "$@" ;;
  "issue list")
    case "$*" in
      *"fix:pr-open"*) echo "[]" ;;  # unstick scan: nothing stuck
      *) cat <<'JSON'
[{"number":7,"title":"app outputs wrong text","labels":[{"name":"bug"},{"name":"severity:high"}],"url":"https://github.com/acme/app/issues/7","body":"src/app.txt should contain a fixed line. Please fix the output."}]
JSON
      ;;
    esac ;;
  "issue view")
    cat <<'JSON'
{"number":7,"title":"app outputs wrong text","labels":[{"name":"bug"},{"name":"severity:high"}],"url":"https://github.com/acme/app/issues/7","state":"OPEN","body":"src/app.txt should contain a fixed line. Please fix the output."}
JSON
    ;;
  "issue edit"|"issue comment"|"issue close") mutate "$@" ;;
  "pr create")  mutate "$@"; echo "https://github.com/acme/app/pull/12" ;;
  "pr merge")   mutate "$@" ;;
  "pr view")    echo "false" ;;   # not merged yet -> fix:pr-open path
  "pr list")    echo "" ;;
  "repo view")  echo "main" ;;
  *) : ;;   # auth setup-git etc. -> no-op
esac
exit 0
```

- [ ] **Step 3: Create the runner with the happy-path test**

Write `tests/integration.sh`:

```bash
#!/usr/bin/env bash
# Deterministic integration tests for fixbuddy.sh. No network, no real gh, no
# real agents: PATH is prefixed with tests/stubs (canned gh + scripted agent
# doubles) and the GitHub remote is a local bare repository, so branch
# creation, commits, and pushes are real git operations. Each scenario runs in
# a fresh mktemp fixture with HOME redirected (no ~/.fixbuddy leakage).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS="$ROOT/tests/stubs"
PASS=0
FAIL=0
CURRENT=""

fail() { FAIL=$((FAIL+1)); printf 'FAIL %s: %s\n' "$CURRENT" "$*"; }

assert_grep()    { grep -qE -- "$2" "$1" || fail "expected /$2/ in ${1##*/}"; }
assert_no_grep() { if grep -qE -- "$2" "$1"; then fail "did not expect /$2/ in ${1##*/}"; fi; }
assert_substr()  { grep -qF -- "$2" "$1" || fail "expected '$2' in ${1##*/}"; }

make_fixture() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/fixbuddy-itest.XXXXXX")"
  mkdir -p "$TMP/home"
  git init -q --bare "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/project" 2>/dev/null
  (
    cd "$TMP/project"
    git config user.email "test@example.com"
    git config user.name "fixbuddy-itest"
    mkdir -p src
    echo "hello" > src/app.txt
    git add .
    git commit -q -m "initial commit"
    git branch -M main
    git push -q -u origin main 2>/dev/null
    git remote set-head origin main
  )
  MUTLOG="$TMP/mutations.log";  : > "$MUTLOG"
  STAGELOG="$TMP/stages.log";   : > "$STAGELOG"
  AGYLOG="$TMP/agy.log";        : > "$AGYLOG"
  RUNLOG="$TMP/run.log"
}

run_fixbuddy() {
  # GH_TOKEN is set on purpose: the agent stub records whether fixbuddy
  # stripped it from the agent environment. HOME is redirected so the user's
  # ~/.fixbuddy/config can never leak in and run logs never pollute the real
  # home directory.
  ( cd "$TMP" && \
    HOME="$TMP/home" \
    PATH="$STUBS:$PATH" \
    GH_TOKEN="test-token-must-not-leak" \
    FIXBUDDY_TEST_SCENARIO="$SCENARIO" \
    FIXBUDDY_TEST_MUTLOG="$MUTLOG" \
    FIXBUDDY_TEST_STAGELOG="$STAGELOG" \
    FIXBUDDY_TEST_AGYLOG="$AGYLOG" \
    bash "$ROOT/fixbuddy.sh" --repo acme/app --project "$TMP/project" --yes "$@" \
  ) > "$RUNLOG" 2>&1
  RC=$?
}

# ---------------- Scenarios ----------------

test_happy_path() {
  SCENARIO=happy; make_fixture
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$STAGELOG" '^claude:verify$'
  assert_grep "$STAGELOG" '^claude:fix$'
  assert_grep "$STAGELOG" '^codex:review$'
  assert_grep "$MUTLOG" '^pr create .*--head fix/issue-7'
  assert_grep "$MUTLOG" '^pr merge .*--auto'
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:pr-open'
  # the push was real: the fix branch must exist in the bare origin
  git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    || fail "fix branch was not pushed to origin"
  # local worktree restored: back on base, fix branch deleted
  [ -z "$(git -C "$TMP/project" branch --list 'fix/issue-7')" ] \
    || fail "local fix branch not cleaned up"
}

# ---------------- Runner ----------------

TESTS=(test_happy_path)

for t in "${TESTS[@]}"; do
  CURRENT="$t"
  FAIL_BEFORE=$FAIL
  "$t"
  if [ "$FAIL" -eq "$FAIL_BEFORE" ]; then
    PASS=$((PASS+1)); printf 'ok   %s\n' "$t"
  else
    printf '     run log tail:\n'; tail -5 "$RUNLOG" 2>/dev/null | sed 's/^/     | /'
  fi
  rm -rf "$TMP"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 4: Make executable, create symlinks**

```bash
chmod +x tests/integration.sh tests/stubs/agent tests/stubs/gh
ln -s agent tests/stubs/claude
ln -s agent tests/stubs/codex
ln -s agent tests/stubs/agy
```

- [ ] **Step 5: Run the suite**

Run: `tests/integration.sh`
Expected: `ok   test_happy_path` … `1 passed, 0 failed` (exit 0). Debug via the printed run-log tail on failure.

- [ ] **Step 6: Static checks**

Run: `bash -n tests/integration.sh tests/stubs/agent tests/stubs/gh && shellcheck tests/integration.sh tests/stubs/agent tests/stubs/gh`
Expected: no output, exit 0.

- [ ] **Step 7: Commit**

```bash
git add tests/
git commit -m "test: deterministic integration harness with stubbed gh/agent CLIs"
```

---

### Task 2: Remaining non-agy scenarios

**Files:**
- Modify: `tests/integration.sh` (append test functions before the Runner section; extend `TESTS`)

- [ ] **Step 1: Add five test functions**

Insert before `# ---------------- Runner ----------------`:

```bash
test_false_positive() {
  SCENARIO=falsepos; make_fixture
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:false-positive'
  assert_grep "$MUTLOG" '^issue close 7'
  assert_no_grep "$STAGELOG" ':fix$'
}

test_review_reject() {
  SCENARIO=reject; make_fixture
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:rejected'
  [ "$(grep -c '^claude:fix$' "$STAGELOG")" -eq 2 ]   || fail "expected 2 fix attempts"
  [ "$(grep -c '^codex:review$' "$STAGELOG")" -eq 2 ] || fail "expected 2 review attempts"
  assert_no_grep "$MUTLOG" '^pr create'
  [ -z "$(git -C "$TMP/project" branch --list 'fix/issue-7')" ] \
    || fail "local fix branch not cleaned up"
}

test_check_gate() {
  SCENARIO=check; make_fixture
  run_fixbuddy --check-cmd 'false'
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:rejected'
  assert_no_grep "$STAGELOG" ':review$'
  assert_no_grep "$MUTLOG" '^pr create'
}

test_dry_run_read_only() {
  SCENARIO=happy; make_fixture
  run_fixbuddy --dry-run
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  [ ! -s "$MUTLOG" ]   || fail "dry-run made mutations: $(tr '\n' ';' < "$MUTLOG")"
  [ ! -s "$STAGELOG" ] || fail "dry-run invoked an agent"
  assert_grep "$RUNLOG" '#7'
}

test_crash_labels_blocked() {
  SCENARIO=crash; make_fixture
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:blocked'
  assert_no_grep "$MUTLOG" 'fix:needs-human'
}
```

- [ ] **Step 2: Extend the test list**

```bash
TESTS=(test_happy_path test_false_positive test_review_reject test_check_gate
       test_dry_run_read_only test_crash_labels_blocked)
```

- [ ] **Step 3: Run the suite**

Run: `tests/integration.sh`
Expected: `6 passed, 0 failed`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add tests/integration.sh
git commit -m "test: cover false-positive, reject, check gate, dry-run, crash paths"
```

---

### Task 3: agy agent in fixbuddy.sh (TDD)

**Files:**
- Modify: `tests/integration.sh`
- Modify: `fixbuddy.sh:26-29` (header), `:190-214` (validation/presence/warning), `:464-484` (run_agent), `:515-517` (timeout classification)

- [ ] **Step 1: Add three failing tests**

Insert before the Runner section of `tests/integration.sh`:

```bash
test_agy_full_pipeline() {
  SCENARIO=happy; make_fixture
  run_fixbuddy --fix-agent agy --review-agent agy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:pr-open'
  # agy invocation contract: workspace dir, print-timeout above the watchdog
  # (default 1200+60), sandbox on verify/review but NOT on fix, GH_TOKEN stripped
  assert_substr "$AGYLOG" "--add-dir=$TMP/project"
  assert_substr "$AGYLOG" "--print-timeout=1260s"
  assert_grep "$AGYLOG" '^stage=verify .*--sandbox'
  assert_grep "$AGYLOG" '^stage=review .*--sandbox'
  assert_no_grep "$AGYLOG" '^stage=fix .*--sandbox'
  assert_grep "$AGYLOG" 'gh_token=unset'
}

test_gemini_rejected_with_migration_hint() {
  SCENARIO=happy; make_fixture
  run_fixbuddy --fix-agent gemini
  [ "$RC" -eq 2 ] || fail "expected exit 2, got $RC"
  assert_grep "$RUNLOG" "agy"
  assert_grep "$RUNLOG" "[Gg]emini CLI"
}

test_agy_internal_timeout_is_blocked() {
  # agy exits 0 on its own --print-timeout with an error line instead of a
  # DONE marker; fixbuddy must classify that as a crash/timeout (fix:blocked,
  # auto-requeue) — not as the never-retried fix:needs-human path.
  SCENARIO=agytimeout; make_fixture
  run_fixbuddy --fix-agent agy --review-agent agy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:blocked'
  assert_no_grep "$MUTLOG" 'fix:needs-human'
}
```

Extend the list:

```bash
TESTS=(test_happy_path test_false_positive test_review_reject test_check_gate
       test_dry_run_read_only test_crash_labels_blocked
       test_agy_full_pipeline test_gemini_rejected_with_migration_hint
       test_agy_internal_timeout_is_blocked)
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `tests/integration.sh`
Expected: 6 passed, 3 failed — `test_agy_full_pipeline` and `test_agy_internal_timeout_is_blocked` fail with "unsupported agent: agy"; `test_gemini_rejected_with_migration_hint` fails because gemini is currently accepted (no exit 2 / no hint).

- [ ] **Step 3: fixbuddy.sh — header comment**

Replace lines 26-29 (keep the line count stable — `--help` prints `sed -n '2,47p'`):

```text
#   --fix-agent <agent>       claude | codex | opencode | agy (default: claude)
#   --review-agent <agent>    claude | codex | opencode | agy (default: codex — cross-agent)
#                             Note: agy (Antigravity CLI) runs verify/review with
#                             --sandbox (terminal restrictions) as defense in depth.
```

- [ ] **Step 4: fixbuddy.sh — agent validation with migration error**

Replace the validation loop (lines 190-195):

```bash
for agent in "$FIX_AGENT" "$REVIEW_AGENT"; do
  case "$agent" in
    claude|codex|opencode|agy) ;;
    gemini)
      err "agent 'gemini' is no longer supported: Google retired the Gemini CLI on 2026-06-18."
      err "Install the Antigravity CLI (curl -fsSL https://antigravity.google/cli/install.sh | bash)"
      err "and use 'agy' instead — also in fix_agent/review_agent config keys."
      exit 2 ;;
    *) err "unsupported agent: $agent (valid: claude, codex, opencode, agy)"; exit 2 ;;
  esac
done
```

- [ ] **Step 5: fixbuddy.sh — presence check + drop gemini warning**

In the presence-check loop, replace the gemini line:

```bash
      agy)      command -v agy      >/dev/null || { err "agy CLI not found";      exit 2; } ;;
```

Delete the entire "Gemini is less reliable…" warning block (the comment and the `if [ "$FIX_AGENT" = "gemini" ] … fi`, lines 207-213) — agy is a full coding agent, treated like opencode. Keep the enclosing `if ! $DRY_RUN; then … fi` intact.

- [ ] **Step 6: fixbuddy.sh — run_agent invocation**

Replace the `gem_mode` comment+assignment (lines 464-468) with:

```bash
  # agy (Antigravity CLI) has no read-only mode; verify/review add --sandbox
  # (terminal restrictions) as defense in depth. --add-dir grants workspace access
  # to the project (agents are launched from the operator's CWD, not $PROJECT).
  # --print-timeout sits 60s ABOVE the fixbuddy watchdog so the watchdog always
  # fires first and the timeout is classified rc=124 (fix:blocked, auto-requeue).
  local agy_args=(--dangerously-skip-permissions --add-dir "$PROJECT" --print-timeout "$((AGENT_TIMEOUT+60))s")
  case "$stage" in verify|review) agy_args+=(--sandbox) ;; esac
```

Replace the `gemini)` case arm in the agent launch:

```bash
    agy)
      env -u GH_TOKEN -u GITHUB_TOKEN agy "${agy_args[@]}" -p "$prompt" </dev/null >"$outfile" 2>&1 &
      ;;
```

- [ ] **Step 7: fixbuddy.sh — reclassify agy's silent timeout**

Directly after the watchdog-marker check (`if grep -q "^\[fixbuddy-watchdog\]" …; then rc=124; fi`), insert:

```bash
  # agy exits 0 (!) when its own --print-timeout fires, printing this line
  # instead of a DONE marker. Reclassify as timeout so the issue is labeled
  # fix:blocked (auto-requeue) rather than the never-retried fix:needs-human.
  # Normally unreachable (our --print-timeout sits above the watchdog) — belt
  # and braces.
  if [ "$agent" = "agy" ] && [ "$rc" -eq 0 ] \
     && ! grep -qE '^DONE-' "$outfile" 2>/dev/null \
     && grep -q '^Error: timed out waiting for response' "$outfile" 2>/dev/null; then
    rc=124
  fi
```

- [ ] **Step 8: Run the suite to verify all pass**

Run: `bash -n fixbuddy.sh && tests/integration.sh`
Expected: `9 passed, 0 failed`, exit 0.

- [ ] **Step 9: Static checks + real-CLI smoke check**

Run: `shellcheck fixbuddy.sh && ./fixbuddy.sh --help | grep -- 'agy'`
Expected: shellcheck clean; help text shows the agy agent line.

- [ ] **Step 10: Commit**

```bash
git add fixbuddy.sh tests/integration.sh
git commit -m "feat: replace retired gemini agent with agy (Antigravity CLI)"
```

---

### Task 4: Wizard update

**Files:**
- Modify: `fixbuddy-wizard.sh:56-68` (prereq scan), `:195-208` (fixer menu), `:219-233` (reviewer menu)

- [ ] **Step 1: Prerequisite scan**

Line 57: `for a in claude codex opencode gemini; do` → `for a in claude codex opencode agy; do`
Line 66: `fail "no agent CLI installed — need at least one of: claude, codex, opencode, gemini"` → `… claude, codex, opencode, agy"`

- [ ] **Step 2: Fixer menu (step 7a)**

Replace the two notes (lines 196-197) with one:

```bash
note "claude is the most reliable fixer; codex, opencode, and agy are strong alternatives."
```

In the menu loop (line 200): `for a in claude codex opencode gemini; do` → `for a in claude codex opencode agy; do`, and delete the gemini label line:

```bash
    [ "$a" = "gemini" ] && label="$a   ${DIM}(experimental — often writes incomplete fixes)${RST}"
```

- [ ] **Step 3: Reviewer menu (step 7b)**

Line 221: `note "gemini in review mode runs read-only — safer but less thorough."` →

```bash
note "agy runs verify/review with a sandbox (terminal restrictions)."
```

Line 224: `for a in codex claude opencode gemini; do` → `for a in codex claude opencode agy; do`
Line 228: `[ "$a" = "gemini" ]    && label="$a   ${DIM}(read-only, experimental — quick second opinion)${RST}"` →

```bash
    [ "$a" = "agy" ]       && label="$a   ${DIM}(sandboxed verify/review)${RST}"
```

- [ ] **Step 4: Verify**

Run: `bash -n fixbuddy-wizard.sh && shellcheck fixbuddy-wizard.sh && grep -c gemini fixbuddy-wizard.sh`
Expected: syntax/shellcheck clean; grep prints `0` (exit 1 from grep -c is fine).

- [ ] **Step 5: Commit**

```bash
git add fixbuddy-wizard.sh
git commit -m "feat(wizard): offer agy instead of retired gemini"
```

---

### Task 5: action.yml + README

**Files:**
- Modify: `action.yml:18,22`
- Modify: `README.md` (badge, comparison, agents table, options, examples, CI notes, roadmap)

- [ ] **Step 1: action.yml input descriptions**

Both `fix-agent` and `review-agent` descriptions: `claude | codex | opencode | gemini` → `claude | codex | opencode | agy`.

- [ ] **Step 2: README — all gemini references**

1. Badge (line 9): `agents-claude%20%7C%20codex%20%7C%20opencode%20%7C%20gemini` → `…%7C%20agy`.
2. "Why fixbuddy" (line 25): `(claude, codex, opencode, gemini)` → `(claude, codex, opencode, agy)`.
3. Comparison table row: `claude · codex · opencode · gemini` → `claude · codex · opencode · agy`.
4. Supported Agents table — replace the gemini row with:

```markdown
| `agy` | `agy --dangerously-skip-permissions --add-dir <project> -p ...` | Antigravity CLI (Gemini's successor). Verify/review add `--sandbox` (terminal restrictions — not read-only). |
```

5. Options table: `--fix-agent` / `--review-agent` descriptions `claude, codex, opencode, or gemini` → `…or agy` (both rows).
6. Replace the example "Use Gemini as a read-only reviewer" with:

```markdown
Use agy (Antigravity CLI) as a cross-vendor reviewer:

​```bash
./fixbuddy.sh --repo owner/repo --project ~/code/repo \
  --fix-agent claude --review-agent agy
​```
```

7. CI prerequisites: agent list `(claude, codex, opencode, gemini)` → `(claude, codex, opencode, agy)`; add after the pinning sentence: `agy has no npm package — install it with the vendor script: curl -fsSL https://antigravity.google/cli/install.sh | bash`.
8. Roadmap: drop "More deterministic integration tests with mocked CLIs" (now shipped); keep the other two items.

- [ ] **Step 3: Verify no stale references**

Run: `grep -rn gemini README.md action.yml`
Expected: no matches (exit 1).

- [ ] **Step 4: Commit**

```bash
git add README.md action.yml
git commit -m "docs: document agy agent, remove gemini from README and action"
```

---

### Task 6: CI — integration job + shellcheck coverage

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Extend shell checks to the new files**

In the `Bash syntax` step add the test files; in `ShellCheck` likewise:

```yaml
      - name: Bash syntax
        run: |
          bash -n fixbuddy.sh
          bash -n fixbuddy-wizard.sh
          bash -n tests/integration.sh tests/stubs/agent tests/stubs/gh

      - name: ShellCheck
        run: shellcheck fixbuddy.sh fixbuddy-wizard.sh tests/integration.sh tests/stubs/agent tests/stubs/gh
```

- [ ] **Step 2: Add the integration job**

```yaml
  integration:
    name: Integration tests (mocked CLIs)
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v5

      - name: Run integration tests
        run: tests/integration.sh
```

- [ ] **Step 3: Verify YAML + suite locally**

Run: `bash -n fixbuddy.sh && tests/integration.sh && python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"`
Expected: 9 passed; no YAML error.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run integration tests, lint test scripts"
```

---

### Task 7: Version bumps, changelog, housekeeping

**Files:**
- Modify: `fixbuddy.sh:2,50`, `fixbuddy-wizard.sh:2,35`, `install.sh:5,10,19,43,47`, `README.md:60,68`, `CHANGELOG.md`, `NEXT_SESSION.md`, `SHA256SUMS`
- Move: `findings.md` → `docs/audit/2026-06-10-findings.md`

- [ ] **Step 1: Version bumps (v0.5.0 → v0.6.0)**

- `fixbuddy.sh` line 2 header and line 50 `VERSION="0.6.0"`
- `fixbuddy-wizard.sh` line 2 header and line 35 banner
- `install.sh` lines 5, 10, 19 (`DEFAULT_REF="v0.6.0"`), 43, 47
- `README.md` quick-start one-liner (line 60) and inspect-first snippet (line 68)

- [ ] **Step 2: CHANGELOG entry**

Insert after the intro block of `CHANGELOG.md`:

```markdown
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

[0.6.0]: https://github.com/Codevena/fixbuddy/compare/v0.5.0...v0.6.0
```

(Also update the bottom link block accordingly.)

- [ ] **Step 3: Housekeeping**

```bash
mkdir -p docs/audit
git mv findings.md docs/audit/2026-06-10-findings.md
```

Rewrite `NEXT_SESSION.md`: status = v0.6.0 ready on branch, agy swap + integration tests done; release checklist (regenerate SHA256SUMS on script changes, tag v0.6.0, move floating v1) and remaining roadmap (notifications, resume mode).

- [ ] **Step 4: Regenerate SHA256SUMS**

Run: `shasum -a 256 fixbuddy.sh fixbuddy-wizard.sh > SHA256SUMS && cat SHA256SUMS`
Expected: two hash lines.

- [ ] **Step 5: Full verification**

Run: `bash -n fixbuddy.sh fixbuddy-wizard.sh install.sh && shellcheck fixbuddy.sh fixbuddy-wizard.sh install.sh tests/integration.sh tests/stubs/agent tests/stubs/gh && tests/integration.sh`
Expected: all clean, 9 passed.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "release: v0.6.0 (version bumps, changelog, SHA256SUMS, housekeeping)"
```

---

### Task 8: Definition-of-Done review pipeline

Per `~/.claude/CLAUDE.md`. The work is committed incrementally, so reviewers
review the **branch diff** (`git diff main...HEAD`), not uncommitted changes.

- [ ] **Step 1: Static checks** — `bash -n` ×3, `shellcheck` (plain severity, mirrors CI), `tests/integration.sh`: all green.
- [ ] **Step 2: Codex availability** — `codex exec "Hello"` responds <10s; if it hangs at 0% CPU, fall back to `agy -p "$(<.review/codex-prompt.txt)" --dangerously-skip-permissions --add-dir .`.
- [ ] **Step 3: Codex review (Agent A)** — prompt via `.review/codex-prompt.txt` (file-based, foreground), reviewing `git diff main...HEAD` for quality/correctness/security/consistency; findings to `.review/codex-a-findings.md`, FINDINGS/VERDICT format.
- [ ] **Step 4: Claude review (Agent A)** — spawn claude agent reviewing the same branch diff; findings to `.review/claude-a-findings.md`.
- [ ] **Step 5: Gate** — both VERDICT: PASS (zero CRITICAL/WARN). On FAIL: fix all findings, re-run all reviewers from scratch.
- [ ] **Step 6: `rm -rf .review/`** then final commit if fixes were made. Stop — ask the user before pushing or tagging.
