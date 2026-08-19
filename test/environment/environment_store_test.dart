// Tests for the machine-owned tracking entry ([EnvironmentTrackingStore]) and
// its input digests ([EnvironmentInputs]): the record→fresh→stale cycle over a
// real temp git repo, mirroring the sidecar-repo test conventions.

import 'dart:io';

import 'package:tina/environment/environment_inputs.dart';
import 'package:tina/environment/environment_store.dart';
import 'package:test/test.dart';

String git(Directory dir, List<String> args) {
  final env = Map<String, String>.from(Platform.environment)
    ..['GIT_AUTHOR_NAME'] = 'Test'
    ..['GIT_AUTHOR_EMAIL'] = 'test@example.com'
    ..['GIT_COMMITTER_NAME'] = 'Test'
    ..['GIT_COMMITTER_EMAIL'] = 'test@example.com';
  final result = Process.runSync('git', ['-C', dir.path, ...args],
      environment: env);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

void main() {
  late Directory tmp;

  Directory newRepo() {
    final repo = Directory('${tmp.path}/repo-${tmp.listSync().length}')
      ..createSync(recursive: true);
    File('${repo.path}/pubspec.yaml').writeAsStringSync('name: a\n');
    git(repo, ['init']);
    git(repo, ['add', '-A']);
    git(repo, ['commit', '-m', 'init']);
    return repo;
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tina_envstore_');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  group('EnvironmentInputs', () {
    test('includes the record plus the manifests that exist', () {
      final repo = newRepo();
      File('${repo.path}/package.json').writeAsStringSync('{}');
      expect(EnvironmentInputs().files(repo.path),
          containsAll(['pubspec.yaml', 'package.json']));
      expect(EnvironmentInputs().files(repo.path), isNot(contains('go.mod')));
    });

    test('a committed manifest bump changes the committed digest', () {
      final repo = newRepo();
      final inputs = const EnvironmentInputs();
      final before = inputs.measure(repo.path);
      File('${repo.path}/pubspec.yaml').writeAsStringSync('name: b\n');
      git(repo, ['add', '-A']);
      git(repo, ['commit', '-m', 'bump']);
      final after = inputs.measure(repo.path);
      expect(after.committed, isNot(before.committed));
      expect(after.commit, isNot(before.commit));
      expect(after.dirty, isEmpty); // still clean after the commit
    });

    test('an uncommitted edit flips the dirty digest only', () {
      final repo = newRepo();
      final inputs = const EnvironmentInputs();
      final before = inputs.measure(repo.path);
      File('${repo.path}/pubspec.yaml').writeAsStringSync('name: dirty\n');
      final after = inputs.measure(repo.path);
      expect(after.dirty, isNotEmpty);
      expect(before.dirty, isEmpty);
      expect(after.committed, before.committed); // HEAD blobs unchanged
    });

    test('outside a git repo both digests ride on file contents', () {
      final plain = Directory('${tmp.path}/plain')..createSync();
      final record = File('${plain.path}/.tina/ENVIRONMENT.md')
        ..createSync(recursive: true);
      record.writeAsStringSync('a');
      final inputs = const EnvironmentInputs();
      final before = inputs.measure(plain.path);
      expect(before.commit, isEmpty);
      record.writeAsStringSync('b');
      final after = inputs.measure(plain.path);
      expect(after.committed, isNot(before.committed));
    });
  });

  group('EnvironmentTrackingStore', () {
    test('stale with "never measured" until something records', () {
      final repo = newRepo();
      final store = EnvironmentTrackingStore(projectRoot: repo.path);
      expect(store.load(), isNull);
      expect(store.staleReason(), 'never measured');
      expect(store.isStale, isTrue);
    });

    test('record → fresh → stale on a committed input change', () {
      final repo = newRepo();
      final store = EnvironmentTrackingStore(projectRoot: repo.path);
      store.record();
      final entry = store.load();
      expect(entry, isNotNull);
      expect(entry!.commit, isNotEmpty);
      expect(entry.measuredAt, isNotEmpty);
      expect(store.staleReason(), isNull,
          reason: 'nothing moved since the measurement');

      File('${repo.path}/pubspec.yaml').writeAsStringSync('name: b\n');
      git(repo, ['add', '-A']);
      git(repo, ['commit', '-m', 'bump']);
      expect(store.staleReason(), 'inputs changed since the last measurement');
    });

    test('an uncommitted manifest edit is stale under "working tree changed"',
        () {
      final repo = newRepo();
      final store = EnvironmentTrackingStore(projectRoot: repo.path);
      store.record();
      File('${repo.path}/pubspec.yaml').writeAsStringSync('name: b\n');
      expect(
          store.staleReason(), 'working tree changed since the last measurement');
    });

    test('a record edit is stale even though .tina is gitignored', () {
      final repo = newRepo();
      File('${repo.path}/.gitignore').writeAsStringSync('.tina/\n');
      final store = EnvironmentTrackingStore(projectRoot: repo.path);
      store.record();
      File('${repo.path}/.tina/ENVIRONMENT.md').writeAsStringSync('## Build');
      expect(store.staleReason(), 'inputs changed since the last measurement',
          reason: 'the record is hashed by content, not via git');
    });

    test('a corrupt entry reads as never measured, not as a crash', () {
      final repo = newRepo();
      final store = EnvironmentTrackingStore(projectRoot: repo.path);
      store.record();
      File('${repo.path}/.tina/environment/tracking.json')
          .writeAsStringSync('{not json');
      expect(store.staleReason(), 'never measured');
    });

    test('the entry JSON round-trips', () {
      final e = EnvironmentTrackingEntry(
        commit: 'abc',
        inputsDigest: 'd1',
        dirtyDigest: 'd2',
        measuredAt: '2026-01-01T00:00:00',
      );
      final back = EnvironmentTrackingEntry.fromJson(e.toJson());
      expect(back.commit, 'abc');
      expect(back.inputsDigest, 'd1');
      expect(back.dirtyDigest, 'd2');
      expect(back.measuredAt, '2026-01-01T00:00:00');
    });
  });
}
