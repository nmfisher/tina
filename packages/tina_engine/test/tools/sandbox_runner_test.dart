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
        projectRoot: temp.path,
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
        projectRoot: a.path,
        extraAllowPaths: [a.path],
      );
      expect(profile, contains('(subpath "${a.resolveSymbolicLinksSync()}")'));
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
        projectRoot: temp.path,
        enabled: true,
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
        projectRoot: '/whatever',
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
      final runner = SandboxedProcessRunner(projectRoot: project.path);
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
      final runner = SandboxedProcessRunner(projectRoot: project.path);
      final target = '${outside.path}/escape.txt';
      final proc = await runner.start('/bin/sh', ['-c', 'echo x > $target']);
      final code = await proc.exitCode;
      expect(code, isNot(0), reason: 'the sandbox must deny the outside write');
      expect(File(target).existsSync(), isFalse,
          reason: 'no file should be created outside the project root');
    });
  });
}
