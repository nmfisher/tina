#!/usr/bin/env python3
"""Run isolated PTY suites concurrently, retaining a separate log for each."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys
import time


SUITES = (
    ('engine2', 'smoke_engine2.py', ('--quick',)),
    ('notcurses-images', 'smoke_notcurses_images.py', ()),
    ('classification', 'smoke_classification_panel.py', ()),
    ('panels', 'smoke_panel_paint.py', ()),
    ('backends', 'smoke_backend_selection.py', ()),
    ('shell', 'smoke_shell.py', ()),
    ('process-output', 'smoke_process_output.py', ()),
)


def run_suite(suite, binary, logs, timeout):
    name, script, options = suite
    log = logs / f'{name}.log'
    started = time.monotonic()
    print(f'START {name}', flush=True)
    with log.open('w') as output:
        try:
            result = subprocess.run(
                [sys.executable, '-u', str(Path(__file__).resolve().parents[1] / script),
                 '--binary', str(binary), *options],
                stdout=output, stderr=subprocess.STDOUT, timeout=timeout,
            )
            passed = result.returncode == 0
        except subprocess.TimeoutExpired:
            output.write(f'\nFAIL: suite exceeded {timeout}s timeout\n')
            passed = False
    duration = round(time.monotonic() - started, 1)
    print(f'{"PASS" if passed else "FAIL"} {name} ({duration}s) — {log}', flush=True)
    if not passed:
        print(log.read_text(errors='replace'), flush=True)
    return name, passed, duration


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=3)
    parser.add_argument('--logs', type=Path, default=Path('build/smoke-logs'))
    parser.add_argument('--timeout', type=int, default=600)
    args = parser.parse_args()
    if args.jobs < 1 or args.timeout < 1:
        parser.error('--jobs and --timeout must be positive')
    if not args.binary.is_file():
        parser.error(f'binary does not exist: {args.binary}')
    args.logs.mkdir(parents=True, exist_ok=True)
    # Every script has its own temp directory, ephemeral HTTP port and PTYs.
    # A process per script also isolates ModelStub's class-level request state.
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(
            lambda suite: run_suite(suite, args.binary.resolve(), args.logs, args.timeout), SUITES))
    failed = [name for name, passed, _ in results if not passed]
    print(f'{len(results) - len(failed)}/{len(results)} suites passed', flush=True)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
