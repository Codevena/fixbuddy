#!/usr/bin/env bash
# Deterministic integration tests for the single-file fixbuddy. No network, no real gh, no
# real agents: PATH is prefixed with tests/stubs (canned gh + scripted agent
# doubles) and the GitHub remote is a local bare repository, so branch
# creation, commits, and pushes are real git operations. Each scenario runs in
# a fresh mktemp fixture with HOME redirected (no ~/.fixbuddy leakage).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUBS="$ROOT/tests/stubs"
REAL_GIT="$(command -v git)"
PASS=0
FAIL=0
CURRENT=""

fail() { FAIL=$((FAIL+1)); printf 'FAIL %s: %s\n' "$CURRENT" "$*"; }

assert_grep()    { grep -qE -- "$2" "$1" || fail "expected /$2/ in ${1##*/}"; }
assert_no_grep() { if grep -qE -- "$2" "$1"; then fail "did not expect /$2/ in ${1##*/}"; fi; }
assert_substr()  { grep -qF -- "$2" "$1" || fail "expected '$2' in ${1##*/}"; }

make_fixture() {
  FIXBUDDY_TEST_BIN=""
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
    PATH="${FIXBUDDY_TEST_BIN:+$FIXBUDDY_TEST_BIN:}$STUBS:$PATH" \
    FIXBUDDY_TEST_REAL_GIT="$REAL_GIT" FIXBUDDY_TEST_PROJECT="$TMP/project" \
    GH_TOKEN="test-token-must-not-leak" \
    FIXBUDDY_TEST_SCENARIO="$SCENARIO" \
    FIXBUDDY_TEST_MUTLOG="$MUTLOG" \
    FIXBUDDY_TEST_STAGELOG="$STAGELOG" \
    FIXBUDDY_TEST_AGYLOG="$AGYLOG" \
    bash "$ROOT/fixbuddy" --repo acme/app --project "$TMP/project" --yes "$@" \
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

test_verify_residue_is_stashed() {
  # No agent CLI offers an enforced read-only mode, so files written during the
  # verify stage must be stashed away before the fix branch is created — the
  # fix stub emits DONE-BLOCKED if it still sees the residue file.
  SCENARIO=verifydirty; make_fixture
  run_fixbuddy --auto-merge
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:pr-open'
  assert_no_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:needs-human'
}

test_verify_residue_cleaned_on_early_return() {
  # The verify guards must run on EVERY outcome, not only PROCEED: here the
  # verify agent dirties the tree AND commits on base, then reports a false
  # positive. The operator checkout must come out clean regardless.
  SCENARIO=fpdirty; make_fixture
  run_fixbuddy --auto-merge
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^issue close 7'
  assert_no_grep "$MUTLOG" '^pr create '
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:needs-human'
  [ -z "$(git -C "$TMP/project" status --porcelain)" ] \
    || fail "verify residue left in the worktree"
  [ "$(git -C "$TMP/project" rev-parse refs/heads/main)" = "$(git -C "$TMP/origin.git" rev-parse refs/heads/main)" ] \
    || fail "verify commit left on the base branch"
}

test_verify_commit_is_discarded() {
  # A verify agent that COMMITS (the worktree stays clean, so the residue
  # stash cannot catch it) must not get that commit into the fix branch: the
  # base ref is pinned back to its pre-verify position.
  SCENARIO=verifycommit; make_fixture
  run_fixbuddy --auto-merge
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^pr create '
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:needs-human'
  git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    && fail "rogue verify commit was pushed"
}

test_reviewer_commit_is_discarded() {
  # A reviewer that commits to the fix branch must not get those commits
  # pushed: the branch is pinned back to the commit the diff was taken from.
  SCENARIO=reviewcommit; make_fixture
  run_fixbuddy --auto-merge
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:pr-open'
  [ "$(git -C "$TMP/origin.git" rev-list --count refs/heads/main..refs/heads/fix/issue-7)" -eq 1 ] \
    || fail "rogue reviewer commit was pushed"
}

test_reviewer_uncommitted_residue_survives_commit_reset() {
  SCENARIO=reviewcommitdirty; make_fixture
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^pr create .*--head fix/issue-7'
  git -C "$TMP/project" stash list | grep -q 'fixbuddy-review-residue-7' \
    || fail "reviewer uncommitted residue was lost during commit reset"
}

test_reviewer_residue_cleaned_before_retry() {
  # A reviewer that modifies tracked files and then REJECTS must not poison
  # the retry: without cleanup the fix-branch recreation fails on the dirty
  # tree (fix:needs-human) or the residue leaks into the next fix attempt.
  SCENARIO=reviewdirty; make_fixture
  run_fixbuddy --auto-merge
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:rejected'
  assert_no_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:needs-human'
  [ "$(grep -c '^claude:fix$' "$STAGELOG")" -eq 2 ] || fail "expected 2 fix attempts"
}

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

test_notify_reports_aborted_batch() {
  # With --crash-abort 1 a single crash aborts the batch; the notification
  # must still fire and carry FIXBUDDY_ABORTED=true.
  SCENARIO=crash; make_fixture
  run_fixbuddy --auto-merge --crash-abort 1 \
    --notify-cmd 'env | grep ^FIXBUDDY_ > notify-env.txt; cat > notify-stdin.txt'
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_substr "$TMP/notify-env.txt" "FIXBUDDY_ABORTED=true"
  assert_substr "$TMP/notify-stdin.txt" "ABORTED"
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

test_default_does_not_request_auto_merge() {
  SCENARIO=happy; make_fixture
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^pr create .*--head fix/issue-7'
  assert_no_grep "$MUTLOG" '^pr merge '
}

test_fix_agent_branch_switch_cannot_push() {
  SCENARIO=fixswitch; make_fixture
  run_fixbuddy --max-retries 0
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:needs-human'
  assert_no_grep "$MUTLOG" '^pr create '
  git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    && fail "branch switched by fixer was pushed"
  [ "$(git -C "$TMP/project" rev-parse refs/heads/main)" = "$(git -C "$TMP/origin.git" rev-parse refs/heads/main)" ] \
    || fail "rogue base commit was not removed"
}

test_review_agent_branch_switch_cannot_push() {
  SCENARIO=reviewswitch; make_fixture
  run_fixbuddy --max-retries 0
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:needs-human'
  assert_no_grep "$MUTLOG" '^pr create '
  git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    && fail "branch switched by reviewer was pushed"
  [ "$(git -C "$TMP/project" rev-parse refs/heads/main)" = "$(git -C "$TMP/origin.git" rev-parse refs/heads/main)" ] \
    || fail "reviewer commit contaminated base"
}

test_fetch_failure_blocks_before_fix() {
  SCENARIO=happy; make_fixture
  git -C "$TMP/project" remote set-url origin "$TMP/no-such-remote.git"
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$STAGELOG" ':fix$'
  assert_no_grep "$STAGELOG" ':verify$'
  assert_no_grep "$MUTLOG" '^pr create '
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:needs-human'
}

test_mismatched_origin_causes_no_writes() {
  SCENARIO=origin-mismatch; make_fixture
  run_fixbuddy
  [ "$RC" -eq 2 ] || fail "expected origin rejection exit 2, got $RC"
  [ ! -s "$MUTLOG" ] || fail "origin mismatch caused GitHub writes"
  [ ! -s "$STAGELOG" ] || fail "origin mismatch invoked an agent"
  git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    && fail "origin mismatch pushed a branch"
}

test_mismatched_push_destination_causes_no_writes() {
  SCENARIO=pushurl-mismatch; make_fixture
  run_fixbuddy
  [ "$RC" -eq 2 ] || fail "expected push-origin rejection exit 2, got $RC"
  [ ! -s "$MUTLOG" ] || fail "push origin mismatch caused GitHub writes"
  [ ! -s "$STAGELOG" ] || fail "push origin mismatch invoked an agent"
}

test_reviewer_cannot_redirect_push_destination() {
  SCENARIO=reviewpushurl; make_fixture
  git init -q --bare "$TMP/wrong.git"
  run_fixbuddy
  [ "$RC" -ne 0 ] || fail "origin changed after review but run succeeded"
  assert_no_grep "$MUTLOG" '^pr create '
  git -C "$TMP/wrong.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    && fail "reviewer redirected the approved branch to another remote"
  assert_substr "$RUNLOG" 'origin fetch/push destination does not match'
}

test_verify_reads_fetched_base() {
  SCENARIO=freshbase; make_fixture
  git clone -q "$TMP/origin.git" "$TMP/other" 2>/dev/null
  (
    cd "$TMP/other" || exit 1
    git config user.email "test@example.com"
    git config user.name "fixbuddy-itest"
    git checkout -q main
    echo "new remote base" >> src/app.txt
    git add src/app.txt
    git commit -q -m "remote update"
    git push -q origin main
  )
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$STAGELOG" '^claude:verify$'
  assert_grep "$STAGELOG" '^claude:fix$'
  assert_no_grep "$MUTLOG" '^issue close 7'
}

test_stale_remote_branch_is_replaced_with_lease() {
  SCENARIO=happy; make_fixture
  (
    cd "$TMP/project" || exit 1
    git checkout -qb fix/issue-7
    echo "old closed PR" >> src/app.txt
    git add src/app.txt
    git commit -q -m "stale branch"
    git push -q origin fix/issue-7
    git checkout -q main
    git branch -D fix/issue-7 >/dev/null
  )
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^pr create .*--head fix/issue-7'
  git -C "$TMP/origin.git" show refs/heads/fix/issue-7:src/app.txt | grep -q 'fixed by claude' \
    || fail "stale remote branch was not replaced by reviewed fix"
}

test_open_pr_remote_branch_is_not_replaced() {
  SCENARIO=stale-open-pr; make_fixture
  (
    cd "$TMP/project" || exit 1
    git checkout -qb fix/issue-7
    echo "existing PR branch" >> src/app.txt
    git add src/app.txt
    git commit -q -m "existing PR branch"
    git push -q origin fix/issue-7
    git checkout -q main
    git branch -D fix/issue-7 >/dev/null
  )
  local old_tip
  old_tip=$(git -C "$TMP/origin.git" rev-parse refs/heads/fix/issue-7)
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  [ "$(git -C "$TMP/origin.git" rev-parse refs/heads/fix/issue-7)" = "$old_tip" ] \
    || fail "open PR branch was overwritten"
  assert_no_grep "$MUTLOG" '^pr create '
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:pr-open'
}

test_push_uses_reviewed_sha_when_branch_moves_late() {
  SCENARIO=pushrace; make_fixture
  mkdir -p "$TMP/bin"
  cp "$STUBS/git-push-race" "$TMP/bin/git"
  chmod +x "$TMP/bin/git"
  FIXBUDDY_TEST_BIN="$TMP/bin"
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^pr create .*--head fix/issue-7'
  if git -C "$TMP/origin.git" show refs/heads/fix/issue-7:src/app.txt | grep -q 'rogue late commit'; then
    fail "unreviewed late commit reached remote branch"
  fi
  git -C "$TMP/origin.git" show refs/heads/fix/issue-7:src/app.txt | grep -q 'fixed by claude' \
    || fail "reviewed fix was not pushed"
}

test_failed_pr_creation_preserves_replaced_remote_branch() {
  SCENARIO=pr-create-fail; make_fixture
  (
    cd "$TMP/project" || exit 1
    git checkout -qb fix/issue-7
    echo "closed PR branch" >> src/app.txt
    git add src/app.txt
    git commit -q -m "closed PR branch"
    git push -q origin fix/issue-7
    git checkout -q main
    git branch -D fix/issue-7 >/dev/null
  )
  run_fixbuddy
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    || fail "PR-create failure deleted the only remote branch ref"
  git -C "$TMP/origin.git" show refs/heads/fix/issue-7:src/app.txt | grep -q 'fixed by claude' \
    || fail "reviewed replacement branch was not retained"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:blocked'
}

test_mixed_verdict_cannot_approve() {
  SCENARIO=mixedverdict; make_fixture
  run_fixbuddy --max-retries 0
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^pr create '
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:rejected'
}

test_prefixed_approval_cannot_approve() {
  SCENARIO=prefixverdict; make_fixture
  run_fixbuddy --max-retries 0
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^pr create '
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:rejected'
}

test_nonzero_reviewer_exit_cannot_approve() {
  SCENARIO=reviewexitbad; make_fixture
  run_fixbuddy --max-retries 0
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$STAGELOG" '^codex-final:DONE-APPROVED$'
  assert_no_grep "$MUTLOG" '^pr create '
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:blocked'
}

test_codex_verbose_transcript_uses_only_final_message() {
  SCENARIO=codexverbose; make_fixture
  run_fixbuddy --max-retries 0
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$STAGELOG" '^codex-final:DONE-APPROVED$'
  assert_grep "$MUTLOG" '^pr create .*--head fix/issue-7'
  git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    || fail "approved final message did not push the fix branch"
}

test_codex_as_fix_agent_uses_final_verify_and_fix_messages() {
  SCENARIO=codexfixer; make_fixture
  run_fixbuddy --fix-agent codex --review-agent claude --max-retries 0
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$STAGELOG" '^codex-final:DONE-PROCEED$'
  assert_grep "$STAGELOG" '^codex-final:DONE-FIX-APPLIED$'
  assert_grep "$STAGELOG" '^claude:review$'
  assert_grep "$MUTLOG" '^pr create .*--head fix/issue-7'
  git -C "$TMP/origin.git" show refs/heads/fix/issue-7:src/app.txt | grep -q 'fixed by codex' \
    || fail "Codex fix was not pushed after a canonical final message"
}

test_codex_empty_final_message_blocks_push() {
  SCENARIO=codexmissing; make_fixture
  run_fixbuddy --max-retries 0
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^pr create '
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:blocked'
  git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    && fail "raw approval was pushed despite an empty final message"
}

test_codex_final_rejection_overrides_raw_approval() {
  SCENARIO=codexfinalreject; make_fixture
  run_fixbuddy --max-retries 0
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$STAGELOG" '^codex-final:DONE-REJECTED:'
  assert_no_grep "$MUTLOG" '^pr create '
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:rejected'
  git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    && fail "raw approval was pushed despite canonical rejection"
}

test_codex_timeout_with_final_approval_cannot_push() {
  SCENARIO=reviewtimeoutfinal; make_fixture
  run_fixbuddy --max-retries 0 --agent-timeout 1 --crash-abort 1
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$STAGELOG" '^codex-final:DONE-APPROVED$'
  assert_no_grep "$MUTLOG" '^pr create '
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:blocked'
  git -C "$TMP/origin.git" show-ref --verify --quiet refs/heads/fix/issue-7 \
    && fail "timed-out approval was pushed"
}

test_queue_reads_past_two_hundred() {
  SCENARIO=many; make_fixture
  run_fixbuddy --dry-run
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$RUNLOG" '#201 '
}

test_unstick_reads_past_two_hundred() {
  SCENARIO=many-stuck; make_fixture
  run_fixbuddy --max 1
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 201 .*--remove-label fix:pr-open'
}

test_closed_merged_issue_gets_applied_label() {
  # A human merge closes the issue before the next FixBuddy run. Reconciliation
  # must replace the stale PR-open label even though the issue is now closed.
  SCENARIO=closed-merged; make_fixture
  run_fixbuddy --max 1
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_grep "$MUTLOG" '^issue edit 42 .*--add-label fix:applied.*--remove-label fix:pr-open'
  assert_no_grep "$MUTLOG" '^pr create '
  [ ! -s "$STAGELOG" ] || fail "closed issue invoked an agent"
}

test_closed_issue_without_merged_pr_keeps_label() {
  SCENARIO=closed-unmerged; make_fixture
  run_fixbuddy --max 1
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^issue edit 42 '
  [ ! -s "$STAGELOG" ] || fail "closed issue invoked an agent"
}

test_old_merge_does_not_apply_later_manual_closure() {
  # A prior fix/issue-42 PR merged, then the issue was reopened and later
  # closed manually. Only the current ClosedEvent, not branch history, counts.
  SCENARIO=closed-old-merge; make_fixture
  run_fixbuddy --max 1
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^issue edit 42 '
}

test_other_merged_pr_cannot_apply_closed_issue() {
  SCENARIO=closed-other-merged; make_fixture
  run_fixbuddy --max 1
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^issue edit 42 '
}

test_fork_merge_cannot_apply_closed_issue() {
  # A fork may use the same head-branch name, but FixBuddy only pushes branches
  # in the selected repository. Its merge must not be attributed to FixBuddy.
  SCENARIO=closed-fork-merged; make_fixture
  run_fixbuddy --max 1
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^issue edit 42 '
}

test_graphql_partial_error_cannot_apply_closed_issue() {
  SCENARIO=closed-graphql-error; make_fixture
  run_fixbuddy --max 1
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^issue edit 42 '
  assert_substr "$RUNLOG" 'leaving labels alone'
}

test_closed_issue_pr_lookup_failure_keeps_label() {
  SCENARIO=closed-pr-query-fail; make_fixture
  run_fixbuddy --max 1
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  assert_no_grep "$MUTLOG" '^issue edit 42 '
  assert_substr "$RUNLOG" 'leaving labels alone'
}

test_closed_merged_issue_dry_run_is_read_only() {
  SCENARIO=closed-merged; make_fixture
  run_fixbuddy --dry-run
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  [ ! -s "$MUTLOG" ] || fail "dry-run relabeled a closed issue"
  [ ! -s "$STAGELOG" ] || fail "dry-run invoked an agent"
}

test_one_second_agent_timeout() {
  SCENARIO=slowverify; make_fixture
  local started elapsed
  started=$(date +%s)
  run_fixbuddy --agent-timeout 1 --crash-abort 1
  elapsed=$(( $(date +%s) - started ))
  [ "$RC" -eq 0 ] || fail "exit code $RC"
  [ "$elapsed" -lt 7 ] || fail "one-second timeout took ${elapsed}s"
  assert_grep "$MUTLOG" '^issue edit 7 .*--add-label fix:blocked'
}

test_action_logs_copy_only_this_run() {
  SCENARIO=happy; make_fixture
  local runs="$TMP/home/.fixbuddy/runs" pointer="$TMP/log-pointer"
  mkdir -p "$runs/old-run" "$runs/current-run" "$TMP/workspace"
  printf 'old private output\n' > "$runs/old-run/issue-1.log"
  printf 'current output\n' > "$runs/current-run/issue-7.log"
  printf '%s\n' "$runs/current-run" > "$pointer"
  HOME="$TMP/home" FIXBUDDY_LOG_POINTER="$pointer" \
    FIXBUDDY_WORKSPACE="$TMP/workspace" GITHUB_OUTPUT="$TMP/action-output" \
    bash "$ROOT/src/action-collect-logs.sh" > "$RUNLOG" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] || fail "collector exit code $RC"
  [ -f "$TMP/workspace/fixbuddy-logs/current-run/issue-7.log" ] \
    || fail "current run log was not copied"
  [ ! -e "$TMP/workspace/fixbuddy-logs/old-run" ] \
    || fail "older run was copied into the workspace"
  assert_substr "$TMP/action-output" 'logs_path='
}

test_json_preview_uses_core_queue() {
  SCENARIO=happy; make_fixture
  ( cd "$TMP" && HOME="$TMP/home" PATH="$STUBS:$PATH" \
    FIXBUDDY_TEST_SCENARIO="$SCENARIO" FIXBUDDY_TEST_MUTLOG="$MUTLOG" \
    FIXBUDDY_TEST_REAL_GIT="$REAL_GIT" FIXBUDDY_TEST_PROJECT="$TMP/project" \
    bash "$ROOT/fixbuddy" --repo acme/app --project "$TMP/project" \
      --dry-run --json --no-auto-merge ) > "$TMP/preview.json" 2> "$RUNLOG"
  RC=$?
  [ "$RC" -eq 0 ] || fail "preview exit code $RC"
  jq -e '.repo == "acme/app" and .autoMerge == false and .issues[0].number == 7' \
    "$TMP/preview.json" >/dev/null 2>&1 || fail "preview JSON did not contain the core issue queue"
  [ ! -s "$MUTLOG" ] || fail "JSON preview caused GitHub mutation"
}

test_json_preview_empty_queue() {
  SCENARIO=empty; make_fixture
  ( cd "$TMP" && HOME="$TMP/home" PATH="$STUBS:$PATH" \
    FIXBUDDY_TEST_SCENARIO="$SCENARIO" FIXBUDDY_TEST_MUTLOG="$MUTLOG" \
    FIXBUDDY_TEST_REAL_GIT="$REAL_GIT" FIXBUDDY_TEST_PROJECT="$TMP/project" \
    bash "$ROOT/fixbuddy" --repo acme/app --project "$TMP/project" \
      --dry-run --json ) > "$TMP/preview.json" 2> "$RUNLOG"
  RC=$?
  [ "$RC" -eq 0 ] || fail "empty preview exit code $RC"
  jq -e '.issues == []' "$TMP/preview.json" >/dev/null 2>&1 \
    || fail "empty preview was not valid JSON with zero issues"
}

test_wizard_autonomous_mode_is_explicit() {
  SCENARIO=happy; make_fixture
  printf 'acme/app\n%s\n5\n3\n1\n1\n1\nn\nn\n' "$TMP/project" | \
    ( cd "$TMP" && HOME="$TMP/home" PATH="$STUBS:$PATH" \
      bash "$ROOT/fixbuddy" --wizard ) > "$RUNLOG" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] || fail "wizard exit code $RC"
  assert_substr "$RUNLOG" '--auto-merge'
}

test_help_does_not_cut_off_header() {
  SCENARIO=happy; make_fixture
  HOME="$TMP/home" bash "$ROOT/fixbuddy" --help > "$RUNLOG" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] || fail "help exit code $RC"
  assert_substr "$RUNLOG" 'cannot be removed from the CLI.'
}

make_install_fixture() {
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/fixbuddy-install-itest.XXXXXX")"
  RUNLOG="$TMP/install.log"
  mkdir -p "$TMP/source/v0.7.1" "$TMP/source/v0.8.0" "$TMP/source/v0.9.4" "$TMP/source/main" "$TMP/bin"
  for ref in v0.7.1 v0.8.0 main; do
    cp "$ROOT/src/core.sh" "$TMP/source/$ref/fixbuddy.sh"
    cp "$ROOT/src/wizard.sh" "$TMP/source/$ref/fixbuddy-wizard.sh"
  done
  cp "$ROOT/src/tui.py" "$TMP/source/v0.8.0/fixbuddy-tui.py"
  cp "$ROOT/src/tui.py" "$TMP/source/main/fixbuddy-tui.py"
  cp "$ROOT/fixbuddy" "$TMP/source/v0.9.4/fixbuddy"
  cp "$ROOT/fixbuddy" "$TMP/source/main/fixbuddy"
  ( cd "$TMP/source/v0.7.1" && shasum -a 256 fixbuddy.sh fixbuddy-wizard.sh > SHA256SUMS )
  ( cd "$TMP/source/v0.8.0" && shasum -a 256 fixbuddy.sh fixbuddy-wizard.sh fixbuddy-tui.py > SHA256SUMS )
  ( cd "$TMP/source/v0.9.4" && shasum -a 256 fixbuddy > SHA256SUMS )
  ( cd "$TMP/source/main" && shasum -a 256 fixbuddy > SHA256SUMS )
  ln -s "$STUBS/curl" "$TMP/bin/curl"
}

test_installer_default_ref_is_one_file() {
  make_install_fixture
  FIXBUDDY_INSTALL_FIXTURE="$TMP/source" PATH="$TMP/bin:$PATH" \
    bash "$ROOT/install.sh" --prefix "$TMP/installed" > "$RUNLOG" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] || fail "default installer exit code $RC"
  [ -x "$TMP/installed/fixbuddy" ] || fail "single-file command not installed"
  [ "$(find "$TMP/installed" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "default installed more than one file"
  assert_substr "$RUNLOG" 'v0.9.4'
}

test_installer_legacy_ref_stays_two_scripts() {
  make_install_fixture
  FIXBUDDY_INSTALL_FIXTURE="$TMP/source" PATH="$TMP/bin:$PATH" \
    bash "$ROOT/install.sh" --ref v0.8.0 --prefix "$TMP/installed" > "$RUNLOG" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] || fail "legacy installer exit code $RC"
  [ -x "$TMP/installed/fixbuddy.sh" ] || fail "legacy CLI not installed"
  [ -x "$TMP/installed/fixbuddy-wizard.sh" ] || fail "legacy wizard not installed"
  [ ! -e "$TMP/installed/fixbuddy-tui.py" ] || fail "old tag unexpectedly installed TUI"
}

test_installer_tui_is_explicit() {
  make_install_fixture
  FIXBUDDY_INSTALL_FIXTURE="$TMP/source" PATH="$TMP/bin:$PATH" \
    bash "$ROOT/install.sh" --ref v0.8.0 --with-tui --prefix "$TMP/installed" > "$RUNLOG" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] || fail "TUI installer exit code $RC"
  [ -x "$TMP/installed/fixbuddy-tui.py" ] || fail "TUI not installed"
}

test_installer_local_is_one_file() {
  make_install_fixture
  bash "$ROOT/install.sh" --local --prefix "$TMP/installed" > "$RUNLOG" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] || fail "local installer exit code $RC"
  [ -x "$TMP/installed/fixbuddy" ] || fail "single-file command not installed"
  [ "$(find "$TMP/installed" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "more than one file installed"
  "$TMP/installed/fixbuddy" --version > "$RUNLOG" 2>&1
  assert_substr "$RUNLOG" "$(bash "$ROOT/fixbuddy" --version)"
}

test_installer_main_is_one_file() {
  make_install_fixture
  FIXBUDDY_INSTALL_FIXTURE="$TMP/source" PATH="$TMP/bin:$PATH" \
    bash "$ROOT/install.sh" --ref main --prefix "$TMP/installed" > "$RUNLOG" 2>&1
  RC=$?
  [ "$RC" -eq 0 ] || fail "single-file ref installer exit code $RC"
  [ -x "$TMP/installed/fixbuddy" ] || fail "single-file command not installed from ref"
  [ "$(find "$TMP/installed" -type f | wc -l | tr -d ' ')" -eq 1 ] || fail "more than one file installed"
}

# ---------------- Runner ----------------

TESTS=(test_happy_path test_false_positive test_review_reject test_check_gate
       test_dry_run_read_only test_crash_labels_blocked
       test_agy_full_pipeline test_gemini_rejected_with_migration_hint
       test_agy_internal_timeout_is_blocked
       test_verify_residue_is_stashed test_verify_commit_is_discarded
       test_verify_residue_cleaned_on_early_return
       test_reviewer_commit_is_discarded test_reviewer_uncommitted_residue_survives_commit_reset
       test_reviewer_residue_cleaned_before_retry
       test_notify_cmd_receives_summary test_notify_failure_does_not_break_run
       test_notify_reports_blocked test_notify_reports_aborted_batch
       test_notify_cmd_from_config test_notify_skipped_on_dry_run
       test_default_does_not_request_auto_merge
       test_fix_agent_branch_switch_cannot_push
       test_review_agent_branch_switch_cannot_push
       test_fetch_failure_blocks_before_fix test_verify_reads_fetched_base
       test_mismatched_origin_causes_no_writes test_mismatched_push_destination_causes_no_writes
       test_reviewer_cannot_redirect_push_destination
       test_stale_remote_branch_is_replaced_with_lease test_open_pr_remote_branch_is_not_replaced
       test_push_uses_reviewed_sha_when_branch_moves_late
       test_failed_pr_creation_preserves_replaced_remote_branch
       test_mixed_verdict_cannot_approve test_prefixed_approval_cannot_approve
       test_nonzero_reviewer_exit_cannot_approve
       test_codex_verbose_transcript_uses_only_final_message
       test_codex_as_fix_agent_uses_final_verify_and_fix_messages
       test_codex_empty_final_message_blocks_push
       test_codex_final_rejection_overrides_raw_approval
       test_codex_timeout_with_final_approval_cannot_push
       test_queue_reads_past_two_hundred test_unstick_reads_past_two_hundred
       test_closed_merged_issue_gets_applied_label
       test_closed_issue_without_merged_pr_keeps_label
       test_old_merge_does_not_apply_later_manual_closure
       test_other_merged_pr_cannot_apply_closed_issue
       test_fork_merge_cannot_apply_closed_issue
       test_graphql_partial_error_cannot_apply_closed_issue
       test_closed_issue_pr_lookup_failure_keeps_label
       test_closed_merged_issue_dry_run_is_read_only
       test_one_second_agent_timeout test_action_logs_copy_only_this_run
       test_json_preview_uses_core_queue test_json_preview_empty_queue
       test_wizard_autonomous_mode_is_explicit
       test_help_does_not_cut_off_header
       test_installer_default_ref_is_one_file test_installer_legacy_ref_stays_two_scripts
       test_installer_tui_is_explicit
       test_installer_local_is_one_file test_installer_main_is_one_file)

# A named scenario runs alone for fast RED/GREEN cycles. With no argument the
# complete offline suite runs, as in CI.
if [ "$#" -gt 0 ]; then TESTS=("$@"); fi

for t in "${TESTS[@]}"; do
  CURRENT="$t"
  FAIL_BEFORE=$FAIL
  "$t"
  if [ "$FAIL" -eq "$FAIL_BEFORE" ]; then
    PASS=$((PASS+1)); printf 'ok   %s\n' "$t"
  else
    printf '     run log tail:\n'; tail -5 "$RUNLOG" 2>/dev/null | sed 's/^/     | /'
  fi
  if [ "${FIXBUDDY_KEEP_FIXTURES:-0}" = "1" ]; then
    printf '     fixture: %s\n' "$TMP"
  else
    rm -rf "$TMP"
  fi
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
