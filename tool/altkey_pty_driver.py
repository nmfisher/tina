#!/usr/bin/env python3
"""Drive tool/altkey_probe.dart over a pty we control, answering the terminal
capability queries notcurses sends at init, then inject Alt+key bytes and
assert the probe logged them with the ALT modifier.

This is the regression harness for the input_pump.c modifier fold (Alt+key
arriving as a bare ESC + key — how macOS Terminal.app sends Option+Left/Right
as ESC b / ESC f — must reach Dart with the ALT bit set). It exists because
every Dart-side seam injects already-translated records and keystrokes can't
be synthesized into /dev/tty from the test process.

A detached tmux would be the usual trick, but notcurses init needs query
replies: a detached tmux server answers nothing, tina's TerminalReplyGuard
detour then unblocks init but leaves notcurses' input thread polling the
guard's dead pty (pre-existing bug — the keyboard never wakes). So instead
this driver runs the probe under a fresh pty and plays terminal on the master
side: answer OSC 10/11 (the guard's probe) and DA1 (notcurses' init gate),
ignore the rest, then write the key bytes once the probe has rendered.

Usage: tool/altkey_pty_driver.py [probe-log-path]
Exit 0 (and prints PASS) when the Alt records carry ALT and plain keys don't.
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

ESC = b"\x1b"


def master_loop(master, proc, log_path):
    """Read probe output, answer capability queries, return once it rendered."""
    seen = b""
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
        # The guard's mute-probe: OSC 10/11 '?'. Answer with a color so it
        # stands down (no fd-0 detour) and init takes the normal path.
        if re.search(rb"\x1b\]1?[01];\?", chunk):
            os.write(master, b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\")
            os.write(master, b"\x1b]11;rgb:0000/0000/0000\x1b\\")
        # DA1 — the reply notcurses' init blocks on. VT220 class, ANSI color,
        # no sixel/kitty: same shape the reply guard uses as its fallback.
        if re.search(rb"\x1b\[c|\x1b\[0c", chunk):
            os.write(master, b"\x1b[?62;22c")
        # DA2
        if re.search(rb"\x1b\[>c|\x1b\[>0c", chunk):
            os.write(master, b"\x1b[>0;276;0c")
        if b"altkey probe" in seen:
            return
    raise RuntimeError(
        "probe never rendered (init did not complete?) — master saw:\n"
        + seen.decode("utf-8", "replace").replace("\x1b", "<ESC>")
    )


def main():
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    if os.path.exists(LOG):
        os.unlink(LOG)

    master, slave = pty.openpty()
    # openpty() gives a 0x0 window; notcurses init fails on that geometry.
    import fcntl
    import struct
    import termios

    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    proc = subprocess.Popen(
        ["dart", "run", "tool/altkey_probe.dart", LOG],
        cwd=REPO,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        close_fds=True,
    )
    os.close(slave)
    try:
        master_loop(master, proc, LOG)

        # Alt+b, Alt+f (ESC + key in one write, as a terminal sends for one
        # keypress), then a plain unmodified b, then quit.
        os.write(master, b"\x1b\x62")
        time.sleep(0.5)
        os.write(master, b"\x1b\x66")
        time.sleep(0.5)
        os.write(master, b"b")
        time.sleep(0.5)
        os.write(master, b"q")
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            # The probe logs "probe exit" before ncs.stop(), which can hang on
            # teardown (known separate issue) — the log is complete by then.
            pass
    finally:
        if proc.poll() is None:
            proc.kill()
        os.close(master)

    log = open(LOG, "rb").read().decode("utf-8", "replace")
    print(log, end="")
    checks = [
        (re.search(r"id=0x62 mods=2.*ALT", log), "ESC b arrived with ALT"),
        (re.search(r"id=0x66 mods=2.*ALT", log), "ESC f arrived with ALT"),
        (re.search(r"id=0x62 mods=0", log), "plain b arrived unmodified"),
    ]
    failed = [msg for ok, msg in checks if not ok]
    if failed:
        print("FAIL: " + "; ".join(failed))
        return 1
    print("PASS: Alt+key survives the pump with ALT set; plain keys unmodified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
