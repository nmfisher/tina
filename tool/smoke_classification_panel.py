#!/usr/bin/env python3
"""Live classifier inspection on a controlling PTY, with local model fixtures."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import threading
import time
import unicodedata
from http.server import ThreadingHTTPServer

sys.dont_write_bytecode = True
from smoke_engine2 import ModelStub, Terminal


def screen_text(output, columns, rows, initial=None):
    """Replay the terminal grid, including native writes that reuse old letters."""
    grid = [[' '] * columns for _ in range(rows)]
    if initial:
        for y, line in enumerate(initial[:rows]):
            for x, char in enumerate(line[:columns]): grid[y][x] = char
    row = col = 0
    saved = (0, 0)
    previous = ' '
    tokens = re.finditer(
        r'\x1b(?:\[[0-?]*[ -/]*[@-~]|[\]PX^_].*?(?:\x07|\x1b\\)|[ -/]+[@-~]|.)|[^\x1b]',
        output.decode(errors='replace'), re.S)
    for token in tokens:
        text = token.group()
        if text.startswith('\x1b['):
            action = text[-1]
            params = text[2:-1]
            if params.startswith(('?', '>', '=')) or any(c not in '0123456789;' for c in params):
                continue
            values = [int(v or 0) for v in params.split(';')]
            n = values[0] or 1
            if action in 'Hf':
                row, col = n - 1, (values[1] or 1) - 1 if len(values) > 1 else 0
            elif action == 'G': col = n - 1
            elif action == 'd': row = n - 1
            elif action == 'A': row -= n
            elif action == 'B': row += n
            elif action == 'C': col += n
            elif action == 'D': col -= n
            elif action == 'E': row, col = row + n, 0
            elif action == 'F': row, col = row - n, 0
            elif action == 's': saved = (row, col)
            elif action == 'u': row, col = saved
            elif action == 'X':
                for x in range(col, min(columns, col + n)): grid[row][x] = ' '
            elif action in 'JK':
                mode = values[0]
                for y in range(rows):
                    for x in range(columns):
                        if action == 'K' and y != row: continue
                        if mode == 2 or mode == 0 and (y, x) >= (row, col) or mode == 1 and (y, x) <= (row, col):
                            grid[y][x] = ' '
            elif action == 'b':
                for x in range(col, min(columns, col + n)): grid[row][x] = previous
                col += n
            row, col = min(rows - 1, max(0, row)), min(columns - 1, max(0, col))
        elif text == '\x1b7': saved = (row, col)
        elif text == '\x1b8': row, col = saved
        elif text.startswith('\x1b'): continue
        elif text == '\r': col = 0
        elif text == '\n': row += 1
        elif text >= ' ':
            width = 0 if unicodedata.combining(text) else 2 if unicodedata.east_asian_width(text) in 'WF' else 1
            if not width: continue
            if col + width > columns: row, col = row + 1, 0
            if row >= rows:
                grid.pop(0)
                grid.append([' '] * columns)
                row = rows - 1
            grid[row][col] = text
            if width == 2: grid[row][col + 1] = ''
            col += width
            previous = text
        if row >= rows:
            grid.pop(0)
            grid.append([' '] * columns)
            row = rows - 1
    return '\n'.join(''.join(line) for line in grid)


def expect_grid(terminal, text, columns, rows, start=0, initial=None):
    terminal.wait_for(lambda: text in screen_text(terminal.output[start:], columns, rows, initial),
                      f'visible grid does not contain {text!r}')


class ClassifierStub(ModelStub):
    judgments = []
    release = threading.Event()

    def do_POST(self):
        if self.path != '/judge':
            return super().do_POST()
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.judgments.append(body)
        assert self.headers['Authorization'] == 'Bearer fixture-classifier-key'
        assert self.release.wait(30), 'classifier response was never released'
        answers = {}
        for key, question in body['questions'].items():
            if question['type'] == 'choice':
                answers[key] = {'type': 'choice', 'choice': 'agentInstruction',
                    'confidence': .99, 'probabilities': {'projectQuestion': .01,
                    'agentInstruction': .99, 'other': 0.0}}
            else:
                answers[key] = {'type': 'noul', 'noul': .98 if key == 'push' else 0.0}
        reply = json.dumps({'model': 'fixture-jev', 'answers': answers,
                            'usage': {'input_tokens': 20, 'output_tokens': 3}}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(reply)))
        self.end_headers()
        try:
            self.wfile.write(reply)
        except (BrokenPipeError, ConnectionResetError):
            pass


def line(terminal, text):
    start = terminal.send(text)
    # Native temporal paste detection requires submission outside the burst.
    time.sleep(.12)
    terminal.send('\r')
    return start


def smoke(launcher, endpoint, backend, columns, rows):
    with tempfile.TemporaryDirectory(prefix='tina-classifier-panel-') as directory:
        root = Path(directory).resolve()
        (root / 'workspace').mkdir()
        config = root / 'config'
        config.write_text(
            '[default]\nprovider = "local"\nmodel = "smoke"\n'
            '[providers.local]\nwire = "anthropic"\n'
            f'base_url = "{endpoint}"\napi_key = "config-smoke-key"\n'
            'models = ["smoke|Smoke model"]\n'
            '[plugins]\nenabled = ["tina/classification", "tina/chat-tui", "tina/panels-tui"]\n'
            '[typesafe]\napi_key = "fixture-classifier-key"\n'
            f'model = "fixture-jev"\nendpoint = "{endpoint}/judge"\n')
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': str(root),
               'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8'}
        command = launcher + ['--config', str(config), '--cwd', str(root / 'workspace'),
                              '--backend', backend]
        ClassifierStub.release.clear()
        request_start = len(ClassifierStub.judgments)
        terminal = Terminal(command, env, columns, rows)
        try:
            terminal.expect('smoke > ')
            start = line(terminal, 'push the branch')
            terminal.expect('smoke answer', start)
            terminal.wait_for(lambda: len(ClassifierStub.judgments) > request_start, 'no classifier request')
            expect_grid(terminal, 'Sent: intent', columns, rows)
            expect_grid(terminal, 'waiting', columns, rows)
            terminal.expect_idle()
            ClassifierStub.release.set()
            terminal.wait_for(lambda: len(ClassifierStub.judgments) == request_start + 2, 'no dependent Git classification')
            expect_grid(terminal, 'instruction', columns, rows)
            terminal.expect_idle()
            start = line(terminal, '/classification hierarchy')
            expect_grid(terminal, 'hierarchy', columns, rows)
            terminal.expect_cursor(False)
            # Browse the complete hierarchy and inspect the root request.
            terminal.send('\x1b[A' * 40)
            time.sleep(.15)
            start = terminal.send('\x1b[C')
            expect_grid(terminal, 'Request', columns, rows)
            terminal.expect_cursor(False)
            terminal.expect_idle()
            previous = screen_text(terminal.output, columns, rows).splitlines()
            start = terminal.resize(40, 10)
            expect_grid(terminal, 'classification', 40, 10, start, previous)
            terminal.expect_cursor(False)
            terminal.send('\x1b')  # return to the conversation, preserving draft
            # ANSI waits 150ms to distinguish standalone Escape from a prefix.
            time.sleep(.25)
            terminal.expect_cursor(True)
            # At 40 columns the inspector occupies most conversation rows.
            terminal.send('\x1b[17~')  # F6 hides it before the follow-up
            terminal.expect_idle()
            start = line(terminal, 'after panel')
            terminal.expect('smoke answer', start)
            terminal.wait_for(lambda: len(ClassifierStub.judgments) == request_start + 4, 'follow-up classification did not finish')
            terminal.expect_idle()
            assert b'fixture-classifier-key' not in terminal.output
            terminal.quit()
        except Exception:
            print(terminal.output[-14000:].decode(errors='replace').replace('\x1b', '<ESC>'), flush=True)
            raise
        finally:
            ClassifierStub.release.set()
            terminal.close()
        print(f'PASS classification panel: {backend} {columns}x{rows}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--dart')
    parser.add_argument('--backend', choices=['ansi', 'notcurses', 'both'], default='both')
    args = parser.parse_args()
    if not args.binary and not args.dart:
        parser.error('--binary or --dart is required')
    launcher = [str(args.binary.resolve())] if args.binary else [args.dart, 'run', 'bin/tina.dart']
    server = ThreadingHTTPServer(('127.0.0.1', 0), ClassifierStub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        backends = ['ansi', 'notcurses'] if args.backend == 'both' else [args.backend]
        for backend in backends:
            for columns, rows in [(80, 10), (100, 24), (160, 40)]:
                smoke(launcher, f'http://127.0.0.1:{server.server_port}', backend, columns, rows)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
