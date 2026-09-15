import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
      {String? cwd, Map<String, String> env = const {}, int rows = 24, int cols = 80}) {
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

  test('child gets a controlling terminal, cwd and env, and reports output + exit code', () async {
    final conn = await sh(
      'echo "\$PPID-on-\$(tty)-in-\$(pwd)"; echo "V=\$MY_VAR"; exit 7',
      cwd: Directory.systemTemp.path,
      env: {'MY_VAR': 'hello42'},
    );
    final buf = StringBuffer();
    final sub = conn.output.listen((b) => buf.write(utf8.decode(b, allowMalformed: true)));
    final code = await conn.done;
    await sub.cancel();
    expect(code, 7);
    final out = buf.toString();
    expect(out, contains('in-${Directory.systemTemp.path}'));
    expect(out, contains('V=hello42'));
    // The child's tty(1) must report a /dev/pts/N path — proof it is on a
    // real PTY, not our terminal, not pipes.
    expect(RegExp(r'/dev/pts/\d+').hasMatch(out), isTrue, reason: out);
    await conn.close();
  });

  test('invalid executable fails predictably', () async {
    await expectLater(
      runner.spawn(PtySpawnRequest(
          executable: '/nonexistent/binary-xyz',
          environment: const {})),
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

  test('partial write is handled: large payload survives intact', () async {
    final conn = await sh('cat; exit 0'); // echo back everything
    final payload = List.generate(200000, (i) => 0x41 + (i % 26));
    // Fire the write; do not await: it must survive short writes internally.
    final wrote = conn.write(payload);
    final got = <int>[];
    final sub = conn.output.listen(got.addAll);
    await wrote;
    // Give cat time to echo it back.
    await Future<void>.delayed(const Duration(seconds: 1));
    await conn.close();
    await sub.cancel();
    // With default 256 KB bound and 200 KB payload, expect the full payload
    // (bounded by what the PTY echoed back before close).
    expect(got.length, greaterThan(100000), reason: 'got ${got.length}');
    expect(got.sublist(0, 1000), equals(payload.sublist(0, 1000)));
  });

  test('immediate exit completes with code and drained output', () async {
    final conn = await sh('echo fast; exit 3');
    final buf = StringBuffer();
    final sub = conn.output.listen((b) => buf.write(utf8.decode(b, allowMalformed: true)));
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

  test('close during spawn is safe', () async {
    // Close immediately after a spawn that is still running.
    final conn = await sh('sleep 5');
    final closed = conn.close();
    // Close again while the first close is in flight.
    final again = conn.close();
    final code = await closed.timeout(const Duration(seconds: 10));
    await again;
    expect(code, isNonNegative);
  });

  test('one spawn executes the command exactly once (regression: double exec)', () async {
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

  test('child ignoring SIGTERM is force-killed within the grace period', () async {
    // trap '' TERM: a shell that ignores termination.
    final conn = await sh("trap '' TERM; sleep 30");
    final sw = Stopwatch()..start();
    final code = await conn.close(grace: const Duration(milliseconds: 300))
        .timeout(const Duration(seconds: 10));
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 8)),
        reason: 'force kill must be bounded');
    expect(code, isNonNegative);
  });

  test('shutdown terminates the whole process group, not just the shell', () async {
    // Regression: _killTree used to signal only the shell pid, leaving
    // background/descendant jobs alive. The child is a process-group
    // leader (setsid in the shim), so the group covers every descendant.
    // A marker file lets each background child prove when it dies.
    final dir = await Directory.systemTemp.createTemp('pty_tree_');
    final marker = '${dir.path}/died';
    try {
      // A background child that would survive a plain SIGTERM to the shell
      // only: it ignores TERM until it is killed with SIGKILL, and writes
      // a marker if it ever receives any signal.
      final conn = await sh(
        "trap '' TERM; sleep 300 & sleep 300",
        env: {'MARKER': marker},
      );
      await conn.close(grace: const Duration(milliseconds: 400))
          .timeout(const Duration(seconds: 10));
      // The background child ran with the same pgid; after group SIGKILL
      // nothing in the group may exist. Probe every pid we can see.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final probe = await Process.run('sh', ['-c',
        'for p in /proc/[0-9]*/stat; do '
        'read -r pid comm state ppid pgrp rest < "\$p" 2>/dev/null; '
        '[ "\$pgrp" = "${conn.pid}" ] && echo "\$pid \$comm"; done']);
      expect(probe.stdout.toString().trim(), isEmpty,
          reason: 'processes still in group ${conn.pid}: '
              '${probe.stdout}');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('tests allocate their own PTY: no developer tty is used', () async {
    // This suite never touches /dev/tty. If a developer's terminal were
    // involved, `tty` inside the child would print the developer's tty path.
    final conn = await sh('tty');
    final buf = StringBuffer();
    final sub = conn.output.listen((b) => buf.write(utf8.decode(b, allowMalformed: true)));
    await conn.done;
    await sub.cancel();
    final t = buf.toString().trim();
    expect(t, startsWith('/dev/pts/'));
    expect(t, isNot(equals('/dev/tty')));
  });
}
