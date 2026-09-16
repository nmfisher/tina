import 'dart:io';

import 'package:tina_engine/src/terminal/pty_runner.dart';
import 'package:test/test.dart';

/// The stub ignores TERM and HUP and moves its sleeper into a sub process
/// group (`set -m`), then reports the descendant's pid and waits. A group
/// signal alone therefore cannot be trusted to have worked: the test probes
/// the descendant's liveness directly, by pid, after close() returns.
const _stub = r'''
trap '' TERM HUP
set -m
sleep 300 &
echo "PID $!"
wait
''';

/// A pid exists iff /proc/<pid> is listed. No process-management commands:
/// reading procfs is how this file observes liveness, on both sides of the
/// shutdown it is testing.
bool _pidAlive(int pid) => Directory('/proc').existsSync()
    ? Directory('/proc/$pid').existsSync()
    : false;

Future<void> _waitUntil(bool Function() probe,
    {required Duration timeout}) async {
  final sw = Stopwatch()..start();
  while (!probe()) {
    if (sw.elapsed > timeout) {
      fail('condition not met within ${timeout.inMilliseconds}ms');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // The grace period bounds how long escalation may take; the probe below
  // stays well inside it.
  const grace = Duration(seconds: 2);

  test(
      'close() kills a descendant that ignores TERM and HUP and sits in its '
      'own process group', () async {
    final conn = await const PtyRunner().spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', _stub],
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
        'TERM': 'xterm-256color',
      },
    ));

    var output = '';
    final sub = conn.output.listen((chunk) {
      output += String.fromCharCodes(chunk);
    });

    // Wait until the descendant certainly exists: it printed its own pid.
    await _waitUntil(
      () => RegExp(r'PID (\d+)').hasMatch(output),
      timeout: const Duration(seconds: 10),
    );
    final descendant =
        int.parse(RegExp(r'PID (\d+)').firstMatch(output)!.group(1)!);
    expect(_pidAlive(descendant), isTrue,
        reason: 'stub descendant $descendant should be alive before close');

    final code = await conn.close(grace: grace);
    await sub.cancel();

    // close() has returned: nothing in the spawned tree may survive — not
    // the shell, and not the TERM/HUP-ignoring descendant in its own group.
    expect(_pidAlive(descendant), isFalse,
        reason: 'descendant $descendant survived shutdown (close returned $code)');
  }, timeout: const Timeout(Duration(seconds: 8)));
}
