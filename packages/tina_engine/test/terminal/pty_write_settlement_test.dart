import 'dart:io';
import 'dart:typed_data';

import 'package:tina_engine/src/terminal/pty_runner.dart';
import 'package:test/test.dart';

/// The shell exits immediately but leaves a HUP-immune descendant holding
/// the slave side, so the PTY master never sees EIO: the worker cannot
/// lean on "slave closed" to finish. Any write still queued when the child
/// exits is undeliverable in practical terms — it must be *settled*
/// (finished, not pending) so the child's exit completes the connection.
const _stub = "trap '' HUP TERM; sleep 30 & exit 0";

void main() {
  test(
      'child exit settles pending writes: done and the write both complete',
      () async {
    final conn = await const PtyRunner().spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', _stub],
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
      },
    ));

    // 4 MiB into a child that reads nothing: this write is still queued
    // (and the caller is inside the backpressure await) when the shell
    // exits.
    final writeFuture = conn.write(Uint8List(4 << 20));

    final code = await conn.done.timeout(const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('done never completed'));
    final accepted = await writeFuture.timeout(const Duration(seconds: 2),
        onTimeout: () => throw TimeoutException('write never settled'));

    expect(code, 0);
    expect(accepted, isTrue, reason: 'the write was accepted before exit');
    await conn.close();
  }, timeout: const Timeout(Duration(seconds: 30)));
}

class TimeoutException implements Exception {
  TimeoutException(this.message);
  final String message;
  @override
  String toString() => 'TimeoutException: $message';
}
