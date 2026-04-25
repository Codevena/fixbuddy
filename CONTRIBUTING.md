# Contributing

Thanks for improving fixbuddy. This project is intentionally small: Bash scripts, clear behavior, and minimal dependencies.

## Development Setup

Required tools:

- `bash`
- `git`
- `jq`
- `gh`
- `shellcheck` for static analysis

Agent CLIs are needed only for end-to-end manual testing.

## Checks

Run these before opening a pull request:

```bash
bash -n fixbuddy.sh
bash -n fixbuddy-wizard.sh
shellcheck fixbuddy.sh fixbuddy-wizard.sh
```

If `shellcheck` is not available locally, the GitHub Actions workflow will run it for pull requests.

## Pull Request Guidelines

- Keep changes focused on one behavior or documentation improvement.
- Do not commit local logs, run artifacts, credentials, generated build output, or personal session notes.
- If you change agent execution, crash handling, cleanup, branch creation, PR creation, or label behavior, describe the happy path and failure path in the PR.
- If you add a new label or status, update `README.md` and the control-label creation code.
- Preserve the guarantee that `fix:applied` means GitHub reported the PR as merged.

## Manual Test Checklist

For behavior changes, test against a disposable repository when possible:

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
