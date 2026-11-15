#!/usr/bin/env python3
"""Verify coordinates and mouse release across the actual C input pump."""
import argparse
import json
import os
from pathlib import Path
import tempfile
import time
import sys

sys.dont_write_bytecode = True

from smoke_engine2 import Terminal


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    package = root / 'packages/tina_console'
    with tempfile.TemporaryDirectory(prefix='tina-mouse-input-') as directory:
        output = Path(directory) / 'events.json'
        env = dict(os.environ, TERM='xterm-256color')
        terminal = Terminal([args.dart, 'run',
            str(package / 'test/fixtures/mouse_input_probe.dart'), str(output)],
            env, 80, 24, cwd=package)
        try:
            deadline = time.monotonic() + 35
            while not Path(str(output) + '.ready').exists():
                terminal.read()
                if time.monotonic() > deadline:
                    raise AssertionError('native mouse probe did not start: ' + terminal.output.decode(errors='replace'))
            # SGR positions are one based; public input events are zero based.
            terminal.send('\x1b[<0;9;5M')
            terminal.send('\x1b[<32;10;20M')
            terminal.send('\x1b[<0;10;20m')
            try:
                terminal.expect_clean_exit()
            except AssertionError as error:
                raise AssertionError(f'{error}; events={output.read_text() if output.exists() else "none"}; '
                    + terminal.output.decode(errors='replace')) from error
            events = json.loads(output.read_text())
            assert events[0] == {'action': 'press', 'row': 4, 'col': 8}, events
            assert events[-1] == {'action': 'release', 'row': 19, 'col': 9}, events
            assert any(event['row'] == 19 and event['col'] == 9 for event in events[1:-1]), events
            print('Native mouse press, drag coordinates and release passed.')
        finally:
            terminal.close()


if __name__ == '__main__':
    main()
