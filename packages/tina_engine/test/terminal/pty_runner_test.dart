import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:tina_engine/src/terminal/pty_runner.dart';
import 'package:test/test.dart';

/// Phase 1 acceptance tests for the PTY backend.
///
/// These allocate their own PTY per spawn: no `/dev/tty` is opened, and
/// nothing here requires `stdout.hasTerminal`. Supported on Linux and macOS;
/// skipped elsewhere (the engine as a whole has no platform guard).
void main() {
  final runner = const PtyRunner();

  Future<PtyConnection> sh(String script,
      {String? cwd,
      Map<String, String> env = const {},
      int rows = 24,
      int cols = 80}) {
    return runner.spawn(PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', script],
      workingDirectory: cwd,
      environment: {
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
        'HOME': Platform.environment['HOME'] ?? '/',
        'TERM': 'xterm-256color',
        ...env,
      },
      rows: rows,
      cols: cols,
    ));
  }

  test(
      'child gets a controlling terminal, cwd and env, and reports output + exit code',
      () async {
    final conn = await sh(
      'echo "\$PPID-on-\$(tty)-in-\$(pwd)"; echo "V=\$MY_VAR"; exit 7',
      cwd: Directory.systemTemp.path,
      env: {'MY_VAR': 'hello42'},
    );
    final buf = StringBuffer();
    final sub = conn.output
        .listen((b) => buf.write(utf8.decode(b, allowMalformed: true)));
    final code = await conn.done;
    await sub.cancel();
    expect(code, 7);
    final out = buf.toString();
    expect(
        out, contains('in-${Directory.systemTemp.resolveSymbolicLinksSync()}'));
    expect(out, contains('V=hello42'));
    // The child's tty(1) must report a pty device path — proof it is on a
    // real PTY, not our terminal, not pipes. Linux uses /dev/pts/N; macOS
    // uses /dev/ttysNNN. (macOS paths unverified in CI: this suite runs on
    // Linux.)
    final ptyRe =
        Platform.isMacOS ? RegExp(r'/dev/ttys\d+') : RegExp(r'/dev/pts/\d+');
    expect(ptyRe.hasMatch(out), isTrue, reason: out);
    await conn.close();
  });

  test('invalid executable fails predictably', () async {
    await expectLater(
      runner.spawn(PtySpawnRequest(
          executable: '/nonexistent/binary-xyz', environment: const {})),
      throwsA(isA<PtyException>()),
    );
  });

  test('invalid cwd fails predictably', () async {
    await expectLater(
      runner.spawn(PtySpawnRequest(
          executable: '/bin/true',
          workingDirectory: '/nonexistent/dir-xyz',
          environment: const {})),
      throwsA(isA<PtyException>()),
    );
  });

  test('resize completes predictably on a live child and after exit', () async {
    final conn = await sh('sleep 0.5; echo done');
    conn.resize(40, 120); // must not throw on a live child
    await conn.done;
    conn.resize(50, 200); // racing close: still must not throw
  });

  test('partial writes deliver the complete payload through a raw child',
      () async {
    final conn = await sh('stty raw -echo; printf READY; cat');
    addTearDown(() => conn.close(grace: Duration.zero));
    final ready = Completer<void>();
    final echoed = Completer<void>();
    final got = <int>[];
    final payload =
        Uint8List.fromList(List.generate(512 * 1024, (i) => i % 256));
    final sub = conn.output.listen((chunk) {
      got.addAll(chunk);
      if (got.length >= 5 && !ready.isCompleted) ready.complete();
      if (got.length >= payload.length + 5 && !echoed.isCompleted)
        echoed.complete();
    });
    await ready.future.timeout(const Duration(seconds: 5));
    expect(utf8.decode(got.take(5).toList()), 'READY');
    expect(
        await conn.write(payload).timeout(const Duration(seconds: 10)), isTrue);
    await echoed.future.timeout(const Duration(seconds: 10));
    expect(got.sublist(5), payload);
    await conn.close(grace: Duration.zero);
    await sub.cancel();
  });

  test('immediate exit completes with code and drained output', () async {
    final conn = await sh('echo fast; exit 3');
    final buf = StringBuffer();
    final sub = conn.output
        .listen((b) => buf.write(utf8.decode(b, allowMalformed: true)));
    final code = await conn.done.timeout(const Duration(seconds: 5));
    await sub.cancel();
    expect(code, 3);
    expect(buf.toString(), contains('fast'));
  });

  test('repeated close is idempotent', () async {
    final conn = await sh('exit 0');
    final a = await conn.close();
    final b = await conn.close();
    expect(a, b);
    await conn.write([0x78]); // after close: returns false, no throw
  });

  test('close immediately after spawn, close racing close, write after close',
      () async {
    // Honesty note: a PtyConnection does not exist until the spawn
    // handshake resolves, so "close during spawn" from the caller's side
    // can only mean close() as soon as the future delivers the connection
    // — which is what this does. The genuinely-pending path (isolate dying
    // mid-handshake) is covered on the failure path instead: an invalid
    // executable makes the handshake fail and every port is closed (see
    // the invalid-executable test and the port-leak lifecycle test).
    // Races covered HERE: close() right after spawn, close() racing close()
    // while the first is still in flight, and write() after close.
    final spawn = sh('sleep 5');
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final early = await spawn;
    final closedEarly = early.close(grace: const Duration(seconds: 2));
    // close() racing close() while the first is still in flight.
    final again = early.close(grace: const Duration(seconds: 2));
    final code = await closedEarly.timeout(const Duration(seconds: 10));
    await again;
    expect(code, isNonNegative);
    // A closed connection refuses writes without throwing.
    expect(await early.write([0x78]), isFalse);
  });

  test('no leaked ports: an isolate that spawns and closes exits on its own',
      () async {
    // Regression: _workerDone was never closed, so a program that spawned,
    // closed, and returned stayed alive on the leaked ReceivePort. Run the
    // whole lifecycle in a child isolate: if any port leaks, that isolate
    // never finishes and this test times out.
    final result = await Isolate.run(() async {
      final c1 = await sh('echo quick');
      await c1.done;
      await c1.close();
      // Spawn failure path must clean up too.
      try {
        await sh('definitely-not-a-real-binary-xyz');
      } on PtyException {
        // expected
      }
      return 'lifecycle-complete';
    });
    expect(result, 'lifecycle-complete');
  });

  test('one spawn executes the command exactly once (regression: double exec)',
      () async {
    // Regression: an extra fork inside the shim made TWO processes run the
    // command; only the second was tracked. The first was an untracked
    // orphan. A single spawn must produce exactly ONE execution.
    final marker = File(
        '${Directory.systemTemp.path}/pty_exec_once_${DateTime.now().microsecondsSinceEpoch}');
    try {
      final conn = await sh(
        'sleep 0.3; echo \$\$ >> ${marker.path}',
      );
      final code = await conn.done.timeout(const Duration(seconds: 10));
      expect(code, 0);
      // Extra settle: a second (buggy) exec could lag the first slightly.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final lines = await marker.readAsLines();
      expect(lines, hasLength(1),
          reason: 'the command must execute exactly once; got $lines');
    } finally {
      if (await marker.exists()) await marker.delete();
    }
  });

  test('bounded grace stays bounded when a descendant holds the slave open',
      () async {
    // Regression: after the shell exited, the drain branch spun without
    // yielding whenever a descendant (`sleep 300 &`) still held the slave
    // open — terminate was never processed and a 50ms grace took ~4.6s,
    // answered by the main isolate force-killing the worker instead of a
    // clean native shutdown.
    final conn = await sh('sleep 300 & sleep 0.2'); // shell exits, bg lives
    final sw = Stopwatch()..start();
    final code = await conn
        .close(grace: const Duration(milliseconds: 50))
        .timeout(const Duration(seconds: 5), onTimeout: () => -999);
    sw.stop();
    expect(code, isNot(-999), reason: 'close hung; grace not bounded');
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)),
        reason: 'a 50ms grace must not take ${sw.elapsed}');
  });

  test('natural exit finalizes the connection: output done, writes refused',
      () async {
    // Regression: after a natural exit, `done` completed but the output
    // stream stayed open and write() still returned true — a half-closed
    // terminal state.
    final conn = await sh('echo fine; exit 0');
    final code = await conn.done.timeout(const Duration(seconds: 10));
    expect(code, 0);
    // Output must be complete now (done implies drained output).
    await conn.output.drain<void>().timeout(const Duration(seconds: 5));
    expect(conn.exited, isTrue);
    // Writes to an exited process must be refused, not silently "succeed".
    final accepted = await conn.write('late'.codeUnits);
    expect(accepted, isFalse,
        reason: 'write to an exited process must return false');
  });

  test('output produced before a listener attaches is buffered, not dropped',
      () async {
    // Regression: output went into a broadcast controller with no buffer;
    // a listener attached 150ms after spawn lost everything a fast command
    // had already produced. Terminal bytes must never be dropped.
    const marker = 'STARTUP-MARKER-9f31';
    final conn = await sh('echo $marker; sleep 1');
    // No listener yet — the child is already producing output.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final collected = <int>[];
    final sub = conn.output.listen(collected.addAll);
    final code = await conn.done.timeout(const Duration(seconds: 10));
    expect(code, 0);
    await sub.cancel();
    expect(utf8.decode(collected), contains(marker),
        reason: 'startup output was dropped: ${utf8.decode(collected)}');
  });

  test('child ignoring SIGTERM is force-killed within the grace period',
      () async {
    // trap '' TERM: a shell that ignores termination.
    final conn = await sh("trap '' TERM; sleep 30");
    final sw = Stopwatch()..start();
    final code = await conn
        .close(grace: const Duration(milliseconds: 300))
        .timeout(const Duration(seconds: 10));
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 8)),
        reason: 'force kill must be bounded');
    expect(code, isNonNegative);
  });

  test('tests allocate their own PTY: no developer tty is used', () async {
    // This suite never touches /dev/tty. If a developer's terminal were
    // involved, `tty` inside the child would print the developer's tty path.
    final conn = await sh('tty');
    final buf = StringBuffer();
    final sub = conn.output
        .listen((b) => buf.write(utf8.decode(b, allowMalformed: true)));
    await conn.done;
    await sub.cancel();
    final t = buf.toString().trim();
    final ptyPrefix = Platform.isMacOS ? '/dev/ttys' : '/dev/pts/';
    expect(t, startsWith(ptyPrefix));
    expect(t, isNot(equals('/dev/tty')));
  });
}
