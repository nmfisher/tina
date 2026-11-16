import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/src/app_io.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('tina-app-io-lock-'));
  tearDown(() => root.deleteSync(recursive: true));

  test('lockExclusive runs the body and cleans up the handle', () {
    final io = defaultAppIo();
    final target = '${root.path}/config';
    final seen = <String>[];
    io.lockExclusive<void>(target, () => seen.add('inside'));
    expect(seen, ['inside']);
    expect(File('$target.lock').existsSync(), isTrue);
  });

  test('nested locks on the same path compose instead of deadlocking', () {
    final io = defaultAppIo();
    final target = '${root.path}/config';
    final order = <String>[];
    io.lockExclusive<void>(target, () {
      order.add('outer');
      io.lockExclusive<void>(target, () => order.add('inner'));
    });
    expect(order, ['outer', 'inner']);
  });

  test('nested locks on different paths compose', () {
    final io = defaultAppIo();
    final order = <String>[];
    io.lockExclusive<void>('${root.path}/one', () {
      order.add('one-outer');
      io.lockExclusive<void>('${root.path}/two', () {
        order.add('two');
        io.lockExclusive<void>(
          '${root.path}/one',
          () => order.add('one-inner'),
        );
      });
    });
    expect(order, ['one-outer', 'two', 'one-inner']);
  });

  test('a failed body releases the lock for later callers', () {
    final io = defaultAppIo();
    final target = '${root.path}/config';
    expect(
      () => io.lockExclusive<void>(target, () => throw StateError('x')),
      throwsStateError,
    );
    var ran = false;
    io.lockExclusive<void>(target, () => ran = true);
    expect(ran, isTrue);
  });

  test('lock files for different paths do not collide', () {
    final io = defaultAppIo();
    final seen = <String>[];
    io.lockExclusive<void>('${root.path}/a', () => seen.add('a'));
    io.lockExclusive<void>('${root.path}/b', () => seen.add('b'));
    expect(seen, ['a', 'b']);
  });
}
