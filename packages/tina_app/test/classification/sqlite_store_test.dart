import 'dart:async';
import 'dart:io';

import 'package:classifier/classification.dart';
import 'package:test/test.dart';
import 'package:tina_app/classification.dart';

Map<String, dynamic> result(String label) => {
  'schema_version': classificationSchemaVersion,
  'signature': 'test',
  'provenance': {
    'request': {'subject': 'src'},
    'plan': {'id': 'test'},
  },
  'source_revision': {'test': true},
  'coverage': {'complete': true, 'gaps': []},
  'request_records': [],
  'result': {
    'outcome': 'classified',
    'value': {
      'labels': [
        {
          'value': label,
          'evidence': ['path:src/a.py'],
        },
      ],
    },
    'evidence': ['path:src/a.py'],
    'explanation': 'A test result.',
  },
};

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('classification-db-');
  });
  tearDown(() => root.delete(recursive: true));
  Future<SqliteClassificationStore> open({bool create = false}) async {
    final store = await SqliteClassificationStore.open(
      root.path,
      create: create,
    );
    addTearDown(store.close);
    return store;
  }

  test('missing database reads create no files', () async {
    final store = await open();
    expect(store.exists, isFalse);
    expect(await store.readManifest(), isNull);
    final view = await readIndex(store: store);
    expect(view.warning, contains('No saved index'));
    expect(await root.list().isEmpty, isTrue);
    await expectLater(store.withWriter(() async {}), throwsStateError);
  });

  test(
    'initialization resumes after an interrupted schema transaction',
    () async {
      final file = File('${root.path}/.tina/classifications/index.db');
      await file.parent.create(recursive: true);
      await file.create();
      final store = await open(create: true);
      final value = result('python');
      final id = canonicalFingerprint(value);
      await store.withWriter(
        () => store.publish('task:.::language', id, value),
      );
      expect(await store.readRecord(id), value);
      expect(await File('${store.root}/.gitignore').readAsString(), '*\n');
    },
  );

  test(
    'records round-trip without duplicate output and readers see atomic checkpoints',
    () async {
      final writer = await open(create: true);
      final python = result('python');
      final pythonId = canonicalFingerprint(python);
      final dart = result('dart');
      final dartId = canonicalFingerprint(dart);
      await writer.withWriter(
        () => writer.publish('task:src::language', pythonId, python),
      );
      final reader = await open();
      expect(await reader.readRecord(pythonId), python);
      await writer.withWriter(() async {
        await writer.publish('task:src::language', dartId, dart);
        // Invalid references roll back the entire manifest replacement.
        await expectLater(
          writer.writeManifest({
            'records': {'task:src::language': 'missing'},
          }),
          throwsStateError,
        );
      });
      expect((await reader.readManifest())!['records'], {
        'task:src::language': pythonId,
      });
      final latest = await open();
      expect((await latest.readManifest())!['records'], {
        'task:src::language': dartId,
      });
      expect(await latest.readRecord(dartId), dart);
      expect(await File('${writer.root}/manifest.json').exists(), isFalse);
      expect(await Directory('${writer.root}/records').exists(), isFalse);
      final detail = await latest.details('src');
      expect(detail['task:src::language'], dart);
      expect(
        (await latest.node('src'))!.toString(),
        isNot(contains('path:src/a.py')),
      );
    },
  );

  test(
    'writer exclusion and failure preserve previously committed progress',
    () async {
      final first = await open(create: true);
      final second = await open(create: true);
      final record = result('python');
      final id = canonicalFingerprint(record);
      await expectLater(
        first.withWriter(() async {
          await first.publish('task:src::language::local', id, record);
          await expectLater(
            SqliteClassificationStore.open(root.path, create: true),
            throwsStateError,
          );
          final reader = await open();
          expect(await reader.readRecord(id), record);
          await expectLater(
            second.withWriter(() async => fail('must not run')),
            throwsStateError,
          );
          throw StateError('cancelled work');
        }),
        throwsStateError,
      );
      await second.withWriter(() async {
        expect(await second.readRecord(id), record);
        expect((await second.readManifest())!['records'], {
          'task:src::language::local': id,
        });
      });
      await expectLater(
        first.publish('task:src::language', id, record),
        throwsStateError,
      );
    },
  );

  test(
    'migration preserves record identities and request links, then removes legacy copies',
    () async {
      final old = FileClassificationStore(root.path);
      final request = result('python')..remove('coverage');
      final requestId = canonicalFingerprint(request);
      final record = result('python')..['request_records'] = [requestId];
      final id = canonicalFingerprint(record);
      await old.withWriter(() async {
        await old.writeRecord(requestId, request);
        await old.writeRecord(id, record);
        await old.writeManifest({
          'schema_version': classificationSchemaVersion,
          'records': {'task:src::language': id, 'request:test': requestId},
        });
      });
      final store = await open();
      expect(await store.readRecord(id), record);
      expect(await store.readRecord(requestId), request);
      expect((await store.readManifest())!['records'], {
        'task:src::language': id,
        'request:test': requestId,
      });
      expect(await File('${old.root}/manifest.json').exists(), isFalse);
      expect(await Directory('${old.root}/records').exists(), isFalse);
      await store.close();
      final reopened = await open();
      expect(await reopened.readRecord(id), record);
    },
  );

  test('failed migration preserves the old store and can be retried', () async {
    final old = FileClassificationStore(root.path);
    final record = result('python');
    final id = canonicalFingerprint(record);
    await old.withWriter(() async {
      await old.writeManifest({
        'schema_version': classificationSchemaVersion,
        'records': {'task:src::language': id},
      });
    });
    await expectLater(
      SqliteClassificationStore.open(root.path),
      throwsStateError,
    );
    expect(await old.readManifest(), isNotNull);
    await old.withWriter(() => old.writeRecord(id, record));
    final store = await open();
    expect(await store.readRecord(id), record);
  });

  test(
    'cancelling migration releases the writer and preserves old checkpoints',
    () async {
      final old = FileClassificationStore(root.path);
      final record = result('python');
      final id = canonicalFingerprint(record);
      await old.withWriter(() async {
        await old.writeRecord(id, record);
        await old.writeManifest({
          'schema_version': classificationSchemaVersion,
          'records': {'task:src::language': id},
        });
      });
      final cancel = Completer<void>();
      await expectLater(
        SqliteClassificationStore.open(
          root.path,
          cancelSignal: cancel.future,
          onProgress: (_) {
            if (!cancel.isCompleted) cancel.complete();
          },
        ),
        throwsStateError,
      );
      expect(await old.readRecord(id), record);
      expect(await old.readManifest(), isNotNull);
      final store = await open();
      expect(await store.readRecord(id), record);
    },
  );

  test(
    'database and journal symlinks are rejected before opening SQLite',
    () async {
      final directory = Directory('${root.path}/.tina/classifications');
      await directory.create(recursive: true);
      final outside = File('${root.path}/outside')..writeAsStringSync('keep');
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final link = Link('${directory.path}/index.db$suffix');
        await link.create(outside.path);
        await expectLater(
          SqliteClassificationStore.open(root.path, create: true),
          throwsStateError,
        );
        expect(await outside.readAsString(), 'keep');
        await link.delete();
      }
    },
  );
}
