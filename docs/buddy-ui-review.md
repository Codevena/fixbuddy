# Buddy-family terminal preview

Local candidate: 0.9.3-dev. Public installer remains pinned to v0.9.2.
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
