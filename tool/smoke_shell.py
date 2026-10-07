#!/usr/bin/env python3
"""Exercise manual shell dispatch, captured output and cancellation on a PTY."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
from smoke_engine2 import ModelStub, Terminal
from smoke_classification_panel import screen_text


def smoke(launcher, endpoint, backend, panels):
    with tempfile.TemporaryDirectory(prefix='tina-shell-pty-') as directory:
        root = Path(directory).resolve()
        config = root / 'config'
        plugins = ['tina/system-instruction', 'tina/providers', 'tina/mode',
                   'tina/tools', 'tina/approvals',
                   'tina/chat-tui', 'tina/shell']
        if panels:
            plugins.append('tina/panels-tui')
        config.write_text(
            '[default]\nprovider="local"\nmodel="smoke"\n'
            '[providers.local]\nwire="anthropic"\n'
            f'base_url="{endpoint}"\napi_key="fixture-key"\n'
            'models=["smoke|Smoke model"]\n'
            f'[plugins]\nenabled={json.dumps(plugins)}\nselection_version=2\n')
        terminal = Terminal(
            launcher + ['--config', str(config), '--cwd', str(root),
                        '--backend', backend],
            dict(os.environ, HOME=str(root), TERM='xterm-256color',
                 LANG='en_US.UTF-8'), 120, 28)
        before = len(ModelStub.requests)

        def visible(text):
            terminal.wait_for(
                lambda: text in screen_text(terminal.output, 120, 28),
                f'{backend}: shell display does not contain {text!r}', timeout=20)

        def submit(command, *, busy=False):
            terminal.send(command)
            # Native input can coalesce a long command as pasted text. Enter
            # must arrive after that burst has settled to submit it.
            if busy:
                deadline = time.monotonic() + 0.35
                while time.monotonic() < deadline:
                    terminal.read()
            else:
                terminal.expect_idle()
            terminal.send('\r')

        try:
            visible('smoke >')
            terminal.send('!')
            visible('smoke !')
            terminal.send('\x7f')
            visible('smoke >')
            # These octal escapes generate markers absent from the input row.
            submit(r"!printf '\123\110\105\114\114\137\117\125\124\n'; "
                   r"printf '\123\110\105\114\114\137\105\122\122\n' >&2; exit 7")
            visible('SHELL_OUT')
            visible('SHELL_ERR')
            visible('exit code: 7')
            visible('smoke >')
            assert len(ModelStub.requests) == before, 'manual shell called the model'
            submit('!echo ready > started; while :; do sleep 0.1; done')
            terminal.wait_for(lambda: (root / 'started').exists(),
                              'manual command did not start')
            terminal.send('\x1b')
            visible('cancelled: command stopped')
            assert len(ModelStub.requests) == before, 'shell cancellation called the model'
            ModelStub.release_stream.clear()
            submit('terminal smoke')
            visible('streaming prefix')
            submit('!echo immediate > busy_shell', busy=True)
            terminal.wait_for(lambda: (root / 'busy_shell').exists(),
                              '! command waited for the active model turn')
            submit("/shell trap 'echo stopped > busy_stopped; exit' TERM; "
                   "echo ready > busy_started; while :; do sleep 0.1; done", busy=True)
            terminal.wait_for(lambda: (root / 'busy_started').exists(),
                              '/shell command waited for the active model turn')
            assert not ModelStub.release_stream.is_set(), 'model turn finished before shell dispatch'
            assert len(ModelStub.requests) == before + 1, 'busy shell called the model'
            display = screen_text(terminal.output, 120, 28)
            assert 'queued]' not in display, 'immediate shell is shown as queued'
            assert 'Message queued' not in display, 'immediate shell emitted a queue notice'
            ModelStub.release_stream.set()
            visible('smoke answer')
            terminal.expect_idle()
            terminal.send('\x1b\x1b')
            terminal.wait_for(lambda: (root / 'busy_stopped').exists(),
                              'shell could not be cancelled after the model finished')
            terminal.send('DRAFT_THAT_MUST_CLEAR')
            visible('DRAFT_THAT_MUST_CLEAR')
            terminal.expect_idle()
            terminal.send('\x03')
            terminal.wait_for(
                lambda: 'DRAFT_THAT_MUST_CLEAR' not in screen_text(terminal.output, 120, 28),
                'Ctrl+C did not clear the idle draft')
            assert terminal.process.poll() is None, 'clearing a draft quit the app'
            ModelStub.release_stream.clear()
            submit('terminal smoke draft')
            terminal.wait_for(lambda: len(ModelStub.requests) == before + 2,
                              'model turn for quit check did not start')
            submit("!trap 'echo stopped > quit_stopped; exit' TERM; "
                   "echo ready > quit_started; while :; do sleep 0.1; done", busy=True)
            terminal.wait_for(lambda: (root / 'quit_started').exists(),
                              'shell command for quit check did not start')
            ModelStub.release_stream.set()
            terminal.expect_idle()
            terminal.wait_for(
                lambda: 'draft answer' in screen_text(terminal.output, 120, 28),
                'model turn for quit check did not finish')
            terminal.send('BUSY_DRAFT_THAT_MUST_CLEAR')
            visible('BUSY_DRAFT_THAT_MUST_CLEAR')
            terminal.expect_idle()
            terminal.send('\x03')
            terminal.wait_for(
                lambda: 'BUSY_DRAFT_THAT_MUST_CLEAR' not in screen_text(terminal.output, 120, 28),
                'Ctrl+C did not clear the busy draft')
            assert terminal.process.poll() is None, 'clearing a busy draft quit the app'
            assert not (root / 'quit_stopped').exists(), 'clearing a draft cancelled work'
            terminal.send('\x03')
            terminal.expect_clean_exit()
            assert (root / 'quit_stopped').exists(), 'quit did not stop the shell process'
            print(f'PASS shell {backend}, panels={panels}: output, exit code, immediate dispatch, cancellation after model turn, Ctrl+C clear/quit',
                  flush=True)
        except Exception:
            print(screen_text(terminal.output, 120, 28), flush=True)
            raise
        finally:
            ModelStub.release_stream.set()
            terminal.close()


def main():
    parser = argparse.ArgumentParser()
    launch = parser.add_mutually_exclusive_group(required=True)
    launch.add_argument('--dart')
    launch.add_argument('--binary')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), ModelStub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        launcher = ([str(Path(args.binary).resolve())] if args.binary
                    else [args.dart, 'run', 'bin/tina.dart'])
        for backend in ('ansi', 'notcurses'):
            for panels in (False, True):
                smoke(launcher, f'http://127.0.0.1:{server.server_port}', backend, panels)
    finally:
        server.shutdown()


if __name__ == '__main__':
    main()
