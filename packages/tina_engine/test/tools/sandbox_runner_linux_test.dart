// Tests for the Linux leg of the bash sandbox: the pure `bwrap` argv builder
// (mounts, extras, the --sandbox-net / --sandbox-readonly flips), the
// platform dispatch matrix, the pass-through + one-time-warning degradation,
// and — only where `bwrap` actually exists — a real confinement check that
// mirrors the macOS integration tests in sandbox_runner_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:tina_engine/src/tools/sandbox_runner.dart';
import 'package:test/test.dart';

import '../helpers/memory_process_runner.dart';

void main() {
  group('resolveSandboxBackendFor (pure dispatch matrix)', () {
    test('macOS picks sandbox-exec only when the binary is present', () {
      expect(
        resolveSandboxBackendFor(
            isMacOS: true, isLinux: false, osName: 'macos',
            sandboxExecPresent: true),
        SandboxBackend.sandboxExec,
      );
      expect(
        resolveSandboxBackendFor(
            isMacOS: true, isLinux: false, osName: 'macos',
            sandboxExecPresent: false),
        SandboxBackend.passThrough,
      );
    });

    test('linux picks bwrap only with the binary AND user namespaces', () {
      expect(
        resolveSandboxBackendFor(
            isMacOS: false, isLinux: true, osName: 'linux',
            bwrapPresent: true, userNsEnabled: true),
        SandboxBackend.bwrap,
      );
      expect(
        resolveSandboxBackendFor(
            isMacOS: false, isLinux: true, osName: 'linux',
            bwrapPresent: false, userNsEnabled: true),
        SandboxBackend.passThrough,
      );
      expect(
        resolveSandboxBackendFor(
            isMacOS: false, isLinux: true, osName: 'linux',
            bwrapPresent: true, userNsEnabled: false),
        SandboxBackend.passThrough,
      );
    });

    test('--no-sandbox and unknown platforms pass through', () {
      expect(
        resolveSandboxBackendFor(
            isMacOS: true, isLinux: false, osName: 'macos',
            sandboxEnabled: false, sandboxExecPresent: true),
        SandboxBackend.passThrough,
      );
      expect(
        resolveSandboxBackendFor(
            isMacOS: false, isLinux: true, osName: 'linux',
            sandboxEnabled: false, bwrapPresent: true),
        SandboxBackend.passThrough,
      );
      expect(
        resolveSandboxBackendFor(
            isMacOS: false, isLinux: false, osName: 'windows'),
        SandboxBackend.passThrough,
      );
    });
  });

  group('sandboxPassThroughReasonFor', () {
    test('names the reason for each degradation, null when active', () {
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: true, isLinux: false, osName: 'macos',
            sandboxExecPresent: true),
        isNull,
      );
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: true, isLinux: false, osName: 'macos'),
        'sandbox-exec not found',
      );
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: false, isLinux: true, osName: 'linux'),
        'bwrap not found on PATH',
      );
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: false, isLinux: true, osName: 'linux',
            bwrapPresent: true, userNsEnabled: false),
        'unprivileged user namespaces are disabled',
      );
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: false, isLinux: false, osName: 'windows'),
        contains('windows'),
      );
      expect(
        sandboxPassThroughReasonFor(
            isMacOS: true, isLinux: false, osName: 'macos',
            sandboxEnabled: false, sandboxExecPresent: true),
        contains('--no-sandbox'),
      );
    });
  });

  group('buildBwrapArgs (Linux profile builder)', () {
    test('default binds: ro system dirs, rw project + tmp, dev/proc, net on',
        () {
      final project = Directory.systemTemp.createTempSync('tina-bwrap-');
      addTearDown(() {
        try {
          project.deleteSync(recursive: true);
        } catch (_) {}
      });
      final root = project.resolveSymbolicLinksSync();
      final args = buildBwrapArgs(projectRoot: project.path);
      final binds = <String, String>{
        for (var i = 0; i < args.length - 1; i++)
          if (args[i] == '--ro-bind' || args[i] == '--bind')
            args[i + 2 + args.indexOf(args[i], i) - i - 1]: args[i + 1]
      };
      // Read-only system dirs (those that exist on this host) are ro-binds.
      for (final dir in kLinuxSandboxReadOnlyBinds) {
        if (Directory(dir).existsSync()) {
          expect(binds[dir], dir, reason: '$dir should be bound read-only');
        }
      }
      // The project + temp trees are writable binds.
      expect(binds[root], root);
      for (final t in ['/tmp', '/var/tmp']) {
        expect(binds.containsKey(t), isTrue,
            reason: '$t should be bound writable');
      }
      // Pseudo-devices provided fresh; network stays on (no --unshare-net);
      // argv ends with `--` so the wrapped command can't be mistaken for a
      // bwrap option.
      expect(args, containsAllInOrder(['--dev', '/dev']));
      expect(args, containsAllInOrder(['--proc', '/proc']));
      expect(args, isNot(contains('--unshare-net')));
      expect(args.last, '--');
    });

    test('TINA_SANDBOX_ALLOW extras become writable binds, after the project',
        () {
      final project = Directory.systemTemp.createTempSync('tina-bwrap-xtra-');
      final extra = Directory('${project.path}/allowed')..createSync();
      addTearDown(() {
        try {
          project.deleteSync(recursive: true);
        } catch (_) {}
      });
      final resolved = extra.resolveSymbolicLinksSync();
      // Put the extra INSIDE the project (the interesting case): bwrap
      // applies mounts in argv order, so the extra must bind AFTER the
      // project — even a read-only project posture leaves the extra writable.
      final args = buildBwrapArgs(
        projectRoot: project.path,
        extraAllowPaths: [extra.path],
        sandboxReadOnly: true,
      );
      final extraIdx = args.indexOf(resolved);
      expect(extraIdx, greaterThan(0));
      expect(args[extraIdx - 1], '--bind', reason: 'extras are writable');
      final rootIdx = args.indexOf(project.resolveSymbolicLinksSync());
      expect(rootIdx, greaterThan(0));
      expect(args[rootIdx - 1], '--ro-bind',
          reason: 'the project posture stays read-only');
      expect(extraIdx, greaterThan(rootIdx),
          reason: 'the extra mounts over the read-only project, so it wins');
    });

    test('--sandbox-net adds --unshare-net before the -- separator', () {
      final args = buildBwrapArgs(
        projectRoot: '/tmp',
        sandboxNet: true,
      );
      final sep = args.indexOf('--');
      expect(args.contains('--unshare-net'), isTrue);
      expect(args.indexOf('--unshare-net'), lessThan(sep));
    });

    test('--sandbox-readonly flips the project bind to read-only', () {
      final project = Directory.systemTemp.createTempSync('tina-bwrap-ro-');
      addTearDown(() {
        try {
          project.deleteSync(recursive: true);
        } catch (_) {}
      });
      final root = project.resolveSymbolicLinksSync();
      final args = buildBwrapArgs(
        projectRoot: project.path,
        sandboxReadOnly: true,
      );
      final rootIdx = args.indexOf(root);
      expect(rootIdx, greaterThan(0));
      // The project mount is a ro-bind…
      expect(args[rootIdx - 1], '--ro-bind');
      // …while temp (bound before the project, so it wins inside its own
      // subtree) stays writable.
      final tmpIdx = args.indexOf('/tmp');
      expect(args[tmpIdx - 1], '--bind');
      expect(tmpIdx, lessThan(rootIdx));
    });

    test('missing read-only dirs are skipped, unresolvable extras logged',
        () {
      final args = buildBwrapArgs(
        projectRoot: '/nonexistent-project',
        readOnlyBinds: ['/definitely/not/here', '/etc'],
      );
      expect(args.contains('/definitely/not/here'), isFalse,
          reason: 'a missing source must not reach bwrap (it would abort)');
      if (Directory('/etc').existsSync()) {
        expect(args, containsAllInOrder(['--ro-bind', '/etc', '/etc']));
      }
    });
  });

  group('SandboxedProcessRunner dispatch (pinned backend)', () {
    test('linux backend rewrites argv to `bwrap <args> -- <exec> <args>`',
        () async {
      final inner = MemoryProcessRunner.always(
          MemoryRunningProcess(exitCodeValue: 0));
      final project = Directory.systemTemp.createTempSync('tina-bwrap-argv-');
      addTearDown(() {
        try {
          project.deleteSync(recursive: true);
        } catch (_) {}
      });
      final runner = SandboxedProcessRunner(
        inner: inner,
        projectRoot: project.path,
        sandboxNet: true,
        backend: SandboxBackend.bwrap,
        unavailableReason: '',
      );
      await runner.start('/bin/sh', ['-c', 'echo hi']);

      expect(inner.starts.single.executable, 'bwrap');
      final args = inner.starts.single.arguments;
      expect(args.contains('--unshare-net'), isTrue);
      final sep = args.indexOf('--');
      expect(sep, greaterThan(0));
      // The original command follows the separator verbatim.
      expect(args.sublist(sep + 1), ['/bin/sh', '-c', 'echo hi']);
      // The project bind is present before the separator.
      expect(args.take(sep),
          contains(project.resolveSymbolicLinksSync()));
    });

    test('pass-through leaves argv untouched and warns exactly once',
        () async {
      final inner = MemoryProcessRunner.always(
          MemoryRunningProcess(exitCodeValue: 0));
      final warnings = <String>[];
      final runner = SandboxedProcessRunner(
        inner: inner,
        projectRoot: '/whatever',
        backend: SandboxBackend.passThrough,
        unavailableReason: 'bwrap not found on PATH',
        warn: warnings.add,
      );
      await runner.start('/bin/sh', ['-c', 'echo hi']);
      await runner.run('/bin/sh', ['-c', 'echo hi']);
      await runner.start('/bin/sh', ['-c', 'echo again']);

      expect(inner.starts, hasLength(2));
      expect(inner.starts.first.executable, '/bin/sh');
      expect(inner.starts.first.arguments, ['-c', 'echo hi']);
      expect(inner.runs.single.executable, '/bin/sh');
      // One-time warning for the degraded backend — not one per invocation.
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('bwrap not found on PATH'));
    });

    test('a deliberate --no-sandbox disable does not warn', () async {
      final inner = MemoryProcessRunner.always(
          MemoryRunningProcess(exitCodeValue: 0));
      final warnings = <String>[];
      final runner = SandboxedProcessRunner(
        inner: inner,
        projectRoot: '/whatever',
        enabled: false,
        backend: SandboxBackend.passThrough,
        unavailableReason: 'explicitly disabled (--no-sandbox)',
        warn: warnings.add,
      );
      await runner.start('/bin/sh', ['-c', 'echo hi']);
      expect(warnings, isEmpty,
          reason: 'the user asked for this; it is not a degradation');
      expect(inner.starts.single.executable, '/bin/sh');
    });

    test('backendDescription reports each backend for the startup log', () {
      String describe(SandboxBackend b) => describeSandboxBackend(b,
          passThroughReason: 'bwrap not found on PATH');
      expect(describe(SandboxBackend.sandboxExec), contains('sandbox-exec'));
      expect(describe(SandboxBackend.bwrap), contains('bwrap'));
      final pass = describe(SandboxBackend.passThrough);
      expect(pass, contains('pass-through'));
      expect(pass, contains('bwrap not found on PATH'));
    });
  });

  // Real `bwrap` confinement — only meaningful where bwrap exists and
  // unprivileged user namespaces are enabled (CI images vary); skipped
  // elsewhere exactly like the macOS group in sandbox_runner_test.dart.
  group('integration (linux bwrap)', () {
    if (!bwrapAvailable) return;

    late Directory project;
    setUp(() {
      project = Directory.systemTemp.createTempSync('tina-bwrap-int-');
    });
    tearDown(() {
      try {
        project.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('a write under the project root succeeds', () async {
      final runner = SandboxedProcessRunner(projectRoot: project.path);
      final target = '${project.path}/inside.txt';
      final proc = await runner.start(
          '/bin/sh', ['-c', 'echo x > "$target" && cat "$target"']);
      final code = await proc.exitCode;
      expect(code, 0, reason: 'the project bind is writable');
      expect(File(target).existsSync(), isTrue);
    });

    test('a write outside the sandbox mounts is blocked', () async {
      // The project's parent (the test runner's cwd tree) is deliberately not
      // mounted: bwrap is namespace-first, so an unmounted path is invisible
      // and the write must fail even though it would succeed unsandboxed.
      final outside = Directory(
          '${Directory.current.path}/.tina-bwrap-outside-${project.hashCode}');
      addTearDown(() {
        try {
          outside.deleteSync(recursive: true);
        } catch (_) {}
      });
      outside.createSync(recursive: true);
      final runner = SandboxedProcessRunner(projectRoot: project.path);
      final proc = await runner.start(
          '/bin/sh', ['-c', 'mkdir -p "$outside" && touch "$outside/e.txt"']);
      final code = await proc.exitCode;
      expect(code, isNot(0),
          reason: 'the sandbox must block a write outside its mounts');
      expect(File('${outside.path}/e.txt').existsSync(), isFalse,
          reason: 'no file should be created outside the sandbox');
    });

    test('--sandbox-net blocks localhost egress', () async {
      final withNet = SandboxedProcessRunner(projectRoot: project.path);
      final netArgs = buildBwrapArgs(
        projectRoot: project.path,
        sandboxNet: true,
      );
      // curl's exit code for "couldn't resolve/connect" — connection refused
      // on the discard port proves the loopback namespace is unshared.
      const probe =
          'curl -sS -m 5 -o /dev/null http://127.0.0.1:1/ ; echo -n \$?';
      final unshared = await withNet.run(
          'bwrap', [...netArgs, '/bin/sh', '-c', probe]);
      expect(unshared.stdout, '7',
          reason: 'with --unshare-net loopback is unreachable (curl exit 7)');

      // The default posture keeps network on: the same probe must NOT see
      // the unshared error (it may connect, time out, or fail on DNS — any
      // code but the can't-create-socket one).
      final shared = await withNet.run(
          'bwrap',
          [...buildBwrapArgs(projectRoot: project.path), '/bin/sh', '-c',
              probe]);
      expect(shared.stdout, isNot('7'),
          reason: 'without --unshare-net the socket is creatable');
    });

    test('--sandbox-readonly blocks a project write but reads still work',
        () async {
      final marker = File('${project.path}/seed.txt');
      marker.writeAsStringSync('seed');
      final runner = SandboxedProcessRunner(
        projectRoot: project.path,
        sandboxReadOnly: true,
      );
      // Temp stays writable (scratch output), the project does not.
      final proc = await runner.start('/bin/sh', [
        '-c',
        'cat "${project.path}/seed.txt" && '
            'echo x > "${project.path}/nope.txt" ; echo -n \$?'
      ]);
      final out = await utf8.decodeStream(proc.stdout);
      final code = await proc.exitCode;
      expect(code, 0, reason: 'reads inside the project keep working');
      expect(out, startsWith('seed'));
      expect(out, isNot(endsWith('0')),
          reason: 'the project write must fail under --sandbox-readonly');
      expect(File('${project.path}/nope.txt').existsSync(), isFalse);
    });
  });
}
