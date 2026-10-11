"""The idle gate permits late final paints but rejects recurring redraws."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from smoke_engine2 import Terminal


class IdleGateTest(unittest.TestCase):
    def run_gate(self, paints=(), continuous=False):
        terminal = Terminal.__new__(Terminal)
        terminal.output = bytearray()
        clock = [0.0]
        pending = list(paints)

        def read():
            clock[0] += 0.05
            if continuous:
                terminal.output.extend(b'paint')
            while pending and pending[0] <= clock[0]:
                pending.pop(0)
                terminal.output.extend(b'paint')

        terminal.read = read
        with patch('smoke_engine2.time.monotonic', lambda: clock[0]):
            terminal.expect_idle()
        return clock[0]

    def test_quiet_terminal_does_not_wait_for_the_deadline(self):
        elapsed = self.run_gate()
        self.assertGreaterEqual(elapsed, 0.35)
        self.assertLess(elapsed, 0.5)

    def test_late_completion_paints_must_settle_before_success(self):
        elapsed = self.run_gate([0.2, 0.5, 0.65])
        self.assertGreaterEqual(elapsed, 1.0)
        self.assertLess(elapsed, 1.15)

    def test_recurring_redraws_still_fail(self):
        with self.assertRaisesRegex(AssertionError, 'kept redrawing'):
            self.run_gate(continuous=True)


if __name__ == '__main__':
    unittest.main()
