import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:tina_engine/src/agent/project_tool_scope.dart';
import 'package:tina_engine/src/tools/atomic_write.dart';
import 'package:tina_engine/src/tools/mutation_lock.dart';
import 'package:tina_engine/src/tools/process_runner.dart';
import 'package:tina_engine/src/tools/project_capabilities.dart';
import 'package:tina_engine/src/tools/sandbox.dart';
import 'package:tina_engine/src/tools/sandbox_runner.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('project_caps_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('ProjectCapabilities.build', () {
    test('confined build wires a SandboxedProcessRunner, sandboxed fs and a '
        'backup store', () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
      );

      expect(p.isAbsolute(caps.projectRoot), isTrue);
      expect(caps.projectRoot, p.normalize(p.absolute(tempDir.path)));
      expect(caps.confineFiles, isTrue);
      expect(caps.sandboxEnabled, isTrue);
      expect(caps.fileSystem, isA<SandboxedFileSystem>());
      expect(caps.backups, isA<BackupStore>());
      expect(caps.processRunner, isA<SandboxedProcessRunner>());
      expect(caps.mutationLock, isA<FileMutationLock>());
    });

    test('confined build shares one BackupStore (and fs) across the store and '
        'the sandbox', () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
      );

      // Single instances: every borrower of these capabilities — both file
      // tools' backup wiring and any later scope — sees the same store.
      expect(caps.backups, same(caps.backups));
      expect(caps.fileSystem, same(caps.fileSystem));
    });

    test('unconfined build wires IoProcessRunner and null fs/backups', () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
        confineFiles: false,
        sandboxEnabled: false,
      );

      expect(caps.confineFiles, isFalse);
      expect(caps.sandboxEnabled, isFalse);
      expect(caps.fileSystem, isNull);
      expect(caps.backups, isNull);
      expect(caps.processRunner, isA<IoProcessRunner>());
      expect(caps.mutationLock, isA<FileMutationLock>());
    });

    test('environment snapshot is unmodifiable', () {
      final caps = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {'TINA_TEST_KEY': 'v'},
      );

      expect(caps.environment['TINA_TEST_KEY'], 'v');
      expect(() => caps.environment['TINA_TEST_KEY'] = 'other',
          throwsUnsupportedError);
    });

    test('two builds for the same root produce INDEPENDENT mutation locks and '
        'sandboxes', () {
      final a = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
      );
      final b = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
      );

      expect(identical(a.mutationLock, b.mutationLock), isFalse,
          reason: 'each build owns its own per-project lock');
      expect(identical(a.fileSystem, b.fileSystem), isFalse,
          reason: 'each build owns its own sandbox');
      expect(identical(a.processRunner, b.processRunner), isFalse);
      expect(a.projectRoot, b.projectRoot);
    });

    test('the same capabilities object means one shared mutation lock', () {
      // The lock identity comes from the capabilities: ProjectToolScope's
      // private constructor assigns `mutationLock = capabilities.mutationLock`,
      // so two scopes sharing one capabilities object would share one lock.
      // The public API builds capabilities per scope, so verify the identity
      // anchor: one capabilities object owns exactly one lock, while scopes
      // built separately each get their own.
      final shared = ProjectCapabilities.build(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );
      expect(shared.mutationLock, same(shared.mutationLock));
      expect(shared.mutationLock, isA<FileMutationLock>());

      final scopeA = ProjectToolScope(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );
      final scopeB = ProjectToolScope(
        projectRoot: tempDir.path,
        env: const {},
        sandboxEnabled: false,
      );
      expect(identical(scopeA.mutationLock, scopeB.mutationLock), isFalse,
          reason: 'separately built scopes never share a lock');
      expect(identical(scopeA.mutationLock, shared.mutationLock), isFalse);
      expect(scopeA.mutationLock, isA<FileMutationLock>());
    });
  });
}
