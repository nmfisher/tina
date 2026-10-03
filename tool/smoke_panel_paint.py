#!/usr/bin/env python3
"""Verify popup restoration and status panel controls on both real backends."""
import argparse
from http.server import ThreadingHTTPServer
import os
from pathlib import Path
import sys
import tempfile
import threading

sys.dont_write_bytecode = True
from smoke_engine2 import ModelStub, Terminal
from smoke_classification_panel import screen_text


def smoke(binary, endpoint, backend, columns, rows):
    with tempfile.TemporaryDirectory(prefix='tina-panel-paint-') as directory:
        root = Path(directory).resolve()
        config = root / 'config'
        config.write_text(
            '[default]\nprovider="local"\nmodel="smoke"\n'
            '[providers.local]\nwire="anthropic"\n'
            f'base_url="{endpoint}"\napi_key="fixture-key"\n'
            'models=["smoke|Smoke model"]\n'
            '[plugins]\nenabled=["tina/chat-tui", "tina/panels-tui", '
            '"tina/plans", "tina/session-controls", "tina/persistence"]\n')
        env = dict(os.environ, HOME=str(root), TERM='xterm-256color', LANG='en_US.UTF-8')
        command = [binary, '--backend', backend, '--config', str(config),
                   '--cwd', str(root), '--store', str(root / 'sessions.db')]
        terminal = Terminal(command, env, columns, rows)

        def grid():
            return screen_text(terminal.output, columns, rows)

        def visible(text):
            terminal.wait_for(lambda: text in grid(), f'grid does not contain {text!r}',
                              timeout=30)

        def line(text):
            terminal.send(text)
            # Let the backend consume and flush the text burst before Enter.
            # A split-panel layout can occupy the native input pump briefly.
            visible(text)
            terminal.expect_idle()
            return terminal.send('\r')

        try:
            terminal.expect('smoke > ')
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
            print(f'PASS popup restoration and panel controls: {backend} {columns}x{rows}', flush=True)
        except Exception:
            print(grid(), flush=True)
            print(terminal.output[-12000:].decode(errors='replace').replace('\x1b', '<ESC>'), flush=True)
            raise
        finally:
            terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), ModelStub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for backend in ['ansi', 'notcurses']:
            for columns, rows in [(80, 10), (120, 24)]:
                smoke(str(Path(args.binary).resolve()),
                      f'http://127.0.0.1:{server.server_port}', backend, columns, rows)
    finally:
        ModelStub.release_stream.set()
        ModelStub.release_cancelled.set()
        server.shutdown()


if __name__ == '__main__':
    main()
