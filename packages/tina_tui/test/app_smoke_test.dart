// Smoke test: the real entry point starts, draws at least one frame,
// and tears down cleanly on /quit. Tagged `tty` and skipped by default
// (see dart_test.yaml): it drives the actual binary, which is meant to
// run next to a real terminal, and the suite must not need a network —
// a full model turn is covered by app_test.dart over a fake Stdio.
//
// Run: dart test --tags tty --run-skipped
@Timeout(Duration(minutes: 2))
@Tags(['tty'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the app starts, paints, and quits', () async {
    final dir = await Directory.systemTemp.createTemp('tina_tui_smoke_');
    addTearDown(() => dir.delete(recursive: true));
    final store = '${dir.path}/store.jsonl';

    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'bin/tina_tui.dart', '--store', store],
    );
    addTearDown(process.kill);

    final out = StringBuffer();
    final painted = Completer<void>();
    // First frame: the input prompt reaches stdout even over a pipe.
    process.stdout
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((chunk) {
      out.write(chunk);
      if (!painted.isCompleted && out.toString().contains('›')) {
        painted.complete();
      }
    });

    await painted.future.timeout(const Duration(seconds: 30),
        onTimeout: () => fail('no input prompt within 30s; '
            'stdout:\n$out'));

    process.stdin.write('/quit\r');
    await process.stdin.flush();
    // The app reads lines until EOF (ctrl-D on a real terminal); a pipe
    // only delivers EOF when its write end closes.
    await process.stdin.close();

    final code =
        await process.exitCode.timeout(const Duration(seconds: 30));
    expect(code, 0,
        reason: 'stdout:\n$out');
  }, skip: stdout.hasTerminal
      ? null
      : 'needs a TTY (or at least an interactive console); '
          'run with --tags tty --run-skipped');
}
