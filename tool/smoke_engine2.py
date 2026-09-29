#!/usr/bin/env python3
"""Run the engine2 entry point on a controlling PTY with a local model stub.

No API credentials or external network. Checks startup, slash completion,
streaming, resize, cancellation/retry, persistence/resume, and clean shutdown.
Run from any directory: python3 tool/smoke_engine2.py [--dart /path/to/dart]
"""

import argparse
import errno
import fcntl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import shutil
import struct
import subprocess
import tempfile
import termios
import threading
import time


PACKAGE = Path(__file__).resolve().parents[1] / "packages/tina_tui"
ANSI = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b[78]")


class ModelStub(BaseHTTPRequestHandler):
    requests = []
    auth_headers = []
    approval_target = None
    release_stream = threading.Event()
    release_cancelled = threading.Event()

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append(request)
        self.auth_headers.append((self.headers.get("x-api-key"), self.headers.get("authorization")))
        prompt = request['messages'][-1]['content']
        streaming = 'terminal smoke' in json.dumps(prompt)
        cancelling = 'cancel this' in json.dumps(prompt)
        prefix = 'streaming prefix ' if streaming else 'cancel pending ' if cancelling else ''
        events = [
            {"type": "message_start", "message": {"id": "smoke", "role": "assistant",
             "content": [], "usage": {"input_tokens": 1, "output_tokens": 0}}},
            {"type": "content_block_start", "index": 0,
             "content_block": {"type": "text", "text": ""}},
            {"type": "content_block_delta", "index": 0,
             "delta": {"type": "text_delta", "text": "draft answer" if "draft" in json.dumps(prompt) else "smoke answer"}},
            {"type": "content_block_stop", "index": 0},
            {"type": "message_delta", "delta": {"stop_reason": "end_turn"},
             "usage": {"output_tokens": 2}},
            {"type": "message_stop"},
        ]
        if 'run cancellable tool' in json.dumps(prompt):
            events[1] = {"type": "content_block_start", "index": 0,
                         "content_block": {"type": "tool_use", "id": "bash-smoke",
                                           "name": "bash", "input": {}}}
            events[2] = {"type": "content_block_delta", "index": 0,
                         "delta": {"type": "input_json_delta", "partial_json": json.dumps({
                             "command": "(sleep 2; echo leaked > cancel-leak) & echo subprocess-live; wait"})}}
            events[4]['delta']['stop_reason'] = 'tool_use'
        if 'approve this' in json.dumps(prompt):
            events[1] = {"type": "content_block_start", "index": 0,
                         "content_block": {"type": "tool_use", "id": "write-smoke",
                                           "name": "write", "input": {}}}
            events[2] = {"type": "content_block_delta", "index": 0,
                         "delta": {"type": "input_json_delta", "partial_json": json.dumps({
                             "filePath": str(self.approval_target), "content": "approved"})}}
            events[4]['delta']['stop_reason'] = 'tool_use'
        for trigger, name, arguments in [
            ('edit example', 'edit', {'filePath': 'preview.txt', 'oldString': 'before', 'newString': 'after'}),
            ('conflict example', 'edit', {'filePath': 'preview.txt', 'oldString': 'missing text', 'newString': 'never applied'}),
            ('delegate example', 'spawn_subagent', {'prompt': 'child example'}),
        ]:
            if trigger in json.dumps(prompt):
                events[1] = {"type": "content_block_start", "index": 0,
                             "content_block": {"type": "tool_use", "id": trigger.replace(' ', '-'),
                                               "name": name, "input": {}}}
                events[2] = {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "input_json_delta", "partial_json": json.dumps(arguments)}}
                events[4]['delta']['stop_reason'] = 'tool_use'
        def encode(items):
            return "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in items).encode()
        first = events[:2] + ([{"type": "content_block_delta", "index": 0,
                  "delta": {"type": "text_delta", "text": prefix}}] if prefix else [])
        first_bytes, last_bytes = encode(first), encode(events[2:])
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(first_bytes) + len(last_bytes)))
        self.end_headers()
        try:
            self.wfile.write(first_bytes)
            self.wfile.flush()
            if streaming:
                assert self.release_stream.wait(30), 'stream was never released'
            if cancelling:
                assert self.release_cancelled.wait(30), 'cancelled stream was never released'
            self.wfile.write(last_bytes)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass  # Cancelling a turn closes the client request.



class Terminal:
    def __init__(self, command, env, columns, rows):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        self.original_modes = termios.tcgetattr(self.master)
        self.output = bytearray()
        self.process = subprocess.Popen(
            command, cwd=PACKAGE.parent.parent, env=env,
            stdin=self.slave, stdout=self.slave, stderr=self.slave,
            start_new_session=True,
            preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0),
        )

    def read(self):
        if select.select([self.master], [], [], 0.05)[0]:
            try:
                self.output.extend(os.read(self.master, 65536))
            except OSError as error:
                if error.errno != errno.EIO:
                    raise

    def expect(self, text, start=0):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            self.read()
            if text.encode() in ANSI.sub(b"", self.output[start:]):
                return
            if self.process.poll() is not None:
                break
        raise AssertionError(f"did not see {text!r}")

    def send(self, text):
        start = len(self.output)
        os.write(self.master, text.encode())
        return start

    def resize(self, columns, rows):
        start = len(self.output)
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        os.kill(self.process.pid, signal.SIGWINCH)
        return start

    def quit(self):
        self.send("/quit\r")
        deadline = time.monotonic() + 8
        while self.process.poll() is None and time.monotonic() < deadline:
            self.read()
        assert self.process.poll() == 0, "app did not exit cleanly with stdin still open"
        self.read()
        assert b"\x1b[?1049l" in self.output, "alternate screen was not restored"
        restored = termios.tcgetattr(self.master)
        modes = termios.ECHO | termios.ICANON
        assert restored[3] & modes == self.original_modes[3] & modes, "echo/line mode changed"

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait()
        os.close(self.master)
        os.close(self.slave)


def smoke(launcher, endpoint, columns, rows):
    with tempfile.TemporaryDirectory(prefix="tina-engine2-smoke-") as directory:
        root = Path(directory)
        config = root / "config"
        # Exercise the real background status without contacting GitHub.
        release_cache = root / '.tina' / 'cache' / 'latest_release.json'
        release_cache.parent.mkdir(parents=True)
        release_cache.write_text(json.dumps({
            'tag': 'v999.0.0', 'release_url': 'https://example.test/release', 'assets': {}}))
        config.write_text('version = 1\n[default]\nprovider = "local-smoke"\nmodel = "smoke"\n'
                          '[providers.local-smoke]\nwire = "anthropic"\n'
                          f'base_url = "{endpoint}"\napi_key = "config-smoke-key"\n'
                          'models = ["smoke|Smoke model"]\n'
                          f'[theme]\nvariant = "{"dark" if rows == 10 else "light" if rows == 24 else "default"}"\n')
        workspace = root / 'workspace'
        workspace.mkdir()
        (workspace / 'preview.txt').write_text('before\n')
        ModelStub.approval_target = root / 'outside-the-workspace' / 'permission-target.txt'
        ModelStub.approval_target.parent.mkdir()
        store = root / "sessions.jsonl"
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
               "HOME": str(root), "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
               "TINA_LLM_ENDPOINT": endpoint, "TINA_LLM_TOKEN": "local-smoke-only"}
        command = launcher + ["--config", str(config),
                   "--cwd", str(workspace), "--store", str(store)]
        request_start = len(ModelStub.requests)
        ModelStub.release_stream.clear()
        ModelStub.release_cancelled.clear()
        terminal = Terminal(command, env, columns, rows)
        try:
            terminal.expect("smoke > ")
            if rows in (10, 24):
                background = b'48;5;234' if rows == 10 else b'48;5;255'
                assert background in terminal.output, 'theme did not set the application background'
            terminal.expect("mode: normal")
            terminal.expect("update ⬆ v999.0.0 · /update")
            start = terminal.send("\x1b[Z")
            terminal.expect("mode: read-only", start)
            start = terminal.send("\x1b[Z")
            terminal.expect("mode: normal", start)
            start = terminal.send("/m")
            terminal.expect("/mode", start)
            start = terminal.send("ode read-only\r")
            terminal.expect("mode: read-only", start)
            # The editor diffs its rows; an unchanged prompt emits no bytes.
            time.sleep(0.05)
            start = terminal.send("terminal smoke\r")
            # The provider is blocked: text must be visible before completion.
            terminal.expect("streaming prefix", start)
            start = terminal.resize(100, 20)
            terminal.expect("streaming prefix", start)
            # Submitted prompts queue behind the stalled turn; unfinished text
            # survives both queued turns and is completed at the idle prompt.
            terminal.send('queued one\rqueued two\rdra')
            time.sleep(0.1)
            assert len(ModelStub.requests) == request_start + 1, 'queued input ran concurrently'
            ModelStub.release_stream.set()
            terminal.expect("smoke answer", start)
            deadline = time.monotonic() + 10
            while len(ModelStub.requests) < request_start + 3 and time.monotonic() < deadline:
                terminal.read()
            assert len(ModelStub.requests) == request_start + 3, 'queued turns did not drain'
            assert 'queued one' in json.dumps(ModelStub.requests[request_start + 1]['messages'][-1])
            assert 'queued two' in json.dumps(ModelStub.requests[request_start + 2]['messages'][-1])
            time.sleep(0.2)
            start = terminal.send('ft\r')
            terminal.expect('draft answer', start)
            assert 'draft' in json.dumps(ModelStub.requests[request_start + 3]['messages'][-1])
            time.sleep(0.1)
            start = terminal.send("cancel this\r")
            terminal.expect("cancel pending", start)
            start = terminal.send("\x1b")
            terminal.expect(' est', start)
            terminal.expect("cancelled: escape", start)
            # A later turn must work even while the cancelled server is stalled.
            time.sleep(0.1)
            start = terminal.send("after cancel\r")
            terminal.expect("smoke answer", start)
            ModelStub.release_cancelled.set()
            time.sleep(0.1)
            start = terminal.send('/mode normal\r')
            terminal.expect('mode: normal', start)
            terminal.resize(columns, rows)
            time.sleep(0.1)
            start = terminal.send('approve this\r')
            terminal.expect('Write outside the project', start)
            start = terminal.send('\t')
            terminal.expect('Details', start)
            start = terminal.resize(40, 8)
            terminal.expect('Details', start)
            # Enter in details returns to choices; it must not approve.
            start = terminal.send('\r')
            terminal.expect('[x] allow always', start)
            assert not ModelStub.approval_target.exists()
            terminal.send('\x1b[B')
            time.sleep(0.05)
            start = terminal.send('\x1b[B')
            terminal.expect('[x] deny', start)
            start = terminal.send('\r')
            terminal.expect('smoke answer', start)
            assert not ModelStub.approval_target.exists(), 'denied write landed'
            time.sleep(0.1)
            start = terminal.send('approve this\r')
            terminal.expect('Write outside the project', start)
            # A remembered grant covers the atomic write's temp/rename steps.
            terminal.expect('[x] allow always', start)
            start = terminal.send('\r')
            terminal.expect('smoke answer', start)
            assert ModelStub.approval_target.read_text() == 'approved'
            time.sleep(0.1)
            start = terminal.send('run cancellable tool\r')
            terminal.expect('run command', start)
            terminal.expect('[x] allow always', start)
            terminal.resize(100, 30)
            start = terminal.send('\r')
            time.sleep(0.05)
            # Browsing during execution must not cancel or submit input.
            start = terminal.send('\x1bOS')
            terminal.expect('Activity', start)
            start = terminal.send('\r')
            terminal.expect('Call: bash-smoke', start)
            terminal.expect('Live output', start)
            terminal.expect('subprocess-live', start)
            terminal.send('\x1bOS')
            time.sleep(0.05)
            start = terminal.send('\x1b')
            terminal.expect('cancelled: escape', start)
            time.sleep(0.1)
            after_count = len(ModelStub.requests)
            start = terminal.send('after subprocess\r')
            deadline = time.monotonic() + 10
            while len(ModelStub.requests) < after_count + 1 and time.monotonic() < deadline:
                terminal.read()
            assert len(ModelStub.requests) == after_count + 1
            terminal.expect('smoke answer', start)
            # Drain repaint output while waiting for any leaked descendant.
            deadline = time.monotonic() + 2.2
            while time.monotonic() < deadline:
                terminal.read()
            assert not (workspace / 'cancel-leak').exists(), 'cancelled descendant survived'
            terminal.resize(80, 24)
            count_before_edit = len(ModelStub.requests)
            start = terminal.send('edit example\r')
            deadline = time.monotonic() + 10
            while len(ModelStub.requests) < count_before_edit + 2 and time.monotonic() < deadline:
                terminal.read()
            assert len(ModelStub.requests) == count_before_edit + 2
            terminal.expect('smoke answer', start)
            start = terminal.send('\x1bOS')
            terminal.expect('Activity', start)
            start = terminal.send('\r')
            terminal.expect('- before', start)
            terminal.expect('+ after', start)
            terminal.send('\x1bOS')
            assert (workspace / 'preview.txt').read_text() == 'after\n'
            time.sleep(0.1)
            count_before_conflict = len(ModelStub.requests)
            start = terminal.send('conflict example\r')
            deadline = time.monotonic() + 10
            while len(ModelStub.requests) < count_before_conflict + 2 and time.monotonic() < deadline:
                terminal.read()
            assert len(ModelStub.requests) == count_before_conflict + 2
            terminal.expect('failed', start)
            terminal.expect('smoke answer', start)
            assert (workspace / 'preview.txt').read_text() == 'after\n'
            time.sleep(0.1)
            start = terminal.send('/activity\r')
            terminal.expect('Activity', start)
            start = terminal.send('\r')
            terminal.expect('Recovery:', start)
            start = terminal.resize(20, 6)
            terminal.expect('Activity', start)
            terminal.send('\x1bOS')
            terminal.resize(80, 24)
            time.sleep(0.1)
            start = terminal.send('delegate example\r')
            terminal.expect('depth 1', start)
            terminal.expect('smoke answer', start)
            time.sleep(0.1)
            start = terminal.send('/settings\r')
            terminal.expect('Settings', start)
            start = terminal.resize(80, 10)
            terminal.expect('Settings', start)
            start = terminal.send('\x1b')
            terminal.expect('Settings closed.', start)
            time.sleep(0.1)
            def plugin_checkbox(plugin_id, checked, scope='session', reset=False):
                time.sleep(0.1)
                start = terminal.send('/settings\r')
                terminal.expect('enter select · esc back', start)
                time.sleep(0.1)
                start = terminal.send('Plugins\r')
                terminal.expect('Scope: global', start)
                if scope != 'global':
                    terminal.send('\r')
                    time.sleep(0.1)
                    start = terminal.send(('\x1b[B' * (1 if scope == 'workspace' else 2)) + '\r')
                    terminal.expect('Scope: ' + scope, start)
                terminal.send(plugin_id)
                time.sleep(0.1)
                terminal.read()
                start = terminal.send('\x12' if reset else ' ')
                terminal.expect(('[x] ' if checked else '[ ] ') + plugin_id, start)
                terminal.send('\x1b')
                time.sleep(0.1)
                closed = terminal.send('\x1b')
                terminal.expect('Settings closed.', closed)
                time.sleep(0.1)
                return start

            plugin_checkbox('tina/goals', False)
            plugin_checkbox('tina/goals', True, reset=True)
            plugin_checkbox('tina/activity-tui', False)
            plugin_checkbox('tina/update-tui', False)
            start = plugin_checkbox('tina/update-tui', True, reset=True)
            terminal.expect('update ⬆ v999.0.0', start)
            start = terminal.send('/activity\r')
            terminal.expect('unknown command', start)
            plugin_checkbox('tina/activity-tui', True, reset=True)
            start = terminal.send('\x1bOS')
            terminal.expect('Activity', start)
            terminal.expect('spawn_subagent', start)
            terminal.send('\x1bOS')
            plugin_checkbox('tina/file-resources', True, scope='workspace')
            plugin_checkbox('tina/file-resources', False, scope='workspace')
            local_config = (workspace / '.tina' / 'config').read_text()
            assert 'tina/file-resources' in local_config and 'false' in local_config
            plugin_checkbox('tina/grok-guard', True)
            before_guard = len(ModelStub.requests)
            start = terminal.send('GROK declined\r')
            terminal.expect('Your message contains grok, this is a no-no.', start)
            terminal.expect('[x] Yes', start)
            terminal.expect('[ ] No', start)
            assert len(ModelStub.requests) == before_guard, 'input reached provider before approval'
            start = terminal.send('\x1b[B\r')
            terminal.expect('message declined', start)
            assert len(ModelStub.requests) == before_guard, 'declined input reached provider'
            # Let the modal's key-burst window finish before typing a new line.
            time.sleep(0.1)
            start = terminal.send('grok approved\r')
            terminal.expect('[x] Yes', start)
            start = terminal.send('\r')
            terminal.expect('smoke answer', start)
            assert len(ModelStub.requests) == before_guard + 1
            request_text = json.dumps(ModelStub.requests[-1]['messages'])
            assert 'grok approved' in request_text and 'GROK declined' not in request_text
            time.sleep(0.1)
            plugin_checkbox('tina/grok-guard', False)
            start = terminal.send('grok unguarded\r')
            terminal.expect('smoke answer', start)
            assert len(ModelStub.requests) == before_guard + 2
            time.sleep(0.1)
            # A new interactive panel owns a separate session and request log.
            start = terminal.send('/spawn\r')
            terminal.expect('2: smoke', start)
            time.sleep(0.1)
            before_child = len(ModelStub.requests)
            start = terminal.send('child panel message\r')
            deadline = time.monotonic() + 10
            while len(ModelStub.requests) == before_child and time.monotonic() < deadline:
                terminal.read()
            terminal.expect('smoke answer', start)
            child_request = json.dumps(ModelStub.requests[-1]['messages'])
            assert 'child panel message' in child_request and 'terminal smoke' not in child_request
            time.sleep(0.1)
            terminal.send('\x07\t\r')  # Ctrl+G, Tab, Enter: focus the root.
            time.sleep(0.1)
            before_root = len(ModelStub.requests)
            start = terminal.send('root panel message\r')
            deadline = time.monotonic() + 10
            while len(ModelStub.requests) == before_root and time.monotonic() < deadline:
                terminal.read()
            terminal.expect('smoke answer', start)
            root_request = json.dumps(ModelStub.requests[-1]['messages'])
            assert 'root panel message' in root_request and 'child panel message' not in root_request
            time.sleep(0.1)
            terminal.send('\x17\t\r')  # Ctrl+W also cycles.
            time.sleep(0.1)
            terminal.send('\x18')  # Ctrl+X closes the child and returns home.
            time.sleep(0.1)
            terminal.quit()
            if rows in (10, 24):
                assert b'\x1b[0m\x1b[?1049l' in terminal.output, 'theme leaked on exit'
        except Exception as error:
            print(f'FAIL {columns}x{rows}: {error}', flush=True)
            print(terminal.output[-20000:].decode(errors="replace").replace("\x1b", "<ESC>"), flush=True)
            raise
        finally:
            ModelStub.release_stream.set()
            ModelStub.release_cancelled.set()
            terminal.close()

        listing = subprocess.run(launcher + ["--store", str(store),
                                  "--sessions"], cwd=PACKAGE.parent.parent, env=env,
                                 capture_output=True, text=True, check=True, timeout=30)
        session = next(line.split()[0] for line in listing.stdout.splitlines() if " entries" in line)
        terminal = Terminal(command + ["--resume", session], env, columns, rows)
        try:
            terminal.expect("smoke > ")
            # Restored rows are painted as a viewport, not printed through
            # stdout one by one. Scroll to inspect the retained first turn.
            terminal.send('\x1b[5~' * 80)
            terminal.expect("terminal smoke")
            terminal.expect("streaming prefix smoke answer")
            terminal.send('\x1b[6~' * 80)
            start = terminal.send('\x1bOS')
            terminal.expect('Activity', start)
            terminal.expect('spawn_subagent', start)
            terminal.send('\x1bOS')
            terminal.quit()
        except Exception:
            print(terminal.output.decode(errors="replace").replace("\x1b", "<ESC>"))
            raise
        finally:
            terminal.close()
        # Legacy conversion runs offline; resumed history must not execute its
        # unfinished tool call. The first new turn uses the ordinary loop/store.
        legacy = root / 'archive.jsonl'
        legacy.write_text('\n'.join(json.dumps(m) for m in [
            {'role': 'user', 'content': [{'type': 'text', 'text': 'legacy hello'}]},
            {'role': 'assistant', 'content': [{'type': 'text', 'text': 'legacy reply'}]},
            {'role': 'assistant', 'content': [{'type': 'tool_use', 'id': 'unfinished',
                'name': 'bash', 'input': {'command': 'touch legacy-replayed'}}]},
        ]) + '\n')
        imported = subprocess.run(command + ['--import-sessions', str(legacy)],
                                  cwd=PACKAGE.parent.parent, env=env,
                                  capture_output=True, text=True, check=True, timeout=30)
        assert 'imported: legacy:archive:archive' in imported.stdout
        terminal = Terminal(command + ['--resume', 'legacy:archive:archive'], env, columns, rows)
        try:
            terminal.expect('smoke > ')
            terminal.send('\x1b[5~' * 20)
            terminal.expect('legacy hello')
            terminal.expect('legacy reply')
            terminal.send('\x1b[6~' * 20)
            start = terminal.send('continue imported\r')
            terminal.expect('smoke answer', start)
            assert not (workspace / 'legacy-replayed').exists(), 'import replayed an old tool'
            terminal.quit()
        except Exception:
            print(terminal.output.decode(errors='replace').replace('\x1b', '<ESC>'))
            raise
        finally:
            terminal.close()
        print(f"PASS {columns}x{rows}: prompt, completion, streaming, queued input/draft, resize, cancel/retry, subprocess output/cancellation, approvals, activity/diffs/errors/subagents, settings, scoped plugins, resume, legacy import/continue, clean exit")


def smoke_cli(launcher):
    with tempfile.TemporaryDirectory(prefix="tina-cli-smoke-") as directory:
        root = Path(directory)
        config = root / 'config'
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(root),
               "TERM": "xterm-256color", "LANG": "en_US.UTF-8"}
        for flag, expected in [('--version', 'engine2'), ('--help', '--configure')]:
            result = subprocess.run(launcher + [flag], cwd=PACKAGE.parent.parent,
                                    env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0 and expected in result.stdout
        for shell in ['bash', 'zsh', 'fish']:
            result = subprocess.run(launcher + ['--completion', shell], cwd=PACKAGE.parent.parent,
                                    env=env, capture_output=True, text=True, timeout=30)
            assert result.returncode == 0 and 'tina' in result.stdout
        terminal = Terminal(launcher + ['--configure', '--config', str(config)], env, 80, 10)
        try:
            terminal.expect('Settings')
            start = terminal.send('Default model\r')
            terminal.expect('Default model', start)
            start = terminal.send('Enter model\r')
            terminal.expect('Model ID', start)
            start = terminal.send('fixture-model\r')
            terminal.expect('Default model: fixture-model', start)
            start = terminal.send('Save\r')
            terminal.expect('Settings saved. Run tina to start.', start)
            assert terminal.process.wait(timeout=5) == 0
            assert termios.tcgetattr(terminal.master) == terminal.original_modes, 'setup left raw terminal modes'
            assert 'fixture-model' in config.read_text()
            assert config.stat().st_mode & 0o777 == 0o600
            assert not (root / '.tina' / 'sessions.db').exists(), 'setup created a model session'
        except Exception:
            print(terminal.output.decode(errors='replace').replace('\x1b', '<ESC>'))
            raise
        finally:
            terminal.close()
        print('PASS CLI: version/help, shell completions, first-run settings/save, terminal restoration')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dart", default=shutil.which("dart"))
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()
    if not args.dart and not args.binary:
        parser.error("dart was not found on PATH")
    launcher = [str(args.binary.absolute())] if args.binary else [args.dart, "run", "bin/tina.dart"]
    smoke_cli(launcher)
    server = ThreadingHTTPServer(("127.0.0.1", 0), ModelStub)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for columns, rows in [(80, 10), (80, 24), (120, 30)]:
            smoke(launcher, f"http://127.0.0.1:{server.server_port}", columns, rows)
        assert len(ModelStub.requests) == 72, (
            f"expected 72 model requests, got {len(ModelStub.requests)}; "
            "commands or resume unexpectedly called the model")
        assert all(r["model"] == "smoke" for r in ModelStub.requests)
        assert all(key == "config-smoke-key" and bearer is None for key, bearer in ModelStub.auth_headers)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
