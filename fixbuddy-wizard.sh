#!/usr/bin/env bash
# fixbuddy-wizard.sh v0.3.2 — beginner-friendly launcher for fixbuddy.sh
#
# Walks a user through the required flags via interactive prompts, validates
# prerequisites, shows a preview of the exact command, and then exec's fixbuddy.sh.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXBUDDY="$SCRIPT_DIR/fixbuddy.sh"

if [ ! -x "$FIXBUDDY" ]; then
  echo "error: fixbuddy.sh not found or not executable at $FIXBUDDY" >&2
  exit 1
fi

# -------- Colors (disabled if output isn't a TTY) --------
if [ -t 1 ]; then
  BOLD=$'\033[1m' DIM=$'\033[2m' RED=$'\033[31m' GRN=$'\033[32m'
  BLU=$'\033[34m' MAG=$'\033[35m' RST=$'\033[0m'
else
  BOLD="" DIM="" RED="" GRN="" BLU="" MAG="" RST=""
fi

step() { printf "\n${BOLD}%s${RST} %s\n" "$1" "$2"; }
ask()  { printf "  ${BLU}?${RST} %s " "$1"; }
ok()   { printf "  ${GRN}✓${RST} %s\n" "$1"; }
fail() { printf "  ${RED}✗${RST} %s\n" "$1" >&2; }
note() { printf "  ${DIM}%s${RST}\n" "$1"; }

printf "%s" "${MAG}${BOLD}"
cat <<'EOF'

  ╔═══════════════════════════════════════════════════╗
  ║              fixbuddy wizard v0.3.2                ║
  ║   Turn GitHub issues into reviewed PRs             ║
  ╚═══════════════════════════════════════════════════╝
EOF
printf "%s" "${RST}"

# -------- Step 1: prerequisites --------
step "1." "Checking prerequisites…"
missing=0
# Required: gh, jq, git, and at least one agent CLI (checked separately below).
for c in gh jq git; do
  if command -v "$c" >/dev/null 2>&1; then
    ok "$c found"
  else
    fail "$c NOT installed"
    missing=1
  fi
done

# Agent CLIs — track which are available so we can offer only the installed ones.
AGENTS_AVAILABLE=()
for a in claude codex opencode gemini; do
  if command -v "$a" >/dev/null 2>&1; then
    ok "$a found"
    AGENTS_AVAILABLE+=("$a")
  else
    note "$a not installed (optional)"
  fi
done

if [ "${#AGENTS_AVAILABLE[@]}" -eq 0 ]; then
  fail "no agent CLI installed — need at least one of: claude, codex, opencode, gemini"
  missing=1
fi

if [ "$missing" -eq 1 ]; then
  printf "\n%sInstall the missing tools and re-run.%s\n" "$RED" "$RST" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  fail "gh is not authenticated. Run: gh auth login"
  exit 1
fi
ok "gh authenticated"

# -------- Step 2: repo --------
step "2." "Which GitHub repo has the issues?"
note "example: vercel/next.js"
ask "Repo (owner/name):"
read -r REPO
REPO="${REPO## }"; REPO="${REPO%% }"
if [ -z "$REPO" ]; then
  fail "repo is required"
  exit 1
fi
if ! gh repo view "$REPO" >/dev/null 2>&1; then
  fail "cannot access $REPO — check spelling and your gh auth"
  exit 1
fi
ok "$REPO accessible"

# -------- Step 3: project path --------
step "3." "Where is the local checkout of $REPO?"
repo_name="${REPO##*/}"
default_path=""
for guess in "$HOME/Developer/$repo_name" "$HOME/Projects/$repo_name" "$HOME/code/$repo_name"; do
  if [ -d "$guess/.git" ]; then
    default_path="$guess"
    break
  fi
done
[ -n "$default_path" ] && note "default: $default_path"
ask "Path (blank = default):"
read -r PROJECT
if [ -z "$PROJECT" ]; then
  PROJECT="$default_path"
fi
# Expand leading ~ / ~/path. The ~user form is not a common case here and bash won't
# expand it inside a quoted string either — surface a clear error instead of a confusing
# "not a git repository" downstream.
case "$PROJECT" in
  \~|\~/*) PROJECT="${HOME}${PROJECT#\~}" ;;
  \~*)     fail "~username paths are not supported — please use an absolute path or ~/…"; exit 1 ;;
esac
if [ -z "$PROJECT" ] || [ ! -d "$PROJECT/.git" ]; then
  fail "\"$PROJECT\" is not a git repository"
  exit 1
fi
ok "$PROJECT"

# -------- Step 4: severity --------
step "4." "Which severity to target?"
cat <<EOF
  [1] critical   (most urgent — recommended first pass)
  [2] high       (typical release cleanup)
  [3] medium
  [4] low
  [5] all severities
EOF
ask "Choice [1-5]:"
read -r sev_choice
case "$sev_choice" in
  1) SEVERITY="critical" ;;
  2) SEVERITY="high" ;;
  3) SEVERITY="medium" ;;
  4) SEVERITY="low" ;;
  5) SEVERITY="" ;;
  *) fail "invalid choice"; exit 1 ;;
esac
if [ -n "$SEVERITY" ]; then
  ok "severity: $SEVERITY"
else
  ok "severity: all"
fi

# -------- Step 5: mode --------
step "5." "How aggressive should fixbuddy be?"
cat <<EOF
  [1] preview      (dry-run only — lists targets, makes no changes)
  [2] careful      (creates PRs, you decide when to merge)
  [3] autonomous   (auto-merges PRs that pass CI — recommended)
EOF
ask "Choice [1-3]:"
read -r mode_choice
MODE_FLAGS=()
case "$mode_choice" in
  1) MODE_FLAGS=(--dry-run);       MODE_LABEL="preview" ;;
  2) MODE_FLAGS=(--no-auto-merge); MODE_LABEL="careful" ;;
  3) MODE_FLAGS=();                MODE_LABEL="autonomous" ;;
  *) fail "invalid choice"; exit 1 ;;
esac
ok "mode: $MODE_LABEL"

# -------- Step 6: batch size --------
step "6." "How many issues per run?"
cat <<EOF
  [1] 3      (safe trial — about 30 minutes wall-clock)
  [2] 10     (normal batch — about 1–2 hours)
  [3] all    (process the entire queue)
EOF
ask "Choice [1-3]:"
read -r max_choice
MAX_FLAG=()
case "$max_choice" in
  1) MAX_FLAG=(--max 3);  MAX_LABEL="3"  ;;
  2) MAX_FLAG=(--max 10); MAX_LABEL="10" ;;
  3) MAX_FLAG=();         MAX_LABEL="all in queue" ;;
  *) fail "invalid choice"; exit 1 ;;
esac
ok "max: $MAX_LABEL"

# -------- Step 7: fix agent --------
is_available() {
  local needle="$1"
  for a in "${AGENTS_AVAILABLE[@]}"; do
    [ "$a" = "$needle" ] && return 0
  done
  return 1
}

step "7a." "Which agent writes the fixes?"
note "claude is the most reliable fixer; codex and opencode are strong alternatives."
note "gemini is read-only-ish and not recommended as a fixer."
FIX_CHOICES=()
n=1
for a in claude codex opencode gemini; do
  if is_available "$a"; then
    label="$a"
    [ "$a" = "gemini" ] && label="$a   ${DIM}(experimental — often writes incomplete fixes)${RST}"
    printf "  [%d] %b\n" "$n" "$label"
    FIX_CHOICES+=("$a")
    n=$((n+1))
  fi
done
ask "Choice:"
read -r fix_choice
if ! [[ "$fix_choice" =~ ^[0-9]+$ ]] || [ "$fix_choice" -lt 1 ] || [ "$fix_choice" -gt "${#FIX_CHOICES[@]}" ]; then
  fail "invalid choice"
  exit 1
fi
FIX_AGENT="${FIX_CHOICES[$((fix_choice-1))]}"
ok "fix agent: $FIX_AGENT"

# -------- Step 7b: reviewer --------
step "7b." "Which reviewer agent?"
note "Cross-agent review (different from the fixer) catches more bugs."
note "gemini in review mode runs read-only — safer but less thorough."
REV_CHOICES=()
n=1
for a in codex claude opencode gemini; do
  if is_available "$a"; then
    label="$a"
    [ "$a" = "$FIX_AGENT" ] && label="$a   ${DIM}(same-agent — less adversarial)${RST}"
    [ "$a" = "gemini" ]    && label="$a   ${DIM}(read-only, experimental — quick second opinion)${RST}"
    printf "  [%d] %b\n" "$n" "$label"
    REV_CHOICES+=("$a")
    n=$((n+1))
  fi
done
ask "Choice:"
read -r rev_choice
if ! [[ "$rev_choice" =~ ^[0-9]+$ ]] || [ "$rev_choice" -lt 1 ] || [ "$rev_choice" -gt "${#REV_CHOICES[@]}" ]; then
  fail "invalid choice"
  exit 1
fi
REVIEW_AGENT="${REV_CHOICES[$((rev_choice-1))]}"
ok "reviewer: $REVIEW_AGENT"

# -------- Build command --------
CMD=("$FIXBUDDY" --repo "$REPO" --project "$PROJECT")
if [ -n "$SEVERITY" ]; then
  CMD+=(--severity "$SEVERITY")
fi
if [ "${#MAX_FLAG[@]}" -gt 0 ]; then
  CMD+=("${MAX_FLAG[@]}")
fi
CMD+=(--fix-agent "$FIX_AGENT" --review-agent "$REVIEW_AGENT")
if [ "${#MODE_FLAGS[@]}" -gt 0 ]; then
  CMD+=("${MODE_FLAGS[@]}")
fi
CMD+=(--yes)

# -------- Preview --------
step "8." "Ready. fixbuddy will run this command:"
printf "\n"
printf "    %s" "$DIM"
for arg in "${CMD[@]}"; do
  # shell-escape each arg so the preview is copy-pasteable
  printf "%q " "$arg"
done
printf "%s\n\n" "$RST"

ask "Start now? [y/N]:"
read -r go
case "$go" in
  [yY]|[yY][eE][sS]) ;;
  *) note "aborted — copy the command above to run later."; exit 0 ;;
esac

# -------- Run --------
exec "${CMD[@]}"
