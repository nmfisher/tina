#!/usr/bin/env python3
"""Verify popup restoration, settings frames and panel controls on both backends."""
import argparse
from http.server import ThreadingHTTPServer
import os
from pathlib import Path
import sys
import tempfile
import threading

sys.dont_write_bytecode = True
from smoke_engine2 import ModelStub, Terminal
from smoke_classification_panel import terminal_grid


def smoke(launcher, endpoint, backend, columns, rows):
    with tempfile.TemporaryDirectory(prefix='tina-panel-paint-') as directory:
        root = Path(directory).resolve()
        config = root / 'config'
        config.write_text(
            '[default]\nprovider="local"\nmodel="smoke"\n'
            '[providers.local]\nwire="anthropic"\n'
            f'base_url="{endpoint}"\napi_key="fixture-key"\n'
            'models=["smoke|Smoke model"]\n'
            '[plugins]\nenabled=["tina/chat-tui", "tina/panels-tui", '
            '"tina/plans", "tina/session-controls", "tina/persistence", "tina/tools"]\n')
        env = dict(os.environ, HOME=str(root), TERM='xterm-256color', LANG='en_US.UTF-8')
        command = launcher + ['--backend', backend, '--config', str(config),
                   '--cwd', str(root), '--store', str(root / 'sessions.db')]
        terminal = Terminal(command, env, columns, rows)

        def grid():
            return terminal_grid(terminal, columns, rows)

        def visible(text):
            terminal.wait_for(lambda: text in grid(), f'grid does not contain {text!r}',
                              timeout=30)

        def line(text):
            terminal.send(text)
            # Let the backend consume and flush the text burst before Enter.
            # A split-panel layout can occupy the native input pump briefly.
            terminal.wait_for(
                lambda: text in grid() or f'[Pasted text : {len(text)} chars]' in grid(),
                f'grid does not contain input {text!r}', timeout=30)
            terminal.expect_idle()
            return terminal.send('\r')

        try:
            terminal.expect('smoke > ')
            terminal.expect_idle()
            assert b'\x1b[?2004h' in terminal.output, (
                f'{backend}: raw tty mode controls did not reach the terminal')
            alerts_before = terminal.output.count(b'\x07')
            line('line scroll example')
            visible('LINE_SCROLL_ROW_119')
            terminal.expect_idle()
            assert terminal.output.count(b'\x07') == alerts_before + 1, (
                f'{backend}: a completed response must emit exactly one terminal alert')

            for repeat in [False, True]:
                requests_before = len(ModelStub.requests)
                alerts_before = terminal.output.count(b'\x07')
                start = line('failed command approval example')
                if not repeat:
                    visible('[y] allow once')
                    terminal.send('\x1b[B\x1b[B\r')
                terminal.wait_for(
                    lambda: len(ModelStub.requests) == requests_before + 2,
                    f'{backend}: failed command approval was not remembered', timeout=15)
                terminal.expect_idle()
                result = [block for message in ModelStub.requests[-1]['messages']
                          for block in message['content'] if block['type'] == 'tool_result'][-1]
                assert 'exit code: 1' in str(result), result
                if repeat:
                    assert b'awaiting approval' not in terminal.output[start:]
                expected_alerts = 1 if repeat else 2
                assert terminal.output.count(b'\x07') == alerts_before + expected_alerts, (
                    f'{backend}: approval/response alerts repeated or missing')
            # Restore long history before checking completion overlay damage.
            line('line scroll example')
            visible('LINE_SCROLL_ROW_119')
            terminal.expect_idle()
            before = grid().splitlines()[:-3]
            for query in ['/', '/sp']:
                terminal.send(query)
                visible('/clear' if query == '/' else '/spawn')
                terminal.send('\x1b')
                terminal.expect_idle()
                assert grid().splitlines()[:-3] == before, (
                    f'{backend} {columns}x{rows}: popup dismissal erased transcript\n{grid()}')
                terminal.send('\x15')
                terminal.expect_idle()

            def frame():
                cells = grid().splitlines()
                tops = [(row, text.index('┌'), text.index('┐'))
                        for row, text in enumerate(cells) if '┌' in text and '┐' in text]
                bottoms = [(row, text.index('└'), text.index('┘'))
                           for row, text in enumerate(cells) if '└' in text and '┘' in text]
                assert len(tops) == len(bottoms) == 1, grid()
                top, bottom = tops[0], bottoms[0]
                assert top[1:] == bottom[1:], grid()
                assert top[2] - top[1] + 1 <= 80
                assert bottom[0] - top[0] + 1 <= 22
                return top, bottom

            line('/settings')
            visible('Settings')
            terminal.expect_idle()
            original_frame = frame()
            line('Plugins')
            visible('Plugins · [-] inherit · [~] mixed')
            terminal.expect_idle()
            assert frame() == original_frame
            terminal.send('tina/goals')
            visible('tina/goals')
            terminal.expect_idle()
            terminal.send('?')
            visible('About tina/goals')
            terminal.expect_idle()
            assert frame() == original_frame
            terminal.send('\x1b')
            visible('Plugins · [-] inherit · [~] mixed')
            assert frame() == original_frame
            # Space out Escape presses: double-Esc is the global cancel gesture.
            terminal.expect_idle()
            terminal.send('\x1b')
            visible('› General')
            assert frame() == original_frame
            terminal.expect_idle()
            terminal.send('\x1b')
            visible('Settings closed.')
            visible('smoke >')
            assert not any('┌' in text for text in grid().splitlines())

            for panel in [2, 3]:
                line('/spawn local/smoke')
                visible(f'{panel}:')
            visible('3 panels (2 hidden)')
            terminal.send('panel draft')
            terminal.expect_idle()
            # Spatial focus reaches the status bar independently of panel count.
            terminal.send('\x07\x1b[B\r')
            visible('Enter panels')
            terminal.expect_cursor(False)
            terminal.send('\r')
            visible('Panels')
            visible('M minimize')
            terminal.send('m')
            visible('minimized')
            terminal.send('\r')
            terminal.expect_idle()
            assert 'Panels' not in grid(), 'restoring a panel left stale controls'
            visible('1:')
            terminal.send('\x07\x1b[B\r\r')
            visible('Panels')
            terminal.send('\x1b[B\x1b[Bx')
            visible('maximized')
            terminal.send('\r')
            visible('panel draft')
            terminal.expect_cursor(True)
            terminal.send('\x15')
            terminal.quit()
            print(f'PASS popup restoration, settings frames and panel controls: {backend} {columns}x{rows}', flush=True)
        except Exception:
            print(grid(), flush=True)
            print(terminal.output[-12000:].decode(errors='replace').replace('\x1b', '<ESC>'), flush=True)
            raise
        finally:
            terminal.close()


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--binary')
    source.add_argument('--dart')
    args = parser.parse_args()
    launcher = [str(Path(args.binary).resolve())] if args.binary else [args.dart, 'run', 'bin/tina.dart']
    server = ThreadingHTTPServer(('127.0.0.1', 0), ModelStub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for backend in ['ansi', 'notcurses']:
            for columns, rows in [(80, 10), (120, 24)]:
                smoke(launcher,
                      f'http://127.0.0.1:{server.server_port}', backend, columns, rows)
    finally:
        ModelStub.release_stream.set()
        ModelStub.release_cancelled.set()
        server.shutdown()


if __name__ == '__main__':
    main()
