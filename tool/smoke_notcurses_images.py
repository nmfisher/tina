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
        # Seatbelt matches canonical paths (/private/var on macOS).
        root = Path(directory).resolve()
        workspace = root / 'workspace'
        workspace.mkdir()
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
                   '--cwd', str(workspace), '--store', str(root / 'sessions.db')]
        terminal = Terminal(command, env, columns, rows)
        try:
            terminal.expect('smoke > ')
            terminal.expect_idle()
            ModelStub.advance_reasoning.clear()
            ModelStub.release_reasoning.clear()
            start = send_line(terminal, 'stream reasoning example')
            terminal.expect('reasoning (ongoing)', start, wrapped=True)
            terminal.expect('~4 tokens', start, wrapped=True)
            assert not ModelStub.release_reasoning.is_set()
            start = terminal.send('\x02\r')  # expand the live reasoning block
            # Retained rendering may reuse unchanged cells from the folded
            # header. Require the newly painted body word before advancing.
            terminal.expect('thought', start, wrapped=True)
            start = len(terminal.output)
            ModelStub.advance_reasoning.set()
            # Native retained updates write only changed cells: expect the
            # new body suffix, not the unchanged words around a changed digit.
            terminal.expect('more', start, wrapped=True)
            assert not ModelStub.release_reasoning.is_set()
            ModelStub.release_reasoning.set()
            terminal.expect_idle()
            terminal.send('\x1b')  # leave fold navigation, return to typing
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
            terminal.send('\x1b[<64;10;5M')
            terminal.expect_idle()
            terminal.send('\x1b[<65;10;5M')
            terminal.expect_idle()
            # Images and their plane teardown must leave the editor usable.
            start = send_line(terminal, 'after screenshot')
            terminal.wait_for(lambda: len(ModelStub.requests) == before + 1,
                              'image rendering broke Enter submission')
            terminal.expect('smoke answer', start, wrapped=True)
            terminal.expect_idle()
            if rows == 24:
                # Exercise Escape through the real native input pump, then
                # submit another message while the cancelled server is held.
                ModelStub.release_cancelled.clear()
                start = send_line(terminal, 'cancel this')
                terminal.expect('cancel pending', start, wrapped=True)
                terminal.send('\x1b')
                terminal.expect('cancelled: escape', start, wrapped=True)
                before = len(ModelStub.requests)
                start = send_line(terminal, 'after cancel')
                terminal.wait_for(lambda: len(ModelStub.requests) > before,
                                  'Enter did not send after response cancellation')
                assert 'after cancel' in json.dumps(ModelStub.requests[-1]['messages'][-1])
                terminal.expect('smoke answer', start, wrapped=True)
                ModelStub.release_cancelled.set()
                terminal.expect_idle()
                # Cancellation of a live subprocess must also release input
                # and kill descendants before the next instruction starts.
                start = send_line(terminal, 'run cancellable tool')
                terminal.expect('[y] allow once', start, wrapped=True)
                terminal.send('y')
                # The command text in the approval preview also contains the
                # output marker. Wait for actual execution, not that preview.
                terminal.wait_for(lambda: (workspace / 'subprocess-ready').exists(),
                                  'approved subprocess did not start')
                terminal.send('\x1b')
                terminal.expect('cancelled: escape', start, wrapped=True)
                before = len(ModelStub.requests)
                start = send_line(terminal, 'after tool cancellation')
                terminal.wait_for(lambda: len(ModelStub.requests) > before,
                                  'Enter did not send after subprocess cancellation')
                assert 'after tool cancellation' in json.dumps(ModelStub.requests[-1]['messages'][-1])
                terminal.expect('smoke answer', start, wrapped=True)
                time.sleep(2.3)
                assert not (workspace / 'cancel-leak').exists(), 'cancelled child survived'
                terminal.expect_idle()
            terminal.quit()
        except Exception:
            print(terminal.output.decode(errors='replace')[-12000:])
            if ModelStub.requests:
                print('Last model input:', json.dumps(ModelStub.requests[-1]['messages'][-1]))
            raise
        finally:
            ModelStub.advance_reasoning.set()
            ModelStub.release_reasoning.set()
            ModelStub.release_cancelled.set()
            terminal.close()
        # Persisted tool-result attachments must be painted on resume too.
        resumed = Terminal(command + ['--resume'], env, columns, rows)
        try:
            resumed.expect('Resume session', wrapped=True)
            resumed.expect('Enter resume', wrapped=True)
            resumed.send('\r')
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
        if rows == 30:
            cancelled = Terminal(command + ['--resume'], env, columns, rows)
            try:
                cancelled.expect('Enter resume', wrapped=True)
                cancelled.send('\x1b')
                cancelled.expect_clean_exit()
            finally:
                cancelled.close()
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
