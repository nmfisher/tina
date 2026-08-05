import 'dart:convert';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// Writes a lockfile at [lockFile] with [pid] (and optional sessionId) so a
/// test can simulate a pre-existing holder without real concurrency.
Future<void> seedLock(
  File lockFile, {
  required int pid,
  String? sessionId,
}) async {
  await lockFile.parent.create(recursive: true);
  await lockFile.writeAsString(jsonEncode({
    'pid': pid,
    'hostname': 'test-host',
    'startedAt': '2026-08-05T00:00:00.000Z',
    if (sessionId != null) 'sessionId': sessionId,
  }));
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tina_lock_test_');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('SessionLock', () {
    test('acquire on a free directory succeeds and writes the lockfile', () async {
      final lock = SessionLock(tmp);
      final conflict = await lock.acquire();
      expect(conflict, isNull);
      expect(lock.isHeld, isTrue);
      final lockFile = File('${tmp.path}${Platform.pathSeparator}.lock');
      expect(await lockFile.exists(), isTrue);
      final payload =
          jsonDecode(await lockFile.readAsString()) as Map<String, dynamic>;
      expect(payload['pid'], pid);
      expect(payload['sessionId'], tmp.uri.pathSegments.last);
    });

    test('release deletes the lockfile and is idempotent', () async {
      final lock = SessionLock(tmp);
      await lock.acquire();
      final lockFile = File('${tmp.path}${Platform.pathSeparator}.lock');
      expect(await lockFile.exists(), isTrue);
      await lock.release();
      expect(await lockFile.exists(), isFalse);
      expect(lock.isHeld, isFalse);
      // Second release is a no-op.
      await lock.release();
    });

    test('acquire conflicts when a live pid holds the lock', () async {
      final lockFile = File('${tmp.path}${Platform.pathSeparator}.lock');
      // This very process is alive, so the liveness check sees it as live.
      await seedLock(lockFile, pid: pid, sessionId: 'the-session');

      final lock = SessionLock(tmp);
      final conflict = await lock.acquire();
      expect(conflict, isNotNull);
      expect(conflict!.pid, pid);
      expect(conflict.sessionId, 'the-session');
      expect(conflict.toMessage(), contains('--force'));
      expect(lock.isHeld, isFalse);
      // The holder's lockfile must be left intact.
      expect(await lockFile.exists(), isTrue);
    });

    test('acquire reclaims a stale lock (dead pid) and proceeds', () async {
      final lockFile = File('${tmp.path}${Platform.pathSeparator}.lock');
      // A pid that will never exist; the liveness check reports it dead.
      await seedLock(lockFile, pid: 999999989);

      final lock = SessionLock(tmp);
      final conflict = await lock.acquire();
      expect(conflict, isNull);
      expect(lock.isHeld, isTrue);
      // The lockfile now carries OUR pid, not the stale one.
      final payload =
          jsonDecode(await lockFile.readAsString()) as Map<String, dynamic>;
      expect(payload['pid'], pid);
    });

    test('force overwrites a live holder', () async {
      final lockFile = File('${tmp.path}${Platform.pathSeparator}.lock');
      await seedLock(lockFile, pid: pid, sessionId: 'held');

      final lock = SessionLock(tmp);
      final conflict = await lock.acquire(force: true);
      expect(conflict, isNull);
      expect(lock.isHeld, isTrue);
      final payload =
          jsonDecode(await lockFile.readAsString()) as Map<String, dynamic>;
      expect(payload['pid'], pid);
    });

    test('an unparseable lockfile is treated as stale and reclaimed', () async {
      final lockFile = File('${tmp.path}${Platform.pathSeparator}.lock');
      await lockFile.parent.create(recursive: true);
      await lockFile.writeAsString('not json');

      final lock = SessionLock(tmp);
      final conflict = await lock.acquire();
      expect(conflict, isNull);
      expect(lock.isHeld, isTrue);
    });

    test('releaseSync deletes the lockfile without awaiting', () async {
      final lock = SessionLock(tmp);
      await lock.acquire();
      final lockFile = File('${tmp.path}${Platform.pathSeparator}.lock');
      expect(await lockFile.exists(), isTrue);
      lock.releaseSync();
      expect(await lockFile.exists(), isFalse);
    });
  });
}
