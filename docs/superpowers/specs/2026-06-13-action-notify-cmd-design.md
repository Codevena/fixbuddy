# Design: `notify-cmd` input for the GitHub Action — v0.7.1

Date: 2026-06-13. Status: approved (user picked this backlog item explicitly).

## Problem

v0.7.0 added `--notify-cmd`, but the composite action (`action.yml`) does not
expose it — CI users can only reach it via a committed `.fixbuddy.conf`. The
action's input set is otherwise complete.

## Decision

New optional action input `notify-cmd`, **newline-separated** (one command per
line), each non-empty trimmed line becoming one repeated `--notify-cmd` flag.

Newlines, NOT commas: the existing `label` input is comma-separated, but shell
commands may legitimately contain commas (`curl -d 'a,b' ...`), so comma
splitting would corrupt them. YAML block scalars make multi-line inputs
natural:

```yaml
with:
  notify-cmd: |
    curl -s -d @- ntfy.sh/my-topic
    ./scripts/post-to-slack.sh
```

## Changes

- `action.yml`:
  - input `notify-cmd` (description documents one-command-per-line, default `""`),
  - passed via `FIXBUDDY_NOTIFY_CMD` env (same injection-safe pattern as the
    other inputs),
  - parsing loop mirroring the `label` loop but splitting on newlines via
    `while IFS= read -r` over a herestring, trimming whitespace, skipping
    empty lines.
- `.github/workflows/action-smoke.yml`: pass `notify-cmd: "echo smoke-notify"`
  so the wiring is exercised on every PR (dry-run never *fires* notify by
  design, but argument construction and fixbuddy's flag parsing run).
- README: row in the action Inputs table.
- Release housekeeping: patch release **v0.7.1** (version bumps everywhere,
  CHANGELOG, fresh SHA256SUMS — scripts change only by their version string,
  but the floating `v1` tag must move for action consumers to get the input).

## Testing

- Local: YAML validation; an extracted-snippet test of the parsing loop
  (multi-line input incl. blank line and surrounding whitespace → exact
  expected argv); `bash -n`/`shellcheck`/full integration suite unchanged.
- CI: the extended action-smoke dry-run exercises the new input end-to-end on
  the PR.
- DoD review gate (Codex + Claude) before merge.
