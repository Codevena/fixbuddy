#!/usr/bin/env python3
"""Optional Pillow visual QA of actual draw calls, using synthetic data only."""
import argparse
import curses
import importlib.util
from pathlib import Path
import sys
from unittest.mock import patch

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('fixbuddy_tui_preview', ROOT / 'src' / 'tui.py')
tui = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = tui
SPEC.loader.exec_module(tui)


class Screen:
    def __init__(self, height, width):
        self.height, self.width, self.writes = height, width, []

    def getmaxyx(self):
        return self.height, self.width

    def erase(self):
        self.writes.clear()

    def addstr(self, y, x, text, style=0):
        if not (0 <= y < self.height and 0 <= x and x + tui.display_width(text) <= self.width):
            raise AssertionError('Rendering outside terminal bounds')
        self.writes.append((y, x, text, style))


def xterm(index):
    if index == -1:
        return '#101018'
    if index >= 232:
        value = 8 + 10 * (index - 232)
        return value, value, value
    if index >= 16:
        index -= 16
        cube = [0, 95, 135, 175, 215, 255]
        return cube[index // 36], cube[(index // 6) % 6], cube[index % 6]
    return '#eeeeee'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--view', choices=('repos', 'issues', 'setup', 'run'), default='run')
    parser.add_argument('--busy', action='store_true')
    parser.add_argument('--details', action='store_true')
    parser.add_argument('--outcome', choices=('finished', 'stopped'))
    parser.add_argument('--output', type=Path, default=ROOT / 'docs' / 'screenshots')
    args = parser.parse_args()
    app = tui.TerminalApp(Path('/synthetic/fixbuddy'), tui.Settings(
        repo='example/python-demo', project='~/code/python-demo'), clock=lambda: 112.4,
        wall_clock=lambda: 43200)
    app.catalog = [tui.RepoRecord('example/python-demo', True, False, True, status='ok', issues=[
        tui.IssueRecord('example/python-demo', 7, 'Handle empty configuration gracefully', [],
                        body='Synthetic issue for the offline interface preview.')]),
        tui.RepoRecord('example/typescript-demo', False, False, True, status='ok')]
    app.rebuild_issue_list()
    app.tab = ('repos', 'issues', 'setup', 'run').index(args.view)
    app.run_details = args.details
    app.phrase_offset = 0
    app.notice = 'Synthetic preview · inventory ready · g checks and confirms a run'
    app.append_activity('2 repositories · 1 open issue · read-only inventory ready')
    app.append_activity('Selected issue #7 · human merge · no external action in this preview')
    if args.busy:
        app.process = object()
        app.run_started = 100
        app.run_info = {'repo': app.settings.repo, 'numbers': [7],
                        'fix_agent': app.settings.fix_agent, 'review_agent': app.settings.review_agent,
                        'auto_merge': app.settings.auto_merge}
        app.notice = 'Pipeline running · x to interrupt safely'
        app.append_activity('Synthetic pipeline progress · review in progress')
    if args.outcome:
        app.process = object()
        app.events.put(('exit', 0 if args.outcome == 'finished' else 1))
        app.drain_events()
        app.clock = lambda: 113.1
    pairs = {}
    with patch.object(curses, 'COLORS', 256, create=True), patch.object(curses, 'start_color'), \
            patch.object(curses, 'use_default_colors'), patch.object(curses, 'init_pair',
            side_effect=lambda n, fg, bg: pairs.setdefault(n, (fg, bg))), \
            patch.object(curses, 'color_pair', side_effect=lambda n: n):
        app.init_colors()
    font_path = next((path for path in (Path('/System/Library/Fonts/Menlo.ttc'),
        Path('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf')) if path.is_file()), None)
    if font_path is None:
        raise SystemExit('Install a monospace font for visual QA')
    font = ImageFont.truetype(str(font_path), 18)
    emoji_path = Path('/System/Library/Fonts/Apple Color Emoji.ttc')
    emoji_font = ImageFont.truetype(str(emoji_path), 20) if emoji_path.is_file() else font
    cell_w, cell_h = 11, 24
    args.output.mkdir(parents=True, exist_ok=True)
    for width, height in ((40, 12), (76, 30), (120, 30)):
        screen = Screen(height, width)
        app.draw(screen)
        result = Image.new('RGB', (width * cell_w, height * cell_h), '#101018')
        draw = ImageDraw.Draw(result)
        for y, x, text, style in screen.writes:
            foreground, background = pairs.get(style & 0xffff, (255, -1))
            offset = 0
            for char in text:
                cells = tui.display_width(char)
                if not cells:
                    continue
                left, top = (x + offset) * cell_w, y * cell_h
                draw.rectangle((left, top, left + cell_w * cells - 1, top + cell_h - 1), fill=xterm(background))
                draw.text((left, top), char, font=emoji_font if char == '😱' else font,
                          fill=xterm(foreground), embedded_color=char == '😱' and emoji_path.is_file())
                offset += cells
        state = ('details-' if args.details else '') + (args.outcome or ('busy' if args.busy else args.view))
        destination = args.output / f'tui-{state}-{width}.png'
        result.save(destination)
        print(destination)


if __name__ == '__main__':
    main()
