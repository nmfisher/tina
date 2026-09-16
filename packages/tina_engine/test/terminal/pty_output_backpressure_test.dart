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
  test('a paused listener stops native reads and resumes without losing bytes',
      () async {
    const total = 2 << 20;
    final conn = await const PtyRunner(maxQueuedOutput: 65536).spawn(
      const PtySpawnRequest(executable: '/bin/sh', arguments: [
        '-c',
        'sleep 0.1; dd if=/dev/zero bs=65536 count=32 2>/dev/null',
      ], environment: {
        'PATH': '/usr/bin:/bin'
      }),
    );
    addTearDown(() => conn.close(grace: Duration.zero));
    var received = 0;
    var exited = false;
    conn.done.then((_) => exited = true);
    final finished = Completer<void>();
    final sub = conn.output
        .listen((chunk) => received += chunk.length, onDone: finished.complete)
      ..pause();
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(received, 0);
    expect(exited, isFalse,
        reason: 'a full credit window must block the producer');
    sub.resume();
    expect(await conn.done.timeout(const Duration(seconds: 10)), 0);
    await finished.future;
    expect(received, total);
  });

  test('close drains the finite kernel tail even with a paused consumer',
      () async {
    final conn = await const PtyRunner(maxQueuedOutput: 65536).spawn(
      const PtySpawnRequest(executable: '/bin/sh', arguments: [
        '-c',
        'dd if=/dev/zero bs=65536 count=128 2>/dev/null',
      ], environment: {
        'PATH': '/usr/bin:/bin'
      }),
    );
    addTearDown(() => conn.close(grace: Duration.zero));
    var bytes = 0;
    final first = Completer<void>();
    final finished = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = conn.output.listen((chunk) {
      bytes += chunk.length;
      if (!first.isCompleted) {
        sub.pause();
        first.complete();
      }
    }, onDone: finished.complete);
    await first.future.timeout(const Duration(seconds: 5));
    expect(
        await conn
            .close(grace: Duration.zero)
            .timeout(const Duration(seconds: 5)),
        isNonNegative);
    sub.resume();
    await finished.future;
    expect(bytes, greaterThan(0));
    expect(bytes, lessThan(256 * 1024));
  });

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
