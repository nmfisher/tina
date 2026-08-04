import 'dart:math' show max;

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  // The lock keys on the file's real path; a non-existent path throws on
  // resolveSymbolicLinks and falls back to the canonicalized path string, so
  // these fake absolute paths collide/differ as needed without touching disk.

  test('same-file ops serialize (never overlap)', () async {
    final lock = FileMutationLock();
    var active = 0;
    var maxActive = 0;
    Future<void> op(String path) async {
      await lock.withFileLock(path, () async {
        active++;
        maxActive = max(maxActive, active);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        active--;
      });
    }

    await Future.wait([op('/tina-fake/same'), op('/tina-fake/same')]);
    expect(maxActive, 1, reason: 'two same-file ops must not overlap');
  });

  test('different-file ops run concurrently', () async {
    final lock = FileMutationLock();
    var active = 0;
    var maxActive = 0;
    Future<void> op(String path) async {
      await lock.withFileLock(path, () async {
        active++;
        maxActive = max(maxActive, active);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        active--;
      });
    }

    await Future.wait([op('/tina-fake/a'), op('/tina-fake/b')]);
    expect(maxActive, 2, reason: 'different-file ops should overlap');
  });

  test('a thrown error releases the lock for the next op', () async {
    final lock = FileMutationLock();
    await expectLater(
      lock.withFileLock<String>('/tina-fake/x', () async => throw 'boom'),
      throwsA('boom'),
    );
    // The queue must not be stuck — a follow-up same-file op runs to completion.
    final res = await lock.withFileLock<int>('/tina-fake/x', () async => 42);
    expect(res, 42);
  });

  test('returns the action result and propagates its value', () async {
    final lock = FileMutationLock();
    final res = await lock.withFileLock<String>('/tina-fake/v', () async => 'done');
    expect(res, 'done');
  });
}
