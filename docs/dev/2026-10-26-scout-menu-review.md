# ScoutBuddy-family menu order

Baseline c75caab5ed6ba3abaa3b014f1f5f7ccc04c4a36c. User requested SETUP first,
matching ScoutBuddy:1SETUP →2REPOS →3RUN →4ISSUES.
Internal view identities, selection, preview binding, pipeline and confirmation
logic stay unchanged. Missing repo/checkout opens SETUP; configured startup REPOS.

Verification: causal menu/startup/link RED→GREEN,42 Python UI/PTY tests PASS;
controller repeated42 PASS (0.615s). Build --check, Bash syntax, version0.9.4 and
SHA256SUMS PASS. Source remains1275lines; generated bundle embeds identical source.

Independent executing review: **PASS0 CRITICAL/0 WARN/0 INFO**. Five selected
tests PASS (0.016s) plus six actual generated-bundle PTY cases at40/76/120, with
empty/configured startup, header/key1–4/Tab order and clean exit, no gh-stub writes.
Bundle equals scripts/build.py render. Embedded UI SHA256
`b8942e80138cf754d20762ffb88c1bb0c537242c43003b14d23bd4efb820a079`;
bundle SHA256 `c1775d0d29b73f124834a7fe7ec5359a5c6fce3df84ea75d044c8f1f67f15b30`.

No live agent, production config, GitHub write, push, merge, installation, tag or
release performed. User-owned untracked review-todo.md is preserved.
