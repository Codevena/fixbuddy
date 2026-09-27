# Contributing

Thanks for improving fixbuddy. The shipped command is one generated file;
maintained source lives in `src/`.

## Development Setup

Required tools:

- `bash`
- `git`
- `jq`
- `gh`
- `shellcheck` for static analysis
- Python 3 for the optional terminal UI and its tests

Agent CLIs are needed only for end-to-end manual testing.

## Checks

Run these before opening a pull request:

```bash
bash -n fixbuddy
bash -n src/core.sh
bash -n src/wizard.sh
bash -n install.sh
bash -n src/action-collect-logs.sh
shellcheck src/core.sh src/wizard.sh install.sh src/action-collect-logs.sh tests/integration.sh tests/stubs/agent tests/stubs/gh tests/stubs/curl tests/stubs/git-push-race tests/stubs/git
tests/integration.sh
python3 scripts/build.py --check
python3 -m py_compile src/tui.py
python3 -m unittest discover -s tests -p 'test_tui.py'
```

`tests/integration.sh` runs the full pipeline offline against stubbed `gh`/agent
CLIs and a local bare repository — no network, no API keys, a few seconds.

After changing `src/core.sh`, `src/tui.py`, or `src/wizard.sh`, run
`python3 scripts/build.py` and update the single `fixbuddy` checksum in
`SHA256SUMS`. If `shellcheck` is unavailable locally, CI runs it on pull requests.

## Pull Request Guidelines

- Keep changes focused on one behavior or documentation improvement.
- Do not commit local logs, run artifacts, credentials, generated build output, or personal session notes.
- If you change agent execution, crash handling, cleanup, branch creation, PR creation, or label behavior, describe the happy path and failure path in the PR.
- If you add a new label or status, update `README.md` and the control-label creation code.
- Preserve the guarantee that `fix:applied` means GitHub reported the PR as merged.

## Manual Test Checklist

Most of these paths are covered by `tests/integration.sh`; for behavior changes,
additionally test against a disposable repository when possible:

1. `--dry-run` lists expected issues.
2. A false-positive verification closes or labels the issue correctly.
3. A blocked agent labels `fix:blocked`.
4. A rejected review retries and eventually labels `fix:rejected`.
5. A successful review opens a PR.
6. An unmerged PR receives `fix:pr-open`, not `fix:applied`.
7. A merged PR receives `fix:applied`.

## Documentation Style

- Keep examples generic: use `owner/repo` and `~/code/repo`.
- Avoid personal paths, private organization names, private repository names, and session-specific notes.
- Prefer precise operational language over marketing claims.
