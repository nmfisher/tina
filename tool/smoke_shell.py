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

        def submit(command):
            terminal.send(command)
            # Native input can coalesce a long command as pasted text. Enter
            # must arrive after that burst has settled to submit it.
            terminal.expect_idle()
            terminal.send('\r')

        try:
            visible('smoke >')
            # These octal escapes generate markers absent from the input row.
            submit(r"!printf '\123\110\105\114\114\137\117\125\124\n'; "
                   r"printf '\123\110\105\114\114\137\105\122\122\n' >&2; exit 7")
            visible('SHELL_OUT')
            visible('SHELL_ERR')
            visible('exit code: 7')
            assert len(ModelStub.requests) == before, 'manual shell called the model'
            submit('!echo ready > started; while :; do sleep 0.1; done')
            terminal.wait_for(lambda: (root / 'started').exists(),
                              'manual command did not start')
            terminal.send('\x1b')
            visible('cancelled: command stopped')
            assert len(ModelStub.requests) == before, 'shell cancellation called the model'
            terminal.quit()
            print(f'PASS shell {backend}, panels={panels}: output, exit code, no model, cancellation',
                  flush=True)
        except Exception:
            print(screen_text(terminal.output, 120, 28), flush=True)
            raise
        finally:
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
