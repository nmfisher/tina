#!/usr/bin/env python3
"""Mute-terminal variant of tool/altkey_pty_driver.py.

Plays a terminal that answers NOTHING — the detached-tmux case. The reply
guard should arm its fd-0 detour, feed notcurses the fallback DA1, and init
should complete on defaults. Then we inject keys and check whether the input
pump ever delivers them.

Exit 0 + PASS: init completed AND injected keys reached the pump.
Exit 1 + DEAD-KEYBOARD: init completed but no injected key arrived.
Exit 2 + INIT-HANG: init never completed (guard failed).
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
import threading

LOG = "/tmp/mute_pty/probe.log"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def main():
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    if os.path.exists(LOG):
        os.unlink(LOG)

    master, slave = pty.openpty()
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

    seen = b""
    rendered = False
    # Drain the master for the WHOLE run (daemon thread). An earlier version
    # stopped reading at the render marker, which blinded the driver to every
    # stderr line the probe printed afterwards — a crash stack trace, an
    # uncaught async error, anything. The pty's output buffer also backs up
    # when nobody drains it.
    chunks = []
    lock = threading.Lock()

    def drain():
        while True:
            try:
                r, _, _ = select.select([master], [], [], 0.5)
                if not r:
                    continue
                data = os.read(master, 65536)
            except OSError:
                break
            if not data:
                break
            with lock:
                chunks.append(data)

    drainer = threading.Thread(target=drain, daemon=True)
    drainer.start()

    # Guard waits 400ms for its probe, then detour + init; allow generous time
    # for the dart cold start on top.
    deadline = time.time() + 180
    while time.time() < deadline:
        with lock:
            joined = b"".join(chunks)
        # MUTE: deliberately answer nothing. Log what was asked.
        if re.search(rb"\x1b\]1?[01];\?", joined) and b"OSC" not in seen:
            seen += b"OSC"
            print(f"[driver] guard probe seen (staying mute)")
        if re.search(rb"\x1b\[c|\x1b\[0c", joined) and b"DA1" not in seen:
            seen += b"DA1"
            print(f"[driver] DA1 query seen (staying mute)")
        if b"altkey probe" in joined:
            rendered = True
            break
        if proc.poll() is not None:
            break
        time.sleep(0.2)

    try:
        if not rendered:
            with lock:
                tail = (b"".join(chunks))[-400:].decode("utf-8", "replace").replace("\x1b", "<ESC>")
            print(f"INIT-HANG or no render. master tail:\n{tail}")
            return 2

        print("[driver] probe rendered — init completed via guard detour")
        # Settle: let the input pump start and the bridge run a first tick
        # before injecting (mirrors tool/syscall_diag_driver.py).
        time.sleep(2.0)
        # Inject keys: plain b, then q to quit.
        os.write(master, b"b")
        time.sleep(1.0)
        os.write(master, b"q")
        time.sleep(1.0)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        print(f"[driver] probe rc={proc.poll()}")
    finally:
        if proc.poll() is None:
            proc.kill()
        os.close(master)
        with lock:
            seen = b"".join(chunks)

    log = open(LOG, "rb").read().decode("utf-8", "replace")
    print("---- probe log ----")
    print(log, end="")
    print("-------------------")
    # Anything the probe wrote to the pty (stdout/stderr) after the render
    # marker: crash traces, uncaught async errors, pump diagnostics.
    marker = seen.find(b"altkey probe")
    tail = seen[marker:] if marker >= 0 else seen[-2000:]
    text = tail.decode("utf-8", "replace").replace("\x1b", "<ESC>")
    text = re.sub(r"<ESC>\[[0-9;?]*[a-zA-Z]", "", text)  # strip CSI noise
    tail_lines = [l for l in text.splitlines() if l.strip()]
    if tail_lines[1:]:
        print("---- pty output after render ----")
        print("\n".join(tail_lines[1:]))
        print("---------------------------------")
    got_b = re.search(r"id=0x62 mods=0", log)
    if got_b:
        print("PASS: keyboard alive after mute-terminal guard detour")
        return 0
    print("DEAD-KEYBOARD: init completed but injected keys never arrived")
    return 1


if __name__ == "__main__":
    sys.exit(main())
