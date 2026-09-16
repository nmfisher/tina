import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:tina_engine/src/terminal/pty_runner.dart';
import 'package:test/test.dart';

/// Issue 5: after a natural exit, `done` completed while the connection
/// was still half-open — `finalized` (and therefore the write gate and
/// output completion) was set by a *second* worker message that could
/// arrive after the awaiting continuation resumed. `done` now completes
/// only with the whole terminal state: writes refused, output done.
void main() {
  test(
      'immediately after done, write() is refused and the output stream is '
      'already completed', () async {
    final conn = await const PtyRunner().spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', 'echo startup; exit 0'],
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
      },
    ));
    final code = await conn.done.timeout(const Duration(seconds: 30));
    expect(code, 0);

    // No scheduling grace: the whole point is that done implies the
    // terminal state, with no observable in-between.
    final accepted = await conn.write('late'.codeUnits);
    expect(accepted, isFalse,
        reason: 'done must imply writes are refused (issue 5)');

    var outputDone = false;
    final outputDoneCompleter = Completer<void>();
    late final StreamSubscription<Uint8List> sub;
    sub = conn.output.listen((_) {}, onDone: () {
      outputDone = true;
      outputDoneCompleter.complete();
    });
    // The stream is multi-view: an already-finished channel completes a
    // new listener synchronously after replay.
    await outputDoneCompleter.future.timeout(const Duration(seconds: 5));
    expect(outputDone, isTrue,
        reason: 'done must imply the output stream is completed');
    await sub.cancel();
  });

  test(
      'write() accepted before done keeps resolving true; a racing write '
      'around finalization never hangs', () async {
    final conn = await const PtyRunner().spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', 'read line; echo got:\$line'],
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
      },
    ));
    // Alive and reading: accepted, and the backpressure await resolves
    // once the worker reports the write landed.
    final accepted = await conn.write('hello\n'.codeUnits)
        .timeout(const Duration(seconds: 10));
    expect(accepted, isTrue);

    final code = await conn.done.timeout(const Duration(seconds: 30));
    expect(code, 0);
    expect(await conn.write('x'.codeUnits), isFalse);
  });
}
