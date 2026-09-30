#!/usr/bin/env python3
"""FixBuddy's embedded terminal UI. Python 3 standard library only.

The UI previews and launches fixbuddy; the Bash pipeline remains the only
component that edits a checkout or calls GitHub write APIs.
"""

from __future__ import annotations

import argparse
import curses
import json
import os
import queue
import random
import re
import signal
import subprocess
import sys
import threading
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable


CSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
SEVERITIES = ("all", "critical", "high", "medium", "low")
AGENTS = ("claude", "codex", "opencode", "agy")
TABS = ("REPOS", "ISSUES", "SETUP", "RUN")
WORDMARK = "FIX BUDDY"
BUDDY_PHRASES = (
    "Putting on my tiny debugging hat.",
    "Checking behind the semicolons.",
    "Fetching coffee for the neurons.",
    "One careful step at a time.",
    "Thinking hard. Looking adorable.",
    "Asking the bugs to form an orderly queue.",
)
ACTIVITY_SECRETS = re.compile(
    r"-----BEGIN (?:[A-Z ]*PRIVATE KEY|PGP PRIVATE KEY BLOCK)-----"
    r"|\b(?:gh[pousr]_|github_pat_|sk-(?:or-v1-)?)[A-Za-z0-9_-]{4,}"
    r"|\bAKIA[A-Z0-9]{16}\b"
    r"|\b(?:api[_-]?key|api[_-]?token|access[_-]?token|secret|password|"
    r"aws_secret_access_key|private_key|authorization)\s*[=:]\s*\S+",
    re.IGNORECASE,
)
PIXEL_GLYPHS = {
    "F": ("█████", "██   ", "████ ", "██   ", "██   "),
    "I": ("█████", "  █  ", "  █  ", "  █  ", "█████"),
    "X": ("██ ██", " ███ ", "  █  ", " ███ ", "██ ██"),
    "B": ("████ ", "██ ██", "████ ", "██ ██", "████ "),
    "U": ("██ ██", "██ ██", "██ ██", "██ ██", "█████"),
    "D": ("████ ", "██ ██", "██ ██", "██ ██", "████ "),
    "Y": ("██ ██", "██ ██", " ███ ", "  █  ", "  █  "),
}
REPO_NAME = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")


@dataclass
class IssueRecord:
    repo: str
    number: int
    title: str
    labels: list[dict[str, str]]
    url: str = ""
    body: str = ""


@dataclass
class RepoRecord:
    full_name: str
    private: bool
    archived: bool
    has_issues: bool
    status: str = "loading"  # loading, ok, disabled, error
    issues: list[IssueRecord] = field(default_factory=list)
    error: str = ""


def _flatten_pages(raw: str) -> list[dict[str, Any]]:
    pages = json.loads(raw)
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise ValueError("GitHub returned an invalid paginated response")
    return [item for page in pages for item in page if isinstance(item, dict)]


def parse_repository_pages(raw: str) -> list[RepoRecord]:
    repos: list[RepoRecord] = []
    seen: set[str] = set()
    for item in _flatten_pages(raw):
        name = item.get("full_name")
        if not isinstance(name, str) or not REPO_NAME.fullmatch(name):
            continue
        key = name.casefold()
        if key in seen:
            continue
        seen.add(key)
        repos.append(RepoRecord(name, bool(item.get("private")),
                                bool(item.get("archived")), bool(item.get("has_issues", True))))
    return repos


def parse_issue_pages(repo: str, raw: str) -> list[IssueRecord]:
    issues: list[IssueRecord] = []
    for item in _flatten_pages(raw):
        number = item.get("number")
        if item.get("pull_request") is not None or str(item.get("state", "")).lower() != "open":
            continue
        if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
            continue
        raw_labels = item.get("labels") or []
        labels = [{"name": entry["name"]} for entry in raw_labels
                  if isinstance(entry, dict) and isinstance(entry.get("name"), str)]
        issues.append(IssueRecord(
            repo=repo, number=number, title=str(item.get("title") or ""),
            labels=labels, url=str(item.get("html_url") or ""),
            body=str(item.get("body") or ""),
        ))
    return issues


def catalog_totals(repos: list[RepoRecord]) -> tuple[int, int, int]:
    return len(repos), sum(len(repo.issues) for repo in repos if repo.status == "ok"), \
        sum(repo.status == "error" for repo in repos)


def github_api(endpoint: str) -> str:
    result = subprocess.run(["gh", "api", "--paginate", "--slurp", endpoint],
                            capture_output=True, text=True, timeout=30, check=False)
    if result.returncode != 0:
        raise RuntimeError(activity_message(result.stderr.strip() or "GitHub API request failed")[:240])
    return result.stdout


def load_catalog(
    api: Callable[[str], str] = github_api,
    on_progress: Callable[[str, Any], None] | None = None,
    max_workers: int = 6,
) -> list[RepoRecord]:
    """Read every accessible repo, with bounded concurrent issue requests."""
    repos = parse_repository_pages(api("user/repos?per_page=100"))
    if on_progress:
        on_progress("repos", repos)
    with ThreadPoolExecutor(max_workers=max(1, min(max_workers, 8))) as pool:
        futures = {}
        for repo in repos:
            if not repo.has_issues:
                repo.status = "disabled"
                if on_progress:
                    on_progress("repo", repo)
                continue
            endpoint = f"repos/{repo.full_name}/issues?state=open&per_page=100"
            futures[pool.submit(api, endpoint)] = repo
        for future in as_completed(futures):
            repo = futures[future]
            try:
                repo.issues = parse_issue_pages(repo.full_name, future.result())
                repo.status = "ok"
            except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
                repo.status = "error"
                repo.error = activity_message(str(error))[:160]
            if on_progress:
                on_progress("repo", repo)
    return repos


def catalog_worker_main() -> int:
    """Stream read-only GitHub inventory updates to the parent TUI."""
    def report(kind: str, value: Any) -> None:
        data = [asdict(repo) for repo in value] if kind == "repos" else asdict(value)
        print(json.dumps({"type": kind, "data": data}, ensure_ascii=False), flush=True)
    try:
        load_catalog(on_progress=report)
        print(json.dumps({"type": "done"}), flush=True)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"type": "error", "message": activity_message(str(error))[:200]}), flush=True)
        return 1


def repo_from_event(data: dict[str, Any]) -> RepoRecord:
    issues = [IssueRecord(**issue) for issue in data.get("issues", [])]
    return RepoRecord(data["full_name"], bool(data["private"]), bool(data["archived"]),
                      bool(data["has_issues"]), data["status"], issues,
                      activity_message(data.get("error") or ""))


def clean_display(value: str) -> str:
    """Remove terminal controls and bidi formatting from untrusted text."""
    value = OSC.sub("", CSI.sub("", str(value))).replace("\x1b", "")
    return "".join(
        " " if char in "\r\n\t" else char
        for char in value
        if char in "\r\n\t" or unicodedata.category(char) not in {"Cc", "Cf", "Cs"}
    )


def activity_message(value: str) -> str:
    """Withhold recognizable credentials before truncating session-only text."""
    value = str(value)
    if len(value) > 16384:
        return "Activity message withheld: input too large."
    if ACTIVITY_SECRETS.search(value):
        return "Activity message withheld: possible credential."
    value = clean_display(value)
    if ACTIVITY_SECRETS.search(value):
        return "Activity message withheld: possible credential."
    return " ".join(value.split())[:400]


def wrap_activity(entries: list[str], width: int) -> list[str]:
    """Wrap whole history, including unbroken tokens, without losing characters."""
    width = max(1, width)
    lines = []
    for entry in entries:
        line, used = "", 0
        for char in entry:
            cells = display_width(char)
            if used + cells > width and line:
                lines.append(line)
                line, used = "", 0
            line += char
            used += cells
        lines.append(line)
    return lines


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
    for number in dict.fromkeys(selected):
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
    def __init__(self, script: Path, settings: Settings, *, clock=None, wall_clock=None):
        self.script = script
        self.settings = settings
        self.self_path = Path(os.environ.get("FIXBUDDY_SELF") or __file__).resolve()
        self.catalog: list[RepoRecord] = []
        self.repo_cursor = 0
        self.issue_filter_repo: str | None = None
        self.catalog_generation = 0
        self.catalog_loading = False
        self.catalog_error: str | None = None
        self.issues: list[dict[str, Any]] = []
        self.selected: set[int] = set()
        self.preview_key: tuple[Any, ...] | None = None
        self.actionable_numbers: set[int] = set()
        self.actionable_order: list[int] = []
        self.actionable_count = 0
        self.cursor = 0
        self.setup_cursor = 0
        self.tab = 0
        self.dialog = ""
        self.notice = "Loading read-only GitHub inventory…"
        self.logs: list[str] = []
        self.log_scroll = 0
        self.process: subprocess.Popen[str] | None = None
        self.run_exit: int | None = None
        self.events: queue.Queue[tuple[str, Any]] = queue.Queue()
        self.catalog_process: subprocess.Popen[str] | None = None
        self.colors: dict[str, int] = {}
        self.clock = clock or time.monotonic
        self.wall_clock = wall_clock or time.time
        self.run_started = None
        self.catalog_started = None
        self.outcome_effect = None
        self.phrase_offset = random.randrange(len(BUDDY_PHRASES))
        self.content_bottom = None
        self._log_revision = 0
        self._history_cache = (None, [])

    def append_activity(self, message: str) -> None:
        stamp = time.strftime('%H:%M:%S', time.localtime(self.wall_clock()))
        self.logs.append(f'{stamp}  {activity_message(message)}')
        self.logs = self.logs[-1500:]
        self._log_revision += 1

    def history_lines(self, width: int) -> list[str]:
        key = (width, self._log_revision, len(self.logs))
        if self._history_cache[0] != key:
            self._history_cache = (key, wrap_activity(self.logs, width))
        return self._history_cache[1]

    def busy_status(self):
        if self.process is not None and self.run_exit is None:
            return 'Pipeline running', self.run_started
        if self.catalog_loading:
            return 'Loading GitHub inventory', self.catalog_started
        return None

    def current_outcome(self):
        effect = self.outcome_effect
        if effect and 0 <= self.clock() - effect['started'] < 4.5:
            return effect
        return None

    def rebuild_issue_list(self) -> None:
        records = [issue for repo in self.catalog if repo.status == "ok"
                   and (self.issue_filter_repo is None or repo.full_name == self.issue_filter_repo)
                   for issue in repo.issues]
        records.sort(key=lambda issue: (issue.repo.casefold(), -issue.number))
        self.issues = [vars(issue).copy() for issue in records]
        self.cursor = min(self.cursor, max(0, len(self.issues) - 1))

    def select_repo(self, full_name: str) -> None:
        if not any(repo.full_name == full_name for repo in self.catalog):
            self.notice = "Repository is not in the current GitHub inventory"
            return
        if self.settings.repo != full_name:
            self.settings.project = ""  # never carry a checkout to another repo
        self.settings.repo = full_name
        self.issue_filter_repo = full_name
        self.selected.clear()
        self.preview_key = None
        self.actionable_order = []
        self.cursor = 0
        self.tab = 1
        self.rebuild_issue_list()
        self.notice = f"{full_name} selected · set its local checkout in SETUP before running"

    def toggle_issue(self, issue: dict[str, Any]) -> None:
        repo_name = str(issue["repo"])
        number = int(issue["number"])
        if self.settings.repo != repo_name:
            self.settings.repo = repo_name
            self.settings.project = ""
            self.selected.clear()
        self.preview_key = None
        self.actionable_order = []
        if number in self.selected:
            self.selected.remove(number)
        else:
            self.selected.add(number)
        self.notice = f"{repo_name} selected · {len(self.selected)} issue(s) selected for this repo"

    def start_catalog(self) -> None:
        if self.catalog_loading:
            return
        self.catalog_generation += 1
        self.catalog_loading = True
        self.catalog_started = self.clock()
        self.outcome_effect = None
        self.catalog_error = None
        self.catalog = []
        self.repo_cursor = 0
        self.issue_filter_repo = None
        self.issues = []
        self.selected.clear()
        self.preview_key = None
        self.actionable_order = []
        self.notice = "Loading GitHub repositories and open issues…"
        self.append_activity(self.notice)
        try:
            self.catalog_process = subprocess.Popen(
                [str(self.self_path), "--catalog-worker"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                bufsize=1, start_new_session=True,
            )
        except OSError as error:
            self.catalog_loading = False
            self.catalog_error = activity_message(str(error))[:180]
            self.notice = f"GitHub inventory failed: {self.catalog_error}"
            self.append_activity(self.notice)
            return
        threading.Thread(target=self._catalog_reader,
                         args=(self.catalog_process,), daemon=True).start()

    def _catalog_reader(self, process: subprocess.Popen[str]) -> None:
        assert process.stdout is not None
        for line in process.stdout:
            try:
                self.events.put(("catalog", json.loads(line)))
            except ValueError:
                self.events.put(("catalog", {"type": "error", "message": "Invalid inventory response"}))
        stderr = process.stderr.read() if process.stderr is not None else ""
        self.events.put(("catalog_exit", (process.wait(), activity_message(stderr)[:200])))

    def invalidate_preview(self) -> None:
        self.selected.clear()
        self.preview_key = None
        self.actionable_numbers.clear()
        self.actionable_order.clear()
        self.actionable_count = 0

    def init_colors(self) -> None:
        curses.start_color()
        curses.use_default_colors()
        if curses.COLORS >= 256:
            colors = {
                "text": (255, -1), "muted": (103, -1), "violet": (141, -1),
                "pink": (205, -1), "magenta": (171, -1), "green": (48, -1), "amber": (215, -1),
                "red": (203, -1), "line": (61, -1), "header": (255, 54),
                "badge": (255, 205), "select": (255, 60), "footer": (255, 235),
            }
        else:
            colors = {
                "text": (curses.COLOR_WHITE, -1), "muted": (curses.COLOR_CYAN, -1),
                "violet": (curses.COLOR_MAGENTA, -1), "pink": (curses.COLOR_MAGENTA, -1),
                "magenta": (curses.COLOR_MAGENTA, -1),
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

    def put(self, screen: curses.window, y: int, x: int, text: str, style: str = "text", bold: bool = False,
            width=None) -> None:
        height, columns = screen.getmaxyx()
        if (y < 0 or y >= height or x < 0 or x >= columns or
                (self.content_bottom is not None and y >= self.content_bottom)):
            return
        text = clip_cells(text, columns - x if width is None else min(width, columns - x))
        if not text:
            return
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
        self.put(screen, y, x + 2, f" {title} ", "pink", True, width - 4)

    def refresh_run_preview(self, screen: curses.window) -> bool:
        identity = (settings_key(self.settings), self.catalog_generation)
        if self.preview_key is not None and self.preview_key != identity:
            self.invalidate_preview()
            self.notice = "Repository or settings changed · selection cleared; press g again"
            return False
        self.preview_key = None
        self.actionable_numbers.clear()
        self.actionable_order.clear()
        self.actionable_count = 0
        if not self.settings.repo or not self.settings.project:
            self.tab = 2
            self.notice = "Select a repository and set its local checkout in SETUP"
            return False
        repo = next((item for item in self.catalog if item.full_name == self.settings.repo), None)
        if repo is None or repo.status != "ok":
            self.notice = "The selected repository has no complete issue snapshot"
            return False
        self.notice = "Checking the selected repository without writes…"
        self.append_activity(self.notice)
        self.draw(screen)
        screen.refresh()
        try:
            result = subprocess.run(
                build_preview_command(self.script, self.settings),
                capture_output=True, text=True, timeout=45, check=False,
            )
            if result.returncode != 0:
                raise RuntimeError(activity_message(result.stderr.strip() or result.stdout.strip())[:240])
            data = json.loads(result.stdout)
            if data.get("repo") != self.settings.repo or data.get("project") != self.settings.project:
                raise RuntimeError("preview settings did not match the requested repository/checkout")
            order = [int(issue["number"]) for issue in data.get("issues", [])]
            numbers = set(order)
            if not order or len(numbers) != len(order):
                raise RuntimeError("no actionable issues in the selected repository")
            if self.selected and not self.selected <= numbers:
                raise RuntimeError("selected issue is no longer actionable")
            self.actionable_numbers = numbers
            self.actionable_order = order
            self.actionable_count = len(numbers)
            self.preview_key = identity
            self.notice = f"{len(numbers)} actionable issue(s) · read-only check passed"
            self.append_activity(self.notice)
            return True
        except (OSError, ValueError, subprocess.TimeoutExpired, RuntimeError) as error:
            self.invalidate_preview()
            self.notice = f"Preview failed: {activity_message(str(error))[:200]}"
            self.append_activity(self.notice)
            return False

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
            if kind == "catalog":
                event_type = value.get("type")
                if event_type == "repos":
                    self.catalog = [repo_from_event(item) for item in value.get("data", [])]
                elif event_type == "repo":
                    updated = repo_from_event(value["data"])
                    for index, existing in enumerate(self.catalog):
                        if existing.full_name == updated.full_name:
                            self.catalog[index] = updated
                            break
                    self.rebuild_issue_list()
                elif event_type == "done":
                    self.catalog_loading = False
                    self.catalog_error = None
                    self.catalog.sort(key=lambda repo: (repo.status == "error", -len(repo.issues), repo.full_name.casefold()))
                    total_repos, total_issues, errors = catalog_totals(self.catalog)
                    self.notice = f"{total_repos} repos · {total_issues} open issues" + \
                        (f" · {errors} unknown" if errors else "")
                    self.append_activity(self.notice)
                elif event_type == "error":
                    self.catalog_loading = False
                    self.catalog_error = activity_message(value.get("message", "unknown error"))
                    self.notice = f"GitHub inventory failed: {self.catalog_error}"
                    self.append_activity(self.notice)
            elif kind == "catalog_exit":
                rc, error = value
                if rc != 0 and self.catalog_loading:
                    self.catalog_loading = False
                    self.catalog_error = activity_message(error or "unknown error")
                    self.notice = f"GitHub inventory stopped: {self.catalog_error}"
                    self.append_activity(self.notice)
            elif kind == "line":
                self.append_activity(value)
            elif kind == "exit" and type(value) is int and self.process is not None:
                self.run_exit = value
                self.outcome_effect = {'exit': value, 'started': self.clock()}
                result = 'Run finished' if value == 0 else 'Run stopped'
                self.notice = f"{result} · exit {self.run_exit} · review the summary in RUN"
                self.append_activity(self.notice)

    def start_run(self) -> None:
        if self.preview_key != (settings_key(self.settings), self.catalog_generation) \
           or not self.actionable_order:
            self.notice = "Settings or issue state changed · check the selected repo before running"
            return
        if not self.selected <= self.actionable_numbers:
            self.notice = "Selection is stale · refresh the queue before running"
            return
        numbers = [number for number in self.actionable_order
                   if not self.selected or number in self.selected]
        command = build_run_command(self.script, self.settings, numbers)
        try:
            self.process = subprocess.Popen(
                command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1,
            )
        except OSError as error:
            self.notice = f"Could not start: {activity_message(str(error))}"
            self.append_activity(self.notice)
            return
        self.invalidate_preview()  # a completed run changes labels/PR state
        self.run_exit = None
        self.run_started = self.clock()
        self.outcome_effect = None
        self.log_scroll = 0
        self.tab = 3
        self.notice = "Pipeline running · x to interrupt safely"
        self.append_activity(self.notice)
        threading.Thread(target=self._reader, args=(self.process,), daemon=True).start()

    def stop_run(self) -> None:
        if self.process is not None and self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
            self.notice = "Interrupt sent · waiting for FixBuddy cleanup"
            self.append_activity(self.notice)

    def draw_header(self, screen: curses.window, width: int) -> None:
        self.put(screen, 0, 0, " " * width, "header")
        self.put(screen, 0, 1, " ◈ ", "badge", True)
        self.put(screen, 0, 6, " FIX BUDDY ", "header", True)
        if width < 72:
            label = f" [{self.tab + 1}] {TABS[self.tab]} "
            self.put(screen, 0, max(20, width - len(label) - 1), label, "header", True)
            return
        x = 24
        for index, label in enumerate(TABS):
            if x + len(label) + 5 >= width - 1:
                break
            self.put(screen, 0, x, f" [{index + 1}] {label} ", "badge" if index == self.tab else "header", index == self.tab)
            x += len(label) + 7
        if width >= 105:
            repo = clean_display(self.settings.repo or "set repository")
            self.put(screen, 0, max(x + 2, width - 30), clip_cells(repo, min(27, width - x - 3)), "header")

    def draw_hero(self, screen: curses.window, width: int, height: int) -> int:
        repo_count, issue_count, error_count = catalog_totals(self.catalog)
        if self.catalog_error:
            repos, issues, unknown = "?", "?", "?"
        elif self.catalog_loading and not self.catalog:
            repos, issues, unknown = "…", "…", "…"
        else:
            repos, issues, unknown = f"{repo_count:03d}", f"{issue_count:03d}", f"{error_count:02d}"
        if height < 23:
            self.put(screen, 2, 2, f"◈ FIX BUDDY · {repos} repos · {issues} issues", "pink", True)
            return 4
        if width < 76:
            self.put(screen, 2, 3, "◈ FIX BUDDY", "pink", True)
            self.put(screen, 4, 3, f"{repos} repos · {issues} open · {unknown} unknown", "text", True)
            self.put(screen, 6, 3, "VERIFY  →  FIX  →  REVIEW  →  PR", "violet", True)
            return 9
        logo_x = 3
        glyph_index = 0
        for letter in WORDMARK:
            if letter == " ":
                logo_x += 3
                continue
            color = "violet" if glyph_index < 2 else "magenta" if glyph_index < 5 else "pink"
            for row, pixels in enumerate(PIXEL_GLYPHS[letter]):
                self.put(screen, row + 2, logo_x, pixels, color, True)
            logo_x += 6
            glyph_index += 1
        x = 56 if width < 105 else 62
        self.put(screen, 2, x, f"{repos}  REPOSITORIES", "muted", True)
        self.put(screen, 3, x, f"{issues}  OPEN ISSUES", "text", True)
        self.put(screen, 4, x, f"{unknown}   UNKNOWN", "amber" if error_count or self.catalog_error else "green", True)
        self.put(screen, 8, 3, "VERIFY  →  FIX  →  REVIEW  →  PR", "violet", True)
        if width >= 110:
            self.put(screen, 3, width - 29, "MERGE POLICY", "muted", True)
            self.put(screen, 4, width - 29,
                     "AUTO-MERGE ON" if self.settings.auto_merge else "HUMAN MERGE",
                     "amber" if self.settings.auto_merge else "green", True)
        return 10

    def draw_repos(self, screen: curses.window, width: int, height: int, top: int) -> None:
        left, right = panel_widths(width)
        panel_height = max(3, height - top - 2)
        self.frame(screen, top, 2, panel_height, left, "GITHUB REPOSITORIES")
        rows = max(0, panel_height - 2)
        if not self.catalog:
            self.put(screen, top + 2, 5,
                     "Loading repositories…" if self.catalog_loading else
                     "Inventory unavailable · press r" if self.catalog_error else "No repositories available", "muted")
            return
        start = max(0, min(self.repo_cursor - rows // 2, len(self.catalog) - rows))
        for row, repo in enumerate(self.catalog[start:start + rows]):
            index = start + row
            count = str(len(repo.issues)) if repo.status in ("ok", "disabled") else \
                "…" if repo.status == "loading" else "?"
            visibility = "◆" if repo.private else "◇"
            prefix = f" {'▸' if index == self.repo_cursor else ' '} {visibility} "
            name_width = max(1, left - 2 - display_width(prefix) - 5)
            line = pad_cells(prefix + pad_cells(repo.full_name, name_width) + f" {count:>3}",
                             max(0, left - 2))
            self.put(screen, top + 1 + row, 3, line,
                     "select" if index == self.repo_cursor else "text")
        if right:
            repo = self.catalog[self.repo_cursor]
            x = left + 5
            self.frame(screen, top, x, panel_height, right, "REPOSITORY")
            inner = max(1, right - 4)
            self.put(screen, top + 2, x + 2, clip_cells(repo.full_name, inner), "pink", True)
            self.put(screen, top + 4, x + 2,
                     "PRIVATE" if repo.private else "PUBLIC", "muted")
            count_text = f"{len(repo.issues)} open issues" if repo.status == "ok" else \
                "Issues disabled" if repo.status == "disabled" else \
                "Still loading" if repo.status == "loading" else "Issue count unknown"
            self.put(screen, top + 6, x + 2, count_text,
                     "amber" if repo.status == "error" else "green")
            if repo.status == "error":
                for offset, line in enumerate(_wrap(repo.error, inner, max(1, panel_height - 10))):
                    self.put(screen, top + 8 + offset, x + 2, line, "amber")
            elif repo.status == "ok":
                for offset, issue in enumerate(repo.issues[:max(0, panel_height - 10)]):
                    self.put(screen, top + 8 + offset, x + 2,
                             clip_cells(f"#{issue.number} {issue.title}", inner), "muted")

    def draw_queue(self, screen: curses.window, width: int, height: int, top: int) -> None:
        left, right = panel_widths(width)
        panel_height = max(3, height - top - 2)
        title = f"{self.issue_filter_repo} · OPEN ISSUES" if self.issue_filter_repo else "ALL OPEN ISSUES"
        self.frame(screen, top, 2, panel_height, left, title)
        rows = max(0, panel_height - 2)
        if not self.issues:
            self.put(screen, top + 2, 5,
                     "Loading issues…" if self.catalog_loading else
                     "Inventory unavailable · press r" if self.catalog_error else "No open issues in this view", "muted")
            return
        start = max(0, min(self.cursor - rows // 2, len(self.issues) - rows))
        for row, issue in enumerate(self.issues[start:start + rows]):
            index = start + row
            number = int(issue.get("number", 0))
            marker = "●" if issue["repo"] == self.settings.repo and number in self.selected else "○"
            severity = _severity(issue)
            repo_label = "" if self.issue_filter_repo else f"{issue['repo']}  "
            prefix = f" {'▸' if index == self.cursor else ' '} {marker} {repo_label}#{number:<5} {severity:<8} "
            title = clean_display(issue.get("title", ""))
            line = pad_cells(prefix + title, max(0, left - 2))
            self.put(screen, top + 1 + row, 3, line, "select" if index == self.cursor else "text")
        if right:
            x = left + 5
            self.frame(screen, top, x, panel_height, right, "SELECTED ISSUE")
            issue = self.issues[self.cursor]
            content_width = max(1, right - 4)
            self.put(screen, top + 2, x + 2,
                     f"{issue.get('repo')}  #{issue.get('number')}  {_severity(issue)}", "pink", True)
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
            ("Repository", self.settings.repo or "choose in REPOS"),
            ("Checkout", self.settings.project or "press Enter to set"),
            ("Severity", self.settings.severity or "all"),
            ("Batch size", str(self.settings.max_issues) if self.settings.max_issues else "all"),
            ("Fix agent", self.settings.fix_agent),
            ("Reviewer", self.settings.review_agent),
            ("Auto-merge", "ON · explicit" if self.settings.auto_merge else "OFF · human merge"),
        )
        value_x = min(width - 18, 25)
        inset = 1 if panel_height < 5 else 2
        visible = max(1, panel_height - inset - 1)
        first = max(0, min(self.setup_cursor - visible // 2, len(fields) - visible))
        for offset, (label, value) in enumerate(fields[first:first + visible]):
            index = first + offset
            y = top + inset + offset
            style = "select" if index == self.setup_cursor else "text"
            self.put(screen, y, 5, pad_cells(f" {'▸' if index == self.setup_cursor else ' '} {label}", max(1, value_x - 5)), style)
            self.put(screen, y, value_x, clip_cells(value, max(1, width - value_x - 5)),
                     "amber" if index == 6 and self.settings.auto_merge else style)
        if panel_height >= 13:
            self.put(screen, top + panel_height - 3, 5,
                     "Enter: select / edit   ← →: cycle   r: refresh GitHub", "muted")

    def draw_run(self, screen: curses.window, width: int, height: int, top: int) -> None:
        panel_height = max(3, height - top - 2)
        self.frame(screen, top, 2, panel_height, max(4, width - 4), "RUN HISTORY")
        state = "RUNNING" if self.process is not None and self.run_exit is None else (
            f"EXIT {self.run_exit}" if self.run_exit is not None else "READY")
        compact = panel_height < 6
        if not compact:
            self.put(screen, top + 1, 4, state, "amber" if state == "RUNNING" else "violet", True)
        inset = 1 if compact else 3
        visible = max(0, panel_height - inset - 1)
        lines = self.history_lines(width - 8)
        self.log_scroll = min(self.log_scroll, max(0, len(lines) - 1))
        start = max(0, len(lines) - visible - self.log_scroll)
        for index, line in enumerate(lines[start:start + visible]):
            self.put(screen, top + inset + index, 4, line, "muted", width=width - 8)
        if not self.logs:
            self.put(screen, top + inset, 4, "Select one repo and press g.", "muted", width=width - 8)

    def draw_activity(self, screen, width, top, height):
        self.frame(screen, top, 2, height, width - 4, "ACTIVITY · [4] history")
        row, remaining = top + 1, height - 2
        effect, busy = self.current_outcome(), self.busy_status()
        if effect:
            stopped = effect['exit'] != 0
            label = 'RUN STOPPED' if stopped else 'RUN FINISHED'
            color = 'amber' if stopped else 'violet'
            face = '😱 (O_O)! ' if stopped else '◈ (o.o) '
            self.put(screen, row, 4, face + label, color, True, width - 8)
            row, remaining = row + 1, remaining - 1
            if remaining > 0:
                message = 'Check the log · no automatic retry' if stopped else 'Review the summary · [4] RUN'
                self.put(screen, row, 4, message, color, width=width - 8)
                row, remaining = row + 1, remaining - 1
            if remaining > 1:
                age = self.clock() - effect['started']
                radius = min(9, int(age * 5))
                wave = ['·'] * 21
                wave[10] = '◆'
                wave[10 - radius] = wave[10 + radius] = '✦'
                self.put(screen, row, 4, ''.join(wave) + f"  exit {effect['exit']}", 'magenta', width=width - 8)
                row, remaining = row + 1, remaining - 1
        elif busy:
            phase, began = busy
            elapsed = max(0, self.clock() - began) if began is not None else 0
            stamp = f'{int(elapsed) // 60:02d}:{int(elapsed) % 60:02d}'
            spinner = '|/-\\'[int(elapsed * 8) % 4]
            face = ('(o.o)', '(o.-)', '(o.o)', '(-.o)')[int(elapsed / 2) % 4]
            title = 'FIX BUDDY IS ON IT' if width >= 76 else 'working'
            self.put(screen, row, 4, f'{spinner} {face} {title} · {stamp}', 'violet', True, width - 8)
            row, remaining = row + 1, remaining - 1
            if remaining >= 3:
                position = int(elapsed * 9) % 38
                position = position if position < 20 else 38 - position
                sweep = ''.join('●' if i == position else '━' if abs(i - position) == 1 else '·'
                                for i in range(20))
                self.put(screen, row, 4, sweep + '  ' + phase, 'magenta', width=width - 8)
                row, remaining = row + 1, remaining - 1
            if remaining >= 2:
                phrase = BUDDY_PHRASES[(self.phrase_offset + int(elapsed / 6)) % len(BUDDY_PHRASES)]
                self.put(screen, row, 4, phrase, 'pink', width=width - 8)
                row, remaining = row + 1, remaining - 1
        lines = ([self.logs[-1]] if remaining == 1 else self.history_lines(width - 8)) if self.logs else [
            'Your Buddy is ready. Events appear here.']
        for offset, line in enumerate(lines[-remaining:] if remaining > 0 else []):
            self.put(screen, row + offset, 4, line, 'muted', width=width - 8)

    def draw_footer(self, screen: curses.window, width: int, height: int) -> None:
        self.put(screen, height - 1, 0, " " * width, "footer")
        hints = "  Tab tabs   ↑↓ move   Enter choose repo   r refresh   g run   ? help   q quit"
        if self.tab == 1:
            hints = "  Tab tabs   ↑↓ issue   Space select   Enter detail   a all/repo   g run   q quit"
        if self.tab == 2:
            hints = "  Tab tabs   ↑↓ field   Enter edit   ←→ choice   g run   ? help   q quit"
        if self.tab == 3:
            hints = "  ↑↓ scroll  PgUp/PgDn page  Home oldest  End latest  x interrupt  q quit"
        if width < 76:
            hints = (" ↑↓ Enter repo · [1–4] tabs · g run · q", " Space select · Enter detail · g · q",
                     " ↑↓ Enter edit · ←→ · [1–4] · g · q", " ↑↓ PgUp/Dn Home/End · x stop · q")[self.tab]
        self.put(screen, height - 1, 0, clip_cells(hints, width), "footer")
        if height >= 3:
            self.put(screen, height - 2, 2, clip_cells(activity_message(self.notice), width - 4),
                     "red" if "failed" in self.notice.lower() else "muted")

    def draw_dialog(self, screen: curses.window, width: int, height: int) -> None:
        box_width = min(width - 4, 76)
        box_height = min(height - 2, 12)
        if box_width < 16 or box_height < 4:
            return
        x, y = (width - box_width) // 2, (height - box_height) // 2
        for row in range(y, y + box_height):
            self.put(screen, row, x, " " * box_width, "footer")
        title = {"help": "KEYBOARD", "detail": "ISSUE DETAIL", "confirm": "START PIPELINE?", "stop": "INTERRUPT RUN?"}.get(self.dialog, "CONFIRM")
        self.frame(screen, y, x, box_height, box_width, title)
        lines: list[str] = []
        if self.dialog == "help":
            lines = ["1–4 or Tab    switch tabs", "↑/↓           move through repos, issues or fields", "Enter         choose repo or inspect issue", "Space         select issues from one repo only", "a             toggle all issues / selected repo", "r             refresh the read-only GitHub inventory", "g             check selection and confirm a run", "q / Esc       close or quit"]
        elif self.dialog == "detail" and self.issues:
            issue = self.issues[self.cursor]
            lines = [f"{issue.get('repo')}  #{issue.get('number')}  {_severity(issue)}", "",
                     clean_display(issue.get("title", "")), ""]
            lines += _wrap(issue.get("body", "") or "No description", box_width - 4, box_height - 6)
        elif self.dialog == "confirm":
            count = len(self.selected) if self.selected else self.actionable_count
            if self.settings.max_issues is not None:
                count = min(count, self.settings.max_issues)
            lines = [f"Repository  {self.settings.repo}", f"Issues      {count} of {self.actionable_count} actionable",
                     f"Agents      {self.settings.fix_agent}  →  {self.settings.review_agent}",
                     f"Merge: {'AUTO-MERGE REQUESTED' if self.settings.auto_merge else 'PR stays open for you'}", "",
                     "Press y to start · n or Esc to cancel" if box_width >= 50 else "y: start · n/Esc: cancel"]
        elif self.dialog == "stop":
            lines = ["FixBuddy will receive SIGINT and clean up its local branch.", "", "Press y to interrupt · n or Esc to keep running"]
        for index, line in enumerate(lines[:box_height - 2]):
            self.put(screen, y + 1 + index, x + 2, line, "text" if index == 0 else "muted", width=box_width - 4)

    def draw(self, screen: curses.window) -> None:
        screen.erase()
        height, width = screen.getmaxyx()
        if width < 40 or height < 12:
            self.put(screen, 0, 0, "FixBuddy · enlarge terminal to 40×12", "pink", True)
            self.put(screen, 2, 0, "q quit", "muted")
            return
        self.draw_header(screen, width)
        top = self.draw_hero(screen, width, height)
        active = self.busy_status() or self.current_outcome()
        wanted = (8 if active else 5) if height >= 23 else (5 if active else 3)
        activity_height = min(wanted, max(3, height - top - 5))
        self.content_bottom = height - 2 - activity_height
        try:
            draw_content = (self.draw_repos, self.draw_queue, self.draw_setup, self.draw_run)[self.tab]
            draw_content(screen, width, height - activity_height, top)
        finally:
            self.content_bottom = None
        self.draw_activity(screen, width, height - 2 - activity_height, activity_height)
        self.draw_footer(screen, width, height)
        if self.dialog:
            self.draw_dialog(screen, width, height)

    def edit_field(self, screen: curses.window) -> None:
        names = ("Repository (owner/repo)", "Local checkout path", "Severity", "Batch size", "Fix agent", "Reviewer", "Auto-merge")
        index = self.setup_cursor
        if index == 0:
            self.tab = 0
            self.notice = "Choose a repository in REPOS with Enter"
            return
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
            if index == 1 and value:
                self.settings.project = os.path.expanduser(value)
            elif index == 3:
                self.settings.max_issues = int(value) if value.isdecimal() and int(value) > 0 else None
            self.invalidate_preview()
            self.notice = "Settings changed · press g to check before running"
        finally:
            curses.noecho()
            curses.curs_set(0)
            screen.nodelay(True)

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
        self.notice = "Settings changed · press g to check before running"

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
            self.tab = (self.tab + 1) % 4
            return True
        if key in (ord("1"), ord("2"), ord("3"), ord("4")):
            self.tab = key - ord("1")
            return True
        if key in (ord("r"), ord("R")):
            if self.process is None or self.process.poll() is not None:
                self.start_catalog()
            return True
        if key in (ord("g"), ord("G")):
            if self.process is not None and self.process.poll() is None:
                self.notice = "A run is already active"
            elif self.refresh_run_preview(screen):
                self.dialog = "confirm"
            return True
        if key in (ord("x"), ord("X")) and self.process is not None and self.process.poll() is None:
            self.dialog = "stop"
            return True
        if self.tab == 0:
            if key in (curses.KEY_DOWN, ord("j")) and self.catalog:
                self.repo_cursor = min(len(self.catalog) - 1, self.repo_cursor + 1)
            elif key in (curses.KEY_UP, ord("k")) and self.catalog:
                self.repo_cursor = max(0, self.repo_cursor - 1)
            elif key in (10, 13, curses.KEY_ENTER) and self.catalog:
                self.select_repo(self.catalog[self.repo_cursor].full_name)
        elif self.tab == 1:
            if key in (curses.KEY_DOWN, ord("j")) and self.issues:
                self.cursor = min(len(self.issues) - 1, self.cursor + 1)
            elif key in (curses.KEY_UP, ord("k")) and self.issues:
                self.cursor = max(0, self.cursor - 1)
            elif key == ord(" ") and self.issues:
                self.toggle_issue(self.issues[self.cursor])
            elif key in (10, 13, curses.KEY_ENTER) and self.issues:
                self.dialog = "detail"
            elif key in (ord("a"), ord("A")):
                self.issue_filter_repo = None if self.issue_filter_repo else self.settings.repo or None
                self.cursor = 0
                self.rebuild_issue_list()
        elif self.tab == 2:
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
        elif self.tab == 3:
            height, width = screen.getmaxyx()
            maximum = max(0, len(self.history_lines(width - 8)) - 1)
            page = max(1, height // 3)
            if key in (curses.KEY_UP, ord("k")):
                self.log_scroll = min(maximum, self.log_scroll + 1)
            elif key in (curses.KEY_DOWN, ord("j")):
                self.log_scroll = max(0, self.log_scroll - 1)
            elif key == curses.KEY_HOME:
                self.log_scroll = maximum
            elif key == curses.KEY_END:
                self.log_scroll = 0
            elif key == curses.KEY_PPAGE:
                self.log_scroll = min(maximum, self.log_scroll + page)
            elif key == curses.KEY_NPAGE:
                self.log_scroll = max(0, self.log_scroll - page)
        return True

    def run(self, screen: curses.window) -> None:
        self.init_colors()
        curses.curs_set(0)
        screen.keypad(True)
        screen.nodelay(True)
        self.start_catalog()
        try:
            while True:
                self.drain_events()
                self.draw(screen)
                screen.refresh()
                key = screen.getch()
                if key == -1:
                    time.sleep(0.03)  # yield even when a PTY returns ERR immediately
                if not self.handle_key(screen, key):
                    break
        finally:
            if self.catalog_process is not None and self.catalog_process.poll() is None:
                os.killpg(self.catalog_process.pid, signal.SIGTERM)
                try:
                    self.catalog_process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(self.catalog_process.pid, signal.SIGKILL)
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
    parser.add_argument("--catalog-worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.catalog_worker:
        return catalog_worker_main()
    script = Path(os.environ.get("FIXBUDDY_SELF") or Path(__file__).with_name("core.sh"))
    if not script.is_file():
        parser.error(f"FixBuddy core executable is unavailable: {script}")
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        parser.error("the terminal UI requires an interactive terminal")
    app = TerminalApp(script, default_settings(args))
    try:
        curses.wrapper(app.run)
    except KeyboardInterrupt:
        app.stop_run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
