#!/usr/bin/env python3
"""Companion to mute_diag_probe.dart: stay mute, inject keys, report diagnostics."""
import os, pty, re, select, subprocess, sys, time, termios, struct, fcntl

LOG = "/tmp/mute_diag/probe.log"
DIAG = "/tmp/mute_diag/diag.log"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def main():
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    if os.path.exists(LOG): os.unlink(LOG)
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    proc = subprocess.Popen(
        ["dart", "run", "tool/mute_diag_probe.dart", LOG, DIAG],
        cwd=REPO, stdin=slave, stdout=slave, stderr=slave, close_fds=True,
    )
    os.close(slave)
    seen = b""
    rendered = False
    deadline = time.time() + 180
    try:
        while time.time() < deadline:
            r, _, _ = select.select([master], [], [], 0.5)
            if not r:
                if proc.poll() is not None: break
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk: break
            seen += chunk
            if re.search(rb"\x1b\]1?[01];\?", chunk):
                print("[driver] probe seen (mute)")
            if re.search(rb"\x1b\[c|\x1b\[0c", chunk):
                print("[driver] DA1 query seen (mute)")
            if b"MUTE-DIAG probe" in seen:
                rendered = True
                break
        print(f"[driver] rendered={rendered}")
        if rendered:
            # Inject keystrokes the same way mute_pty_driver.py does.
            print("[driver] injecting 'b' ...")
            os.write(master, b"b")
            time.sleep(1.0)
            print("[driver] injecting 'q' ...")
            os.write(master, b"q")
            time.sleep(2.0)
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                pass
    finally:
        if proc.poll() is None:
            proc.kill()
        os.close(master)

    # Print diagnostics regardless of exit code; they are the whole point.
    print("==== probe log (" + LOG + ") ==== ")
    try:
        with open(LOG, "r") as f:
            print(f.read(), end="")
    except Exception as e:
        print("(no probe log: " + str(e) + ")")
    print("==== diag log (" + DIAG + ") ==== ")
    try:
        with open(DIAG, "r") as f:
            print(f.read(), end="")
    except Exception as e:
        print("(no diag log: " + str(e) + ")")

    # The actual PASS/FAIL is decided by whether 'b' arrived at the pump
    # (the same check mute_pty_driver does) — but the primary output for
    # investigation is the diag timeline showing termios/readyFd evolution.
    try:
        with open(LOG, "r") as f:
            text = f.read()
        if "id=0x62 mods=0" in text:
            print("PASS (key reached pump — unexpected with cooked stdin)")
            return 0
        else:
            print("NOPUMP (empty log; consistent with cooked stdin theory)")
            return 1  # same exit code convention as mute_pty_driver
    except Exception as e:
        print("NOPROB (cannot read probe log: " + str(e) + ")")
        return 1

if __name__ == "__main__":
    sys.exit(main())
