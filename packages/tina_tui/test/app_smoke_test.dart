// The real entry point on a controlling PTY, including a localhost HTTP turn.
// Run: dart test --tags tty --run-skipped test/app_smoke_test.dart
@Timeout(Duration(minutes: 3))
@Tags(['tty'])
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
      'PTY streaming, approvals, settings, scoped plugins, resume and clean shutdown',
      () async {
    var root = Directory.current;
    while (!File('${root.path}/tool/smoke_engine2.py').existsSync()) {
      if (root.parent.path == root.path)
        throw StateError('tina repository not found');
      root = root.parent;
    }
    final result = await Process.run('python3', [
      '${root.path}/tool/smoke_engine2.py',
      '--dart',
      Platform.resolvedExecutable,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }, skip: Platform.isWindows ? 'requires a POSIX PTY' : null);
}
