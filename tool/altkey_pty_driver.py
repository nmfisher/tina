#!/usr/bin/env python3
"""Exercise keyboard bytes through notcurses and the native input pump.

Covers legacy text, effective text in extended key reports, Alt shortcuts,
Ctrl shortcuts, repeats and releases. Run both with terminal capability replies
and without them, exercising TerminalReplyGuard's PTY detour too. No physical
terminal or keyboard is needed. CI runs this on Linux and macOS.

Usage: tool/altkey_pty_driver.py [probe-log-path]
Exit 0 when the complete sequence of decoded records matches.
"""
import os
import pty
import re
import select
import subprocess
import sys
import time

LOG = sys.argv[1] if len(sys.argv) > 1 else "/tmp/altkey_verify/probe.log"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def master_loop(master, proc, mute):
    """Read probe output, answer capability queries, return once it rendered."""
    seen = b""
    pending = b""
    queries = re.compile(rb"\x1b\](10|11);\?|\x1b\[(>?)(?:0)?c|\x1b\[6n")
    deadline = time.time() + 150  # dart run cold start can be slow
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.5)
        if not r:
            if proc.poll() is not None:
                raise RuntimeError(f"probe exited early: {proc.returncode}")
            continue
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        seen += chunk
        # Queries may straddle read boundaries. Include the cursor report:
        # recent native builds require it before initialization can finish.
        pending += chunk
        consumed = 0
        for match in ([] if mute else queries.finditer(pending)):
            if match.group(1):
                reply = b"\x1b]" + match.group(1) + b";rgb:ffff/ffff/ffff\x1b\\"
            elif match.group(0) == b"\x1b[6n":
                reply = b"\x1b[1;1R"
            elif match.group(2) == b">":
                reply = b"\x1b[>0;276;0c"
            else:
                reply = b"\x1b[?62;22c"
            os.write(master, reply)
            consumed = match.end()
        pending = pending[consumed:][-64:]
        if b"altkey probe" in seen:
            return
    raise RuntimeError(
        "probe never rendered (init did not complete?) — master saw:\n"
        + seen.decode("utf-8", "replace").replace("\x1b", "<ESC>")
    )


def run(log_path, mute):
    os.makedirs(os.path.dirname(os.path.abspath(log_path)), exist_ok=True)
    if os.path.exists(log_path):
        os.unlink(log_path)

    master, slave = pty.openpty()
    # openpty() gives a 0x0 window; notcurses init fails on that geometry.
    import fcntl
    import struct
    import termios
    import tty

    tty.setraw(slave)
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    proc = subprocess.Popen(
        ["dart", "run", "tool/altkey_probe.dart", log_path],
        cwd=REPO,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
        env={**os.environ, "TERM": "xterm-256color"},
        start_new_session=True,
        preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0),
    )
    os.close(slave)
    try:
        master_loop(master, proc, mute)
        cases = [
            (b"\x1bb", [(0x62, 2)]),                 # legacy Alt+b
            (b"\x1bf", [(0x66, 2)]),                 # legacy Alt+f
            (b"b", [(0x62, 0)]),
            (b"@", [(0x40, 0)]),                     # legacy Shift+2 text
            (b"2", [(0x32, 0)]),
            (b"\x1b[50;2;64u", [(0x40, 0)]),        # effective @, base 2
            (b"\x1b[50;2:2;64u", [(0x40, 0)]),      # repeat is kept
            (b"\x1b[50;2:3;64u", []),               # release is dropped
            (b"\x1b[59;2;58u", [(0x3a, 0)]),        # effective colon
            (b"\x1b[101;3;233u", [(0xe9, 0)]),      # Alt-produced Unicode
            (b"\x1b[99;5;99u", [(0x43, 4)]),        # Ctrl+C stays a shortcut
            ("\u03bb".encode(), [(0x3bb, 0)]),       # legacy UTF-8
            (b"q", [(0x71, 0)]),
        ]
        for encoded, _ in cases:
            os.write(master, encoded)
            time.sleep(0.15)
        proc.wait(timeout=10)
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        os.close(master)

    with open(log_path, encoding="utf-8") as source:
        log = source.read()
    actual = [(int(key, 16), int(mods)) for key, mods in
              re.findall(r"id=0x([0-9a-f]+) mods=(\d+)", log)]
    expected = [event for _, events in cases for event in events]
    if actual != expected or proc.returncode != 0:
        print(log, end="")
        print(f"FAIL: expected {expected}, got {actual}, exit={proc.returncode}")
        return 1
    mode = "PTY detour" if mute else "terminal replies"
    print(f"PASS ({mode}): text, modifiers, repeats and releases")
    return 0


if __name__ == "__main__":
    sys.exit(run(LOG, False) | run(LOG + ".mute", True))
