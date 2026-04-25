#!/usr/bin/env bash
# fixbuddy v0.3.2 — two-agent pipeline for autonomous issue fixing
#
# Pipeline per issue:
#   1. VERIFY (fix-agent)    — is this real? → PROCEED / FALSE-POSITIVE / BLOCKED
#   2. FIX    (fix-agent)    — implement fix on fix/issue-N branch + local commit
#   3. REVIEW (review-agent) — independent reviewer, fresh context → APPROVED / REJECTED
#      (1× retry on reject, with reviewer feedback fed back)
#   4. PUSH  + PR + optional auto-merge — CI gates regressions
#
# Crash handling (v0.3):
#   - Watchdog kills agents that exceed --agent-timeout (rc=124 → BLOCKED)
#   - Usage-limit / transport errors detected as rc=125 → BLOCKED (not rejected)
#   - Issues labeled `fix:blocked` auto-requeue on the next run
#   - N consecutive crashes (default 3) abort the batch with a clear message
#
# Usage:
#   ./fixbuddy.sh --repo <owner/repo> --project <path> [options]
#
# Options:
#   --label <label>           Filter issues by label (repeatable)
#   --severity <level>        Only issues with label severity:<level>
#   --max <n>                 Stop after N issues processed
#   --fix-agent <agent>       claude | codex | opencode | gemini (default: claude)
#   --review-agent <agent>    claude | codex | opencode | gemini (default: codex — cross-agent)
#                             Note: gemini runs read-only (--approval-mode plan) when
#                             used as verify/review agent. Warned about as fix-agent.
#   --max-retries <n>         Fix retries after review rejection (default: 1 → 2 total attempts)
#   --agent-timeout <secs>    Wall-clock timeout per agent invocation (default: 1200 = 20min)
#   --crash-abort <n>         Abort batch after N consecutive agent crashes (default: 3)
#   --base <branch>           Base branch (default: auto-detect main/master)
#   --no-auto-merge           Create PR but don't enable auto-merge
#   --skip-label <lbl>        Skip issues with this label (default: fix:applied)
#   --dry-run                 List targets, don't execute
#   --yes, -y                 Skip confirmation

set -uo pipefail
VERSION="0.3.2"

# -------- Defaults --------
REPO=""
PROJECT=""
LABELS=()
SEVERITY=""
MAX=""
FIX_AGENT="claude"
REVIEW_AGENT="codex"
MAX_RETRIES=1
AGENT_TIMEOUT=1200  # 20 min per agent invocation
CRASH_ABORT_THRESHOLD=3
BASE_BRANCH=""
SKIP_LABEL="fix:applied"
AUTO_MERGE=true
DRY_RUN=false
AUTO_YES=false

# Runtime crash counter (bumped by handle_agent_crash, reset on successful agent output)
CONSECUTIVE_CRASHES=0

# -------- Logging --------
ts()    { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
info()  { printf "\033[36m[INFO ]\033[0m %s %s\n" "$(ts)" "$*" >&2; }
warn()  { printf "\033[33m[WARN ]\033[0m %s %s\n" "$(ts)" "$*" >&2; }
err()   { printf "\033[31m[ERROR]\033[0m %s %s\n" "$(ts)" "$*" >&2; }
ok()    { printf "\033[32m[ OK  ]\033[0m %s %s\n" "$(ts)" "$*" >&2; }
hdr()   { printf "\033[35m\n====== %s ======\033[0m\n" "$*" >&2; }

# -------- Arg parsing --------
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --label) LABELS+=("$2"); shift 2 ;;
    --severity) SEVERITY="$2"; shift 2 ;;
    --max) MAX="$2"; shift 2 ;;
    --fix-agent) FIX_AGENT="$2"; shift 2 ;;
    --review-agent) REVIEW_AGENT="$2"; shift 2 ;;
    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    --agent-timeout) AGENT_TIMEOUT="$2"; shift 2 ;;
    --crash-abort) CRASH_ABORT_THRESHOLD="$2"; shift 2 ;;
    --base) BASE_BRANCH="$2"; shift 2 ;;
    --no-auto-merge) AUTO_MERGE=false; shift ;;
    --skip-label) SKIP_LABEL="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -y|--yes) AUTO_YES=true; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    --version) echo "fixbuddy $VERSION"; exit 0 ;;
    *) err "Unknown arg: $1"; exit 2 ;;
  esac
done

# -------- Validation --------
[ -n "$REPO" ]    || { err "--repo is required"; exit 2; }
[ -n "$PROJECT" ] || { err "--project is required"; exit 2; }
[ -d "$PROJECT" ] || { err "project path does not exist: $PROJECT"; exit 2; }
[ -d "$PROJECT/.git" ] || { err "not a git repo: $PROJECT"; exit 2; }

for agent in "$FIX_AGENT" "$REVIEW_AGENT"; do
  case "$agent" in
    claude)   command -v claude   >/dev/null || { err "claude CLI not found";   exit 2; } ;;
    codex)    command -v codex    >/dev/null || { err "codex CLI not found";    exit 2; } ;;
    opencode) command -v opencode >/dev/null || { err "opencode CLI not found"; exit 2; } ;;
    gemini)   command -v gemini   >/dev/null || { err "gemini CLI not found";   exit 2; } ;;
    *) err "unsupported agent: $agent (valid: claude, codex, opencode, gemini)"; exit 2 ;;
  esac
done

# Gemini is less reliable at independent reasoning than claude/codex/opencode — when used
# as the fix-agent it sometimes commits incomplete patches. We allow it (user's choice)
# but nudge toward using it read-only (verify/review) where it's much safer.
if [ "$FIX_AGENT" = "gemini" ]; then
  warn "gemini as fix-agent is experimental — it may produce incomplete or wrong fixes."
  warn "Consider --fix-agent claude (or codex/opencode) with --review-agent gemini instead."
fi

command -v gh >/dev/null || { err "gh CLI not found"; exit 2; }
command -v jq >/dev/null || { err "jq not found";    exit 2; }

# -------- Auto-detect base branch --------
if [ -z "$BASE_BRANCH" ]; then
  BASE_BRANCH=$(cd "$PROJECT" && git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||')
  [ -z "$BASE_BRANCH" ] && BASE_BRANCH="main"
fi
info "Base branch: $BASE_BRANCH"

# -------- Pre-flight: refuse to run on a dirty working tree --------
# fixbuddy creates commits on per-issue branches. A dirty tree (tracked modifications
# OR untracked files) can silently carry into those branches when git checkout happens
# to succeed — the fix agent would then see user WIP mixed in with its own work.
# Require a clean tree up-front; user recovers stashed content via `git stash pop` when
# the run is done.
dirty_status=$(cd "$PROJECT" && git status --porcelain)
if [ -n "$dirty_status" ]; then
  err "working tree at $PROJECT is not clean:"
  printf '%s\n' "$dirty_status" | sed 's/^/    /' >&2
  err "Commit, stash, or clean your changes before running fixbuddy (it creates commits"
  err "on per-issue branches and cannot safely share the worktree with local WIP)."
  exit 2
fi

# -------- Ensure control labels exist --------
for l_info in "fix:applied|0E8A16|fixbuddy merged a fix" \
              "fix:pr-open|1D76DB|fixbuddy opened a PR that is not merged yet" \
              "fix:blocked|D93F0B|agent could not resolve autonomously" \
              "fix:false-positive|CCCCCC|agent determined not a real issue" \
              "fix:rejected|B60205|reviewer rejected all fix attempts"; do
  IFS='|' read -r name color desc <<< "$l_info"
  gh label create "$name" --color "$color" --description "$desc" --repo "$REPO" --force >/dev/null 2>&1 || true
done

# -------- Fetch issues --------
search_args=(--repo "$REPO" --state open --json "number,title,labels,url,body" --limit 200)
for l in "${LABELS[@]}"; do search_args+=(--label "$l"); done
[ -n "$SEVERITY" ] && search_args+=(--label "severity:$SEVERITY")

info "Fetching issues from $REPO..."
issues_json=$(gh issue list "${search_args[@]}")
total_issues=$(echo "$issues_json" | jq 'length')

# Filter out completed, pending-PR, rejected, false-positive, and umbrella/meta issues.
filtered=$(echo "$issues_json" | jq --arg skip "$SKIP_LABEL" '
  [.[] | select(
    ((.labels|map(.name)) | index($skip) | not)
    and ((.labels|map(.name)) | index("fix:pr-open") | not)
    and ((.labels|map(.name)) | index("audit:umbrella") | not)
    and ((.labels|map(.name)) | index("audit:meta") | not)
    and ((.labels|map(.name)) | index("fix:false-positive") | not)
    and ((.labels|map(.name)) | index("fix:rejected") | not)
  )]')
target_count=$(echo "$filtered" | jq 'length')

info "Found $total_issues matching; $target_count actionable after filters"
[ "$target_count" = "0" ] && { warn "No issues to process."; exit 0; }

if $DRY_RUN; then
  echo ""
  echo "=== Would process (first 20): ==="
  echo "$filtered" | jq -r '.[] | "#\(.number) [\(.labels|map(.name)|join(","))] \(.title)"' | head -20
  exit 0
fi

if ! $AUTO_YES; then
  echo ""
  echo "About to run pipeline against $target_count issue(s) on $REPO"
  echo "  Fix agent:    $FIX_AGENT"
  echo "  Review agent: $REVIEW_AGENT"
  echo "  Project:      $PROJECT"
  echo "  Base branch:  $BASE_BRANCH"
  echo "  Auto-merge:   $AUTO_MERGE"
  [ -n "$MAX" ] && echo "  Max issues:   $MAX"
  echo ""
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in [yY]|[yY][eE][sS]) ;; *) info "Aborted."; exit 0 ;; esac
fi

# -------- Run directory --------
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
log_root="$HOME/.fixbuddy/runs/$run_id"
mkdir -p "$log_root"
info "Logs: $log_root"

# -------- Agent runner (with wall-clock timeout watchdog) --------
# Prevents hung claude/codex CLI invocations from stalling the pipeline.
# On timeout: sends TERM, waits 5s grace, then KILL. Returns output + exit code 124.
run_agent() {
  local agent="$1" prompt="$2" logfile="$3" stage="${4:-}"
  {
    echo "===== RUN_AGENT: $agent${stage:+ [$stage]} at $(ts) (timeout=${AGENT_TIMEOUT}s) ====="
    echo "----- PROMPT -----"
    printf "%s\n" "$prompt"
    echo "----- OUTPUT -----"
  } >> "$logfile"

  local outfile
  outfile=$(mktemp)

  # Gemini is restricted to read-only (plan mode) for verify/review — it should observe
  # and report, not write. Only the fix stage grants --yolo (tool-use). Claude/codex/
  # opencode manage their own permissions via their own flags.
  local gem_mode="yolo"
  case "$stage" in verify|review) gem_mode="plan" ;; esac

  # Launch agent pipeline in background; $! captures the PID of the last command.
  case "$agent" in
    claude)
      printf "%s" "$prompt" | claude --dangerously-skip-permissions -p - >"$outfile" 2>&1 &
      ;;
    codex)
      printf "%s" "$prompt" | codex exec --dangerously-bypass-approvals-and-sandbox >"$outfile" 2>&1 &
      ;;
    opencode)
      opencode run --dangerously-skip-permissions "$prompt" >"$outfile" 2>&1 &
      ;;
    gemini)
      gemini -p "$prompt" --approval-mode "$gem_mode" --output-format text >"$outfile" 2>&1 &
      ;;
  esac
  local agent_pid=$!

  # Watchdog — polls every 10s, kills process group on timeout
  (
    # `local` is a no-op inside a plain subshell, so use a regular assignment.
    waited=0
    while [ "$waited" -lt "$AGENT_TIMEOUT" ]; do
      sleep 10
      waited=$((waited+10))
      kill -0 "$agent_pid" 2>/dev/null || exit 0
    done
    pkill -TERM -P "$agent_pid" 2>/dev/null
    kill -TERM "$agent_pid" 2>/dev/null
    sleep 5
    pkill -KILL -P "$agent_pid" 2>/dev/null
    kill -KILL "$agent_pid" 2>/dev/null
    echo "" >> "$outfile"
    echo "[fixbuddy-watchdog] agent PID $agent_pid killed after ${AGENT_TIMEOUT}s wall-clock timeout" >> "$outfile"
  ) 2>/dev/null &
  local watch_pid=$!

  wait "$agent_pid" 2>/dev/null
  local rc=$?

  # Detect timeout by watchdog marker
  if grep -q "^\[fixbuddy-watchdog\]" "$outfile" 2>/dev/null; then
    rc=124
  fi

  # Detect agent crash — nonzero exit without any DONE-* marker.
  # Covers codex usage-limit (rc=1 + "You've hit your usage limit"), MCP transport
  # errors, and any other hard exit that prevents the agent from completing its task.
  # Distinct rc=125 lets the pipeline mark the issue fix:blocked (not fix:rejected)
  # so it re-enters the queue automatically on the next run.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && ! grep -qE '^DONE-' "$outfile" 2>/dev/null; then
    echo "" >> "$outfile"
    echo "[fixbuddy-crash] agent exited rc=$rc with no DONE marker (likely usage-limit or transport error)" >> "$outfile"
    rc=125
  fi

  kill "$watch_pid" 2>/dev/null
  wait "$watch_pid" 2>/dev/null

  local out
  out=$(cat "$outfile")
  rm -f "$outfile"

  printf "%s\n" "$out" >> "$logfile"
  echo "===== END $agent (rc=$rc) =====" >> "$logfile"
  printf "%s" "$out"
  return "$rc"
}

# -------- Crash handling helpers --------
is_crash() { [ "$1" -eq 124 ] || [ "$1" -eq 125 ]; }

cleanup_branch() {
  local num="$1" branch="$2" reason="$3"
  [ -n "$branch" ] || return 0
  (
    cd "$PROJECT" || exit 0
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git stash push --include-untracked -m "fixbuddy-$reason-$num-$(ts)" --quiet >/dev/null 2>&1 || true
    fi
    git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
    git branch -D "$branch" >/dev/null 2>&1 || true
  ) || true
}

# Called when run_agent returned a crash rc. Labels the issue fix:blocked (auto-requeues
# on next run), adds a comment explaining the failure class, cleans up the fix branch if
# provided, and bumps CONSECUTIVE_CRASHES so the main loop can abort after N in a row.
#
# Args: issue_num, stage (verify|fix|review), rc (124 or 125), branch-or-empty
handle_agent_crash() {
  local num="$1" stage="$2" rc="$3" branch="$4"
  local kind="unknown"
  [ "$rc" -eq 124 ] && kind="timeout (>${AGENT_TIMEOUT}s wall-clock)"
  [ "$rc" -eq 125 ] && kind="crash (likely usage-limit or transport error)"
  CONSECUTIVE_CRASHES=$((CONSECUTIVE_CRASHES+1))
  warn "[#$num] $stage → BLOCKED: $kind (consecutive crashes: $CONSECUTIVE_CRASHES)"
  gh issue edit "$num" --repo "$REPO" --add-label "fix:blocked" >/dev/null 2>&1 || true
  gh issue comment "$num" --repo "$REPO" --body "**fixbuddy $stage → BLOCKED**: $kind

Will be retried automatically on the next fixbuddy run (the \`fix:blocked\` label does not exclude from the queue).

_Auto-generated by fixbuddy v$VERSION. See fixbuddy-crash/watchdog markers in the run log._" >/dev/null 2>&1 || true
  if [ -n "$branch" ]; then
    # Stash any worktree state instead of `reset --hard` so we never destroy user WIP
    # restored by `git stash pop` in the caller. Uncommitted worktree changes stay
    # recoverable via `git stash list`. Note: any commits that existed on the deleted
    # fix branch are unreachable after branch -D and will be garbage-collected by git.
    cleanup_branch "$num" "$branch" "crash"
  fi
  blocked=$((blocked+1))
}

# -------- Prompt builders --------
verify_prompt() {
  local num="$1" title="$2" body="$3"
  cat <<EOF
You are verifying whether a GitHub audit finding is real and should be fixed.

**Repository:** $REPO
**Working directory:** $PROJECT
**Issue #$num:** $title

---
$body
---

## Your task (VERIFY-ONLY — do NOT make any code changes)

1. \`cd\` to the working directory.
2. Read the files referenced in the Evidence section.
3. Confirm: does the described issue currently exist in the code?

Possible outcomes — end with ONE marker on its own line:

- \`DONE-PROCEED\` — bug is real, should be fixed. No other output needed.
- \`DONE-FALSE-POSITIVE: <reason>\` — bug is not present (already fixed, wrong evidence, misunderstanding). Write 1–3 sentences explaining what you found in the code that invalidates the finding. The issue will be closed with your reasoning.
- \`DONE-BLOCKED: <reason>\` — you can't determine it autonomously (requires product decisions, credentials, external services, etc.).

**DO NOT create commits, modify files, or call \`gh\` in this phase.** Read only.
EOF
}

fix_prompt() {
  local num="$1" title="$2" body="$3" feedback="$4"
  local fb=""
  if [ -n "$feedback" ]; then
    fb=$(cat <<EOF

## Prior-attempt feedback (from reviewer)
$feedback

The previous attempt was rejected. Address the concerns above in this attempt.
EOF
)
  fi
  cat <<EOF
You are implementing a fix for a verified GitHub audit finding.

**Repository:** $REPO
**Working directory:** $PROJECT
**Issue #$num:** $title
**Branch:** you are on \`fix/issue-$num\`, freshly created from \`origin/$BASE_BRANCH\`.

---
$body
---
$fb

## Your task

1. \`cd\` to the working directory.
2. Implement the recommended fix. Adapt to the current code where needed — the audit may be slightly out of date.
3. **Scope strictly to this issue.** Only touch files related to the finding. Do NOT refactor unrelated code.
4. If tests are added/modified, they MUST assert real behavior. **No tautologies** (\`expect(true)\`, \`expect(x || !x)\`, etc).
5. **Never commit generated artifacts.** Check that build output, reports, coverage, \`.next/\`, \`dist/\`, \`playwright-report/\`, \`node_modules/\`, \`.env*\`, etc. are NOT staged. Add to \`.gitignore\` if they appear untracked.
6. Run repo's checks. Try in order: \`pnpm lint\`, \`pnpm typecheck\`, \`pnpm build\`, \`pnpm test\` (fallback to npm/yarn/Make). Fix anything YOUR change broke.
7. Stage only relevant files — use \`git add <path>\`, NOT \`git add -A\` or \`git add .\`.
8. Commit with this exact format:
   \`\`\`
   fix: <concise summary>

   <optional 1-3 line explanation>

   Closes #$num
   \`\`\`
9. **Do NOT push.** Do NOT use \`git push\` or \`gh pr create\`. The next stage handles that.

End with ONE marker on its own line:
- \`DONE-FIX-APPLIED\` — commit created, ready for review
- \`DONE-BLOCKED: <reason>\` — cannot implement autonomously (explain why)

If your fix breaks checks and you can't resolve, run \`git reset --hard HEAD\` and emit \`DONE-BLOCKED\`.
EOF
}

review_prompt() {
  local num="$1" title="$2" body="$3" diff="$4"
  cat <<EOF
You are an independent senior code reviewer. You have not seen this fix before. **Be skeptical.**

**Repository:** $REPO
**Working directory:** $PROJECT
**Issue #$num being fixed:** $title

## Original issue
$body

## Proposed fix (diff vs \`$BASE_BRANCH\`)
\`\`\`diff
$diff
\`\`\`

## Your task

**Review ONLY the committed diff above.** Ignore \`git status\` / untracked files / unstaged changes in the worktree — they are pre-existing state, not part of this fix.

1. \`cd\` to the working directory (branch is already \`fix/issue-$num\`).
2. **Independently verify** the fix actually addresses the root cause described in the issue. A diff that compiles but misses the point is a REJECT.
3. **Scope check — on the commit diff only**: all files in \`git diff $BASE_BRANCH..HEAD\` are relevant to this finding. Any unrelated changes IN THE COMMIT → REJECT. Files that are untracked/unstaged on disk but NOT in the commit are NOT your concern.
4. **Artifact check — on the commit diff only**: the commit must not contain build output, reports, env files, or lockfile churn unrelated to the fix.
5. **Test check**: if tests were changed IN THIS COMMIT, they MUST have real assertions (not tautologies, not \`.catch(() => false)\` anti-patterns).
6. **Run checks**: \`pnpm lint\`, \`pnpm typecheck\`, \`pnpm build\`, \`pnpm test\` (or repo's equivalents). Any new failures caused by this commit → REJECT. Pre-existing failures are NOT your concern.
7. **Regression check**: does the change plausibly break something else (security, behavior, API contract)?

Do NOT modify files. Do NOT commit. Reviewer mode only.

End with ONE marker on its own line:
- \`DONE-APPROVED\` — ready to push
- \`DONE-REJECTED: <specific reason(s)>\` — one line per concern. Be precise so the fixer can address them next attempt.

When in doubt between APPROVED and REJECTED: **REJECT**.
EOF
}

# -------- Per-issue pipeline --------
processed=0
merged=0
opened=0
fp=0
blocked=0
rejected=0

process_issue() {
  local num="$1" title="$2" body="$3"
  local branch="fix/issue-$num"
  local issue_log="$log_root/issue-$num.log"
  : > "$issue_log"

  hdr "Issue #$num: $title"

  # ---- Stage 1: VERIFY ----
  info "[#$num] VERIFY"
  local out rc
  out=$(run_agent "$FIX_AGENT" "$(verify_prompt "$num" "$title" "$body")" "$issue_log" verify)
  rc=$?

  if is_crash "$rc"; then
    handle_agent_crash "$num" "verify" "$rc" ""
    return 0
  fi
  CONSECUTIVE_CRASHES=0

  if echo "$out" | grep -qE '^DONE-FALSE-POSITIVE'; then
    local reason
    reason=$(echo "$out" | grep -E '^DONE-FALSE-POSITIVE' | head -1 | sed 's/^DONE-FALSE-POSITIVE:\s*//; s/^DONE-FALSE-POSITIVE//')
    ok "[#$num] FALSE-POSITIVE: $reason"
    gh issue comment "$num" --repo "$REPO" --body "**fixbuddy verification → FALSE-POSITIVE**

$reason

_Auto-closed by fixbuddy v$VERSION._" >/dev/null 2>&1 || true
    gh issue edit "$num" --repo "$REPO" --add-label "fix:false-positive" >/dev/null 2>&1 || true
    gh issue close "$num" --repo "$REPO" --reason "not planned" >/dev/null 2>&1 || true
    fp=$((fp+1))
    return 0
  fi
  if echo "$out" | grep -qE '^DONE-BLOCKED'; then
    local reason
    reason=$(echo "$out" | grep -E '^DONE-BLOCKED' | head -1 | sed 's/^DONE-BLOCKED:\s*//; s/^DONE-BLOCKED//')
    warn "[#$num] BLOCKED (verify): $reason"
    gh issue edit "$num" --repo "$REPO" --add-label "fix:blocked" >/dev/null 2>&1 || true
    gh issue comment "$num" --repo "$REPO" --body "**fixbuddy verification → BLOCKED**: $reason" >/dev/null 2>&1 || true
    blocked=$((blocked+1))
    return 0
  fi
  if ! echo "$out" | grep -qE '^DONE-PROCEED'; then
    err "[#$num] verify-agent emitted no marker — skipping"
    gh issue edit "$num" --repo "$REPO" --add-label "fix:blocked" >/dev/null 2>&1 || true
    blocked=$((blocked+1))
    return 0
  fi

  # ---- Stage 2+3: FIX + REVIEW (with retry) ----
  local feedback="" attempt=0 approved=false
  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    attempt=$((attempt+1))

    # Fresh branch from up-to-date base. We intentionally do NOT `reset --hard` or
    # `clean -fd` here — that would wipe user WIP. If the worktree is dirty and blocks
    # the checkout, abort this issue cleanly instead of letting the fix agent run on
    # the wrong branch. `handle_agent_crash` stashes its cleanup instead of destroying.
    if ! (
      cd "$PROJECT"
      git fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true
      git checkout "$BASE_BRANCH" >/dev/null 2>&1 || exit 1
      git pull --ff-only origin "$BASE_BRANCH" >/dev/null 2>&1 || true
      git branch -D "$branch" >/dev/null 2>&1 || true
      git checkout -b "$branch" >/dev/null 2>&1 || exit 1
    ); then
      err "[#$num] failed to create fix branch '$branch' — skipping issue"
      gh issue edit "$num" --repo "$REPO" --add-label "fix:blocked" >/dev/null 2>&1 || true
      gh issue comment "$num" --repo "$REPO" --body "**fixbuddy → BLOCKED**: could not create branch \`$branch\` from \`$BASE_BRANCH\` (git checkout failed, likely dirty worktree). Clean or commit your local changes in \`$PROJECT\` and retry. Anything fixbuddy stashed previously can be recovered via \`git stash list\`." >/dev/null 2>&1 || true
      blocked=$((blocked+1))
      return 0
    fi

    info "[#$num] FIX attempt $attempt/$((MAX_RETRIES+1))"
    out=$(run_agent "$FIX_AGENT" "$(fix_prompt "$num" "$title" "$body" "$feedback")" "$issue_log" fix)
    rc=$?

    if is_crash "$rc"; then
      handle_agent_crash "$num" "fix" "$rc" "$branch"
      return 0
    fi
    CONSECUTIVE_CRASHES=0

    if echo "$out" | grep -qE '^DONE-BLOCKED'; then
      local reason
      reason=$(echo "$out" | grep -E '^DONE-BLOCKED' | head -1)
      warn "[#$num] BLOCKED (fix): $reason"
      gh issue edit "$num" --repo "$REPO" --add-label "fix:blocked" >/dev/null 2>&1 || true
      gh issue comment "$num" --repo "$REPO" --body "**fixbuddy fix → BLOCKED**: $reason" >/dev/null 2>&1 || true
      cleanup_branch "$num" "$branch" "blocked"
      blocked=$((blocked+1))
      return 0
    fi
    if ! echo "$out" | grep -qE '^DONE-FIX-APPLIED'; then
      err "[#$num] fix-agent emitted no marker — aborting issue"
      gh issue edit "$num" --repo "$REPO" --add-label "fix:blocked" >/dev/null 2>&1 || true
      cleanup_branch "$num" "$branch" "missing-marker"
      blocked=$((blocked+1))
      return 0
    fi

    # make sure a commit was actually made
    local commit_count
    commit_count=$(cd "$PROJECT" && git rev-list --count "$BASE_BRANCH".."$branch")
    if [ "$commit_count" = "0" ]; then
      err "[#$num] fix-agent claimed DONE-FIX-APPLIED but no commit on branch"
      gh issue edit "$num" --repo "$REPO" --add-label "fix:blocked" >/dev/null 2>&1 || true
      cleanup_branch "$num" "$branch" "missing-commit"
      blocked=$((blocked+1))
      return 0
    fi

    # ---- REVIEW ----
    info "[#$num] REVIEW attempt $attempt/$((MAX_RETRIES+1))"
    local diff
    diff=$(cd "$PROJECT" && git diff "$BASE_BRANCH".."$branch")
    # Cap diff size to avoid prompt blow-up (100KB)
    if [ "${#diff}" -gt 100000 ]; then
      diff="${diff:0:100000}

[... diff truncated at 100KB, $((${#diff}-100000)) bytes omitted ...]"
    fi

    # Hide untracked/unstaged files from reviewer so it only sees the commit diff
    local did_stash=0
    if [ -n "$(cd "$PROJECT" && git status --porcelain)" ]; then
      if (cd "$PROJECT" && git stash push --include-untracked -m "fixbuddy-review-$num" --quiet) >/dev/null 2>&1; then
        did_stash=1
      fi
    fi

    out=$(run_agent "$REVIEW_AGENT" "$(review_prompt "$num" "$title" "$body" "$diff")" "$issue_log" review)
    rc=$?

    if [ "$did_stash" = "1" ]; then
      (cd "$PROJECT" && git stash pop --quiet) >/dev/null 2>&1 || warn "[#$num] 'git stash pop' failed — check 'git stash list'"
    fi

    if is_crash "$rc"; then
      # Reviewer crashed mid-review: don't waste retry budget on a fake reject.
      # Mark blocked, cleanup, return — issue re-enters queue next run.
      handle_agent_crash "$num" "review" "$rc" "$branch"
      return 0
    fi
    CONSECUTIVE_CRASHES=0

    if grep -qE '^DONE-APPROVED' <<<"$out"; then
      ok "[#$num] APPROVED"
      approved=true
      break
    fi

    # REJECTED: capture reason and retry if we have budget
    feedback=$(grep -E '^DONE-REJECTED' <<<"$out" | head -1)

    # Robustness fallback: for very large outputs, the $out variable can be
    # mangled/truncated. Re-parse the last agent block in the logfile as a
    # secondary source of truth.
    if [ -z "$feedback" ]; then
      local last_block
      last_block=$(awk '/^===== RUN_AGENT: /{buf=""} {buf=buf$0"\n"} /^===== END /{last=buf; buf=""} END{printf "%s", last}' "$issue_log")
      if grep -qE '^DONE-APPROVED$' <<<"$last_block"; then
        ok "[#$num] APPROVED (recovered from log)"
        approved=true
        break
      fi
      feedback=$(grep -E '^DONE-REJECTED' <<<"$last_block" | head -1)
    fi
    # Reviewer produced no recognizable verdict at all — surface a useful placeholder
    # so the warn, GitHub comment, and the next fix attempt's feedback aren't blank.
    if [ -z "$feedback" ]; then
      feedback="DONE-REJECTED: (reviewer produced no DONE-APPROVED or DONE-REJECTED marker — inspect $issue_log)"
    fi
    warn "[#$num] $feedback"

    if [ "$attempt" -gt "$MAX_RETRIES" ]; then
      err "[#$num] retry budget exhausted, giving up"
      gh issue edit "$num" --repo "$REPO" --add-label "fix:rejected" >/dev/null 2>&1 || true
      gh issue comment "$num" --repo "$REPO" --body "**fixbuddy reviewer rejected all $((MAX_RETRIES+1)) attempts.**

Last reviewer feedback:
$feedback

Full logs: \`$issue_log\` on the machine where fixbuddy ran." >/dev/null 2>&1 || true
      cleanup_branch "$num" "$branch" "rejected"
      rejected=$((rejected+1))
      return 0
    fi

    info "[#$num] retrying with reviewer feedback"
    # Loop continues: branch will be reset at top of loop
  done

  $approved || return 0

  # ---- Stage 4: PUSH + PR + optional auto-merge ----
  info "[#$num] PUSH $branch"
  if ! ( cd "$PROJECT" && git push -u origin "$branch" ) >> "$issue_log" 2>&1; then
    err "[#$num] push failed"
    gh issue edit "$num" --repo "$REPO" --add-label "fix:blocked" >/dev/null 2>&1 || true
    gh issue comment "$num" --repo "$REPO" --body "**fixbuddy → BLOCKED**: push failed for \`$branch\`. Check the run log and repository permissions, then retry." >/dev/null 2>&1 || true
    cleanup_branch "$num" "$branch" "push-failed"
    blocked=$((blocked+1))
    return 0
  fi

  local commit_title
  commit_title=$(cd "$PROJECT" && git log -1 --pretty=%s "$branch")

  local pr_url
  pr_url=$(gh pr create --repo "$REPO" --base "$BASE_BRANCH" --head "$branch" \
    --title "$commit_title" \
    --body "Automated fix via fixbuddy v$VERSION — verified by \`$FIX_AGENT\`, reviewed by \`$REVIEW_AGENT\`.

Closes #$num" 2>&1) || {
    err "[#$num] PR creation failed: $pr_url"
    local existing_pr
    existing_pr=$(gh pr list --repo "$REPO" --head "$branch" --json url --jq '.[0].url // ""' 2>/dev/null || true)
    if [ -n "$existing_pr" ]; then
      warn "[#$num] PR already exists: $existing_pr"
      gh issue edit "$num" --repo "$REPO" --add-label "fix:pr-open" >/dev/null 2>&1 || true
      gh issue comment "$num" --repo "$REPO" --body "**fixbuddy PR already open** → $existing_pr

The issue is labeled \`fix:pr-open\` so future fixbuddy runs do not create duplicate PRs." >/dev/null 2>&1 || true
      cleanup_branch "$num" "$branch" "pr-already-open"
      opened=$((opened+1))
      return 0
    fi
    gh issue edit "$num" --repo "$REPO" --add-label "fix:blocked" >/dev/null 2>&1 || true
    gh issue comment "$num" --repo "$REPO" --body "**fixbuddy → BLOCKED**: PR creation failed for \`$branch\`.

\`\`\`text
$pr_url
\`\`\`

Check the run log and repository permissions, then retry." >/dev/null 2>&1 || true
    ( cd "$PROJECT" && git push origin --delete "$branch" >/dev/null 2>&1 ) || true
    cleanup_branch "$num" "$branch" "pr-create-failed"
    blocked=$((blocked+1))
    return 0
  }
  info "[#$num] PR: $pr_url"

  local merge_requested=false
  if $AUTO_MERGE; then
    if gh pr merge "$pr_url" --repo "$REPO" --auto --squash --delete-branch >>"$issue_log" 2>&1; then
      merge_requested=true
      info "[#$num] auto-merge enabled"
    elif gh pr merge "$pr_url" --repo "$REPO" --squash --delete-branch >>"$issue_log" 2>&1; then
      merge_requested=true
      info "[#$num] merged immediately"
    else
      warn "[#$num] auto-merge not possible; PR left open"
    fi
  fi

  local pr_merged=false
  pr_merged=$(gh pr view "$pr_url" --repo "$REPO" --json state,mergedAt \
    --jq '(.state == "MERGED") or (.mergedAt != null)' 2>>"$issue_log" || echo false)

  if [ "$pr_merged" = "true" ]; then
    gh issue edit "$num" --repo "$REPO" --add-label "fix:applied" --remove-label "fix:pr-open" >/dev/null 2>&1 || true
    gh issue comment "$num" --repo "$REPO" --body "**fixbuddy pipeline complete** → merged $pr_url" >/dev/null 2>&1 || true
    ok "[#$num] merged"
    merged=$((merged+1))
  else
    gh issue edit "$num" --repo "$REPO" --add-label "fix:pr-open" >/dev/null 2>&1 || true
    if $merge_requested; then
      gh issue comment "$num" --repo "$REPO" --body "**fixbuddy PR opened** → $pr_url

Auto-merge has been requested. The issue will close when GitHub merges the PR after required checks pass." >/dev/null 2>&1 || true
    else
      gh issue comment "$num" --repo "$REPO" --body "**fixbuddy PR opened** → $pr_url

The PR is awaiting human review or merge. The issue is labeled \`fix:pr-open\` so future fixbuddy runs do not create duplicate PRs." >/dev/null 2>&1 || true
    fi
    ok "[#$num] PR opened"
    opened=$((opened+1))
  fi

  cleanup_branch "$num" "$branch" "pr-complete"
}

# -------- Main loop --------
while IFS= read -r issue; do
  num=$(echo "$issue" | jq -r '.number')
  title=$(echo "$issue" | jq -r '.title')
  body=$(echo "$issue" | jq -r '.body')

  if [ -n "$MAX" ] && [ "$processed" -ge "$MAX" ]; then
    info "Reached --max $MAX. Stopping."
    break
  fi

  process_issue "$num" "$title" "$body"
  processed=$((processed+1))

  if [ "$CONSECUTIVE_CRASHES" -ge "$CRASH_ABORT_THRESHOLD" ]; then
    err "$CONSECUTIVE_CRASHES consecutive agent crashes — aborting batch to avoid fake-rejects."
    err "Likely cause: review-agent ($REVIEW_AGENT) or fix-agent ($FIX_AGENT) hit a usage limit or is unreachable."
    err "Next steps:"
    err "  • Wait for recovery and rerun — issues marked fix:blocked auto-requeue."
    err "  • Or rerun with --review-agent $([ "$REVIEW_AGENT" = codex ] && echo claude || echo codex) as a fallback."
    break
  fi
done < <(echo "$filtered" | jq -c '.[]')

# -------- Summary --------
hdr "Summary"
info "Processed:        $processed"
ok   "Merged:           $merged"
ok   "PRs opened:       $opened"
ok   "False positives:  $fp"
warn "Blocked:          $blocked"
err  "Rejected:         $rejected"
info "Logs: $log_root"
