import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tina_engine/src/terminal/pty_runner.dart';
import 'package:test/test.dart';

void main() {
  test(
      'output produced before completion reaches a listener that attaches '
      'after done', () async {
    final conn = await const PtyRunner().spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', 'printf startup; exit 0'],
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
        'TERM': 'xterm-256color',
      },
    ));

    // Attach NOTHING while the command runs and completes. The listener is
    // only interested afterwards — the natural-exit race from the review.
    final code = await conn.done.timeout(const Duration(seconds: 10));
    expect(code, 0);

    var sawDone = false;
    final collected = <int>[];
    final sub = conn.output.listen(collected.addAll);
    // A finished connection reports a finished stream to a new listener.
    await _streamDone(sub, () => sawDone = true)
        .timeout(const Duration(seconds: 5));
    expect(sawDone, isTrue,
        reason: 'a finished connection has finished output');
    expect(utf8.decode(collected), 'startup');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test(
      'buffered output keeps its order relative to live output when a '
      'listener attaches mid-flight', () async {
    final conn = await const PtyRunner().spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', 'sleep 0.3; printf ab; sleep 0.2; printf cd; exit 0'],
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
        'TERM': 'xterm-256color',
      },
    ));

    final seen = <String>[];
    final finished = Completer<void>();
    final sub = conn.output.listen((chunk) {
      seen.add(utf8.decode(chunk));
    }, onDone: finished.complete);

    final code = await conn.done.timeout(const Duration(seconds: 10));
    await finished.future.timeout(const Duration(seconds: 5));
    expect(code, 0);
    final joined = seen.join();
    expect(joined, contains('ab'));
    expect(joined, contains('cd'));
    // Relative order must be preserved: 'ab' before 'cd'.
    expect(joined.indexOf('ab'), lessThan(joined.indexOf('cd')));
    sub.cancel();
  }, timeout: const Timeout(Duration(seconds: 30)));
}

/// Completes when [sub] is done — on the actual done event, not on cancel.
/// [onDone] runs exactly once, when the stream finishes.
Future<void> _streamDone(StreamSubscription<void> sub, void Function() onDone) {
  final c = Completer<void>();
  var done = false;
  sub.onDone(() {
    if (!done) {
      done = true;
      onDone();
      c.complete();
    }
  });
  return c.future;
}
