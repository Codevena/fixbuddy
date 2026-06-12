# Design: `--notify-cmd` run-summary notifications — v0.7.0

Date: 2026-06-12. Status: approved (user chose: notifications via an
operator-trusted command hook; the resume-mode roadmap item is retired in favor
of documentation, since the label system already provides resume semantics).

## Problem

fixbuddy runs take 30 minutes to hours. Operators running unattended batches
(cron, long queues) currently learn the outcome only by reading the log
directory. There is no way to get a push notification, chat message, or email
when a run finishes or aborts.

## Decision

A single mechanism, consistent with the project's dependency-light philosophy:

- **`--notify-cmd <cmd>`** (repeatable) and the **additive config key
  `notify_cmd`** — exactly the trust and parsing model of `--check-cmd`:
  operator-trusted strings, run via the shell, combinable from config and CLI,
  not removable from the CLI once set in config.
- No built-in webhook. `--notify-cmd 'curl -s -d @- https://...'` covers it.

## Behavior

**When it fires:** once per run, immediately after the Summary block prints.
This includes the crash-abort path (the abort `break`s out of the issue loop
and falls through to the summary). It does NOT fire:

- under `--dry-run` (a preview is contractually read-only and side-effect-free),
- when the run exits early because no issues matched (nothing happened),
- on Ctrl-C/SIGTERM (interactive abort; the interrupt trap stays minimal).

**Where it runs:** in fixbuddy's launch directory (CWD), like config loading —
NOT in `$PROJECT`. Notifications are about the run, not the checkout.

**What it receives:**

1. Environment variables:

| Variable | Value |
| --- | --- |
| `FIXBUDDY_REPO` | target `owner/repo` |
| `FIXBUDDY_PROCESSED` | issues processed this run |
| `FIXBUDDY_MERGED` | PRs confirmed merged |
| `FIXBUDDY_PR_OPENED` | PRs opened (not yet merged) |
| `FIXBUDDY_FALSE_POSITIVES` | issues closed as false positives |
| `FIXBUDDY_BLOCKED` | issues blocked (crash/timeout/needs-human) |
| `FIXBUDDY_REJECTED` | issues whose fixes were rejected |
| `FIXBUDDY_ABORTED` | `true` when the batch hit `--crash-abort`, else `false` |
| `FIXBUDDY_LOG_DIR` | the run's log directory |
| `FIXBUDDY_VERSION` | fixbuddy version |

2. stdin: a human-readable multi-line summary (repo, counts, log dir, abort
   note when applicable), so `ntfy publish t`, `mail -s ...`, or a Slack
   `curl -d @-` work without any argument plumbing.

**Failure handling:** each command's stdout/stderr is appended to
`$log_root/notify.log`. A non-zero exit warns (`notify command failed (exit N)`)
but never changes fixbuddy's exit code, and the remaining notify commands still
run. Notify commands get no watchdog (same as `--check-cmd`; operator-trusted).

## Implementation sketch

- New global `NOTIFY_CMDS=()`; parse `--notify-cmd` flag and `notify_cmd`
  config key (additive, mirroring `check_cmd`).
- New `aborted` flag set to `true` in the crash-abort branch before `break`.
- New function `run_notifications` called after the Summary block:

```bash
run_notifications() {
  [ "${#NOTIFY_CMDS[@]}" -gt 0 ] || return 0
  local summary cmd rc
  summary="fixbuddy v$VERSION run on $REPO
Processed: $processed | Merged: $merged | PRs opened: $opened
False positives: $fp | Blocked: $blocked | Rejected: $rejected
${aborted:+Batch ABORTED after consecutive agent crashes.
}Logs: $log_root"
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

(The final form follows the existing `run_checks` style; `aborted` is a plain
`true`/`false` string, so the summary line uses an explicit `if` rather than
the `${aborted:+...}` shorthand if that reads better.)

- Help header: new option line(s) added to the top comment — the `--help`
  handler prints `sed -n '2,47p' "$0"`, so the range must be extended to match
  the new header length.

## Docs

- README: Options table row, config-key table row, an Examples entry
  (`ntfy`/Slack-curl/macOS `osascript`), and a note on the trust model.
- README Roadmap: remove both remaining items — notifications ships here, and
  resume mode is retired because the label system already provides resume
  (interrupted issues stay in the queue; `fix:blocked` auto-requeues;
  `fix:pr-open` deduplicates). Add an FAQ entry: "What happens if I interrupt
  a run?" documenting exactly that.
- Wizard and action.yml: unchanged (advanced flag; CI users add their own
  notification steps after the action).

## Testing (extend tests/integration.sh)

1. Happy path with TWO `--notify-cmd` entries writing env vars and stdin to
   files — assert exact values (`FIXBUDDY_PR_OPENED=1`, `FIXBUDDY_MERGED=0`,
   `FIXBUDDY_ABORTED=false`, …) and the stdin text, proving both commands ran.
2. Failing notify command (`exit 7`) → run still exits 0, warning in run log,
   and a SECOND notify command still runs.
3. Crash scenario with notify → `FIXBUDDY_BLOCKED=1`.
4. `notify_cmd` via `.fixbuddy.conf` in the launch dir → fires (additive with
   CLI).
5. `--dry-run` with `--notify-cmd` → does NOT fire.

## Release

v0.7.0: version bumps (fixbuddy.sh, wizard, install.sh `DEFAULT_REF`, README
one-liners), CHANGELOG entry, fresh `SHA256SUMS`, full DoD review gate, PR.
Tagging/pushing only with explicit user approval.
