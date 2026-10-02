#!/usr/bin/env python3
"""Verify automatic native startup, ANSI fallback, status and resumed input."""
import argparse
from http.server import ThreadingHTTPServer
import os
from pathlib import Path
import sys
import tempfile
import threading

sys.dont_write_bytecode = True
from smoke_engine2 import ANSI, ModelStub, Terminal
from smoke_classification_panel import screen_text


def smoke(launcher, endpoint, selection, term, expected):
    with tempfile.TemporaryDirectory(prefix='tina-backend-') as directory:
        root = Path(directory).resolve()
        config = root / 'config'
        config.write_text(
            '[default]\nprovider="local"\nmodel="smoke"\n'
            '[providers.local]\nwire="anthropic"\n'
            f'base_url="{endpoint}"\napi_key="fixture-key"\n'
            'models=["smoke|Smoke model"]\n'
            '[plugins]\nenabled=["tina/chat-tui", "tina/panels-tui", '
            '"tina/persistence", "tina/session-controls"]\n')
        command = launcher + ['--config', str(config), '--cwd', str(root),
                              '--store', str(root / 'sessions.db')]
        if selection is not None:
            command += ['--backend', selection]
        env = dict(os.environ, HOME=str(root), TERM=term, LANG='en_US.UTF-8')
        terminal = None

        def grid():
            return screen_text(terminal.output, 120, 24)

        def visible(text):
            terminal.wait_for(lambda: text in grid(), f'grid does not contain {text!r}')

        def turn(text):
            answers_before = grid().count('smoke answer')
            terminal.send(text)
            # Native input may show a long paste as a compact placeholder.
            # Assert the delivered contents at the model boundary instead.
            terminal.expect_idle()
            terminal.send('\r')
            terminal.wait_for(lambda: any(text in str(request) for request in ModelStub.requests),
                              f'input did not reach the model: {text}')
            terminal.wait_for(lambda: grid().count('smoke answer') > answers_before,
                              'model reply did not appear in the terminal grid')
            terminal.expect_idle()

        try:
            terminal = Terminal(command, env, 120, 24)
            if expected is None:
                terminal.expect('Failed to initialize notcurses', wrapped=True)
                terminal.expect_clean_exit(66)
                print('PASS explicit notcurses failure is reported and terminal restored', flush=True)
                return
            terminal.wait_for(lambda: expected in grid().splitlines()[-1],
                              f'status does not identify {expected}')
            visible('smoke >')
            turn(f'backend launch {selection or "default"} {term}')
            terminal.quit()
            terminal.close()

            terminal = Terminal(command + ['--resume'], env, 120, 24)
            terminal.expect('Enter resume', wrapped=True)
            terminal.send('\r')
            terminal.wait_for(lambda: expected in grid().splitlines()[-1],
                              f'resumed status does not identify {expected}')
            visible('smoke >')
            terminal.expect_idle()
            turn(f'backend resume {selection or "default"} {term}')
            terminal.quit()
            print(f'PASS backend {selection or "default"} / {term}: {expected}, status, turn, resume', flush=True)
        except Exception:
            if terminal is not None:
                print(grid(), flush=True)
                print(ANSI.sub(b'', terminal.output[-6000:]).decode(errors='replace'), flush=True)
            raise
        finally:
            if terminal is not None:
                terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--dart')
    args = parser.parse_args()
    if not args.binary and not args.dart:
        parser.error('--binary or --dart is required')
    launcher = [str(args.binary.resolve())] if args.binary else [args.dart, 'run', 'bin/tina.dart']
    server = ThreadingHTTPServer(('127.0.0.1', 0), ModelStub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        invalid = 'tina-nonexistent-terminal-fixture'
        for selection, term, expected in [
                (None, 'xterm-256color', 'notcurses'),
                ('ansi', 'xterm-256color', 'ansi'),
                ('notcurses', 'xterm-256color', 'notcurses'),
                (None, invalid, 'ansi'),
                ('notcurses', invalid, None)]:
            smoke(launcher, f'http://127.0.0.1:{server.server_port}', selection, term, expected)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
