#!/usr/bin/env python3
"""Use independent Ubuntu mirrors when archive.ubuntu.com DNS is unavailable.

Only archive URLs in APT source files change. Suites, components, and Ubuntu's
Signed-By keys are preserved, so APT still authenticates the same packages.

A candidate mirror is only used after it DELIVERS a small real file over
HTTPS (the InRelease index of a suite already named by the runner's
sources). A handshake that later resets mid-download — Princeton did
exactly that during the commit-18-era run, taking four jobs down with
apt exit 100 — fails the probe and the next candidate is tried.
"""

import argparse
from pathlib import Path
import re
import socket
import subprocess
import urllib.request

CONNECT_TIMEOUT = 3
FETCH_TIMEOUT = 10
PROBE_SIZE = 64 * 1024


def probe_connect(host):
    """Stage 1: the host accepts a TCP connection on 443."""
    try:
        socket.create_connection((host, 443), timeout=CONNECT_TIMEOUT).close()
        return True
    except OSError:
        return False


def probe_fetch(url):
    """Stage 2: the mirror actually serves [url] over HTTPS.

    Reads at most PROBE_SIZE bytes — enough to prove delivery, small
    enough to stay instant. Any transport error, TLS failure, HTTP
    error status or truncated response fails the probe.
    """
    try:
        with urllib.request.urlopen(
                urllib.request.Request(url, method='GET'),
                timeout=FETCH_TIMEOUT) as response:
            if response.status < 200 or response.status >= 300:
                return False
            return len(response.read(PROBE_SIZE)) > 0
    except Exception:
        return False


def suites_in(sources_text):
    """The suite names an APT sources file references (deb lines,
    .sources Suites entries). Used to probe a path that really exists
    on the mirror instead of a synthetic one."""
    suites = set()
    for match in re.finditer(r'^\s*deb(?:-\w+)?\s+\S+\s+(\S+)', sources_text,
                             re.MULTILINE):
        suites.add(match.group(1).split('/', 1)[0])
    for match in re.finditer(r'^Suites:\s*(.+)$', sources_text,
                             re.MULTILINE | re.IGNORECASE):
        for suite in match.group(1).split():
            suites.add(suite.split('/', 1)[0])
    suites.discard('')
    return sorted(suites)


def first_delivering(mirrors, suites):
    """The first candidate that connects AND serves a suite InRelease.

    Failures log which probe mode failed (connect vs fetch), so a CI
    log shows whether a mirror was unreachable or flaking mid-download.
    """
    for mirror in mirrors:
        host = re.match(r'https?://([^/]+)', mirror).group(1)
        if not probe_connect(host):
            print(f'mirror unreachable (connect): {host}')
            continue
        for suite in suites or ['noble']:
            if probe_fetch(f'{mirror.rstrip("/")}/dists/{suite}/InRelease'):
                print(f'mirror probe ok (fetch): {host} '
                      f'dists/{suite}/InRelease')
                return mirror
        print(f'mirror undelivering (fetch): {host} — no InRelease '
              f'for suites {suites or ["noble"]}')
    return None


def rewrite(text, mirror):
    """Host-only rewrite of archive URLs in one sources document."""
    archive = re.compile(
        r'(?:https?://(?:[\w.-]+\.)?archive\.ubuntu\.com/ubuntu'
        r'|https?://security\.ubuntu\.com/ubuntu'
        r'|https?://(?:[\w.-]+\.)?ports\.ubuntu\.com/ubuntu-ports'
        r'|mirror\+file:/etc/apt/apt-mirrors(?:-security)?\.txt)/?(?=\s|$)'
    )
    return archive.sub(mirror, text)


def configure(apt_root: Path, architecture: str) -> int:
    candidates = {
        'amd64': [
            'https://mirror.math.princeton.edu/pub/ubuntu',
            'https://mirrors.ocf.berkeley.edu/ubuntu',
            'https://mirrors.edge.kernel.org/ubuntu',
        ],
        'arm64': ['https://mirrors.mit.edu/ubuntu-ports'],
    }
    sources = [apt_root / 'sources.list',
               *sorted((apt_root / 'sources.list.d').glob('*.list')),
               *sorted((apt_root / 'sources.list.d').glob('*.sources'))]
    sources = [path for path in sources if path.is_file()]
    suites = sorted({suite
                     for path in sources
                     for suite in suites_in(path.read_text())})
    mirror = first_delivering(candidates[architecture], suites)
    if mirror is None:
        print('Ubuntu mirror: no candidate delivered a probe file; keeping '
              'the runner default sources')
        return 0
    # Hosted images can retain a binary package cache that does not reflect
    # a changed source URI. Read the freshly fetched lists for installation.
    config = apt_root / 'apt.conf.d' / '99-tina-package-cache'
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('Dir::Cache::pkgcache "";\nDir::Cache::srcpkgcache "";\n')
    changed = 0
    for source in sources:
        original = source.read_text()
        updated = rewrite(original, mirror)
        if updated != original:
            source.write_text(updated)
            changed += 1
    print(f'Ubuntu mirror: {mirror} ({changed} source files updated)')
    return changed


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apt-root', type=Path, default=Path('/etc/apt'))
    parser.add_argument('--architecture', choices=['amd64', 'arm64'])
    args = parser.parse_args()
    architecture = args.architecture or subprocess.check_output(
        ['dpkg', '--print-architecture'], text=True).strip()
    configure(args.apt_root, architecture)
