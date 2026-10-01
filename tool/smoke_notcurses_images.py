#!/usr/bin/env python3
"""Exercise retained image rendering on a real notcurses PTY, offline."""
import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import threading
import time
import sys
from http.server import ThreadingHTTPServer

sys.dont_write_bytecode = True
from smoke_engine2 import ModelStub, PACKAGE, Terminal

PNG = 'iVBORw0KGgoAAAANSUhEUgAAABgAAAAgCAYAAAAIXrg4AAAAJ0lEQVR4nO3NsQ0AAAjAoP7/tF7hYMLATFNzKYFAIBAIBAKBQPAlWMuz+kyFM+vqAAAAAElFTkSuQmCC'
RED = re.compile(rb'(?:38|48);2;255;0;0|(?:38|48);5;(?:196|9)|\x1b\[(?:0;)?(?:31|41|91|101)m')


def red_present(terminal, start=0):
    return RED.search(terminal.output[start:]) is not None


def send_line(terminal, text):
    start = terminal.send(text)
    # Native temporal paste detection correctly treats a burst containing
    # Enter as pasted multiline text. Separate typing from the submit key.
    time.sleep(0.1)
    terminal.send('\r')
    return start


def smoke(binary, endpoint, columns, rows):
    with tempfile.TemporaryDirectory(prefix='tina-native-image-') as directory:
        root = Path(directory)
        config = root / 'config'
        fixture = PACKAGE.parent / 'plugins/tina_mcp/test/fixtures/server.py'
        config.write_text(
            'version = 1\n[default]\nprovider = "local"\nmodel = "smoke"\n'
            '[providers.local]\nwire = "anthropic"\n'
            f'base_url = "{endpoint}"\napi_key = "config-smoke-key"\n'
            'models = ["smoke|Smoke model"]\n'
            '[mcp.servers.fixture]\ncommand = "python3"\n'
            f'args = [{json.dumps(str(fixture))}]\n'
            '[mcp.servers.fixture.env]\n'
            f'TINA_MCP_FIXTURE_IMAGE = "{PNG}"\n')
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
               'HOME': str(root), 'TERM': 'xterm-256color',
               'COLORTERM': 'truecolor', 'LANG': 'en_US.UTF-8',
               'COCOON_UPDATE_CHECK': '0'}
        command = [str(binary), '--backend', 'notcurses', '--config', str(config),
                   '--cwd', str(root), '--store', str(root / 'sessions.db')]
        terminal = Terminal(command, env, columns, rows)
        try:
            terminal.expect('smoke > ')
            terminal.expect_idle()
            start = send_line(terminal, 'mcp screenshot example')
            terminal.expect('[y] allow once', start, wrapped=True)
            start = terminal.send('y')
            terminal.expect('24×32', start)
            terminal.expect('smoke answer', start, wrapped=True)
            terminal.wait_for(lambda: red_present(terminal, start),
                              'notcurses did not paint decoded image pixels')
            print(f'PASS notcurses {columns}x{rows}: decoded screenshot painted')
            terminal.expect_idle()
            before = len(ModelStub.requests)
            # Resize and repaint must retain the picture, rather than leave a
            # one-shot overlay behind or paint over the input area.
            start = terminal.resize(columns - 8, rows + 2)
            terminal.wait_for(lambda: red_present(terminal, start),
                              'resize lost the retained image')
            terminal.expect_idle()
            start = terminal.send('\x1b[1;3A')
            terminal.expect_idle()
            terminal.send('\x1b[1;3B')
            terminal.expect_idle()
            # Images and their plane teardown must leave the editor usable.
            start = send_line(terminal, 'after screenshot')
            terminal.wait_for(lambda: len(ModelStub.requests) == before + 1,
                              'image rendering broke Enter submission')
            terminal.expect('smoke answer', start, wrapped=True)
            terminal.expect_idle()
            terminal.quit()
        except Exception:
            print(terminal.output.decode(errors='replace')[-12000:])
            raise
        finally:
            terminal.close()
        # Persisted tool-result attachments must be painted on resume too.
        resumed = Terminal(command + ['--continue'], env, columns, rows)
        try:
            resumed.expect('smoke > ')
            for _ in range(3):
                resumed.send('\x1b[5~')
                time.sleep(0.05)
            resumed.expect('24×32')
            resumed.wait_for(lambda: red_present(resumed), 'resume lost image pixels')
            resumed.expect_idle()
            start = send_line(resumed, '/clear')
            resumed.expect('cleared', start, wrapped=True)
            resumed.expect_idle()
            # /quit is short enough not to be mistaken for a pasted burst.
            resumed.quit()
        except Exception:
            print(resumed.output.decode(errors='replace')[-12000:])
            raise
        finally:
            resumed.close()
        print(f'PASS notcurses images {columns}x{rows}: MCP pixels, idle, resize, scroll, input, resume, clear, teardown')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), ModelStub)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        for columns, rows in [(80, 10), (80, 24), (120, 30)]:
            smoke(args.binary.absolute(), f'http://127.0.0.1:{server.server_port}', columns, rows)
    finally:
        server.shutdown()
        server.server_close()
        worker.join()


if __name__ == '__main__':
    main()
