#!/usr/bin/env python3
"""Check that captured process output stays in its owning UI on a real PTY."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import re
import signal

sys.dont_write_bytecode = True
from smoke_engine2 import ModelStub, Terminal
from smoke_classification_panel import terminal_grid


class OutputStub(ModelStub):
    process_command = ''

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.requests.append(request)
        messages = request['messages']
        completed = any(block.get('type') == 'tool_result'
                        for block in messages[-1]['content'])
        text = json.dumps(messages[-1]['content'])
        name = 'bash'
        arguments = {'command': self.process_command}
        if 'pipeline output' in text:
            arguments = {'command': '/bin/sh flood.sh 2>&1 | tail -45'}
        if 'background output' in text:
            arguments = {'command': '/bin/sh background.sh', 'background': True}
        if 'inspect job' in text:
            name = 'process'
            job = re.search(r'Job ID: ([^ .\\\n]+)', json.dumps(messages)).group(1)
            arguments = {'job_id': job, 'action': 'wait', 'wait_ms': 3000}
        content = ({'type': 'text', 'text': 'OUTPUT_TEST_COMPLETE'} if completed else
                   {'type': 'tool_use', 'id': 'output-probe', 'name': name,
                    'input': arguments})
        judge = request.get('output_config', {}).get('format') is not None
        if judge:
            completed = True
            content = {'type': 'text', 'text': json.dumps({'decision': 'ALLOW', 'reason': ''})}
        if not completed and 'mcp output' in text:
            name = next(tool['name'] for tool in request['tools']
                        if tool['description'] == '[MCP fixture] Fixture mutate')
            content = {'type': 'tool_use', 'id': 'output-probe', 'name': name,
                       'input': {'value': 'MCP_CAPTURED_RESULT'}}
        events = [
            {'type': 'message_start', 'message': {
                'id': 'output-probe', 'role': 'assistant', 'content': [],
                'usage': {'input_tokens': 1, 'output_tokens': 0}}},
            {'type': 'content_block_start', 'index': 0, 'content_block':
                {'type': 'text', 'text': ''} if completed else
                {'type': 'tool_use', 'id': 'output-probe', 'name': name, 'input': {}}},
            {'type': 'content_block_delta', 'index': 0, 'delta':
                {'type': 'text_delta', 'text': content['text']} if completed else
                {'type': 'input_json_delta', 'partial_json': json.dumps(content['input'])}},
            {'type': 'content_block_stop', 'index': 0},
            {'type': 'message_delta', 'delta': {
                'stop_reason': 'end_turn' if completed else 'tool_use'},
                'usage': {'output_tokens': 1}},
            {'type': 'message_stop'},
        ]
        response = ''.join(f'event: {e["type"]}\ndata: {json.dumps(e)}\n\n'
                           for e in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)


def smoke(launcher, endpoint, backend, panels):
    with tempfile.TemporaryDirectory(prefix='tina-process-output-') as directory:
        root = Path(directory).resolve()
        config = root / 'config'
        plugins = ['tina/system-instruction', 'tina/providers', 'tina/mode',
                   'tina/tools', 'tina/approvals', 'tina/chat-tui',
                   'tina/activity-tui', 'tina/shell', 'tina/mcp']
        if panels:
            plugins.append('tina/panels-tui')
        fixture = Path(__file__).resolve().parent.parent / 'packages/plugins/tina_mcp/test/fixtures/server.py'
        mcp_events = root / 'mcp-events.jsonl'
        (root / 'mcp.sh').write_text(
            'printf "MCP_TTY_LEAK\\n" >/dev/tty\n'
            'printf "MCP_LOG_STDERR\\n" >&2\n'
            f'exec {json.dumps(sys.executable)} {json.dumps(str(fixture))} {json.dumps(str(mcp_events))}\n')
        config.write_text(
            '[default]\nprovider="local"\nmodel="smoke"\n'
            '[providers.local]\nwire="anthropic"\n'
            f'base_url="{endpoint}"\napi_key="fixture-key"\n'
            'models=["smoke|Smoke model"]\n'
            f'[plugins]\nenabled={json.dumps(plugins)}\nselection_version=2\n'
            '[mcp.servers.fixture]\ncommand="/bin/sh"\nargs=["mcp.sh"]\n')
        # Generate output markers only in the subprocess, absent from the draft.
        script = root / 'flood.sh'
        script.write_text('i=0; while [ "$i" -lt 1000 ]; do\n'
                          'printf "PROCESS_STDOUT_%04d\\t%s\\n" "$i" "long output line"\n'
                          'printf "PROCESS_STDERR_%04d\\r%s\\n" "$i" "error output line" >&2\n'
                          'i=$((i+1)); done\n'
                          'printf "Warning: Encountered 20 render/write errors.\\n" >&2\n'
                          'printf "Build failed: 20 render/write errors.\\n" >&2\n'
                          'printf "DIRECT_TTY_LEAK\\n" >/dev/tty\nexit 3\n')
        (root / 'background.sh').write_text(
            ': > background-ready\n'
            'while [ ! -f background-release ]; do\n'
            'printf "BACKGROUND_STDOUT\\n"; printf "BACKGROUND_STDERR\\n" >&2\n'
            'printf "BACKGROUND_TTY_LEAK\\n" >/dev/tty; sleep 0.05; done\n')
        (root / 'manual.sh').write_text(
            'printf "MANUAL_STDOUT\\n"; printf "MANUAL_STDERR\\n" >&2\n'
            'printf "MANUAL_TTY_LEAK\\n" >/dev/tty; exit 7\n')
        OutputStub.process_command = '/bin/sh flood.sh'
        terminal = Terminal(launcher + ['--config', str(config), '--cwd', str(root),
                            '--backend', backend, '--no-sandbox'],
                            dict(os.environ, HOME=str(root), TERM='xterm-256color',
                                 LANG='en_US.UTF-8'), 120, 28)

        def grid():
            return terminal_grid(terminal, 120, 28)

        def visible(text):
            terminal.wait_for(lambda: text in grid(), f'missing {text!r}', timeout=30)

        def submit(text):
            terminal.send(text)
            terminal.expect_idle()
            return terminal.send('\r')

        def inject_output(data):
            # A macOS PTY can have a full output queue while a repaint is
            # pending. A blocking write to the slave would stop this harness
            # draining the master, deadlocking the test itself. Open a separate
            # nonblocking descriptor so the application's own fd flags stay
            # unchanged, and continue draining while injecting the damage.
            descriptor = os.open(os.ttyname(terminal.slave),
                                 os.O_WRONLY | os.O_NONBLOCK | os.O_NOCTTY)
            try:
                deadline = time.monotonic() + 5
                while data and time.monotonic() < deadline:
                    terminal.read()
                    try:
                        data = data[os.write(descriptor, data):]
                    except BlockingIOError:
                        pass
                assert not data, 'fixture could not write terminal damage within 5s'
            finally:
                os.close(descriptor)

        def tool(text, approve=True, auto=False):
            before = len(OutputStub.requests)
            start = submit(text)
            if approve:
                visible('[y] allow once')
                terminal.send('y')
            terminal.wait_for(lambda: len(OutputStub.requests) == before + (3 if auto else 2),
                              'tool did not complete', timeout=30)
            terminal.expect_idle()
            assert b'\n' not in terminal.output[start:], 'raw line breaks escaped positioned painting'
            assert 'DIRECT_TTY_LEAK' not in grid(), 'a child reopened the UI terminal'
            assert 'PROCESS_STDOUT_' not in grid(), 'stdout escaped a folded tool result'
            assert 'PROCESS_STDERR_' not in grid(), 'stderr escaped a folded tool result'
            assert 'Warning: Encountered' not in grid(), 'pipeline output escaped its result'
            assert 'Build failed:' not in grid(), 'pipeline output escaped its result'
            assert 'MCP_TTY_LEAK' not in grid(), 'MCP server reopened the UI terminal'
            assert 'MCP_LOG_STDERR' not in grid(), 'MCP logging bypassed its stderr pipe'
            return [b for m in OutputStub.requests[-1]['messages']
                    for b in m['content'] if b['type'] == 'tool_result'][-1]

        try:
            visible('smoke >')
            result = tool('test process output')
            assert 'PROCESS_STDOUT_0999' in str(result)
            assert 'PROCESS_STDERR_0999' in str(result)
            assert '/dev/tty' in str(result), 'terminal-open failure was not captured'
            result = tool('pipeline output')
            assert 'PROCESS_STDOUT_0999' in str(result)
            assert 'PROCESS_STDERR_0999' in str(result)
            assert 'Build failed:' in str(result)
            submit('/mode auto')
            visible('mode: auto')
            result = tool('pipeline output', approve=False, auto=True)
            assert 'Build failed:' in str(result)
            visible('run command allowed by classifier:')
            submit('/mode ask')
            visible('mode: ask')
            result = tool('background output')
            assert 'Job ID:' in str(result)
            terminal.wait_for(lambda: (root / 'background-ready').exists(),
                              'background subprocess did not start')
            start = len(terminal.output)
            deadline = time.monotonic() + 0.4
            while time.monotonic() < deadline:
                terminal.read()
            assert b'\n' not in terminal.output[start:], 'background output reached the UI terminal'
            assert 'BACKGROUND_' not in grid(), 'detached job output escaped into the transcript'
            (root / 'background-release').touch()
            result = tool('inspect job', approve=False)
            assert 'BACKGROUND_STDOUT' in str(result)
            assert 'BACKGROUND_STDERR' in str(result)
            assert 'BACKGROUND_TTY_LEAK' not in grid()
            result = tool('mcp output')
            assert 'MCP_CAPTURED_RESULT' in str(result)
            assert mcp_events.exists(), 'MCP never initialized'
            # Manual shell intentionally displays captured output in the UI.
            before = len(OutputStub.requests)
            start = submit('!/bin/sh manual.sh')
            visible('MANUAL_STDOUT')
            visible('MANUAL_STDERR')
            visible('exit code: 7')
            terminal.expect_idle()
            assert b'\n' not in terminal.output[start:], 'manual shell output bypassed row painting'
            assert 'MANUAL_TTY_LEAK' not in grid()
            assert len(OutputStub.requests) == before, 'manual shell called the model'
            # An already-running outside watcher can hold a terminal descriptor
            # opened before Tina starts. Simulate that write, then request the
            # same resize repaint used by the application without changing size.
            before_damage = grid()
            inject_output(b'\x1b[10;10HEXTERNAL_WATCHER_OUTPUT')
            visible('EXTERNAL_WATCHER_OUTPUT')
            os.kill(terminal.process.pid, signal.SIGWINCH)
            terminal.wait_for(lambda: grid() == before_damage,
                              'resize repaint left external process output on screen', timeout=5)
            inject_output(b'\x1b[10;10HEXTERNAL_WATCHER_OUTPUT')
            visible('EXTERNAL_WATCHER_OUTPUT')
            terminal.send('\x0c')
            terminal.wait_for(lambda: 'EXTERNAL_WATCHER_OUTPUT' not in grid(),
                              'Ctrl+L left external process output on screen', timeout=5)
            terminal.quit()
            print(f'PASS process output {backend}, panels={panels}: '
                  'flood, pipeline/classifier, direct tty, background, MCP and manual shell', flush=True)
        except Exception:
            print(grid(), flush=True)
            raise
        finally:
            terminal.close()


def main():
    parser = argparse.ArgumentParser()
    launch = parser.add_mutually_exclusive_group(required=True)
    launch.add_argument('--dart')
    launch.add_argument('--binary')
    parser.add_argument('--backend', choices=('ansi', 'notcurses'))
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), OutputStub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        launcher = ([str(Path(args.binary).resolve())] if args.binary else
                    [args.dart, 'run', 'bin/tina.dart'])
        for backend in ([args.backend] if args.backend else ('ansi', 'notcurses')):
            for panels in (False, True):
                smoke(launcher, f'http://127.0.0.1:{server.server_port}', backend, panels)
    finally:
        server.shutdown()


if __name__ == '__main__':
    main()
