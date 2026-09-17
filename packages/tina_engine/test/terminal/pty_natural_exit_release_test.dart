import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:tina_engine/src/terminal/pty_runner.dart';
import 'package:test/test.dart';

/// Issue 6: a connection that reaches a NATURAL exit (no close() call)
/// kept the main-side ReceivePorts open forever. An open ReceivePort
/// keeps an isolate alive, so any isolate that owned such a connection
/// could never wind down — the leak below reproduces that exactly: the
/// helper isolate does the whole lifecycle, reports success, and then
/// must actually TERMINATE. A leaked port keeps it hanging and the
/// parent's onExit wait times out.
Future<void> _naturalLifecycleInHelper(SendPort reportTo) async {
  final conn = await const PtyRunner().spawn(PtySpawnRequest(
    executable: '/bin/sh',
    arguments: ['-c', 'echo natural-exit; exit 0'],
    environment: {
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      'HOME': Platform.environment['HOME'] ?? '/',
    },
  ));
  final code = await conn.done;
  reportTo.send(code);
  // Returning: with every port released by finalization, the isolate
  // winds down on its own.
}

void main() {
  test('a connection that exits naturally does not keep its isolate alive',
      () async {
    final helperGone = ReceivePort(); // helper isolate's onExit signal
    final result = ReceivePort();
    await Isolate.spawn(_naturalLifecycleInHelper, result.sendPort,
        onExit: helperGone.sendPort);
    try {
      final code = await result.first.timeout(const Duration(seconds: 30));
      expect(code, 0, reason: 'the child must exit cleanly');
      // The helper reported success; it must now actually terminate.
      // Before the fix the connection leaked a ReceivePort, the helper
      // stayed alive forever, and this wait timed out.
      await helperGone.first.timeout(const Duration(seconds: 10),
          onTimeout: () => fail(
              'helper isolate still alive 10s after its connection reached '
              'a natural exit: a ReceivePort leaked (issue 6)'));
    } finally {
      helperGone.close();
      result.close();
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
