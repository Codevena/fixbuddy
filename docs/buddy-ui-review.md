# Buddy-family terminal preview

Release candidate: 0.9.3. The installer is pinned to v0.9.3.

## Historical preview — product commit `3a637e4`

The local preview used 0.9.3-dev while the public installer was pinned to v0.9.2.
The updated activity panel, animation and timestamped wrapped session history
use the ScoutBuddy visual vocabulary, with no runtime dependency on it.
Existing preview/selection/confirmation, merge policy and interruption commands
remain unchanged. Process exit zero is a neutral completion, never merge proof.

Verification: 35 Python tests including the real offline PTY smoke pass.
The complete 62-scenario offline integration run passed 61 cases; its local
installer case hardcoded the previous release version. That test now compares
with the source bundle's version and passes independently. Bash core differs
only in the development version. Syntax, deterministic bundle, SHA256 and diff
checks pass. Synthetic renders cover 40×12, 76×30 and 120×30.

Independent POST first reproduced secret-prefix leaks in existing error paths
that shortened text before redaction. Five causal regression tests cover those
paths; complete original diagnostics are now sanitized before any slice. Final
delta verdict PASS, no open CRITICAL/WARN. No live agent or GitHub write tests.
The read-only pre-run preview retains its existing synchronous operation; the
pipeline and repository inventory animate. Core run logs remain in their
existing location; the UI adds no durable copy of raw output.

## Release candidate — 2026-09-30

The historical preview evidence above describes product commit `3a637e4`.
Release preparation updates the version and installer pins to stable v0.9.3,
with no additional behavior change, and rebuilds the single-file bundle.
All five focused offline installer cases pass, including the explicit v0.8
paths, as do Bash syntax, deterministic bundle, checksum and diff checks.
The final complete suites passed: 35 Python UI tests and 62 offline integration
cases. ShellCheck, actionlint, bundle consistency and checksum verification also
passed. GitHub PR #19 passed shell checks, integration tests and the Action
dry-run wrapper smoke test. Release publication is the next step.
