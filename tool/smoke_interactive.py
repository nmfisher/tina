#!/usr/bin/env python3
"""Exercise the packaged notcurses UI in a fresh project before publication.

No model calls: use a dummy local provider, open command help, then quit.
The PTY answers terminal queries so native initialization uses the normal path.
"""

import argparse
import errno
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time
import tty


def smoke(binary, rows):
    with tempfile.TemporaryDirectory(prefix="tina-release-smoke-") as directory:
        root = Path(directory)
        project = root / "project"
        project.mkdir()
        subprocess.run(["git", "init", "-q", str(project)], check=True)
        (project / ".gitignore").write_text(".tina/\n")
        home = root / "home"
        config_dir = home / ".tina"
        config_dir.mkdir(parents=True)
        (config_dir / "config").write_text('''version = 1
[default]
provider = "smoke"
model = "smoke"
[providers.smoke]
api_key = "smoke-placeholder"
base_url = "http://127.0.0.1:1"
wire = "openai"
''')
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(home),
            "TERM": "xterm-256color",
            "LANG": "en_US.UTF-8",
            "COCOON_MODELS_DEV": "0",
            "COCOON_UPDATE_CHECK": "0",
            "COCOON_DEBUG": "1",
        }
        master, slave = pty.openpty()
        tty.setraw(slave)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, 80, 0, 0))
        process = subprocess.Popen(
            [str(binary), "--trust", "--backend", "notcurses"],
            cwd=project, env=env, stdin=slave, stdout=slave, stderr=slave,
            start_new_session=True,
            # setsid detaches the controlling terminal. Attach the slave again
            # before exec: Darwin's native initialization requires a real
            # controlling terminal, not just tty-shaped stdin/stdout pipes.
            preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0),
        )
        os.close(slave)
        output = bytearray()
        query_buffer = b""
        query_pattern = re.compile(rb"\x1b\](10|11);\?|\x1b\[(>?)(?:0)?c|\x1b\[6n")
        prompt_seen = False
        quit_sent = False
        quit_at = None
        help_at = None
        help_sent = False
        help_seen = False
        deadline = time.monotonic() + 45
        try:
            while time.monotonic() < deadline:
                if help_at is not None and not help_sent and time.monotonic() >= help_at:
                    os.write(master, b"/help\r")
                    help_sent = True
                if quit_at is not None and not quit_sent and time.monotonic() >= quit_at:
                    os.write(master, b"/quit\r")
                    quit_sent = True
                readable, _, _ = select.select([master], [], [], 0.1)
                if readable:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output.extend(chunk)
                    query_buffer += chunk
                    consumed = 0
                    for match in query_pattern.finditer(query_buffer):
                        if match.group(1):
                            color = b"ffff/ffff/ffff" if match.group(1) == b"10" else b"1818/1818/1818"
                            reply = b"\x1b]" + match.group(1) + b";rgb:" + color + b"\x1b\\"
                        elif match.group(0) == b"\x1b[6n":
                            reply = b"\x1b[1;1R"
                        elif match.group(2) == b">":
                            reply = b"\x1b[>0;276;0c"
                        else:
                            reply = b"\x1b[?62;22c"
                        os.write(master, reply)
                        consumed = match.end()
                    query_buffer = query_buffer[consumed:][-64:]
                    plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", output)
                    if not prompt_seen and b"smoke >" in plain:
                        prompt_seen = True
                        # Let the native startup reply drain finish before input.
                        help_at = time.monotonic() + 1.2
                    if help_sent and not help_seen and b"ESC cancels" in plain:
                        help_seen = True
                        quit_at = time.monotonic() + 0.3
                elif process.poll() is not None:
                    break
            code = process.wait(timeout=5)
            if not prompt_seen or not help_seen or not quit_sent or code != 0 or b"tina crashed:" in output:
                raise RuntimeError(
                    f"80x{rows}: prompt={prompt_seen}, help={help_seen}, quit={quit_sent}, exit={code}"
                )
            print(f"PASS 80x{rows}: startup, /help, /quit, clean exit")
        except Exception:
            print(output.decode("utf-8", errors="replace").replace("\x1b", "<ESC>"))
            raise
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            os.close(master)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    for terminal_rows in (10, 24):
        # Keep launcher symlinks intact: native assets must resolve correctly
        # when the user starts Tina through the installed PATH entry.
        smoke(args.binary.absolute(), terminal_rows)
