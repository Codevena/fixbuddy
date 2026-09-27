#!/usr/bin/env bash
# Copy only the run directory recorded by this invocation of the composite
# action. Old runs on a persistent self-hosted runner are never traversed.
set -euo pipefail

pointer="${FIXBUDDY_LOG_POINTER:-}"
[ -n "$pointer" ] && [ -f "$pointer" ] || exit 0
IFS= read -r run_dir < "$pointer" || true
[ -n "${run_dir:-}" ] || exit 0  # dry-run or failure before run creation

runs_root="$(cd "$HOME/.fixbuddy/runs" && pwd -P)"
run_dir="$(cd "$run_dir" && pwd -P)"
if [ "$(dirname "$run_dir")" != "$runs_root" ]; then
  echo "error: log pointer is outside the fixbuddy runs directory" >&2
  exit 1
fi

workspace="${FIXBUDDY_WORKSPACE:?FIXBUDDY_WORKSPACE is required}"
target_root="$workspace/fixbuddy-logs"
target="$target_root/${run_dir##*/}"
if [ -L "$target_root" ] || [ -e "$target" ]; then
  echo "error: log destination already exists or is a symlink: $target" >&2
  exit 1
fi
mkdir -p "$target"
cp -R "$run_dir/." "$target/"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'logs_path=%s\n' "$target" >> "$GITHUB_OUTPUT"
fi
printf 'fixbuddy logs copied from this run to %s\n' "$target"
