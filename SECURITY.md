# Security

fixbuddy gives AI coding agents shell access to a local repository and lets them create commits and pull requests. That is useful, but it is not a security boundary.

## Threat Model

Use fixbuddy only when all of these are acceptable:

- The target repository is trusted.
- The issue content being processed is trusted enough to show to an agent with shell access.
- The selected agent CLIs may run commands, read repository files, and modify the worktree.
- GitHub credentials available to `gh` may create labels, comments, branches, PRs, and merges depending on repository permissions.

Do not run fixbuddy against untrusted issues, untrusted forks, or repositories where arbitrary issue text should not influence shell-capable automation.

## Sensitive Data

fixbuddy logs prompts and agent output to:

```text
~/.fixbuddy/runs/
```

Those logs can include issue bodies, code snippets, command output, file paths, and agent responses. Do not publish logs without reviewing them.

## Recommended Permissions

- Use the least-privileged GitHub token or account that can perform the needed workflow.
- Prefer branch protection and required CI checks before enabling auto-merge.
- Start with `--dry-run`, then `--max 1`, before larger batches.
- Use `--no-auto-merge` for repositories that require human release control.

## Reporting Security Issues

Please report security issues privately through the repository's security advisory feature if available. If advisories are not enabled, open a minimal public issue that says a private security report is needed, without including exploit details.

Include:

- affected version or commit
- operating system
- relevant command flags
- a concise impact description
- sanitized logs if they are necessary to reproduce the problem
