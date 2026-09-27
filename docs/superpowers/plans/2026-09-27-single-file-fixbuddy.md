# Single-file FixBuddy — implementation plan

## Intent

Markus wants one delivered executable named `fixbuddy`, invoked with one
command, while retaining the CLI pipeline, terminal UI, and wizard. The demo
mode is removed. The TUI discovers GitHub repositories visible to the logged-in
account and shows all open issues across them before a repository is selected.
This is a local candidate only: the current user request does not authorize a
new push, tag, release, or replacement of the public v0.8.0 artifact.

## Contract

- `fixbuddy` with no arguments opens the TUI on an interactive terminal when
  Python 3 is available; otherwise it opens the existing Bash wizard.
- `fixbuddy --wizard` forces the old wizard. `fixbuddy --repo ... --project ...`
  and other existing CLI flags execute the same Bash core without changing its
  Git/GitHub semantics. `--demo` is removed.
- The TUI starts with a global read-only overview: all accessible repositories,
  counts per repo, a total, and a cross-repository open-Issue list. Selecting a
  repo narrows the Issue list. GitHub pull requests are excluded from issue
  counts. One run targets only one selected repo with a verified local checkout.
  No repository is cloned automatically. Listing errors are shown as unknown,
  never as zero, and the overview says when it is incomplete.
- Before any label, issue, PR, push, or agent side effect, the Bash core checks
  that the selected `owner/repo` is the repository of the local checkout's
  `origin` fetch **and push** destination. Accept only normalized GitHub HTTPS
  and SSH forms for the same owner/name; reject missing, mismatched, redirected,
  or ambiguous origins. The failure path causes zero downstream writes. The
  test harness uses a Git stub for the effective URL while retaining its local
  bare remote for real offline push tests; the production gate has no bypass.
- Repository discovery uses paginated `GET /user/repos` and each repo's
  paginated `GET /repos/{owner}/{repo}/issues?state=open` through the existing
  authenticated `gh` CLI. Bounded concurrency and a background load keep the
  TUI responsive; issue titles, labels and details support its list/detail view.
- The **delivered** file is a single Bash executable that embeds the Python
  TUI and Bash wizard as inert heredoc data and appends the tested Bash core.
  `python3 -c` and `bash -c` receive embedded source as an argument, so stdin
  remains the terminal for keyboard input. No temporary source extraction is
  needed at runtime. The CLI still works without Python 3.
- Source files live under `src/` for maintenance; the repository root exposes
  only the built `fixbuddy` product file and `install.sh` as the acquisition
  script. A deterministic builder checks the committed bundle byte for byte.
- v0.8.0 remains the published, multi-file release until Markus explicitly
  authorizes another publication. The existing pinned `v0.8.0` download path
  keeps its legacy behavior. A new `install.sh --local` path installs only the
  freshly built `fixbuddy` from this checkout; it verifies the single-file
  checksum and leaves old installed names untouched for compatibility. The
  next release will switch remote installation to the single file; no new
  public URL or tag is claimed now.

## Changes

1. Add offline GitHub discovery/aggregation tests for pagination, private and
   collaborator repos, PR exclusion, partial failure, cross-repo selection,
   and no downstream write on preview. Confirm expected RED.
2. Add a mismatched-origin regression: selected repo A, effective checkout
   origin B, zero labels/agents/pushes. Implement the pre-write identity gate
   in the Bash core and test HTTPS/SSH normalization plus missing/pushurl cases.
3. Implement the global REPOS/ISSUES views and bounded background loading in
   the Python TUI; remove demo handling and prevent mixed-repo run selection.
4. Add wrapper integration tests (one-file bundle, no-arg TUI PTY, wizard
   input, CLI flags, missing-Python fallback). Confirm expected RED.
5. Move core/TUI/wizard source under `src/`, adjust their self-location and
   invocation paths, and add a deterministic `scripts/build.py` that emits
   root `fixbuddy`. Keep core behavior unchanged except for the origin identity
   gate in task 2.
6. Update Action, CI, installer/local installation path, checksums, README,
   CONTRIBUTING and handoff. The Action uses the same `fixbuddy` executable.
7. Run all 43+ offline core scenarios against the bundled executable, TUI PTY
   tests, Bash syntax, ShellCheck, bundle `--check`, checksum check, Action
   syntax, and an isolated installer smoke. Independently review the resulting
   public interface and packaging paths before any local commit.

## Risks

- A generated bundle that differs from source could bypass tests. CI and the
  installer smoke must check byte identity and execute the bundle itself.
- Heredoc markers inside embedded source would break the Bash parser; the
  builder rejects marker collisions and validates the output with `bash -n`.
- stdin used to feed embedded source would break TUI/wizard input. Tests must
  drive both through a PTY and exercise a wizard prompt.
- A cross-repo selection must never send an issue number to the wrong repo.
  Run command construction checks the selected issue's repo identity and the
  last successful snapshot before it can start an agent.
- Some GitHub repositories have no local checkout or no accessible issue
  endpoint. The dashboard must still list them and show unknown/disabled run
  state without pretending they have zero issues.

## Plan-review round 1

- CRITICAL: an issue may belong to repo A while the chosen local checkout's
  origin pushes to B. Added the explicit pre-write fetch/push-origin gate and
  zero-side-effect mismatch tests in task 2.
- WARN: the pinned `v0.8.0` installer cannot fetch a future one-file artifact.
  Kept its published path unchanged and specified a checked `--local` install
  of the candidate, with separate tests for both paths in task 6.
- The user-owned untracked `review-todo.md` stays unmodified and unstaged.

## Implementation review delta

- Recheck effective origin identity after every agent and operator check stage,
  before remote inspection/push and after push. A focused RED test demonstrated
  that a reviewer could otherwise redirect `remote.origin.pushurl` to another
  bare repository; the guard now stops that path before the push.
- Treat an initial account-wide GitHub API failure as unknown global counts,
  never an empty account. A RED UI test covers the error state.
- Preserve the ordered issue IDs from the successful JSON preview in the run
  command, even when no issues are manually ticked. A RED test showed that an
  unqualified run could include a newly arrived issue; the run now passes
  explicit `--issue` values in preview order so `--max` keeps its meaning.
