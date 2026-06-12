# Demo GIF

`docs/demo.gif` (shown at the top of the main README) is recorded with
[VHS](https://github.com/charmbracelet/vhs).

To keep it reproducible and offline, the recording uses **deterministic demo
doubles**, not real services:

- `bin/agent` — stands in for the AI coding CLIs (`claude` / `codex`). It emits the
  `DONE-*` markers fixbuddy expects and, in the FIX stage, makes a **real** small
  code change, so the diff fixbuddy reviews and the PR it opens are genuine.
- `bin/gh` — stands in for the GitHub CLI with canned responses.

Everything else is the **real** fixbuddy pipeline: branch creation, the local
commit, the `git diff`, `git push` (to a local bare repo), and the
label / state-machine flow.

## Regenerate

```bash
bash docs/demo/gen.sh
```

Requires `vhs` on `PATH`. Writes `docs/demo.gif`. Edit `demo.tape` to change the
timing/size/theme.
