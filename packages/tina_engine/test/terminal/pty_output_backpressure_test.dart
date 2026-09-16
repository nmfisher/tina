import 'dart:async';
import 'dart:io';

import 'package:tina_engine/src/terminal/pty_runner.dart';
import 'package:test/test.dart';

/// A fast producer with NO listener: the worker must not outrun the
/// consumer. The consumer's capacity controls the reads: the producer is
/// throttled (the PTY backs up), and every byte produced eventually reaches
/// a consumer that attaches — nothing is discarded above a buffer high
/// water mark.
///
/// The producer is NUL bytes via dd: a terminal line discipline with OPOST
/// expands `\n` to `\r\n` (ONLCR), so byte-exact producers must avoid
/// newlines entirely — `yes` would deliver 12 MiB for 8 MiB written.
void main() {
  test(
      'a fast producer with no listener is throttled, not discarded: a late '
      'consumer still receives every byte', () async {
    const total = 8 << 20; // 8 MiB — far above any reasonable buffer
    final conn = await const PtyRunner().spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: [
        '-c',
        'dd if=/dev/zero bs=65536 count=128 2>/dev/null',
      ],
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
      },
    ));

    // Give an ungated worker plenty of time to swallow the whole stream.
    await Future<void>.delayed(const Duration(milliseconds: 400));

    // Now attach the consumer. It must receive ALL bytes, and the
    // connection must complete.
    var received = 0;
    final finished = Completer<void>();
    final sub = conn.output.listen((chunk) => received += chunk.length);
    sub.onDone(finished.complete);

    final code = await conn.done.timeout(const Duration(seconds: 60));
    await finished.future.timeout(const Duration(seconds: 30));
    expect(code, 0);
    expect(received, total,
        reason: 'terminal bytes must not be dropped for lack of a listener');
    sub.cancel();
  }, timeout: const Timeout(Duration(seconds: 120)));
}
