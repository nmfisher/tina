"""Exercise runner concurrency, failure aggregation and diagnostic logs."""
from contextlib import redirect_stdout
import io
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import run_release_smokes as runner


class ReleaseRunnerTest(unittest.TestCase):
    def test_failure_keeps_other_suites_running_with_bounded_parallelism(self):
        active = maximum = 0
        completed = []
        lock = threading.Lock()

        def execute(command, **kwargs):
            nonlocal active, maximum
            name = Path(command[2]).name
            with lock:
                active += 1
                maximum = max(maximum, active)
            time.sleep(.03)
            kwargs['stdout'].write(f'{name} diagnostics\n')
            with lock:
                active -= 1
                completed.append(name)
            return subprocess.CompletedProcess(command, 1 if name == 'smoke_engine2.py' else 0)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / 'tina'
            binary.touch()
            argv = ['runner', '--binary', str(binary), '--logs', str(root / 'logs'), '--jobs', '3']
            with patch('sys.argv', argv), patch.object(runner.subprocess, 'run', execute), redirect_stdout(io.StringIO()):
                self.assertEqual(runner.main(), 1)
            self.assertEqual(len(completed), 7)
            self.assertEqual(maximum, 3)
            self.assertEqual(len(list((root / 'logs').glob('*.log'))), 7)
            self.assertIn('smoke_engine2.py diagnostics', (root / 'logs/engine2.log').read_text())

    def test_timeout_is_reported_as_failure_in_its_log(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            with patch.object(runner.subprocess, 'run', side_effect=subprocess.TimeoutExpired('fixture', 1)), redirect_stdout(io.StringIO()):
                name, passed, _ = runner.run_suite(runner.SUITES[0], logs / 'tina', logs, 1)
            self.assertEqual(name, 'engine2')
            self.assertFalse(passed)
            self.assertIn('exceeded 1s timeout', (logs / 'engine2.log').read_text())


if __name__ == '__main__':
    unittest.main()
