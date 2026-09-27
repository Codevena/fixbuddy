#!/usr/bin/env python3
"""FixBuddy's optional terminal UI. Python 3 standard library only.

The UI previews and launches fixbuddy.sh; the Bash pipeline remains the only
component that edits a checkout or calls GitHub write APIs.
"""

from __future__ import annotations

import argparse
import curses
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any


CSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
SEVERITIES = ("all", "critical", "high", "medium", "low")
AGENTS = ("claude", "codex", "opencode", "agy")
TABS = ("QUEUE", "SETUP", "RUN")
LOGO = (
    "██████╗ ██████╗ ",
    "██╔═══╝ ██╔══██╗",
    "█████╗   ██████╔╝",
    "██╔══╝   ██╔══██╗",
    "██║      ██████╔╝",
    "╚═╝      ╚═════╝ ",
)


def clean_display(value: str) -> str:
    """Remove terminal controls and bidi formatting from untrusted text."""
    value = OSC.sub("", CSI.sub("", str(value))).replace("\x1b", "")
    return "".join(
        " " if char in "\r\n\t" else char
        for char in value
        if char in "\r\n\t" or unicodedata.category(char) not in {"Cc", "Cf", "Cs"}
    )


def display_width(value: str) -> int:
    width = 0
    for char in value:
        if unicodedata.combining(char) or unicodedata.category(char) in {"Cf", "Cc"}:
            continue
        width += 2 if unicodedata.east_asian_width(char) in {"W", "F"} else 1
    return width


def clip_cells(value: str, width: int) -> str:
    """Truncate to terminal cells, retaining an ellipsis when truncated."""
    if width <= 0:
        return ""
    value = clean_display(value)
    if display_width(value) <= width:
        return value
    if width == 1:
        return "…"
    used = 0
    out: list[str] = []
    for char in value:
        char_width = display_width(char)
        if used + char_width > width - 1:
            break
        out.append(char)
        used += char_width
    return "".join(out) + "…"


def pad_cells(value: str, width: int) -> str:
    value = clip_cells(value, width)
    return value + " " * max(0, width - display_width(value))


def panel_widths(width: int) -> tuple[int, int]:
    available = max(0, width - 4)
    if width < 104:
        return available, 0
    left = int((available - 3) * 0.62)
    return left, available - 3 - left


def read_config(path: Path) -> dict[str, str]:
    """Read values as inert strings, following the Bash config's simple syntax."""
    if not path.is_file():
        return {}
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = (part.strip() for part in line.split("=", 1))
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


@dataclass
class Settings:
    repo: str = ""
    project: str = ""
    severity: str = ""
    max_issues: int | None = None
    fix_agent: str = "claude"
    review_agent: str = "codex"
    auto_merge: bool = False


def settings_key(settings: Settings) -> tuple[str, str, str, int | None, str, str, bool]:
    """Identity of the exact preview and run options shown to the operator."""
    return (settings.repo, settings.project, settings.severity, settings.max_issues,
            settings.fix_agent, settings.review_agent, settings.auto_merge)


def default_settings(args: argparse.Namespace) -> Settings:
    values: dict[str, str] = {}
    values.update(read_config(Path.home() / ".fixbuddy" / "config"))
    values.update(read_config(Path.cwd() / ".fixbuddy.conf"))
    raw_max = values.get("max", "")
    max_issues = int(raw_max) if raw_max.isdecimal() and int(raw_max) > 0 else None
    return Settings(
        repo=args.repo or values.get("repo", ""),
        project=args.project or values.get("project", ""),
        severity=values.get("severity", "") if values.get("severity", "") in SEVERITIES else "",
        max_issues=max_issues,
        fix_agent=values.get("fix_agent", "claude") if values.get("fix_agent", "claude") in AGENTS else "claude",
        review_agent=values.get("review_agent", "codex") if values.get("review_agent", "codex") in AGENTS else "codex",
        # Explicit UI choice is required even when a config enables merging.
        auto_merge=False,
    )


def common_command(script: Path, settings: Settings) -> list[str]:
    command = [str(script), "--repo", settings.repo, "--project", settings.project,
               "--fix-agent", settings.fix_agent, "--review-agent", settings.review_agent]
    if settings.severity:
        command += ["--severity", settings.severity]
    if settings.max_issues is not None:
        command += ["--max", str(settings.max_issues)]
    command.append("--auto-merge" if settings.auto_merge else "--no-auto-merge")
    return command


def build_preview_command(script: Path, settings: Settings) -> list[str]:
    return common_command(script, settings) + ["--dry-run", "--json"]


def build_run_command(script: Path, settings: Settings, selected: list[int]) -> list[str]:
    command = common_command(script, settings)
    for number in sorted(set(selected)):
        command += ["--issue", str(number)]
    return command + ["--yes"]


def _severity(issue: dict[str, Any]) -> str:
    labels = [entry.get("name", "") for entry in issue.get("labels", [])]
    for level in ("critical", "high", "medium", "low"):
        if f"severity:{level}" in labels:
            return level.upper()
    return "ISSUE"


def _wrap(text: str, width: int, limit: int) -> list[str]:
    words = clean_display(text).split()
    lines: list[str] = []
    line = ""
    for word in words:
        candidate = f"{line} {word}" if line else word
        if display_width(candidate) > width and line:
            lines.append(line)
            line = word
        else:
            line = candidate
        if len(lines) >= limit:
            break
    if len(lines) < limit and line:
        lines.append(line)
    return [clip_cells(item, width) for item in lines[:limit]]


class TerminalApp:
    def __init__(self, script: Path, settings: Settings, demo: bool = False):
        self.script = script
        self.settings = settings
        self.demo = demo
        self.issues: list[dict[str, Any]] = []
        self.selected: set[int] = set()
        self.preview_key: tuple[str, str, str, int | None, str, str, bool] | None = None
        self.cursor = 0
        self.setup_cursor = 0
        self.tab = 0
        self.dialog = ""
        self.notice = "Read-only preview · press r to refresh"
        self.logs: list[str] = []
        self.log_scroll = 0
        self.process: subprocess.Popen[str] | None = None
        self.run_exit: int | None = None
        self.events: queue.Queue[tuple[str, Any]] = queue.Queue()
        self.colors: dict[str, int] = {}
        if demo:
            self.settings.repo = self.settings.repo or "codevena/fixbuddy"
            self.settings.project = self.settings.project or "~/Developer/fixbuddy"
            self.issues = [
                {"number": 7, "title": "Guard branch and base refs after each agent", "labels": [{"name": "severity:critical"}], "body": "A branch switch must never place an unreviewed commit into a later pull request.", "url": "https://github.com/Codevena/fixbuddy/issues/7"},
                {"number": 12, "title": "Retry closed PRs with stale remote branches", "labels": [{"name": "severity:high"}], "body": "A closed pull request may leave fix/issue-N on origin.", "url": "https://github.com/Codevena/fixbuddy/issues/12"},
                {"number": 18, "title": "Reject contradictory review verdicts", "labels": [{"name": "severity:high"}], "body": "Only one exact final verdict may authorize a push.", "url": "https://github.com/Codevena/fixbuddy/issues/18"},
                {"number": 23, "title": "Page through the full issue queue", "labels": [{"name": "severity:medium"}], "body": "Queues above two hundred issues need complete pagination.", "url": "https://github.com/Codevena/fixbuddy/issues/23"},
            ]
            self.notice = "DEMO · sample data · no GitHub calls or writes"
            self.preview_key = settings_key(self.settings)

    def invalidate_preview(self) -> None:
        self.issues = []
        self.selected.clear()
        self.cursor = 0
        self.preview_key = None

    def init_colors(self) -> None:
        curses.start_color()
        curses.use_default_colors()
        if curses.COLORS >= 256:
            colors = {
                "text": (255, -1), "muted": (103, -1), "violet": (141, -1),
                "pink": (205, -1), "green": (48, -1), "amber": (215, -1),
                "red": (203, -1), "line": (61, -1), "header": (255, 54),
                "badge": (255, 205), "select": (255, 60), "footer": (255, 235),
            }
        else:
            colors = {
                "text": (curses.COLOR_WHITE, -1), "muted": (curses.COLOR_CYAN, -1),
                "violet": (curses.COLOR_MAGENTA, -1), "pink": (curses.COLOR_MAGENTA, -1),
                "green": (curses.COLOR_GREEN, -1), "amber": (curses.COLOR_YELLOW, -1),
                "red": (curses.COLOR_RED, -1), "line": (curses.COLOR_BLUE, -1),
                "header": (curses.COLOR_WHITE, curses.COLOR_MAGENTA),
                "badge": (curses.COLOR_WHITE, curses.COLOR_RED),
                "select": (curses.COLOR_WHITE, curses.COLOR_BLUE),
                "footer": (curses.COLOR_WHITE, curses.COLOR_BLUE),
            }
        for index, (name, (foreground, background)) in enumerate(colors.items(), 1):
            curses.init_pair(index, foreground, background)
            self.colors[name] = curses.color_pair(index)

    def put(self, screen: curses.window, y: int, x: int, text: str, style: str = "text", bold: bool = False) -> None:
        height, width = screen.getmaxyx()
        if y < 0 or y >= height or x < 0 or x >= width:
            return
        text = clip_cells(text, width - x)
        try:
            screen.addstr(y, x, text, self.colors.get(style, 0) | (curses.A_BOLD if bold else 0))
        except curses.error:
            pass  # curses rejects the lower-right cell on some terminals.

    def frame(self, screen: curses.window, y: int, x: int, height: int, width: int, title: str) -> None:
        if height < 3 or width < 4:
            return
        self.put(screen, y, x, "╭" + "─" * (width - 2) + "╮", "line")
        self.put(screen, y + height - 1, x, "╰" + "─" * (width - 2) + "╯", "line")
        for row in range(y + 1, y + height - 1):
            self.put(screen, row, x, "│", "line")
            self.put(screen, row, x + width - 1, "│", "line")
        self.put(screen, y, x + 2, f" {title} ", "pink", True)

    def refresh_preview(self, screen: curses.window) -> None:
        if self.demo:
            self.notice = "DEMO · preview refresh disabled"
            return
        identity = settings_key(self.settings)
        previous_selection = set(self.selected) if self.preview_key == identity else set()
        self.invalidate_preview()
        if not self.settings.repo or not self.settings.project:
            self.tab = 1
            self.notice = "Enter a repository and local checkout in SETUP"
            return
        self.notice = "Loading the read-only issue queue…"
        self.draw(screen)
        screen.refresh()
        try:
            result = subprocess.run(
                build_preview_command(self.script, self.settings),
                capture_output=True, text=True, timeout=45, check=False,
            )
            if result.returncode != 0:
                raise RuntimeError(clean_display(result.stderr.strip() or result.stdout.strip())[:240])
            data = json.loads(result.stdout)
            if data.get("repo") != self.settings.repo or data.get("project") != self.settings.project:
                raise RuntimeError("preview settings did not match the requested repository/checkout")
            self.issues = data.get("issues", [])
            self.selected = previous_selection & {int(issue["number"]) for issue in self.issues}
            self.cursor = min(self.cursor, max(0, len(self.issues) - 1))
            self.preview_key = identity
            self.notice = f"{len(self.issues)} actionable issue(s) · read-only preview"
        except (OSError, ValueError, subprocess.TimeoutExpired, RuntimeError) as error:
            self.notice = f"Preview failed: {clean_display(str(error))[:200]}"

    def _reader(self, process: subprocess.Popen[str]) -> None:
        assert process.stdout is not None
        for line in process.stdout:
            self.events.put(("line", clean_display(line.rstrip("\r\n"))))
        self.events.put(("exit", process.wait()))

    def drain_events(self) -> None:
        while True:
            try:
                kind, value = self.events.get_nowait()
            except queue.Empty:
                return
            if kind == "line":
                self.logs.append(value)
                self.logs = self.logs[-1500:]
            else:
                self.run_exit = int(value)
                self.notice = f"Run finished · exit {self.run_exit} · inspect logs below"

    def start_run(self) -> None:
        if self.demo:
            self.notice = "DEMO is read-only; exit demo to run FixBuddy"
            return
        if self.preview_key != settings_key(self.settings) or not self.issues:
            self.notice = "Settings changed or preview failed · refresh the queue before running"
            return
        valid_numbers = {int(issue["number"]) for issue in self.issues}
        if not self.selected <= valid_numbers:
            self.notice = "Selection is stale · refresh the queue before running"
            return
        numbers = sorted(self.selected)
        command = build_run_command(self.script, self.settings, numbers)
        try:
            self.process = subprocess.Popen(
                command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
            )
        except OSError as error:
            self.notice = f"Could not start: {clean_display(str(error))}"
            return
        self.logs = []
        self.invalidate_preview()  # a completed run changes labels/PR state
        self.run_exit = None
        self.log_scroll = 0
        self.tab = 2
        self.notice = "Pipeline running · x to interrupt safely"
        threading.Thread(target=self._reader, args=(self.process,), daemon=True).start()

    def stop_run(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
            self.notice = "Interrupt sent · waiting for FixBuddy cleanup"

    def draw_header(self, screen: curses.window, width: int) -> None:
        self.put(screen, 0, 0, " " * width, "header")
        self.put(screen, 0, 1, " FB ", "badge", True)
        self.put(screen, 0, 6, " FIXBUDDY ", "header", True)
        x = 20
        for index, label in enumerate(TABS):
            if x + len(label) + 3 >= width - 15:
                break
            self.put(screen, 0, x, f" {index + 1} {label} ", "badge" if index == self.tab else "header", index == self.tab)
            x += len(label) + 5
        if width >= 90:
            repo = clean_display(self.settings.repo or "set repository")
            self.put(screen, 0, max(x + 2, width - 30), clip_cells(repo, min(27, width - x - 3)), "header")

    def draw_hero(self, screen: curses.window, width: int, height: int) -> int:
        if height < 23:
            self.put(screen, 2, 2, "VERIFY  →  FIX  →  REVIEW  →  PR", "violet", True)
            return 4
        logo_x = 3
        for row, line in enumerate(LOGO):
            self.put(screen, row + 2, logo_x, line[:8], "violet", True)
            self.put(screen, row + 2, logo_x + 8, line[8:], "pink", True)
        x = 26 if width >= 62 else 22
        self.put(screen, 2, x, "ISSUES IN VIEW", "muted", True)
        self.put(screen, 3, x, f"{len(self.issues):03d}  actionable", "text", True)
        self.put(screen, 4, x, f"{len(self.selected):03d}  selected", "pink", True)
        self.put(screen, 6, x, "VERIFY  →  FIX  →  REVIEW  →  PR", "violet", True)
        if width >= 95:
            self.put(screen, 3, width - 29, "MERGE POLICY", "muted", True)
            self.put(screen, 4, width - 29,
                     "AUTO-MERGE ON" if self.settings.auto_merge else "HUMAN MERGE",
                     "amber" if self.settings.auto_merge else "green", True)
        return 9

    def draw_queue(self, screen: curses.window, width: int, height: int, top: int) -> None:
        left, right = panel_widths(width)
        panel_height = max(3, height - top - 2)
        self.frame(screen, top, 2, panel_height, left, "ISSUE QUEUE")
        rows = max(0, panel_height - 2)
        if not self.issues:
            self.put(screen, top + 2, 5, "No actionable issues. Press r to refresh.", "muted")
            return
        start = max(0, min(self.cursor - rows // 2, len(self.issues) - rows))
        for row, issue in enumerate(self.issues[start:start + rows]):
            index = start + row
            number = int(issue.get("number", 0))
            marker = "●" if number in self.selected else "○"
            severity = _severity(issue)
            prefix = f" {'▸' if index == self.cursor else ' '} {marker} #{number:<5} {severity:<8} "
            title = clean_display(issue.get("title", ""))
            line = pad_cells(prefix + title, max(0, left - 2))
            self.put(screen, top + 1 + row, 3, line, "select" if index == self.cursor else "text")
        if right:
            x = left + 5
            self.frame(screen, top, x, panel_height, right, "SELECTED ISSUE")
            issue = self.issues[self.cursor]
            content_width = max(1, right - 4)
            self.put(screen, top + 2, x + 2, f"#{issue.get('number')}  {_severity(issue)}", "pink", True)
            line_y = top + 4
            for line in _wrap(issue.get("title", ""), content_width, 3):
                self.put(screen, line_y, x + 2, line, "text", True)
                line_y += 1
            line_y += 1
            for line in _wrap(issue.get("body", "") or "No description", content_width,
                              max(1, top + panel_height - line_y - 3)):
                self.put(screen, line_y, x + 2, line, "muted")
                line_y += 1
                if line_y >= top + panel_height - 2:
                    break
            if panel_height >= 11:
                self.put(screen, top + panel_height - 3, x + 2,
                         clip_cells(issue.get("url", ""), content_width), "violet")

    def draw_setup(self, screen: curses.window, width: int, height: int, top: int) -> None:
        panel_height = max(3, height - top - 2)
        self.frame(screen, top, 2, panel_height, max(4, width - 4), "RUN SETUP")
        fields = (
            ("Repository", self.settings.repo or "press Enter to set"),
            ("Checkout", self.settings.project or "press Enter to set"),
            ("Severity", self.settings.severity or "all"),
            ("Batch size", str(self.settings.max_issues) if self.settings.max_issues else "all"),
            ("Fix agent", self.settings.fix_agent),
            ("Reviewer", self.settings.review_agent),
            ("Auto-merge", "ON · explicit" if self.settings.auto_merge else "OFF · human merge"),
        )
        value_x = min(width - 18, 25)
        visible = max(1, panel_height - 4)
        first = max(0, min(self.setup_cursor - visible // 2, len(fields) - visible))
        for offset, (label, value) in enumerate(fields[first:first + visible]):
            index = first + offset
            y = top + 2 + offset
            style = "select" if index == self.setup_cursor else "text"
            self.put(screen, y, 5, pad_cells(f" {'▸' if index == self.setup_cursor else ' '} {label}", max(1, value_x - 5)), style)
            self.put(screen, y, value_x, clip_cells(value, max(1, width - value_x - 5)),
                     "amber" if index == 6 and self.settings.auto_merge else style)
        if panel_height >= 13:
            self.put(screen, top + panel_height - 3, 5,
                     "Enter: edit / cycle   ← →: cycle   r: refresh preview", "muted")

    def draw_run(self, screen: curses.window, width: int, height: int, top: int) -> None:
        panel_height = max(3, height - top - 2)
        self.frame(screen, top, 2, panel_height, max(4, width - 4), "RUN ACTIVITY")
        state = "RUNNING" if self.process is not None and self.run_exit is None else (
            f"EXIT {self.run_exit}" if self.run_exit is not None else "READY")
        self.put(screen, top + 1, 5, state, "amber" if state == "RUNNING" else "green", True)
        visible = max(0, panel_height - 4)
        start = max(0, len(self.logs) - visible - self.log_scroll)
        for index, line in enumerate(self.logs[start:start + visible]):
            self.put(screen, top + 3 + index, 5, line, "muted")
        if not self.logs:
            self.put(screen, top + 4, 5, "Start from QUEUE with g. No GitHub write occurs in preview.", "muted")

    def draw_footer(self, screen: curses.window, width: int, height: int) -> None:
        self.put(screen, height - 1, 0, " " * width, "footer")
        hints = "  Tab tabs   ↑↓ move   Space select   Enter detail   r refresh   g run   ? help   q quit"
        if self.tab == 1:
            hints = "  Tab tabs   ↑↓ field   Enter edit   ←→ choice   r refresh   g run   ? help   q quit"
        if self.tab == 2:
            hints = "  Tab tabs   ↑↓ scroll   x interrupt   ? help   q quit"
        self.put(screen, height - 1, 0, clip_cells(hints, width), "footer")
        if height >= 3:
            self.put(screen, height - 2, 2, clip_cells(self.notice, width - 4),
                     "red" if "failed" in self.notice.lower() else "muted")

    def draw_dialog(self, screen: curses.window, width: int, height: int) -> None:
        box_width = min(width - 6, 76)
        box_height = min(height - 6, 12)
        if box_width < 16 or box_height < 4:
            return
        x, y = (width - box_width) // 2, (height - box_height) // 2
        for row in range(y, y + box_height):
            self.put(screen, row, x, " " * box_width, "footer")
        title = {"help": "KEYBOARD", "detail": "ISSUE DETAIL", "confirm": "START PIPELINE?", "stop": "INTERRUPT RUN?"}.get(self.dialog, "CONFIRM")
        self.frame(screen, y, x, box_height, box_width, title)
        lines: list[str] = []
        if self.dialog == "help":
            lines = ["1/2/3 or Tab   switch tabs", "↑/↓           move through issues or fields", "Space         select issues; no selection means all", "Enter         inspect issue or change a setup field", "r             refresh read-only GitHub preview", "g             confirm and start the pipeline", "x             interrupt the running pipeline", "q / Esc       close or quit"]
        elif self.dialog == "detail" and self.issues:
            issue = self.issues[self.cursor]
            lines = [f"#{issue.get('number')}  {_severity(issue)}  {clean_display(issue.get('title', ''))}", ""]
            lines += _wrap(issue.get("body", "") or "No description", box_width - 4, box_height - 6)
        elif self.dialog == "confirm":
            count = len(self.selected) if self.selected else len(self.issues)
            if self.settings.max_issues is not None:
                count = min(count, self.settings.max_issues)
            lines = [f"Repository  {self.settings.repo}", f"Issues      {count} of {len(self.issues)} actionable",
                     f"Agents      {self.settings.fix_agent}  →  {self.settings.review_agent}",
                     f"Merge       {'AUTO-MERGE REQUESTED' if self.settings.auto_merge else 'PR stays open for you'}", "",
                     "Press y to start · n or Esc to cancel"]
        elif self.dialog == "stop":
            lines = ["FixBuddy will receive SIGINT and clean up its local branch.", "", "Press y to interrupt · n or Esc to keep running"]
        for index, line in enumerate(lines[:box_height - 2]):
            self.put(screen, y + 1 + index, x + 2, line, "text" if index == 0 else "muted")

    def draw(self, screen: curses.window) -> None:
        screen.erase()
        height, width = screen.getmaxyx()
        if width < 40 or height < 12:
            self.put(screen, 0, 0, "FixBuddy · enlarge terminal to 40×12", "pink", True)
            self.put(screen, 2, 0, "q quit", "muted")
            return
        self.draw_header(screen, width)
        top = self.draw_hero(screen, width, height)
        if self.tab == 0:
            self.draw_queue(screen, width, height, top)
        elif self.tab == 1:
            self.draw_setup(screen, width, height, top)
        else:
            self.draw_run(screen, width, height, top)
        self.draw_footer(screen, width, height)
        if self.dialog:
            self.draw_dialog(screen, width, height)

    def edit_field(self, screen: curses.window) -> None:
        names = ("Repository (owner/repo)", "Local checkout path", "Severity", "Batch size", "Fix agent", "Reviewer", "Auto-merge")
        index = self.setup_cursor
        if index in (2, 4, 5, 6):
            self.cycle_field(1)
            return
        height, width = screen.getmaxyx()
        screen.timeout(-1)
        curses.echo()
        curses.curs_set(1)
        self.put(screen, height - 2, 0, " " * width, "footer")
        prompt = f"{names[index]}: "
        self.put(screen, height - 2, 1, prompt, "pink", True)
        screen.refresh()
        try:
            raw = screen.getstr(height - 2, min(width - 2, len(prompt) + 1), max(1, width - len(prompt) - 3))
            value = raw.decode("utf-8", errors="replace").strip()
            if index == 0 and value:
                self.settings.repo = value
            elif index == 1 and value:
                self.settings.project = os.path.expanduser(value)
            elif index == 3:
                self.settings.max_issues = int(value) if value.isdecimal() and int(value) > 0 else None
            self.invalidate_preview()
            self.notice = "Settings changed · press r to refresh the queue"
        finally:
            curses.noecho()
            curses.curs_set(0)
            screen.timeout(100)

    def cycle_field(self, direction: int) -> None:
        index = self.setup_cursor
        if index == 2:
            current = self.settings.severity or "all"
            self.settings.severity = SEVERITIES[(SEVERITIES.index(current) + direction) % len(SEVERITIES)]
            if self.settings.severity == "all":
                self.settings.severity = ""
        elif index == 4:
            self.settings.fix_agent = AGENTS[(AGENTS.index(self.settings.fix_agent) + direction) % len(AGENTS)]
        elif index == 5:
            self.settings.review_agent = AGENTS[(AGENTS.index(self.settings.review_agent) + direction) % len(AGENTS)]
        elif index == 6:
            self.settings.auto_merge = not self.settings.auto_merge
        self.invalidate_preview()
        self.notice = "Settings changed · press r to refresh the queue"

    def handle_key(self, screen: curses.window, key: int) -> bool:
        if key == -1:
            return True
        if self.dialog:
            if key in (27, ord("n"), ord("N")):
                self.dialog = ""
            elif key in (ord("y"), ord("Y")) and self.dialog == "confirm":
                self.dialog = ""
                self.start_run()
            elif key in (ord("y"), ord("Y")) and self.dialog == "stop":
                self.dialog = ""
                self.stop_run()
            return True
        if key in (ord("?"),):
            self.dialog = "help"
            return True
        if key in (ord("q"), ord("Q")):
            if self.process is not None and self.process.poll() is None:
                self.notice = "Pipeline running · press x to interrupt before quitting"
                return True
            return False
        if key in (9,):
            self.tab = (self.tab + 1) % 3
            return True
        if key in (ord("1"), ord("2"), ord("3")):
            self.tab = key - ord("1")
            return True
        if key in (ord("r"), ord("R")):
            if self.process is None or self.process.poll() is not None:
                self.refresh_preview(screen)
            return True
        if key in (ord("g"), ord("G")):
            if self.process is not None and self.process.poll() is None:
                self.notice = "A run is already active"
            elif self.issues and self.preview_key == settings_key(self.settings):
                self.dialog = "confirm"
            else:
                self.notice = "No actionable issues or missing repository/checkout"
            return True
        if key in (ord("x"), ord("X")) and self.process is not None and self.process.poll() is None:
            self.dialog = "stop"
            return True
        if self.tab == 0:
            if key in (curses.KEY_DOWN, ord("j")) and self.issues:
                self.cursor = min(len(self.issues) - 1, self.cursor + 1)
            elif key in (curses.KEY_UP, ord("k")) and self.issues:
                self.cursor = max(0, self.cursor - 1)
            elif key == ord(" ") and self.issues:
                number = int(self.issues[self.cursor]["number"])
                if number in self.selected:
                    self.selected.remove(number)
                else:
                    self.selected.add(number)
            elif key in (10, 13, curses.KEY_ENTER) and self.issues:
                self.dialog = "detail"
        elif self.tab == 1:
            if key in (curses.KEY_DOWN, ord("j")):
                self.setup_cursor = min(6, self.setup_cursor + 1)
            elif key in (curses.KEY_UP, ord("k")):
                self.setup_cursor = max(0, self.setup_cursor - 1)
            elif key in (curses.KEY_RIGHT,):
                self.cycle_field(1)
            elif key in (curses.KEY_LEFT,):
                self.cycle_field(-1)
            elif key in (10, 13, curses.KEY_ENTER, ord("e")):
                self.edit_field(screen)
        elif self.tab == 2:
            if key in (curses.KEY_UP, ord("k")):
                self.log_scroll = min(max(0, len(self.logs) - 1), self.log_scroll + 1)
            elif key in (curses.KEY_DOWN, ord("j")):
                self.log_scroll = max(0, self.log_scroll - 1)
        return True

    def run(self, screen: curses.window) -> None:
        self.init_colors()
        curses.curs_set(0)
        screen.keypad(True)
        screen.timeout(100)
        if not self.demo:
            self.refresh_preview(screen)
        try:
            while True:
                self.drain_events()
                self.draw(screen)
                screen.refresh()
                if not self.handle_key(screen, screen.getch()):
                    break
        finally:
            if self.process is not None and self.process.poll() is None:
                self.stop_run()
                try:
                    self.process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    self.process.terminate()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="FixBuddy terminal interface")
    parser.add_argument("--repo", help="GitHub repository (owner/name)")
    parser.add_argument("--project", help="local target checkout")
    parser.add_argument("--demo", action="store_true", help="read-only visual demo without GitHub calls")
    args = parser.parse_args(argv)
    script = Path(__file__).with_name("fixbuddy.sh")
    if not script.is_file():
        parser.error(f"fixbuddy.sh must be next to this file: {script}")
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error("the terminal UI requires an interactive terminal")
    app = TerminalApp(script, default_settings(args), demo=args.demo)
    try:
        curses.wrapper(app.run)
    except KeyboardInterrupt:
        app.stop_run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
