"""Focused tests for the optional terminal UI. No terminal or GitHub needed."""

import importlib.util
import json
import os
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time
import unittest
from unittest import mock
import fcntl
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("fixbuddy_tui", ROOT / "src" / "tui.py")
assert SPEC and SPEC.loader
tui = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = tui
SPEC.loader.exec_module(tui)


class TerminalUiTests(unittest.TestCase):
    def test_paginated_repo_catalog_includes_private_and_collaborator_repos(self):
        pages = json.dumps([
            [{"full_name": "Codevena/alpha", "private": False, "archived": False, "has_issues": True}],
            [{"full_name": "Partner/private-app", "private": True, "archived": False, "has_issues": True},
             {"full_name": "Codevena/alpha", "private": False, "archived": False, "has_issues": True}],
        ])
        repos = tui.parse_repository_pages(pages)
        self.assertEqual([repo.full_name for repo in repos], ["Codevena/alpha", "Partner/private-app"])
        self.assertTrue(repos[1].private)

    def test_issue_pages_exclude_pull_requests_and_closed_issues(self):
        pages = json.dumps([[{
            "number": 7, "title": "bug", "state": "open", "html_url": "https://github.com/acme/app/issues/7",
            "labels": [{"name": "bug"}], "body": "details"
        }, {
            "number": 8, "title": "PR", "state": "open", "pull_request": {"url": "x"}, "labels": []
        }], [{"number": 9, "title": "old", "state": "closed", "labels": []}]])
        issues = tui.parse_issue_pages("acme/app", pages)
        self.assertEqual([(issue.repo, issue.number, issue.title) for issue in issues],
                         [("acme/app", 7, "bug")])

    def test_partial_repo_failure_is_unknown_not_zero(self):
        responses = {
            "user/repos?per_page=100": json.dumps([[{
                "full_name": "acme/ok", "private": False, "archived": False, "has_issues": True
            }, {
                "full_name": "acme/fail", "private": True, "archived": False, "has_issues": True
            }]]),
            "repos/acme/ok/issues?state=open&per_page=100": json.dumps([[{
                "number": 3, "title": "open", "state": "open", "labels": []
            }]]),
        }
        def api(endpoint):
            if endpoint not in responses:
                raise RuntimeError("offline")
            return responses[endpoint]
        repos = tui.load_catalog(api, max_workers=2)
        by_name = {repo.full_name: repo for repo in repos}
        self.assertEqual(len(by_name["acme/ok"].issues), 1)
        self.assertEqual(by_name["acme/fail"].status, "error")
        self.assertEqual(tui.catalog_totals(repos), (2, 1, 1))

    def test_repository_api_failure_shows_unknown_global_counts(self):
        app = tui.TerminalApp(Path("/bin/fixbuddy"), tui.Settings())
        app.catalog_loading = True
        app.events.put(("catalog", {"type": "error", "message": "offline"}))
        app.drain_events()
        with mock.patch.object(app, "put") as put:
            app.draw_hero(mock.Mock(), 120, 32)
        metrics = [call.args[3] for call in put.call_args_list]
        self.assertTrue(any("?  REPOSITORIES" in metric for metric in metrics))
        self.assertTrue(any("?  OPEN ISSUES" in metric for metric in metrics))
        self.assertIn("offline", app.notice)

    def test_switching_repos_clears_same_number_selection(self):
        settings = tui.Settings(repo="acme/one", project="/tmp/one")
        app = tui.TerminalApp(Path("/bin/fixbuddy"), settings)
        app.catalog = [tui.RepoRecord("acme/one", False, False, True, status="ok",
                                      issues=[tui.IssueRecord("acme/one", 7, "first", [])]),
                       tui.RepoRecord("acme/two", True, False, True, status="ok",
                                      issues=[tui.IssueRecord("acme/two", 7, "second", [])])]
        app.selected = {7}
        app.select_repo("acme/two")
        self.assertEqual(app.settings.repo, "acme/two")
        self.assertEqual(app.selected, set())
        self.assertEqual(app.issues[0]["title"], "second")
        with mock.patch.object(tui.subprocess, "Popen") as popen:
            app.start_run()
        popen.assert_not_called()

    def test_all_issues_never_mix_same_number_from_two_repos(self):
        app = tui.TerminalApp(Path("/bin/fixbuddy"), tui.Settings())
        app.toggle_issue({"repo": "acme/one", "number": 7})
        self.assertEqual(app.selected, {7})
        app.toggle_issue({"repo": "acme/two", "number": 7})
        self.assertEqual(app.settings.repo, "acme/two")
        self.assertEqual(app.settings.project, "")
        self.assertEqual(app.selected, {7})

    def test_untrusted_issue_text_cannot_control_terminal(self):
        text = "Fix \x1b[2J\x1b]0;secret\x07\u202e title\nnext\tline"
        cleaned = tui.clean_display(text)
        self.assertEqual(cleaned, "Fix  title next line")

    def test_clip_respects_double_width_characters(self):
        clipped = tui.clip_cells("A界B", 3)
        self.assertEqual(clipped, "A…")
        self.assertLessEqual(tui.display_width(clipped), 3)

    def test_config_is_parsed_as_data(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / ".fixbuddy.conf"
            config.write_text('repo = acme/app\nproject = "/tmp/my repo"\n'
                              'check_cmd = $(touch /tmp/never-run)\n')
            values = tui.read_config(config)
        self.assertEqual(values["repo"], "acme/app")
        self.assertEqual(values["project"], "/tmp/my repo")
        self.assertEqual(values["check_cmd"], "$(touch /tmp/never-run)")

    def test_preview_is_read_only_and_uses_explicit_merge_mode(self):
        settings = tui.Settings(repo="acme/app", project="/tmp/app", severity="high")
        command = tui.build_preview_command(Path("/bin/fixbuddy"), settings)
        self.assertEqual(command[:5], ["/bin/fixbuddy", "--repo", "acme/app", "--project", "/tmp/app"])
        self.assertIn("--dry-run", command)
        self.assertIn("--json", command)
        self.assertIn("--no-auto-merge", command)
        self.assertEqual(command[command.index("--severity") + 1], "high")

    def test_run_targets_only_selected_issues(self):
        settings = tui.Settings(repo="acme/app", project="/tmp/app", auto_merge=True, max_issues=3)
        command = tui.build_run_command(Path("/bin/fixbuddy"), settings, [7, 42])
        self.assertEqual(command.count("--issue"), 2)
        self.assertEqual(command[command.index("--issue") + 1], "7")
        self.assertIn("--auto-merge", command)
        self.assertIn("--yes", command)
        self.assertEqual(command[command.index("--max") + 1], "3")

    def test_run_targets_preview_order_and_excludes_later_issues(self):
        settings = tui.Settings(repo="acme/app", project="/tmp/app", max_issues=1)
        app = tui.TerminalApp(Path("/bin/fixbuddy"), settings)
        app.preview_key = (tui.settings_key(settings), app.catalog_generation)
        app.actionable_numbers = {42, 7}
        app.actionable_order = [42, 7]
        app.catalog = [tui.RepoRecord("acme/app", False, False, True, status="ok",
                                      issues=[tui.IssueRecord("acme/app", 99, "arrived later", [])])]
        with mock.patch.object(tui.subprocess, "Popen") as popen, \
             mock.patch.object(tui.threading.Thread, "start"):
            app.start_run()
        command = popen.call_args.args[0]
        self.assertEqual([command[index + 1] for index, value in enumerate(command)
                          if value == "--issue"], ["42", "7"])
        self.assertNotIn("99", command)

    def test_layout_fits_narrow_and_wide_terminals(self):
        self.assertEqual(tui.panel_widths(80), (76, 0))
        left, right = tui.panel_widths(120)
        self.assertGreater(left, right)
        self.assertLessEqual(left + right + 5, 120)

    def test_global_inventory_renders_in_narrow_and_wide_ptys(self):
        for columns, rows, expected in ((40, 12, b"GITHUB REPOSITORIES"),
                                        (120, 32, b"REPOSITORY")):
            with self.subTest(columns=columns):
                with tempfile.TemporaryDirectory() as home:
                    master, slave = pty.openpty()
                    fcntl.ioctl(slave, termios.TIOCSWINSZ,
                                struct.pack("HHHH", rows, columns, 0, 0))
                    env = dict(os.environ, TERM="xterm-256color", PYTHONDONTWRITEBYTECODE="1",
                               HOME=home, PATH=f"{ROOT / 'tests' / 'stubs'}:{os.environ['PATH']}")
                    def child_setup():
                        os.setsid()
                        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
                    process = subprocess.Popen(
                        [str(ROOT / "fixbuddy")],
                        stdin=slave, stdout=slave, stderr=slave, env=env,
                        preexec_fn=child_setup,
                    )
                    os.close(slave)
                    data = bytearray()
                    sent_quit = False
                    deadline = time.monotonic() + 8
                    try:
                        while time.monotonic() < deadline:
                            readable, _, _ = select.select([master], [], [], 0.1)
                            if readable:
                                try:
                                    data.extend(os.read(master, 65536))
                                except OSError:
                                    break
                            if expected in data and b"acme/app" in data and not sent_quit:
                                os.write(master, b"q")
                                sent_quit = True
                            if process.poll() is not None:
                                break
                        self.assertTrue(sent_quit, (len(data), expected in data, b"acme/app" in data,
                                                    process.poll(), data[-300:]))
                        self.assertIn(b"FIX BUDDY", data)
                        self.assertEqual(process.wait(timeout=2), 0, data[-500:])
                    finally:
                        if process.poll() is None:
                            process.terminate()
                            process.wait(timeout=2)
                        os.close(master)

    def test_failed_run_check_keeps_global_queue_but_clears_selection(self):
        settings = tui.Settings(repo="acme/old", project="/tmp/old")
        app = tui.TerminalApp(Path("/bin/fixbuddy"), settings)
        app.catalog = [tui.RepoRecord("acme/old", False, False, True, status="ok")]
        app.issues = [{"repo": "acme/old", "number": 7, "title": "old issue", "labels": []}]
        app.selected = {7}
        app.preview_key = (tui.settings_key(settings), app.catalog_generation)
        screen = mock.Mock()
        with mock.patch.object(app, "draw"), mock.patch.object(
            tui.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "offline")
        ):
            self.assertFalse(app.refresh_run_preview(screen))
        self.assertEqual(len(app.issues), 1)
        self.assertEqual(app.selected, set())
        self.assertIsNone(app.preview_key)

    def test_changed_repo_cannot_launch_old_preview(self):
        settings = tui.Settings(repo="acme/old", project="/tmp/old")
        app = tui.TerminalApp(Path("/bin/fixbuddy"), settings)
        app.issues = [{"number": 7, "title": "old issue", "labels": []}]
        app.selected = {7}
        app.preview_key = (tui.settings_key(settings), app.catalog_generation)
        settings.repo = "acme/new"
        app.handle_key(mock.Mock(), ord("g"))
        self.assertNotEqual(app.dialog, "confirm")
        with mock.patch.object(tui.subprocess, "Popen") as popen:
            app.start_run()
        popen.assert_not_called()

    def test_changed_repo_requires_a_fresh_run_check(self):
        settings = tui.Settings(repo="acme/old", project="/tmp/old")
        app = tui.TerminalApp(Path("/bin/fixbuddy"), settings)
        app.catalog = [tui.RepoRecord("acme/new", False, False, True, status="ok")]
        app.issues = [{"repo": "acme/old", "number": 7, "title": "old issue", "labels": []}]
        app.selected = {7}
        app.preview_key = (tui.settings_key(settings), app.catalog_generation)
        settings.repo = "acme/new"
        with mock.patch.object(app, "draw"), mock.patch.object(
            tui.subprocess, "run"
        ) as run:
            self.assertFalse(app.refresh_run_preview(mock.Mock()))
        run.assert_not_called()
        self.assertEqual(app.selected, set())
        self.assertIsNone(app.preview_key)


if __name__ == "__main__":
    unittest.main()
