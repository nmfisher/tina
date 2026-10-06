@Tags(['tty'])
library;

import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('manual shell output and cancellation on both backends and panel modes',
      () async {
    var root = Directory.current;
    while (!File('${root.path}/tool/smoke_shell.py').existsSync()) {
      if (root.parent.path == root.path)
        throw StateError('tina repository not found');
      root = root.parent;
    }
    final result = await Process.run('python3', [
      '${root.path}/tool/smoke_shell.py',
      '--dart',
      Platform.resolvedExecutable,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }, skip: Platform.isWindows, timeout: const Timeout(Duration(minutes: 3)));
}
