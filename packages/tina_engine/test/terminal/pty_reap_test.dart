import 'dart:io';

import 'package:tina_engine/src/terminal/pty_runner.dart';
import 'package:test/test.dart';

// Regression for the VM-reaper race: the exec'd child must report its exit
// status even when the host process (the Dart VM) runs a wait(-1)-style
// reaper that could steal the child. The shim's double-fork keeps the child
// out of the caller's wait domain; this test exercises the shortest possible
// exit (echo, then exit) under `dart test`, where the reaper is provably
// armed.
void main() {
  test('exit status is reported under the test runner reaper', () async {
    final conn = await const PtyRunner().spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', 'echo hi; exit 7'],
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
        'TERM': 'xterm-256color',
      },
    ));
    final code = await conn.done.timeout(const Duration(seconds: 10),
        onTimeout: () => -99);
    expect(code, 7);
    await conn.close();
  }, timeout: const Timeout(Duration(seconds: 15)));
}
