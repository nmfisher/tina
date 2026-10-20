#!/usr/bin/env python3
"""Resume with a usable terminal whose restart pathname cannot be resolved."""
import argparse
from http.server import ThreadingHTTPServer
import os
from pathlib import Path
import shlex
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
from smoke_engine2 import ANSI, ModelStub, Terminal


def smoke(dart, endpoint, backend):
    with tempfile.TemporaryDirectory(prefix='tina-resume-terminal-') as directory:
        root = Path(directory).resolve()
        config = root / "config with 'quotes'"
        config.write_text(
            '[default]\nprovider="local"\nmodel="smoke"\n'
            '[providers.local]\nwire="anthropic"\n'
            f'base_url="{endpoint}"\napi_key="fixture-key"\n'
            'models=["smoke|Smoke model"]\n'
            '[plugins]\nenabled=["tina/chat-tui", "tina/panels-tui", '
            '"tina/persistence", "tina/session-controls"]\n')
        command = [dart, 'apps/tina_cli/test/fixtures/resume_terminal.dart',
                   '--backend', backend, '--config', str(config),
                   '--cwd', str(root), '--store', str(root / 'session history.db')]
        env = dict(os.environ, HOME=str(root), TERM='xterm-256color', LANG='en_US.UTF-8')
        terminal = None
        def line(text):
            start = terminal.send(text)
            time.sleep(.12)
            terminal.send('\r')
            return start

        def resume_arguments():
            # The hint must survive leaving the alternate screen, and be
            # directly executable even when custom paths need shell quoting.
            tail = bytes(terminal.output).rsplit(b'\x1b[?1049l', 1)[-1]
            shown = ANSI.sub(b'', tail).decode()
            hint = shown.split('Resume this session:', 1)[1].strip().splitlines()[0]
            arguments = shlex.split(hint)
            assert arguments[:2] == ['tina', '--resume'], hint
            for flag in ['--cwd', '--config', '--store', '--backend']:
                assert arguments[arguments.index(flag) + 1] == command[command.index(flag) + 1], hint
            return arguments[1:]

        try:
            terminal = Terminal(command, env, 100, 24)
            terminal.expect('RESTART_DEVICE_UNAVAILABLE')
            terminal.expect('smoke >')
            start = line('before resume')
            terminal.expect('smoke answer', start)
            terminal.quit()
            saved_arguments = resume_arguments()
            terminal.close()

            terminal = Terminal(command + ['--resume'], env, 100, 24)
            terminal.expect('RESTART_DEVICE_UNAVAILABLE')
            terminal.expect('Enter resume')
            start = terminal.send('\r')
            terminal.expect('smoke >', start)
            terminal.expect_idle()
            start = line(f'after resume {backend}')
            terminal.wait_for(
                lambda: any(f'after resume {backend}' in str(request)
                            for request in ModelStub.requests),
                'resumed input never reached the model')
            terminal.expect('smoke answer', start)
            terminal.quit()
            assert resume_arguments() == saved_arguments
            terminal.close()

            # Execute the exact printed arguments, then quit during streaming.
            # Neither /quit nor Ctrl+C may wait for the provider to finish.
            for quit_input in ['/quit\r', '\x03']:
                terminal = Terminal(command[:2] + saved_arguments, env, 100, 24)
                terminal.expect('smoke >')
                terminal.expect('before resume')
                ModelStub.release_cancelled.clear()
                try:
                    start = line('cancel this on quit')
                    # Native rendering may reuse the already-painted "cancel"
                    # from the submitted input; its delta still paints pending.
                    terminal.expect('pending', start)
                    terminal.send(quit_input)
                    terminal.expect_clean_exit()
                    assert resume_arguments() == saved_arguments
                finally:
                    ModelStub.release_cancelled.set()
                terminal.close()

            # A new empty session is intentionally not persisted.
            terminal = Terminal(command, env, 100, 24)
            terminal.expect('smoke >')
            terminal.quit()
            assert b'Resume this session:' not in terminal.output
            terminal.close()

            terminal = Terminal(command + ['--resume'], env, 100, 24)
            terminal.expect('Enter resume')
            terminal.send('\x1b')
            terminal.expect_clean_exit()
            print(f'PASS missing restart pathname: launch, resume/input, cancel ({backend})', flush=True)
        except Exception:
            if terminal is not None:
                print(ANSI.sub(b'', terminal.output[-6000:]).decode(errors='replace'), flush=True)
            raise
        finally:
            if terminal is not None:
                terminal.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dart', default='dart')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), ModelStub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for backend in ['ansi', 'notcurses']:
            smoke(args.dart, f'http://127.0.0.1:{server.server_port}', backend)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
