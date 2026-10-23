#!/usr/bin/env python3
"""Check native startup, late replies, and Unicode pastes split across reads."""
import argparse
from collections import deque
import os
from pathlib import Path
import re
import select
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from smoke_engine2 import Terminal
from smoke_classification_panel import screen_text


class ReplyingTerminal(Terminal):
    queries = re.compile(rb'\x1b\](10|11);\?|\x1b\]4;(\d+);\?|\x1b\[(>?)(?:0)?c|\x1b\[6n')

    def __init__(self, *args):
        self.query_offset = 0
        self.pending = b''
        self.replies = deque()
        super().__init__(*args)
        os.set_blocking(self.master, False)

    def read(self):
        super().read()
        self.pending += bytes(self.output[self.query_offset:])
        self.query_offset = len(self.output)
        consumed = 0
        for match in self.queries.finditer(self.pending):
            if match.group(1):
                reply = b'\x1b]' + match.group(1) + b';rgb:ffff/ffff/ffff\x07'
            elif match.group(2):
                reply = b'\x1b]4;' + match.group(2) + b';rgb:0000/d7d7/5f5f\x07'
            elif match.group(0) == b'\x1b[6n':
                reply = b'\x1b[1;1R'
            elif match.group(3) == b'>':
                reply = b'\x1b[>0;276;0c'
            else:
                reply = b'\x1b[?62;22c'
            self.replies.append(reply)
            consumed = match.end()
        self.pending = self.pending[consumed:][-64:]
        while self.replies and select.select([], [self.master], [], 0)[1]:
            try:
                sent = os.write(self.master, self.replies[0])
            except BlockingIOError:
                break
            if sent == len(self.replies[0]):
                self.replies.popleft()
            else:
                self.replies[0] = self.replies[0][sent:]
                break

    def settle(self, seconds=0.1):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.read()

    def visible(self, text):
        self.wait_for(lambda: text in screen_text(self.output, 100, 28),
                      f'input did not paint {text!r}')

    def write_bytes(self, data):
        deadline = time.monotonic() + 5
        while data and time.monotonic() < deadline:
            self.read()
            if select.select([], [self.master], [], 0.05)[1]:
                try:
                    data = data[os.write(self.master, data):]
                except BlockingIOError:
                    pass
        assert not data, 'native input stopped accepting paste bytes'


def check_unicode_paste(terminal):
    text = 'large pasted line\n' * 400
    terminal.write_bytes(b'\x1b[200~')
    terminal.write_bytes(text.encode())
    # Force every possible read boundary inside 2-, 3-, and 4-byte codepoints.
    # The old mixed-input parser spins forever on the first incomplete prefix.
    for char in ('é', '’', '🙂'):
        encoded = char.encode()
        for split in range(1, len(encoded)):
            # Keep each delivered fragment above the temporal paste threshold
            # so all fragments remain part of the same editable paste chip.
            text += char + ' padding '
            terminal.write_bytes(encoded[:split])
            terminal.settle(0.05)
            terminal.write_bytes(encoded[split:] + b' padding ')
    terminal.write_bytes(b'\x1b[201~')
    terminal.visible(f'[Pasted text : {len(text)} chars]')
    terminal.send('\x05\x15')
    terminal.settle()
    terminal.send('responsive after paste')
    terminal.visible('responsive after paste')
    terminal.send('\x05\x15')
    terminal.settle()


def smoke(binary):
    with tempfile.TemporaryDirectory(prefix='tina-native-startup-') as directory:
        root = Path(directory).resolve()
        config = root / 'config'
        # No provider request is needed: edit a draft, then use local commands.
        config.write_text(
            '[default]\nprovider="local"\nmodel="smoke"\n'
            '[providers.local]\nwire="anthropic"\n'
            'base_url="http://127.0.0.1:1"\napi_key="fixture-key"\n'
            'models=["smoke|Smoke model"]\n')
        env = dict(os.environ, HOME=str(root), TERM='xterm-256color',
                   LANG='en_US.UTF-8', COCOON_UPDATE_CHECK='0')
        env.pop('TMUX', None)
        command = [str(binary), '--config', str(config), '--cwd', str(root),
                   '--store', str(root / 'sessions.db'), '--backend', 'notcurses']
        for continuing in (False, True):
            terminal = ReplyingTerminal(command + (['-c'] if continuing else []), env, 100, 28)
            try:
                terminal.visible('smoke >')
                # A cold terminal can split a delayed palette reply across
                # reads. Its raw BEL is delivered by notcurses as Ctrl+G.
                terminal.send('\x1b]4;41;rgb:0000/d7d7/5f5f')
                terminal.settle()
                terminal.send('\x07')
                terminal.settle()
                # Keep keystrokes outside the temporal paste window so the
                # editor can move within the text instead of an atomic paste.
                for char in 'typing works':
                    terminal.send(char)
                    terminal.settle(0.05)
                terminal.visible('typing works')
                terminal.settle()
                terminal.send('\x1b[D')
                terminal.settle()
                terminal.send('!')
                terminal.visible('typing work!s')
                terminal.send('\x05\x15')  # Ctrl+E, Ctrl+U clears the whole draft.
                terminal.settle()
                check_unicode_paste(terminal)
                if not continuing:
                    # /clear records a context reset, giving -c a persisted
                    # session to resume without calling a model.
                    terminal.send('/clear')
                    terminal.settle()
                    terminal.send('\r')
                    terminal.visible('Conversation cleared.')
                    terminal.settle()
                terminal.send('/quit')
                terminal.settle()
                terminal.send('\r')
                terminal.expect_clean_exit()
                print(f'PASS native {"continue" if continuing else "fresh launch"}: '
                      'late BEL reply, typing, split Unicode paste, arrow editing, quit', flush=True)
            except Exception:
                print(screen_text(terminal.output, 100, 28))
                raise
            finally:
                terminal.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    smoke(parser.parse_args().binary.resolve())
