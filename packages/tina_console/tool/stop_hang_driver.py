#!/usr/bin/env python3
"""Measure whether the probe PROCESS exits after 'q' (ncs.stop() path), not
just whether the log completes. Answers capability queries like
altkey_pty_driver.py, then reports actual exit + elapsed time after quit.
"""
import os
import pty
import re
import select
import subprocess
import sys
import time
import fcntl
import struct
import termios

LOG = "/tmp/stophang/probe.log"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    if os.path.exists(LOG):
        os.unlink(LOG)

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    t0 = time.time()
    proc = subprocess.Popen(
        ["dart", "run", "tool/altkey_probe.dart", LOG],
        cwd=REPO, stdin=slave, stdout=slave, stderr=slave, close_fds=True,
    )
    os.close(slave)
    seen = b""
    deadline = time.time() + 180
    try:
        while time.time() < deadline:
            r, _, _ = select.select([master], [], [], 0.5)
            if not r:
                if proc.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            seen += chunk
            if re.search(rb"\x1b\]1?[01];\?", chunk):
                os.write(master, b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\")
                os.write(master, b"\x1b]11;rgb:0000/0000/0000\x1b\\")
            if re.search(rb"\x1b\[c|\x1b\[0c", chunk):
                os.write(master, b"\x1b[?62;22c")
            if re.search(rb"\x1b\[>c|\x1b\[>0c", chunk):
                os.write(master, b"\x1b[>0;276;0c")
            if b"altkey probe" in seen:
                break

        print(f"[driver] rendered after {time.time()-t0:.1f}s; sending q")
        os.write(master, b"q")
        tq = time.time()
        try:
            rc = proc.wait(timeout=20)
            print(f"[driver] process exited rc={rc} {time.time()-tq:.1f}s after q")
            verdict = 0 if time.time() - tq < 10 else 1
            print("STOP-CLEAN" if verdict == 0 else "STOP-SLOW(>10s)")
        except subprocess.TimeoutExpired:
            print(f"[driver] STILL RUNNING >20s after q — stop() hang confirmed")
            verdict = 1
            print("STOP-HANG")
        return verdict
    finally:
        if proc.poll() is None:
            proc.kill()
        os.close(master)


if __name__ == "__main__":
    sys.exit(main())
