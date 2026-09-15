// Minimal `package:test` repro: does the exact test body pass under `dart test`?
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/src/terminal/pty_runner.dart';

void main() {
  test('repro', () async {
    print('test process pid=$pid'); // ignore: avoid_print
    final conn = await const PtyRunner().spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', 'echo "child-of-\$PPID-on-\$(tty)"; exit 7'],
      workingDirectory: Directory.systemTemp.path,
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
        'TERM': 'xterm-256color',
      },
    ));
    final buf = StringBuffer();
    final sub = conn.output.listen((b) => buf.write(utf8.decode(b, allowMalformed: true)));
    final code = await conn.done.timeout(const Duration(seconds: 10), onTimeout: () => -99);
    await sub.cancel();
    print('code=$code out=[${buf.toString().trim()}]'); // ignore: avoid_print
    await conn.close();
  }, timeout: const Timeout(Duration(seconds: 15)));
}
