#!/usr/bin/env python3
"""Verify input after a full Tina terminal teardown and restart; no credentials."""
import argparse
import os
from pathlib import Path
import signal
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
from smoke_engine2 import ANSI, ModelStub, Terminal, ThreadingHTTPServer
from smoke_classification_panel import screen_text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dart', default='dart')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), ModelStub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    terminal = None
    try:
        with tempfile.TemporaryDirectory(prefix='tina-restart-') as directory:
            root = Path(directory)
            config = root / 'config'
            config.write_text(
                'version = 1\n[default]\nprovider = "local-smoke"\nmodel = "smoke"\n'
                '[providers.local-smoke]\nwire = "anthropic"\n'
                f'base_url = "http://127.0.0.1:{server.server_port}"\n'
                'api_key = "fixture-key"\nmodels = ["smoke|Smoke model"]\n')
            terminal = Terminal([args.dart,
                'packages/tina_tui/test/fixtures/restart_app.dart',
                str(config), str(root)],
                dict(os.environ, COCOON_UPDATE_CHECK='0', TERM='xterm-256color'), 80, 24)
            terminal.expect('smoke >')
            # Match the restarted prompt only, not the old app's final repaint.
            start = terminal.send('/restart-test')
            terminal.expect_idle()
            terminal.send('\r')
            terminal.expect('RESTART_PARENT_CLOSED', start)
            marker = b'RESTART_PARENT_CLOSED'
            start = terminal.output.index(marker, start) + len(marker)
            # The restarted app is a fresh `dart run` cold start of the whole
            # engine; on a loaded runner that JIT alone can outlast the
            # harness's default 10s window before notcurses even inits. Allow
            # the same 30s budget expect() grants the parent app.
            terminal.wait_for(
                lambda: 'config:' in screen_text(terminal.output[start:], 80, 24)
                and 'smoke >' in screen_text(terminal.output[start:], 80, 24),
                'restarted app did not show a ready prompt', timeout=30)
            time.sleep(0.2)
            start = terminal.send('hello after restart')
            terminal.expect_idle()
            terminal.send('\r')
            terminal.wait_for(lambda: any('hello after restart' in str(r)
                                         for r in ModelStub.requests),
                              'restarted input did not reach the model')
            terminal.wait_for(lambda: 'smoke answer' in screen_text(terminal.output, 80, 24),
                              'restarted model reply did not appear')
            terminal.quit()
            print('PASS full restarted app input and model reply')
    except Exception:
        if terminal is not None:
            print(ANSI.sub(b'', terminal.output[-6000:]).decode(errors='replace'), file=sys.stderr)
        raise
    finally:
        if terminal is not None:
            if terminal.process.poll() is None:
                os.killpg(terminal.process.pid, signal.SIGKILL)
            terminal.close()
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
