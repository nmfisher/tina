import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine/src/terminal/pty_runner.dart';

void main() {
  test('repro in test context', () async {
    final conn = await const PtyRunner().spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', r'echo "$PPID-on-$(tty)-in-$(pwd)"; echo "V=$MY_VAR"; exit 7'],
      workingDirectory: Directory.systemTemp.path,
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
        'TERM': 'xterm-256color',
        'MY_VAR': 'hello42',
      },
    ));
    final buf = StringBuffer();
    final sub = conn.output.listen((b) => buf.write(utf8.decode(b, allowMalformed: true)));
    print('awaiting done with 10s timeout...');
    final code = await conn.done.timeout(const Duration(seconds: 10), onTimeout: () {
      print('DONE TIMED OUT — worker never sent exited');
      return -99;
    });
    await sub.cancel();
    print('code=' + code.toString());
    print('out=[' + buf.toString().trim() + ']');
    await conn.close();
    expect(code, 7);
  }, timeout: Timeout(Duration(seconds: 30)));
}
