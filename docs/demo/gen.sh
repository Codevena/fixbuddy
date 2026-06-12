#!/usr/bin/env bash
# Regenerate docs/demo.gif with VHS, using deterministic demo doubles (no real services).
# Usage:  bash docs/demo/gen.sh        (requires `vhs` on PATH)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEMO_DIR="$REPO_ROOT/docs/demo"
WORK=/tmp/fixbuddy-demo

command -v vhs >/dev/null || { echo "vhs not found — install https://github.com/charmbracelet/vhs"; exit 1; }

rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/home"

# Runtime bin: stub agents + stub gh + fixbuddy, all on PATH.
chmod +x "$DEMO_DIR/bin/agent" "$DEMO_DIR/bin/gh"
ln -sf "$DEMO_DIR/bin/agent"   "$WORK/bin/claude"
ln -sf "$DEMO_DIR/bin/agent"   "$WORK/bin/codex"
ln -sf "$DEMO_DIR/bin/gh"      "$WORK/bin/gh"
ln -sf "$REPO_ROOT/fixbuddy.sh" "$WORK/bin/fixbuddy"

# Playground repo with a real bug and a real origin (so `git push` genuinely works).
git init -q --bare "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/playground" 2>/dev/null
(
  cd "$WORK/playground"
  git config user.email demo@example.com
  git config user.name  "demo"
  git checkout -q -b main
  mkdir -p src
  printf 'def add(a, b):\n    return a - b   # BUG: should be a + b\n' > src/calc.py
  git add -A
  git commit -q -m "calc: initial"
  git push -q -u origin main
)

export PATH="$WORK/bin:$PATH"
export DEMO_PROJECT="$WORK/playground"
export HOME="$WORK/home"     # isolate fixbuddy run logs

cd "$REPO_ROOT"
vhs "$DEMO_DIR/demo.tape"
echo "Wrote $REPO_ROOT/docs/demo.gif"
