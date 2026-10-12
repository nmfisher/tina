#!/usr/bin/env python3
"""Run the real CLI against a local stub with isolated HOME/workspace/store.

Build AOT from apps/tina_cli:
  dart build cli -t tool/perf/startup_stages.dart -o build/perf/stages
Then: python3 apps/tina_cli/tool/startup_bench.py --dart /path/to/dart --runs 5
Parent receipt timestamps include launch, JIT and pipe delivery. Child durations
measure the actual operations. These are warm filesystem-cache measurements.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import statistics
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = Path(__file__).resolve().parent.parent


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        reply = 'ok' if body.get('tools') else 'VERDICT: yes — completed'
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for delta, finish in [({'role': 'assistant'}, None),
                              ({'content': reply}, None), ({}, 'stop')]:
            data = {'id': 'bench', 'object': 'chat.completion.chunk',
                    'choices': [{'index': 0, 'delta': delta,
                                 'finish_reason': finish}]}
            self.wfile.write(f'data: {json.dumps(data)}\n\n'.encode())
            self.wfile.flush()
        self.wfile.write(b'data: [DONE]\n\n')
        self.wfile.flush()


def run_one(command, args, env):
    start = time.perf_counter_ns()
    process = subprocess.Popen(command + args, cwd=REPO, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True)
    received, errors = {}, []

    def read_stderr():
        for line in process.stderr:
            if line.startswith('TINA_PERF '):
                name = line.strip().split(' ', 1)[1]
                received.setdefault(name, (time.perf_counter_ns() - start) / 1e6)
            else:
                errors.append(line)

    reader = threading.Thread(target=read_stderr)
    reader.start()
    # Read stdout concurrently with stderr, with a bounded child lifetime.
    output = []
    output_reader = threading.Thread(target=lambda: output.extend(process.stdout))
    output_reader.start()
    try:
        process.wait(timeout=120)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise
    finally:
        reader.join()
        output_reader.join()
    if process.returncode:
        raise RuntimeError(''.join(errors) + ''.join(output))
    row = json.loads(next(line for line in reversed(output) if line.startswith('{')))
    if row['exit_code'] or 'first-text' not in received:
        raise RuntimeError(f'no successful text response: {row}')
    row['parent_ms'] = received
    row['wall_ms'] = (time.perf_counter_ns() - start) / 1e6
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--builds', nargs='+', choices=['jit', 'aot'], default=['jit', 'aot'])
    parser.add_argument('--aot', type=Path,
                        default=REPO / 'build/perf/stages/bundle/bin/startup_stages')
    parser.add_argument('--out', type=Path, default=REPO / 'build/perf/startup.json')
    options = parser.parse_args()
    if options.runs < 1:
        parser.error('--runs must be positive')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    rows = []
    # Put scratch data on the workspace filesystem being measured.
    scratch = REPO / 'build/perf'
    scratch.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='startup-', dir=scratch) as temp:
            root = Path(temp)
            home, workspace = root / 'home', root / 'workspace'
            home.mkdir()
            workspace.mkdir()
            config = home / 'config'
            config.write_text(f'''version = 1
[default]
provider = "stub"
model = "stub-1"
[providers.stub]
wire = "openai"
base_url = "http://127.0.0.1:{server.server_port}"
api_key = "stub-key"
models = ["stub-1|Stub model"]
''')
            env = dict(os.environ, HOME=str(home))
            # Changing HOME must not accidentally download a fresh pub cache.
            env['PUB_CACHE'] = os.environ.get('PUB_CACHE', str(Path.home() / '.pub-cache'))
            for build in options.builds:
                command = ([options.dart, 'run', str(REPO / 'tool/perf/startup_stages.dart')]
                           if build == 'jit' else [str(options.aot.resolve())])
                base = ['--config', str(config), '--cwd', str(workspace), '--goal', 'hi']
                seed = root / f'{build}-seed.db'
                # Closed CLI checkpoints the seed. Copy only after successful exit.
                seeded = run_one(command, base + ['--store', str(seed)], env)
                saved = sqlite3.connect(f'file:{seed}?mode=ro', uri=True)
                try:
                    seed_entries = saved.execute(
                        "SELECT COUNT(*) FROM log_registry WHERE json_extract(payload, '$.slice') = ?",
                        (seeded['session_id'],)).fetchone()[0]
                finally:
                    saved.close()
                for mode in ['fresh', 'resume']:
                    for i in range(options.runs):
                        store = root / f'{build}-{mode}-{i}.db'
                        args = base + ['--store', str(store)]
                        if mode == 'resume':
                            shutil.copyfile(seed, store)
                            args += ['--resume', seeded['session_id']]
                        row = run_one(command, args, env)
                        row.update(build=build, mode=mode, sample=i)
                        expected = 0 if mode == 'fresh' else seed_entries
                        if row['seed_entries'] != expected:
                            raise RuntimeError('sample history differs from its seed')
                        rows.append(row)
                        print(f"{build} {mode} {i + 1}: ready={row['parent_ms']['assembly-ready']:.1f}ms "
                              f"text={row['parent_ms']['first-text']:.1f}ms "
                              f"commits={row['pre_request_commits']}", flush=True)
    finally:
        server.shutdown()
        server.server_close()
    options.out.parent.mkdir(parents=True, exist_ok=True)
    options.out.write_text(json.dumps(rows, indent=2) + '\n')
    for build in options.builds:
        for mode in ['fresh', 'resume']:
            group = [r for r in rows if r['build'] == build and r['mode'] == mode]
            def summary(values):
                values = list(values)
                return {'min': min(values), 'median': statistics.median(values), 'max': max(values)}
            metrics = {name: summary(r['parent_ms'][name] for r in group)
                       for name in ['assembly-ready', 'provider-send', 'first-text']}
            metrics['max_event_loop_gap_ms'] = summary(r['max_event_loop_gap_ms'] for r in group)
            print(build, mode, json.dumps(metrics))


if __name__ == '__main__':
    main()
