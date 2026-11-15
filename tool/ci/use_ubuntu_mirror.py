#!/usr/bin/env python3
"""Use independent Ubuntu mirrors when archive.ubuntu.com DNS is unavailable.

Only archive URLs in APT source files change. Suites, components, and Ubuntu's
Signed-By keys are preserved, so APT still authenticates the same packages.
"""

import argparse
from pathlib import Path
import re
import subprocess


def configure(apt_root: Path, architecture: str) -> int:
    mirrors = {
        'amd64': 'https://mirrors.edge.kernel.org/ubuntu',
        'arm64': 'https://mirrors.mit.edu/ubuntu-ports',
    }
    mirror = mirrors[architecture]
    # Hosted images can retain a binary package cache that does not reflect
    # a changed source URI. Read the freshly fetched lists for installation.
    config = apt_root / 'apt.conf.d' / '99-tina-package-cache'
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text('Dir::Cache::pkgcache "";\nDir::Cache::srcpkgcache "";\n')
    archive = re.compile(
        r'(?:https?://(?:[\w.-]+\.)?archive\.ubuntu\.com/ubuntu'
        r'|https?://security\.ubuntu\.com/ubuntu'
        r'|https?://(?:[\w.-]+\.)?ports\.ubuntu\.com/ubuntu-ports'
        r'|mirror\+file:/etc/apt/apt-mirrors(?:-security)?\.txt)/?(?=\s|$)'
    )
    changed = 0
    for source in [apt_root / 'sources.list',
                   *sorted((apt_root / 'sources.list.d').glob('*.list')),
                   *sorted((apt_root / 'sources.list.d').glob('*.sources'))]:
        if not source.is_file():
            continue
        original = source.read_text()
        updated = archive.sub(mirror, original)
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
