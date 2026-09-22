// Tests for the macOS `sandbox-exec` confinement wrapper around the bash
// subprocess: the profile builder, the argv rewrite at the ProcessRunner seam,
// pass-through when disabled, and (on macOS) a real integration check that a
// confined command can write under the project root but NOT outside it.

import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/memory_process_runner.dart';

void main() {
  group('buildSandboxProfile', () {
    test('denies all writes then re-grants the project root + temp + devs', () {
      final temp = Directory.systemTemp.createTempSync('tina-sb-profile-');
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final profile = buildSandboxProfile(
        workspaceRoot: temp.path,
        extraAllowPaths: const [],
      );
      expect(profile, contains('(version 1)'));
      expect(profile, contains('(allow default)'));
      expect(profile, contains('(deny file-write*)'));
      // The real project root is re-granted as a writable subpath.
      final resolved = temp.resolveSymbolicLinksSync();
      expect(profile, contains('(allow file-write* (subpath "$resolved"))'));
      // OS temp + the pseudo-devices a normal command touches (granted as
      // subpaths, uniformly with the project root).
      expect(profile, contains('/private/var/folders'));
      expect(profile, contains('/tmp'));
      expect(profile, contains('(subpath "/dev/null")'));
      expect(profile, contains('(subpath "/dev/dtracehelper")'));
    });

    test('extra allow-paths are resolved and granted', () {
      final a = Directory.systemTemp.createTempSync('tina-sb-extra-');
      addTearDown(() {
        try {
          a.deleteSync(recursive: true);
        } catch (_) {}
      });
      final profile = buildSandboxProfile(
        workspaceRoot: a.path,
        extraAllowPaths: [a.path],
      );
      expect(profile, contains('(subpath "${a.resolveSymbolicLinksSync()}")'));
    });

    test('--sandbox-readonly drops the project write grant, keeps it readable',
        () {
      final temp = Directory.systemTemp.createTempSync('tina-sb-ro-');
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final resolved = temp.resolveSymbolicLinksSync();
      final profile = buildSandboxProfile(
        workspaceRoot: temp.path,
        sandboxReadOnly: true,
      );
      // The project is no longer writable…
      expect(
          profile,
          isNot(contains(
              '(allow file-write* (subpath "$resolved"))')));
      // …but reads under the user's home are denied and the project is
      // re-granted read-only, so a read/analyze run still works inside it.
      // Which directory that is depends on the host's $HOME; the exact path is
      // pinned by the hermetic 'home directory' test below.
      expect(profile, contains('(deny file-read* (subpath "'));
      expect(profile, contains('(allow file-read* (subpath "$resolved"))'));
      // Temp stays writable for scratch output.
      expect(profile, contains('(allow file-write* (subpath "/tmp"))'));
    });
  });

  group('SandboxedProcessRunner argv rewrite', () {
    test('wraps the command in `sandbox-exec -p <profile> <exec> <args>`',
        () async {
      final inner = MemoryProcessRunner.always(
          MemoryRunningProcess(exitCodeValue: 0));
      final temp = Directory.systemTemp.createTempSync('tina-sb-argv-');
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } catch (_) {}
      });
      final runner = SandboxedProcessRunner(
        inner: inner,
        workspaceRoot: temp.path,
        enabled: true,
        // Pinned so the macOS rewrite is exercised on every platform; the
        // per-platform dispatch itself is covered in
        // sandbox_runner_linux_test.dart.
        backend: SandboxBackend.sandboxExec,
      );
      await runner.start('/bin/sh', ['-c', 'echo hi']);

      expect(inner.starts.single.executable, 'sandbox-exec');
      final args = inner.starts.single.arguments;
      expect(args[0], '-p');
      expect(args[1], contains('(deny file-write*)'));
      // The original command follows the profile.
      expect(args[2], '/bin/sh');
      expect(args.sublist(2), ['/bin/sh', '-c', 'echo hi']);
    });

    test('passes the command through unchanged when disabled', () async {
      final inner = MemoryProcessRunner.always(
          MemoryRunningProcess(exitCodeValue: 0));
      final runner = SandboxedProcessRunner(
        inner: inner,
        workspaceRoot: '/whatever',
        enabled: false,
      );
      await runner.start('/bin/sh', ['-c', 'echo hi']);
      expect(inner.starts.single.executable, '/bin/sh');
      expect(inner.starts.single.arguments, ['-c', 'echo hi']);
    });
  });

  // Real `sandbox-exec` confinement — only meaningful where it exists.
  group('integration (macOS sandbox-exec)', () {
    // Skipped entirely on non-macOS: the runner is a pass-through there and
    // there is no OS-level write containment to exercise.
    if (!sandboxExecAvailable) return;

    late Directory project;
    setUp(() {
      project = Directory.systemTemp.createTempSync('tina-sb-int-');
    });
    tearDown(() {
      try {
        project.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('a write under the project root succeeds', () async {
      final runner = SandboxedProcessRunner(workspaceRoot: project.path);
      final target = '${project.path}/inside.txt';
      final proc = await runner.start('/bin/sh', ['-c', 'echo x > $target']);
      final code = await proc.exitCode;
      expect(code, 0);
      expect(File(target).existsSync(), isTrue);
    });

    test('a write outside the project root is blocked', () async {
      // The sandbox's allow-list includes the project root AND the OS temp
      // tree (/private/var/folders), so a temp dir sibling would still be
      // writable. To prove confinement we need a target that is writable in
      // normal operation but genuinely OUTSIDE both: the package's own
      // directory (cwd, on disk — not under temp). We never grant that path,
      // so the confined write must fail.
      final outside = Directory(
          '${Directory.current.path}/.tina-sb-outside-${project.hashCode}');
      addTearDown(() {
        try {
          outside.deleteSync(recursive: true);
        } catch (_) {}
      });
      // Create the parent first so that a blocked write fails purely because
      // of the sandbox (not a missing-directory error), and so an unsandboxed
      // run would succeed here.
      outside.createSync(recursive: true);
      final runner = SandboxedProcessRunner(workspaceRoot: project.path);
      final target = '${outside.path}/escape.txt';
      final proc = await runner.start('/bin/sh', ['-c', 'echo x > $target']);
      final code = await proc.exitCode;
      expect(code, isNot(0), reason: 'the sandbox must deny the outside write');
      expect(File(target).existsSync(), isFalse,
          reason: 'no file should be created outside the project root');
    });
  });

  group('macOS profile rendering', () {
    // The renderer is pure: paths arrive already resolved, so these pin the
    // text without depending on the developer machine.
    test('a read-only run denies reads of each named directory', () {
      final profile = buildMacSandboxProfile(
        writablePaths: const ['/proj'],
        root: '/proj',
        readOnlyProject: true,
        readDenyPaths: const ['/custom/home', '/Volumes/data'],
        isolateNetwork: false,
      );
      expect(profile, contains('(deny file-read* (subpath "/custom/home"))'));
      expect(profile, contains('(deny file-read* (subpath "/Volumes/data"))'));
      expect(profile, contains('(allow file-read* (subpath "/proj"))'));
      expect(profile, isNot(contains('(deny network*)')));
    });

    test('a read-only run that names nothing to deny cannot be rendered', () {
      // The baseline is `(allow default)`, so a missing deny would silently
      // leave reads open — fail loudly instead.
      expect(
          () => buildMacSandboxProfile(
                writablePaths: const ['/proj'],
                root: '/proj',
                readOnlyProject: true,
                isolateNetwork: false,
              ),
          throwsA(isA<AssertionError>()));
    });

    test('a writable run denies no reads', () {
      final profile = buildMacSandboxProfile(
        writablePaths: const ['/proj'],
        root: '/proj',
        readOnlyProject: false,
        isolateNetwork: false,
      );
      expect(profile, isNot(contains('deny file-read*')));
      expect(profile, contains('(allow file-write* (subpath "/proj"))'));
    });

    test('network isolation is its own deny', () {
      final profile = buildMacSandboxProfile(
        writablePaths: const ['/proj'],
        root: '/proj',
        readOnlyProject: false,
        isolateNetwork: true,
      );
      expect(profile, contains('(deny network*)'));
    });

    test('the read-deny names the real home, not the old hard-coded /Users',
        () async {
      final home = Directory.systemTemp.createTempSync('tina-home-');
      addTearDown(() => home.deleteSync(recursive: true));
      final resolved = home.resolveSymbolicLinksSync();

      final profile = buildSandboxProfile(
        workspaceRoot: home.path,
        sandboxReadOnly: true,
        homeOverride: home.path,
      );
      expect(profile, contains('(deny file-read* (subpath "$resolved"))'));
      expect(profile, isNot(contains('(subpath "/Users")')));
    });
  });
}
