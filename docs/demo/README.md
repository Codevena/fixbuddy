# Demo GIF

`docs/demo.gif` (shown at the top of the main README) is recorded with
[VHS](https://github.com/charmbracelet/vhs).

To keep it reproducible and offline, the recording uses **deterministic demo
doubles**, not real services:

- `bin/agent` — stands in for the AI coding CLIs (`claude` / `codex`). It emits the
  `DONE-*` markers fixbuddy expects and, in the FIX stage, makes a **real** small
  code change, so the diff fixbuddy reviews and the PR it opens are genuine.
- `bin/gh` — stands in for the GitHub CLI with canned responses.
- `bin/git` — reports the matching GitHub origin identity while forwarding
  commits, branch operations and pushes to real Git and the local bare repo.

Everything else is the **real** fixbuddy pipeline: branch creation, the local
commit, the `git diff`, `git push` (to a local bare repo), and the
label / state-machine flow.

## Regenerate

```bash
bash docs/demo/gen.sh
```

Requires `vhs` on `PATH`. Writes `docs/demo.gif`. Edit `demo.tape` to change the
timing/size/theme.

This GIF was rendered with the official VHS v0.11.0 macOS binary. On the Mac
used for this release, VHS v0.12.0 returned success without writing media,
even for a one-second minimal tape. `gen.sh` detects a missing GIF and restores
the prior file. Until that VHS behavior is fixed, put v0.11.0 first on `PATH`
when regenerating here.
