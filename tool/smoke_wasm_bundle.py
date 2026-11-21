#!/usr/bin/env python3
"""Check release binaries with fixture data and a loopback model stub."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
from queue import Empty, Queue
import subprocess
import sys
import tempfile
import threading
import time

sys.dont_write_bytecode = True
from smoke_engine2 import ANSI, Terminal


class ModelStub(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        content = request['messages'][-1]['content']
        prompt = content if isinstance(content, str) else ''.join(
            block['text'] for block in content if block['type'] == 'text')
        calls = {
            'Wasm bundle round trip': ('write', {'filePath': 'note.txt', 'content': 'café\n'}),
            'Read fixture config': ('read', {'filePath': 'fixture.toml'}),
            'Read fixture session log': ('read', {'filePath': '.tina/sessions.jsonl'}),
        }
        if prompt in calls:
            name, arguments = calls[prompt]
            call_id = 'fixture-' + prompt.split()[-1]
            block = {'type': 'tool_use', 'id': call_id, 'name': name, 'input': {}}
            delta = {'type': 'input_json_delta', 'partial_json': json.dumps(arguments)}
            stop_reason = 'tool_use'
        else:
            block = {'type': 'text', 'text': ''}
            delta = {'type': 'text_delta', 'text': 'Fixture response'}
            stop_reason = 'end_turn'
        events = [
            {'type': 'message_start', 'message': {'id': 'fixture', 'role': 'assistant',
             'content': [], 'usage': {'input_tokens': 1, 'output_tokens': 0}}},
            {'type': 'content_block_start', 'index': 0, 'content_block': block},
            {'type': 'content_block_delta', 'index': 0, 'delta': delta},
            {'type': 'content_block_stop', 'index': 0},
            {'type': 'message_delta', 'delta': {'stop_reason': stop_reason},
             'usage': {'output_tokens': 2}},
            {'type': 'message_stop'},
        ]
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for event in events:
            self.wfile.write(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n".encode())


def check_engine(host, workspace, config, store, env):
    target = workspace / 'note.txt'
    original = 'original content longer than the replacement\n'
    target.write_text(original, encoding='utf-8')
    with tempfile.TemporaryFile(mode='w+', encoding='utf-8') as stderr, subprocess.Popen(
        [str(host), '--headless', f'--config-file={config}', f'--store-file={store}'],
        cwd=workspace, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=stderr, text=True, encoding='utf-8',
    ) as process:
        lines = Queue()

        def read_output():
            for line in process.stdout:
                lines.put(line)
            lines.put(None)

        threading.Thread(target=read_output, daemon=True).start()

        def send(**request):
            process.stdin.write(json.dumps(request) + '\n')
            process.stdin.flush()

        def expect(predicate):
            deadline = time.monotonic() + 45
            while True:
                try:
                    line = lines.get(timeout=max(0, deadline - time.monotonic()))
                except Empty as error:
                    raise AssertionError('runner stopped emitting events') from error
                assert line is not None, 'runner exited early'
                event = json.loads(line)
                assert event['type'] != 'error', event
                if predicate(event):
                    return event

        def completed(id):
            receipt = expect(lambda e: e['type'] == 'receipt' and e['id'] == id
                             and e['state'] in ('completed', 'failed', 'cancelled'))
            assert receipt['state'] == 'completed', receipt

        def blocks(event):
            content = event.get('entry', {}).get('message', {}).get('content')
            return content if isinstance(content, list) else []

        try:
            ready = expect(lambda e: e['type'] == 'ready')
            send(op='submit', id='write', line='Wasm bundle round trip')
            approval = expect(lambda e: e['type'] == 'approval'
                              or (e['type'] == 'receipt'
                                  and e['state'] in ('completed', 'failed', 'cancelled')))
            assert approval['type'] == 'approval', 'the write did not request approval'
            assert target.read_text(encoding='utf-8') == original, 'write ran before approval'
            send(op='approve', id=approval['id'], decision='allow')
            completed('write')
            assert target.read_text(encoding='utf-8') == 'café\n'
            print('PASS default approval and UTF-8 overwrite', flush=True)

            for id, prompt in [('config', 'Read fixture config'), ('store', 'Read fixture session log')]:
                send(op='submit', id=id, line=prompt)
                call_id = 'fixture-' + prompt.split()[-1]
                result = expect(lambda e: e['type'] == 'approval' or any(
                    block.get('tool_use_id') == call_id for block in blocks(e)))
                assert result['type'] != 'approval', f'{id} should be protected before approval'
                block = next(b for b in blocks(result) if b.get('tool_use_id') == call_id)
                assert block.get('is_error') and 'protected path' in str(block['content']), block
                completed(id)
            send(op='shutdown')
            assert process.wait(timeout=30) == 0
            rows = [json.loads(line) for line in store.read_text(encoding='utf-8').splitlines()]
            assert any(row['id'] == ready['session'] and row['t'] == 'marker' for row in rows)
            print('PASS private fixture paths and persisted session', flush=True)
            return ready['session']
        except Exception:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            stderr.seek(0)
            print(stderr.read()[-6000:], file=sys.stderr)
            raise


def check_resume(cli, host, workspace, config, env, session):
    terminal = Terminal(
        [str(cli), '--engine', 'wasm', '--engine-host', str(host), '--continue',
         '--backend', 'ansi', '--config', str(config), '--cwd', str(workspace)],
        env, 100, 28, cwd=workspace,
    )
    try:
        terminal.expect('Wasm bundle round trip')
        terminal.quit()
        tail = ANSI.sub(b'', terminal.output.rsplit(b'\x1b[?1049l', 1)[-1])
        assert f'--resume {session}'.encode() in tail, tail.decode(errors='replace')
        print('PASS native CLI resumes the saved Wasm session', flush=True)
    except Exception:
        print(ANSI.sub(b'', terminal.output[-6000:]).decode(errors='replace'), file=sys.stderr)
        raise
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cli', type=Path)
    parser.add_argument('host', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tina-wasm-smoke-') as directory, \
            ThreadingHTTPServer(('127.0.0.1', 0), ModelStub) as server:
        root = Path(directory).resolve()
        home = root / 'home'
        home.mkdir()
        workspace = root / 'workspace'
        workspace.mkdir()
        store = workspace / '.tina' / 'sessions.jsonl'
        (workspace / '.tina').mkdir()
        # A preexisting empty log makes protected-path denial observable
        # before the guest flushes buffered rows at shutdown.
        store.touch()
        config = workspace / 'fixture.toml'
        config.write_text(
            'version = 1\n[default]\nprovider = "local"\nmodel = "smoke"\n'
            '[providers.local]\nwire = "anthropic"\napi_key = "fixture-key"\n'
            f'base_url = "http://127.0.0.1:{server.server_port}/v1"\n'
            'models = ["smoke|Smoke model"]\n', encoding='utf-8')
        env = {'PATH': os.defpath, 'HOME': str(home), 'TERM': 'xterm-256color',
               'LANG': 'en_US.UTF-8'}
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            session = check_engine(args.host.resolve(), workspace, config, store, env)
            check_resume(args.cli.resolve(), args.host.resolve(), workspace, config, env, session)
        finally:
            server.shutdown()
            worker.join()


if __name__ == '__main__':
    main()
