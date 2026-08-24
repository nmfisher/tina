#!/usr/bin/env python3
"""Definitive diagnosis driver for TINA_IMPROVEMENTS_LOG #33.

Runs tool/mute_diag_probe.dart under a mute pty and, from OUTSIDE:
  - drains the master for the WHOLE run (a previous version stopped at the
    render marker, which blinded it to every stderr diag line the probe
    printed afterwards)
  - samples FIONREAD on a reopened slave right after injecting a key: the
    disappearance timeline shows WHO consumes the byte and how fast
  - snapshots /proc/PID/fd readlink targets + per-task syscall/wchan

Usage: python3 tool/syscall_diag_driver.py [probe flags...]
       (default probe flags: LOG DIAG --nopump)
"""
import fcntl
import os
import pty
import select
import struct
import subprocess
import sys
import threading
import time

LOG = "/tmp/sysdiag/probe.log"
DIAG = "/tmp/sysdiag/diag.log"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIONREAD = 0x541B


def decode_pollfds(pid, tid, sc_line):
    """For a thread blocked in poll/ppoll, read its pollfd array out of
    process memory and report the actual fd numbers (parent->child mem
    access is permitted under Yama ptrace_scope=1)."""
    parts = sc_line.split()
    try:
        nr = int(parts[0])
    except ValueError:  # "running"
        return ""
    if nr not in (7, 271, 16, 291):  # poll, ppoll, ioctl, epoll_wait
        return ""
    try:
        arg0 = int(parts[1], 16)
        nfds = int(parts[2], 0)
        if nfds <= 0 or nfds > 8:
            return ""
        mem = open(f"/proc/{pid}/mem", "rb", buffering=0)
        try:
            mem.seek(arg0)
            raw = mem.read(nfds * 8)
        finally:
            mem.close()
        out = []
        for i in range(nfds):
            fd, events = struct.unpack("<iH", raw[i * 8:i * 8 + 6])
            out.append(f"fd{fd}(ev=0x{events:x})")
        return " polls=" + ",".join(out)
    except (OSError, ValueError, IndexError, struct.error):
        return ""


def snapshot(pid, label):
    print(f"===== {label} =====")
    try:
        fds = {}
        for n in os.listdir(f"/proc/{pid}/fd"):
            try:
                fds[int(n)] = os.readlink(f"/proc/{pid}/fd/{n}")
            except OSError:
                fds[int(n)] = "<gone>"
        for n in sorted(fds):
            print(f"  fd {n:2d} -> {fds[n]}")
    except OSError as e:
        print(f"  fd table error: {e}")
        return
    for tid in sorted(os.listdir(f"/proc/{pid}/task"), key=int):
        try:
            sc = open(f"/proc/{pid}/task/{tid}/syscall").read().strip()
            wch = open(f"/proc/{pid}/task/{tid}/wchan").read().strip()
            comm = open(f"/proc/{pid}/task/{tid}/comm").read().strip()
            extra = decode_pollfds(pid, tid, sc)
            print(f"  tid {tid} [{comm}] wchan={wch} syscall={sc[:60]}"
                  f"{extra}")
        except OSError as e:
            print(f"  tid {tid} err {e}")


def pending_bytes(fd):
    buf = bytearray(4)
    try:
        fcntl.ioctl(fd, FIONREAD, buf, True)
        return struct.unpack("i", buf)[0]
    except OSError as e:
        return f"err:{e.errno}"


def disappearance_timeline(slave_path, master, label):
    """Write one key, then watch the kernel input queue from outside."""
    probe_fd = os.open(slave_path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOCTTY)
    try:
        os.write(master, b"b")
        t0 = time.monotonic()
        marks = [0.001, 0.005, 0.010, 0.050, 0.100, 0.300, 1.0, 2.0]
        for m in marks:
            while time.monotonic() - t0 < m:
                time.sleep(0.0002)
            print(f"  [{label}] t=+{m:6.3f}s FIONREAD(pts)="
                  f"{pending_bytes(probe_fd)}")
    finally:
        os.close(probe_fd)


def main():
    os.makedirs("/tmp/sysdiag", exist_ok=True)
    for f in (LOG, DIAG):
        if os.path.exists(f):
            os.unlink(f)

    extra = sys.argv[1:] or ["--nopump"]
    # DIAG_PROBE/DIAG_MARKER let the harness run a different probe (e.g.
    # tool/altkey_probe.dart, whose render text is "altkey probe") under the
    # same continuously-drained pty, isolating driver-vs-probe differences.
    probe_rel = os.environ.get("DIAG_PROBE", "tool/mute_diag_probe.dart")
    marker = os.environ.get("DIAG_MARKER", "MUTE-DIAG probe")

    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    slave_name = os.ttyname(slave)
    proc = subprocess.Popen(
        ["dart", "run", probe_rel, LOG, DIAG, *extra],
        cwd=REPO, stdin=slave, stdout=slave, stderr=slave, close_fds=True,
    )
    os.close(slave)
    print(f"[driver] child pty slave = {slave_name} probe flags = {extra}")

    # Drain the master for the WHOLE run so stderr diag lines written after
    # render are captured instead of silently lost to a full buffer.
    chunks = []
    lock = threading.Lock()
    eof = threading.Event()

    def drain():
        while True:
            try:
                r, _, _ = select.select([master], [], [], 0.5)
                if not r:
                    if proc.poll() is not None:
                        time.sleep(0.2)
                        continue
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

    deadline = time.time() + 180
    rendered = False
    while time.time() < deadline:
        with lock:
            joined = b"".join(chunks)
        if marker.encode() in joined:
            rendered = True
            break
        if proc.poll() is not None:
            break
        time.sleep(0.2)
    if not rendered or proc.poll() is not None:
        print(f"probe failed to render rc={proc.returncode}")
        tail = joined[-300:].decode("utf-8", "replace").replace("\x1b", "<ESC>")
        print(tail)
        return 2

    print("[driver] probe rendered; waiting 2s for threads to settle")
    time.sleep(2)
    snapshot(proc.pid, "BEFORE key injection")

    disappearance_timeline(slave_name, master, "b")
    snapshot(proc.pid, "AFTER 'b' injection")

    os.write(master, b"q")
    time.sleep(2.5)
    try:
        proc.wait(timeout=5)
        print(f"[driver] probe exited rc={proc.returncode}")
    except subprocess.TimeoutExpired:
        print("[driver] probe still running; killing")
        proc.kill()
    os.close(master)
    time.sleep(0.2)

    seen = b"".join(chunks)
    print("===== probe log =====")
    print(open(LOG).read() if os.path.exists(LOG) else "<missing>")
    print("===== diag lines from pty stream (stderr instrumentation) =====")
    for line in seen.decode("utf-8", "replace").splitlines():
        if ("BRIDGEDIAG" in line or "FD0PEEK" in line
                or "DIRECTGET" in line):
            print("  " + line.strip())
    print("===== diag tail =====")
    if os.path.exists(DIAG):
        lines = open(DIAG).read().splitlines()
        for line in lines[:8] + ["..."] + lines[-8:]:
            print(line)
    return 0


if __name__ == "__main__":
    import termios
    sys.exit(main())
