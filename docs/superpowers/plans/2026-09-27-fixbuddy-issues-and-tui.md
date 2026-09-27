# FixBuddy reliability fixes and terminal UI — execution plan

## Intent and boundaries

Close the seven findings in the untracked `review-todo.md` from 2026-08-30 and
add an optional, polished terminal UI inspired by `pd`. The Bash orchestrator
remains the only process allowed to mutate a target repository or GitHub.
Development verification uses local bare Git remotes and stubbed CLIs. No live
agent, GitHub write, push, release, or deployment is part of this work.

## Product design

- The CLI and Action default to opening a PR without requesting auto-merge;
  only explicit `--auto-merge` or `auto_merge = true` enables it. The wizard's
  “autonomous” choice must pass that flag explicitly.
- Every transition out of verify, fix, and review checks the active branch and
  base/issue refs before using a diff or pushing. A failed fetch or base update
  blocks the issue. A branch switch or unexpected base change blocks the issue
  after recoverable local cleanup; no downstream push or PR follows.
- A closed PR's old remote `fix/issue-N` branch can be replaced only with a
  lease pinned to the observed remote SHA. An open PR for that branch prevents
  replacement. Queue and unstick scans use all GitHub API pages.
- Reviewer approval requires one unambiguous, exact, final `DONE-APPROVED` line.
  Rejection requires an exact final `DONE-REJECTED: ...` line. Other output
  follows the reject/retry path and cannot approve a push.
- The watchdog checks the remaining time so a one-second timeout does not
  sleep ten seconds. Action log collection copies only this invocation's run
  directory, communicated through a per-step pointer file.
- The optional Python 3 standard-library TUI uses the same `fixbuddy.sh`
  preview and run paths. It starts in a read-only queue view, with violet/pink
  header, restrained dark panels, clear issue selection, config and run views,
  responsive narrow-terminal layout, keyboard help, and a final run
  confirmation. Untrusted titles and process output are stripped of terminal
  controls before rendering. A JSON dry-run preview keeps its queue semantics
  identical to the Bash core.

## Files and sequence

1. `tests/integration.sh`, `tests/stubs/agent`, `tests/stubs/gh`: add causal
   RED cases for branch switching, fetch failure, stale remote branch,
   contradictory verdicts, >200 open issues, default auto-merge, short timeout,
   and scoped Action log behavior. Keep the baseline 20 scenarios green.
2. `fixbuddy.sh`: implement the smallest reliable state checks, paginated
   reads, lease push, strict verdict, timer and JSON preview. No prompt or
   remote mutation in dry-run mode.
3. `action.yml`, `fixbuddy-wizard.sh`: make auto-merge explicit and scope logs
   to the run. Verify the Action shell body with the local stubbed setup.
4. `fixbuddy-tui.py`, `tests/test_tui.py`: implement and test the optional UI,
   including sanitization, command construction and a PTY render smoke.
5. `install.sh`, `SHA256SUMS`, `README.md`, `CHANGELOG.md`, `NEXT_SESSION.md`:
   document the new defaults, TUI installation and shortcuts. TUI download is
   explicit with `--with-tui` and requires a ref containing the TUI plus its
   checksum (for development: `--ref main --with-tui`). The pinned v0.7.1
   default continues to download only its two existing scripts until a
   separately authorized release exists. Run offline installer smokes with
   fixture refs for both the two-script default and the TUI-enabled ref.

## Verification and review

- Focused tests fail for each intended reason before the corresponding fix.
- Final: `bash -n` for each modified shell script; `shellcheck` for those
  scripts; `tests/integration.sh`; `python3 -m unittest discover -s tests -p
  'test_tui.py'`; `python3 -m py_compile fixbuddy-tui.py`; Action YAML syntax;
  checksum verification; PTY render smoke; `git diff --check` and final diff.
- Independent plan review before product changes, and independent final review
  of the changed Git/PR and TUI boundaries. Re-review only findings deltas.

## Plan review round 1

- WARN: An unconditional TUI addition to `SCRIPTS` would make the v0.7.1
  default installer fetch a file absent from that tag. Fixed in task 5 by an
  explicit `--with-tui` option, ref-specific checksum requirement, and an
  offline smoke for both ref shapes.

## Post-review delta

The independent diff review found four critical gaps that the first test batch
did not cover. Focused failing cases were added and then passed for: verify-time
ref mutation followed by `FALSE-POSITIVE`, TUI selection reuse across repos or
failed previews, PR-create failure after stale-branch replacement, and a late
branch move between approval and push. The corrections block changed verify
state, bind a successful preview to its settings, retain the pushed remote ref
on PR API failure, and push/read back the captured reviewed SHA.
