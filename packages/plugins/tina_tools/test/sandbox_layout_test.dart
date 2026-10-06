// The OS-sandbox argv builders as tables: request + layout in, exact argv
// out, for bwrap (Linux) and sandbox-exec (macOS). No sandbox binary is
// needed — these are pure builders over stated inputs.
//
// Run: dart test
library;

import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

SandboxHostLayout _layout() => SandboxHostLayout(
      readOnlyDirectories: ['/usr', '/bin', '/etc'],
      temporaryDirectories: ['/tmp'],
      resolverTarget: '/etc/resolv.conf',
    );

void main() {
  group('buildBwrapArguments (Linux argv table)', () {
    test(
        'the full layout, in order: ro-binds, resolver, temps, project, '
        'env, namespaces, then the command after --', () {
      final argv = buildBwrapArguments(
        host: _layout(),
        workspaceRoot: '/work/proj',
        tinaDir: '/home/user/.tina',
        writablePaths: ['/work/proj/out'],
        isolateNetwork: true,
        childEnvironment: {'PATH': '/usr/bin:/bin'},
      );
      expect(argv, [
        // System directories, read-only, in the layout's order.
        '--ro-bind', '/usr', '/usr',
        '--ro-bind', '/bin', '/bin',
        '--ro-bind', '/etc', '/etc',
        // The resolver by its resolved name: preserves the /etc symlink
        // without exposing the rest of /run.
        '--ro-bind', '/etc/resolv.conf', '/etc/resolv.conf',
        // Temp scratch, writable.
        '--bind', '/tmp', '/tmp',
        // The project and its extra grants, read-write.
        '--bind', '/work/proj', '/work/proj',
        '--bind', '/work/proj/out', '/work/proj/out',
        // Protect tina's data after granting its writable ancestors.
        '--ro-bind', '/home/user/.tina', '/home/user/.tina',
        // Fresh device/proc trees.
        '--dev', '/dev', '--proc', '/proc',
        // A cleared environment, rebuilt from the allowlist only.
        '--clearenv',
        '--setenv', 'PATH', '/usr/bin:/bin',
        // Own process namespace; die with the agent; no network.
        '--unshare-pid',
        '--die-with-parent',
        '--unshare-net',
        '--',
      ]);
    });

    test('network on drops only --unshare-net; the rest is identical', () {
      final on = buildBwrapArguments(
        host: _layout(),
        workspaceRoot: '/w',
        writablePaths: const [],
        isolateNetwork: false,
        childEnvironment: const {},
      );
      expect(on.contains('--unshare-net'), isFalse);
      final off = buildBwrapArguments(
        host: _layout(),
        workspaceRoot: '/w',
        writablePaths: const [],
        isolateNetwork: true,
        childEnvironment: const {},
      );
      final onWithoutFlag = [...off]..remove('--unshare-net');
      expect(onWithoutFlag, on);
    });

    test(
        'the child environment is exactly the allowlist — nothing '
        'inherited', () {
      final argv = buildBwrapArguments(
        host: _layout(),
        workspaceRoot: '/w',
        writablePaths: const [],
        isolateNetwork: true,
        childEnvironment: {'PATH': '/bin'},
      );
      final setenv = [
        for (var i = 0; i < argv.length - 2; i++)
          if (argv[i] == '--setenv') argv.sublist(i + 1, i + 3),
      ];
      expect(setenv, [
        ['PATH', '/bin']
      ]);
    });

    test('no tinaDir means no tina bind; writable grants each get one bind',
        () {
      final argv = buildBwrapArguments(
        host: SandboxHostLayout(
          readOnlyDirectories: const [],
          temporaryDirectories: const [],
        ),
        workspaceRoot: '/w',
        writablePaths: ['/shared/a', '/shared/b'],
        isolateNetwork: true,
        childEnvironment: const {},
      );
      expect(argv, [
        '--bind',
        '/w',
        '/w',
        '--bind',
        '/shared/a',
        '/shared/a',
        '--bind',
        '/shared/b',
        '/shared/b',
        '--dev',
        '/dev',
        '--proc',
        '/proc',
        '--clearenv',
        '--unshare-pid',
        '--die-with-parent',
        '--unshare-net',
        '--',
      ]);
    });
  });

  group('buildSeatbeltProfile (macOS profile table)', () {
    test('baseline: allow default, deny writes, re-grant per writable path',
        () {
      final profile = buildSeatbeltProfile(
        writablePaths: ['/work/proj', '/tmp'],
        isolateNetwork: true,
      );
      expect(profile, '''
(version 1)
(allow default)
(deny network*)
(deny file-write*)
(allow file-write-data (literal "/dev/null"))
(allow file-write* (subpath "/work/proj"))
(allow file-write* (subpath "/tmp"))
''');
    });

    test('network on drops the deny rule but keeps the write shape', () {
      final profile = buildSeatbeltProfile(
        writablePaths: ['/w'],
        isolateNetwork: false,
      );
      expect(profile, isNot(contains('deny network')));
      expect(profile, contains('(deny file-write*)'));
      expect(profile, contains('(allow file-write* (subpath "/w"))'));
    });

    test('profile paths escape quotes and backslashes', () {
      final profile = buildSeatbeltProfile(
        writablePaths: [r'/odd "quoted"\path'],
        isolateNetwork: true,
      );
      expect(
        profile,
        contains('(allow file-write* (subpath "/odd '
            r'\"quoted\"\\path"))'),
      );
    });

    test('a hidden home is read-denied, with re-allows beneath it', () {
      final profile = buildSeatbeltProfile(
        writablePaths: const [],
        isolateNetwork: true,
        hidePath: '/Users/u',
        readAllowPaths: ['/Users/u/proj'],
      );
      expect(profile, contains('(deny file-read* (subpath "/Users/u"))'));
      expect(profile, contains('(allow file-read* (subpath "/Users/u/proj"))'));
      // Writes stay denied everywhere the grants do not reach — including
      // inside the re-allowed reads.
      expect(profile, contains('(deny file-write*)'));
    });
  });

  group('SandboxPlan — the one place layout and gate agree', () {
    test(
        'writableLayout is exactly what the gate should take: root, '
        'grants, temp space — deduplicated', () {
      final plan = SandboxPlan(
        workspaceRoot: '/w',
        writablePaths: ['/shared', '/w'],
      );
      expect(plan.writableLayout(),
          <String>{'/w', '/shared', ...defaultSandboxTempDirs()}.toList());
    });

    test('mountedLayout adds the read-only system directories and tinaDir', () {
      final plan = SandboxPlan(workspaceRoot: '/w', tinaDir: '/t');
      expect(plan.mountedLayout(), containsAll(['/w', '/usr', '/etc', '/t']));
    });

    test('the default child environment carries no inherited values', () {
      final plan = SandboxPlan(workspaceRoot: '/w');
      expect(plan.childEnvironment.keys, ['PATH', 'HOME', 'TMPDIR', 'LANG']);
      expect(plan.childEnvironment['HOME'], '/tmp');
    });
  });
}
