#!/usr/bin/env python3
"""Kill disposable writers around COMMIT and verify WAL recovery.

This checks process crashes and concurrent writers, not power-loss durability.
Run: python3 tool/sqlite_recovery_test.py --dart /path/to/dart
"""
import argparse
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    options = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='tina-recovery-') as temp:
        root = Path(temp)
        # Compile once: concurrent `dart run`s race while copying native assets
        # on macOS. Only the database writers should contend during this test.
        subprocess.run([options.dart, 'build', 'cli', '-t',
                        str(REPO / 'tool/perf/sqlite_batches.dart'), '-o', str(root / 'writer')],
                       cwd=REPO, check=True, capture_output=True, timeout=120)
        command = [str(root / 'writer/bundle/bin/sqlite_batches')]
        for mode in ['before', 'after']:
            db, ready = root / f'{mode}.db', root / f'{mode}.ready'
            with (root / f'{mode}.stderr').open('w+') as errors:
                process = subprocess.Popen(command + [mode, str(db), str(ready)],
                                           cwd=REPO, stdin=subprocess.PIPE,
                                           stdout=subprocess.DEVNULL, stderr=errors,
                                           start_new_session=True)
                try:
                    deadline = time.monotonic() + 90
                    while not ready.exists():
                        if process.poll() is not None or time.monotonic() > deadline:
                            errors.seek(0)
                            raise RuntimeError(f'{mode} writer failed: {errors.read()}')
                        time.sleep(.02)
                    assert Path(str(db) + '-wal').stat().st_size > 0
                finally:
                    # Only this newly created test process group is terminated.
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                    process.stdin.close()
            with sqlite3.connect(db) as recovered:
                assert recovered.execute('PRAGMA integrity_check').fetchone() == ('ok',)
                payloads = [json.loads(row[0]) for row in recovered.execute('SELECT payload FROM entries ORDER BY id')]
                assert payloads[0] == {'baseline': True}
                assert len(payloads) == (1 if mode == 'before' else 1001)
                if mode == 'after':
                    assert [row['seq'] for row in payloads[1:]] == list(range(1000))
            print(f'{mode} commit: integrity and atomic recovery passed', flush=True)

        db = root / 'concurrent.db'
        # Initialize before the two processes race for write locks.
        subprocess.run(command + ['concurrent', str(db), 'seed'], cwd=REPO,
                       check=True, capture_output=True, timeout=90)
        writers = [subprocess.Popen(command + ['concurrent', str(db), name], cwd=REPO,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                   for name in ['parent', 'child']]
        try:
            for writer in writers:
                out, err = writer.communicate(timeout=90)
                assert writer.returncode == 0, (out, err)
        finally:
            for writer in writers:
                if writer.poll() is None:
                    writer.kill()
                    writer.wait()
        with sqlite3.connect(db) as recovered:
            assert recovered.execute('PRAGMA integrity_check').fetchone() == ('ok',)
            for name in ['parent', 'child']:
                rows = recovered.execute("SELECT json_extract(payload, '$.seq') FROM entries "
                                         "WHERE json_extract(payload, '$.writer') = ? ORDER BY id", (name,))
                assert [row[0] for row in rows] == list(range(1000))
        print('concurrent writers: 2,000 entries, ordered and intact')


if __name__ == '__main__':
    main()
