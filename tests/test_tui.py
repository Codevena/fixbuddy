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
SPEC = importlib.util.spec_from_file_location("fixbuddy_tui", ROOT / "fixbuddy-tui.py")
assert SPEC and SPEC.loader
tui = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = tui
SPEC.loader.exec_module(tui)


class TerminalUiTests(unittest.TestCase):
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
        command = tui.build_preview_command(Path("/bin/fixbuddy.sh"), settings)
        self.assertEqual(command[:5], ["/bin/fixbuddy.sh", "--repo", "acme/app", "--project", "/tmp/app"])
        self.assertIn("--dry-run", command)
        self.assertIn("--json", command)
        self.assertIn("--no-auto-merge", command)
        self.assertEqual(command[command.index("--severity") + 1], "high")

    def test_run_targets_only_selected_issues(self):
        settings = tui.Settings(repo="acme/app", project="/tmp/app", auto_merge=True, max_issues=3)
        command = tui.build_run_command(Path("/bin/fixbuddy.sh"), settings, [7, 42])
        self.assertEqual(command.count("--issue"), 2)
        self.assertEqual(command[command.index("--issue") + 1], "7")
        self.assertIn("--auto-merge", command)
        self.assertIn("--yes", command)
        self.assertEqual(command[command.index("--max") + 1], "3")

    def test_layout_fits_narrow_and_wide_terminals(self):
        self.assertEqual(tui.panel_widths(80), (76, 0))
        left, right = tui.panel_widths(120)
        self.assertGreater(left, right)
        self.assertLessEqual(left + right + 5, 120)

    def test_demo_renders_in_narrow_and_wide_ptys(self):
        for columns, rows, expected in ((40, 12, b"ISSUE QUEUE"),
                                        (120, 32, b"SELECTED ISSUE")):
            with self.subTest(columns=columns):
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ,
                            struct.pack("HHHH", rows, columns, 0, 0))
                env = dict(os.environ, TERM="xterm-256color", PYTHONDONTWRITEBYTECODE="1")
                process = subprocess.Popen(
                    [sys.executable, str(ROOT / "fixbuddy-tui.py"), "--demo"],
                    stdin=slave, stdout=slave, stderr=slave, env=env,
                )
                os.close(slave)
                data = bytearray()
                sent_quit = False
                deadline = time.monotonic() + 5
                try:
                    while time.monotonic() < deadline:
                        readable, _, _ = select.select([master], [], [], 0.1)
                        if readable:
                            try:
                                data.extend(os.read(master, 65536))
                            except OSError:
                                break
                        if expected in data and not sent_quit:
                            os.write(master, b"q")
                            sent_quit = True
                        if process.poll() is not None:
                            break
                    self.assertTrue(sent_quit, data[-500:])
                    self.assertEqual(process.wait(timeout=2), 0, data[-500:])
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=2)
                    os.close(master)

    def test_failed_refresh_invalidates_previous_queue_and_selection(self):
        settings = tui.Settings(repo="acme/old", project="/tmp/old")
        app = tui.TerminalApp(Path("/bin/fixbuddy.sh"), settings)
        app.issues = [{"number": 7, "title": "old issue", "labels": []}]
        app.selected = {7}
        app.preview_key = tui.settings_key(settings)
        settings.repo = "acme/new"
        screen = mock.Mock()
        with mock.patch.object(app, "draw"), mock.patch.object(
            tui.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", "offline")
        ):
            app.refresh_preview(screen)
        self.assertEqual(app.issues, [])
        self.assertEqual(app.selected, set())
        self.assertIsNone(app.preview_key)

    def test_changed_repo_cannot_launch_old_preview(self):
        settings = tui.Settings(repo="acme/old", project="/tmp/old")
        app = tui.TerminalApp(Path("/bin/fixbuddy.sh"), settings)
        app.issues = [{"number": 7, "title": "old issue", "labels": []}]
        app.selected = {7}
        app.preview_key = tui.settings_key(settings)
        settings.repo = "acme/new"
        app.handle_key(mock.Mock(), ord("g"))
        self.assertNotEqual(app.dialog, "confirm")
        with mock.patch.object(tui.subprocess, "Popen") as popen:
            app.start_run()
        popen.assert_not_called()

    def test_successful_refresh_of_new_repo_drops_same_number_selection(self):
        settings = tui.Settings(repo="acme/old", project="/tmp/old")
        app = tui.TerminalApp(Path("/bin/fixbuddy.sh"), settings)
        app.issues = [{"number": 7, "title": "old issue", "labels": []}]
        app.selected = {7}
        app.preview_key = tui.settings_key(settings)
        settings.repo = "acme/new"
        data = json.dumps({"repo": "acme/new", "project": "/tmp/old", "issues": [
            {"number": 7, "title": "different issue", "labels": []}
        ]})
        with mock.patch.object(app, "draw"), mock.patch.object(
            tui.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, data, "")
        ):
            app.refresh_preview(mock.Mock())
        self.assertEqual(app.selected, set())
        self.assertEqual(app.issues[0]["title"], "different issue")


if __name__ == "__main__":
    unittest.main()
