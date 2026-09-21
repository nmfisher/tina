import 'dart:async';
import 'dart:io';

import 'package:classifier/classification.dart';
import 'package:tina_app/src/classification/repository_evidence.dart';
import 'package:test/test.dart';
import 'package:tina_app/src/classification/file_classification_store.dart';
import 'package:tina_app/src/classification/repository_classification_source.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  late Directory project;
  late FileClassificationStore store;
  late RepositoryEvidenceReader source;
  setUp(() async {
    project = await Directory.systemTemp.createTemp('classifications-');
    await Process.run('git', ['init', '-q', project.path]);
    store = FileClassificationStore(project.path);
    source = RepositoryEvidenceReader(
      root: project.path,
      sandbox: SandboxedFileSystem(
        const IoFileSystem(),
        projectRoot: project.path,
        tinaDir: Directory('${project.path}/private'),
      ),
    );
  });
  tearDown(() => project.delete(recursive: true));
  Future<void> write(String path, String text) async {
    final file = File('${project.path}/$path');
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  test(
    'missing restore does not create storage; records survive a new adapter',
    () async {
      expect(await store.readManifest(), isNull);
      expect(await Directory('${project.path}/.tina').exists(), isFalse);
      final record = <String, Object?>{'result': 'dart'};
      final id = canonicalFingerprint(record);
      await store.withWriter(() async {
        await store.writeRecord(id, record);
        await store.writeManifest({
          'records': {'root': id},
        });
      });
      final reopened = FileClassificationStore(project.path);
      expect(await reopened.readRecord(id), record);
      expect((await reopened.readManifest())!['records'], {'root': id});
      expect(
        await File(
          '${project.path}/.tina/classifications/.gitignore',
        ).readAsString(),
        '*\n',
      );
    },
  );

  test(
    'concurrent writers fail before work and release the lock on errors',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final first = store.withWriter(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      await expectLater(
        FileClassificationStore(
          project.path,
        ).withWriter(() async => fail('must not run')),
        throwsStateError,
      );
      release.complete();
      await first;
      await expectLater(
        store.withWriter(() async => throw StateError('failed')),
        throwsStateError,
      );
      await store.withWriter(() async {});
    },
  );

  test('corrupt and oversized manifests restore as misses', () async {
    await write('.tina/classifications/manifest.json', '{');
    expect(await store.readManifest(), isNull);
    await write(
      '.tina/classifications/manifest.json',
      ' ' * (2 * 1024 * 1024 + 1),
    );
    expect(await store.readManifest(), isNull);
    expect(() => store.readRecord('../outside'), throwsFormatException);
  });

  test('storage rejects linked directory and linked records', () async {
    await Directory('${project.path}/outside').create();
    await Link('${project.path}/.tina').create('${project.path}/outside');
    await expectLater(store.readManifest(), throwsStateError);
    await expectLater(store.withWriter(() async {}), throwsStateError);
    await Link('${project.path}/.tina').delete();
    await store.withWriter(() async {});
    await write('data', '{}');
    await Link(
      '${project.path}/.tina/classifications/manifest.json',
    ).create('${project.path}/data');
    await expectLater(store.readManifest(), throwsStateError);
  });

  test(
    'inventory includes new untracked files and excludes child scopes and private output',
    () async {
      await write('a/pubspec.yaml', 'name: a');
      await write('b/package.json', '{}');
      await write('.gitignore', 'ignored/\n');
      await write('ignored/secret', 'x');
      await write('.env', 'secret');
      await write('.tina/classifications/noise', 'x');
      final query = EvidenceQuery(
        EvidenceKind.listing,
        '.',
        excludedScopes: ['b'],
      );
      final first = await source.observe(query);
      expect(first.value, ['.gitignore', 'a/pubspec.yaml']);
      await write('a/main.dart', 'void main() {}');
      expect(
        (await source.observe(query)).fingerprint,
        isNot(first.fingerprint),
      );
    },
  );

  test(
    'files and absence are hashed from current working tree, rejecting links and binary data',
    () async {
      final query = EvidenceQuery(EvidenceKind.file, 'package.json');
      final missing = await source.observe(query);
      expect(missing.value, isNull);
      await write('package.json', '{}');
      expect(
        (await source.observe(query)).fingerprint,
        isNot(missing.fingerprint),
      );
      await Link(
        '${project.path}/linked.json',
      ).create('${project.path}/package.json');
      await expectLater(
        source.observe(EvidenceQuery(EvidenceKind.file, 'linked.json')),
        throwsStateError,
      );
      await write('binary', '\u0000');
      await expectLater(
        source.observe(EvidenceQuery(EvidenceKind.file, 'binary')),
        throwsStateError,
      );
      await write('large', 'x' * (128 * 1024 + 1));
      await expectLater(
        source.observe(EvidenceQuery(EvidenceKind.file, 'large')),
        throwsStateError,
      );
      await expectLater(
        source.observe(EvidenceQuery(EvidenceKind.file, '.env')),
        throwsStateError,
      );
    },
  );

  test(
    'non-Git repository cannot produce an exhaustive negative result',
    () async {
      await Directory('${project.path}/.git').delete(recursive: true);
      await expectLater(
        source.observe(EvidenceQuery(EvidenceKind.listing, '.')),
        throwsStateError,
      );
    },
  );
  test('another process cannot acquire the writer lock', () async {
    final probe = File('${project.path}/lock_probe.dart');
    await probe.writeAsString(
      "import 'dart:io';\nvoid main(List<String> args) async {\n"
      "final file = await File(args.single).open(mode: FileMode.append);\n"
      "try { await file.lock(FileLock.exclusive); print('acquired'); }\n"
      "on FileSystemException { print('blocked'); } finally { await file.close(); }\n}\n",
    );
    await store.withWriter(() async {
      final result = await Process.run(Platform.resolvedExecutable, [
        probe.path,
        '${project.path}/.tina/classifications/.lock',
      ]).timeout(const Duration(seconds: 15));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect((result.stdout as String).trim(), 'blocked');
    });
  });
  test('deleted tracked files leave the working-tree inventory', () async {
    await write('main.dart', 'void main() {}');
    await Process.run('git', [
      'add',
      'main.dart',
    ], workingDirectory: project.path);
    final query = EvidenceQuery(EvidenceKind.listing, '.');
    final before = await source.observe(query);
    expect(before.value, ['main.dart']);
    await File('${project.path}/main.dart').delete();
    final after = await source.observe(query);
    expect(after.value, isEmpty);
    expect(after.fingerprint, isNot(before.fingerprint));
  });
}
