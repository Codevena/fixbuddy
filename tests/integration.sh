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
    cd "$TMP/project" || exit 1
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
  run_fixbuddy --auto-merge
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

test_false_positive() {
  SCENARIO=falsepos; make_fixture
  run_fixbuddy --auto-merge
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:false-positive'
  assert_grep "$MUTLOG" '^issue close 7'
  assert_no_grep "$STAGELOG" ':fix$'
}

test_review_reject() {
  SCENARIO=reject; make_fixture
  run_fixbuddy --auto-merge
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
  run_fixbuddy --auto-merge
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:blocked'
  # the label-create bootstrap lists every label; only issue edits matter here
  assert_no_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:needs-human'
}

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
  assert_no_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:needs-human'
}

# ---------------- Runner ----------------

TESTS=(test_happy_path test_false_positive test_review_reject test_check_gate
       test_dry_run_read_only test_crash_labels_blocked
       test_agy_full_pipeline test_gemini_rejected_with_migration_hint
       test_agy_internal_timeout_is_blocked)

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
