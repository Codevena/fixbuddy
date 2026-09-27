"""Buddy-family presentation tests; synthetic events, no external calls."""
import contextlib
import io
import json
import re
import subprocess
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from test_tui import tui


class Screen:
    def __init__(self, height, width):
        self.height, self.width, self.writes = height, width, []

    def getmaxyx(self):
        return self.height, self.width

    def erase(self):
        self.writes.clear()

    def addstr(self, y, x, text, style=0):
        if not (0 <= y < self.height and 0 <= x and x + tui.display_width(text) <= self.width):
            raise AssertionError('Drawing outside terminal bounds')
        if any(char in text for char in ('\n', '\r', '\t', '\x1b', '\u202e')):
            raise AssertionError('Terminal control in rendered text')
        self.writes.append((y, x, text, style))

    def refresh(self):
        pass

    def content(self):
        return '\n'.join(text for _, _, text, _ in self.writes)


class BuddyUITests(unittest.TestCase):
    def setUp(self):
        self.app = tui.TerminalApp(Path('/synthetic/fixbuddy'), tui.Settings(repo='example/demo'))
        self.now = 100.0
        self.app.clock = lambda: self.now
        self.app.catalog = [tui.RepoRecord('example/demo', True, False, True, status='ok', issues=[
            tui.IssueRecord('example/demo', 7, 'Synthetic issue', [], body='Synthetic description')])]
        self.app.rebuild_issue_list()

    def test_activity_panel_and_keyboard_tabs_fit_all_views(self):
        self.app.events.put(('line', 'Synthetic event completed.'))
        self.app.drain_events()
        for width, height in ((40, 12), (76, 30), (120, 30)):
            for tab in range(4):
                with self.subTest(width=width, tab=tab):
                    self.app.tab = tab
                    screen = Screen(height, width)
                    self.app.draw(screen)
                    self.assertIn('ACTIVITY', screen.content())
                    self.assertIn(f'[{tab + 1}]', screen.content())
                    self.assertRegex(screen.content(), r'\d{2}:\d{2}:\d{2}')

    def test_busy_face_sweep_and_phrase_advance_on_fake_clock(self):
        self.app.process = Mock()
        self.app.run_started = 100.0
        screen = Screen(30, 120)
        self.app.draw(screen)
        before = screen.content()
        self.assertIn('FIX BUDDY IS ON IT', before)
        self.assertIn('00:00', before)
        self.now += 8.3
        self.app.draw(screen)
        self.assertIn('00:08', screen.content())
        self.assertNotEqual(before, screen.content())
        self.assertNotIn('%', screen.content())
        self.app.draw(Screen(12, 40))

    def test_successful_process_exit_is_not_claimed_as_a_merge(self):
        self.app.process = Mock()
        self.app.events.put(('exit', 0))
        self.app.drain_events()
        screen = Screen(30, 120)
        self.app.draw(screen)
        self.assertIn('RUN FINISHED', screen.content())
        self.assertIn('Review the summary', screen.content())
        self.assertNotIn('FIX APPLIED', screen.content())
        self.assertNotIn('😱', screen.content())
        self.now += 5
        self.app.draw(screen)
        self.assertNotIn('RUN FINISHED', screen.content())

    def test_stopped_process_gets_warning_effect_without_focus_change(self):
        self.app.process = Mock()
        self.app.tab = 2
        self.app.events.put(('exit', 1))
        self.app.drain_events()
        screen = Screen(12, 40)
        self.app.draw(screen)
        self.assertIn('RUN STOPPED', screen.content())
        self.assertIn('😱', screen.content())
        self.assertEqual(self.app.tab, 2)

    def test_raw_log_text_does_not_trigger_an_outcome_effect(self):
        self.app.events.put(('line', 'RUN FINISHED · merged · DONE-APPROVED'))
        self.app.drain_events()
        self.assertFalse(getattr(self.app, 'outcome_effect', None))

    def test_history_wraps_long_lines_and_can_return_to_latest(self):
        self.app.tab = 3
        self.app.events.put(('line', 'Synthetic long event: ' + 'word ' * 30 + 'END-MARKER'))
        self.app.drain_events()
        screen = Screen(30, 76)
        self.app.draw(screen)
        self.assertIn('END-MARKER', screen.content())
        self.app.handle_key(screen, tui.curses.KEY_HOME)
        self.assertGreater(self.app.log_scroll, 0)
        self.app.handle_key(screen, tui.curses.KEY_END)
        self.assertEqual(self.app.log_scroll, 0)

    def test_activity_redacts_before_truncating_and_is_bounded(self):
        key = 'sk-' + 'synthetic' * 5
        self.app.events.put(('line', 'x' * 394 + ' ' + key))
        self.app.drain_events()
        self.assertNotIn(key[:5], repr(self.app.logs))
        for index in range(1501):
            self.app.events.put(('line', f'Synthetic {index}'))
        self.app.drain_events()
        self.assertEqual(len(self.app.logs), 1500)
        self.assertTrue(self.app.logs[-1].endswith('Synthetic 1500'))

    def test_confirm_dialog_retains_merge_and_run_details_with_activity(self):
        self.app.settings.project = '/synthetic/project'
        self.app.actionable_count = 1
        self.app.dialog = 'confirm'
        screen = Screen(30, 120)
        self.app.draw(screen)
        self.assertIn('START PIPELINE?', screen.content())
        self.assertIn('PR stays open for you', screen.content())
        self.assertIn('Press y to start', screen.content())

    def test_narrow_confirmation_keeps_explicit_merge_choice_and_cancel(self):
        self.app.settings.auto_merge = True
        self.app.actionable_count = 1
        self.app.dialog = 'confirm'
        screen = Screen(12, 40)
        self.app.draw(screen)
        self.assertIn('AUTO-MERGE REQUESTED', screen.content())
        self.assertIn('cancel', screen.content())

    def test_catalog_loading_has_real_elapsed_animation(self):
        self.app.catalog_loading = True
        self.app.catalog_started = 100.0
        self.now += 7
        screen = Screen(30, 76)
        self.app.draw(screen)
        self.assertIn('00:07', screen.content())
        self.assertIn('Loading GitHub inventory', screen.content())

    def test_history_retains_unbroken_words_and_pages_without_changing_tabs(self):
        self.app.tab = 3
        message = 'a' * 120 + 'TAILMARKER'
        self.app.events.put(('line', message))
        self.app.drain_events()
        screen = Screen(30, 76)
        self.app.draw(screen)
        self.assertTrue(''.join(self.app.history_lines(68)).endswith(message))
        self.app.handle_key(screen, tui.curses.KEY_PPAGE)
        self.assertGreater(self.app.log_scroll, 0)
        self.app.handle_key(screen, tui.curses.KEY_NPAGE)
        self.assertEqual(self.app.log_scroll, 0)
        self.assertEqual(self.app.tab, 3)

    def test_activity_withholds_credentials_hidden_by_controls_and_oversized_input(self):
        marker = 'sk-' + 'synthetic' * 5
        for value in (marker[:5] + '\u202e' + marker[5:], 'x' * 17000 + marker,
                      'Authorization: Bearer synthetic-private-value'):
            self.app.events.put(('line', value))
        self.app.drain_events()
        self.assertNotIn('synthetic', repr(self.app.logs))
        self.assertTrue(all(len(line) <= 410 for line in self.app.logs))

    def test_catalog_start_error_redacts_before_error_length_limit(self):
        marker = 'sk-' + 'synthetic' * 5
        message = 'x' * 175 + ' ' + marker
        with patch.object(tui.subprocess, 'Popen', side_effect=OSError(message)):
            self.app.start_catalog()
        self.assertFalse(self.app.catalog_loading)
        self.assertNotIn('sk-', repr((self.app.logs, self.app.notice, self.app.catalog_error)))
        self.assertIn('possible credential', self.app.catalog_error)

    def test_preview_exception_and_nonzero_exit_redact_original_error(self):
        self.app.settings.project = '/synthetic/project'
        marker = 'sk-' + 'synthetic' * 5
        message = 'x' * 195 + ' ' + marker
        for result in (RuntimeError(message), subprocess.CompletedProcess([], 1, '', message)):
            with self.subTest(error_type=type(result).__name__), patch.object(self.app, 'draw'), \
                    patch.object(tui.subprocess, 'run', side_effect=(
                        result if isinstance(result, Exception) else lambda *args, **kwargs: result)):
                self.assertFalse(self.app.refresh_run_preview(Mock()))
            self.assertNotIn('sk-', repr((self.app.logs, self.app.notice)))
            self.assertIn('possible credential', self.app.notice)

    def test_github_error_is_redacted_before_projected_exception(self):
        marker = 'sk-' + 'synthetic' * 5
        message = 'x' * 235 + ' ' + marker
        with patch.object(tui.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', message)), \
                self.assertRaises(RuntimeError) as raised:
            tui.github_api('user/repos?per_page=100')
        self.assertNotIn('sk-', str(raised.exception))
        self.assertIn('possible credential', str(raised.exception))

    def test_issue_catalog_error_is_redacted_before_repository_projection(self):
        marker = 'sk-' + 'synthetic' * 5
        def api(endpoint):
            if endpoint.startswith('user/repos'):
                return json.dumps([[{'full_name': 'example/demo', 'private': True, 'has_issues': True}]])
            raise RuntimeError('x' * 155 + ' ' + marker)
        repo = tui.load_catalog(api=api, max_workers=1)[0]
        self.assertEqual(repo.status, 'error')
        self.assertNotIn('sk-', repo.error)
        self.assertIn('possible credential', repo.error)

    def test_catalog_worker_and_reader_redact_before_error_projection(self):
        marker = 'sk-' + 'synthetic' * 5
        message = 'x' * 195 + ' ' + marker
        output = io.StringIO()
        with patch.object(tui, 'load_catalog', side_effect=RuntimeError(message)), \
                contextlib.redirect_stdout(output):
            self.assertEqual(tui.catalog_worker_main(), 1)
        self.assertNotIn('sk-', output.getvalue())
        self.assertIn('possible credential', output.getvalue())
        process = Mock(stdout=io.StringIO(''), stderr=io.StringIO(message))
        process.wait.return_value = 1
        self.app.catalog_loading = True
        self.app._catalog_reader(process)
        self.app.drain_events()
        self.assertNotIn('sk-', repr((self.app.logs, self.app.notice, self.app.catalog_error)))
        self.assertIn('possible credential', self.app.catalog_error)

    def test_body_does_not_draw_below_reserved_activity_top(self):
        self.app.setup_cursor = 6
        for tab in range(4):
            self.app.tab = tab
            screen = Screen(12, 40)
            self.app.draw(screen)
            activity = next(index for index, (_, _, text, _) in enumerate(screen.writes) if 'ACTIVITY' in text)
            top = screen.writes[activity][0]
            # The two writes immediately before the title are the activity frame.
            body = screen.writes[:activity]
            forbidden = ('RUNNING', 'READY', 'Auto-merge', 'human merge', 'No description')
            self.assertFalse(any(y >= top and any(word in text for word in forbidden)
                                 for y, _, text, _ in body))


if __name__ == '__main__':
    unittest.main()
