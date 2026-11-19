"""Unit coverage for the mirror probe's testable parts.

The network path (connect + HTTPS fetch) is exercised only in CI and
manual runs; here the pure pieces are pinned: suite extraction from
both source formats, the host-only rewrite (keys and suites
preserved), candidate lists per architecture, and the keep-default /
exit-0 semantics when no candidate delivers.
"""

from contextlib import redirect_stdout
import io
import unittest
from unittest.mock import patch

import use_ubuntu_mirror as mirror


class SuiteExtractionTest(unittest.TestCase):
    def test_deb_lines_and_sources_entries(self):
        legacy = ('deb http://archive.ubuntu.com/ubuntu noble main\n'
                  'deb http://archive.ubuntu.com/ubuntu noble-updates main\n'
                  'deb-src http://security.ubuntu.com/ubuntu noble-security main\n')
        deb822 = ('Types: deb\n'
                  'URIs: http://ports.ubuntu.com/ubuntu-ports\n'
                  'Suites: jammy jammy-updates\n'
                  'Components: main\n')
        self.assertEqual(mirror.suites_in(legacy), ['noble', 'noble-security',
                                                   'noble-updates'])
        self.assertEqual(mirror.suites_in(deb822), ['jammy', 'jammy-updates'])

    def test_component_paths_strip_to_the_suite(self):
        text = 'deb http://archive.ubuntu.com/ubuntu noble/updates main\n'
        self.assertEqual(mirror.suites_in(text), ['noble'])

    def test_empty_documents_have_no_suites(self):
        self.assertEqual(mirror.suites_in(''), [])
        self.assertEqual(mirror.suites_in('# comment only\n'), [])


class RewriteTest(unittest.TestCase):
    def test_archive_hosts_rewrite_host_only(self):
        for original in [
            'deb http://archive.ubuntu.com/ubuntu noble main\n',
            'deb http://security.ubuntu.com/ubuntu noble-security main\n',
            'deb http://us.archive.ubuntu.com/ubuntu noble main\n',
            'deb http://ports.ubuntu.com/ubuntu-ports noble main\n',
            'deb http://ftp.ports.ubuntu.com/ubuntu-ports noble main\n',
            'deb mirror+file:/etc/apt/apt-mirrors.txt noble main\n',
            'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\n'
            'Suites: noble\nComponents: main\n',
        ]:
            updated = mirror.rewrite(original, 'https://example.test/ubuntu')
            self.assertIn('https://example.test/ubuntu', updated)
            self.assertNotIn('archive.ubuntu.com', updated)
            self.assertNotIn('ports.ubuntu.com', updated)
            # Suites and components are preserved verbatim.
            self.assertIn('noble', updated)
            self.assertIn('main', updated)

    def test_signed_by_keys_survive(self):
        original = ('deb [signed-by=/usr/share/keyrings/ubuntu-archive-'
                    'keyring.gpg] http://archive.ubuntu.com/ubuntu noble '
                    'main\n')
        updated = mirror.rewrite(original, 'https://example.test/ubuntu')
        self.assertIn('signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg',
                      updated)

    def test_unrelated_hosts_are_untouched(self):
        original = 'deb https://ppa.example.test/ubuntu noble main\n'
        self.assertEqual(mirror.rewrite(original, 'https://m.example/ubuntu'),
                         original)


class ConfigureTest(unittest.TestCase):
    def _write(self, root):
        (root / 'sources.list.d').mkdir(parents=True)
        (root / 'sources.list').write_text(
            'deb http://archive.ubuntu.com/ubuntu noble main\n')
        (root / 'sources.list.d/extra.sources').write_text(
            'Types: deb\nURIs: http://security.ubuntu.com/ubuntu\n'
            'Suites: noble-security\nComponents: main\n')

    def test_first_delivering_candidate_rewrites_sources(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root)
            with patch.object(mirror, 'probe_connect', return_value=True), \
                 patch.object(mirror, 'probe_fetch', return_value=True), \
                 patch.object(mirror, 'first_delivering',
                              mirror.first_delivering) as _:
                out = io.StringIO()
                with redirect_stdout(out):
                    changed = mirror.configure(root, 'amd64')
            self.assertEqual(changed, 2)
            self.assertIn('https://mirror.math.princeton.edu/pub/ubuntu',
                          (root / 'sources.list').read_text())
            self.assertIn('Suites: noble-security',
                          (root / 'sources.list.d/extra.sources').read_text())
            self.assertIn('mirror probe ok (fetch)', out.getvalue())

    def test_no_delivering_candidate_keeps_defaults_and_exits_zero(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root)
            with patch.object(mirror, 'probe_connect', return_value=False):
                out = io.StringIO()
                with redirect_stdout(out):
                    changed = mirror.configure(root, 'amd64')
            self.assertEqual(changed, 0)
            self.assertIn('no candidate delivered', out.getvalue())
            self.assertIn('mirror unreachable (connect)', out.getvalue())
            # The runner's default sources are untouched.
            self.assertIn('archive.ubuntu.com',
                          (root / 'sources.list').read_text())

    def test_fetch_failure_logs_the_mode_and_falls_through(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write(root)
            with patch.object(mirror, 'probe_connect', return_value=True), \
                 patch.object(mirror, 'probe_fetch', return_value=False):
                out = io.StringIO()
                with redirect_stdout(out):
                    changed = mirror.configure(root, 'arm64')
            self.assertEqual(changed, 0)
            self.assertIn('mirror undelivering (fetch)', out.getvalue())
            self.assertIn('archive.ubuntu.com',
                          (root / 'sources.list').read_text())


if __name__ == '__main__':
    unittest.main()
