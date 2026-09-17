import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_engine/src/terminal/pty_runner.dart';
import 'package:tina_engine/src/tools/process_registry.dart';

Future<bool> alive(int pid) async {
  final r = await Process.run('/bin/ps', ['-p', '$pid', '-o', 'stat=']);
  final state = r.stdout.toString().trim();
  return r.exitCode == 0 && state.isNotEmpty && !state.startsWith('Z');
}

void main() {
  for (final jobControl in [false, true]) {
    test('close awaits TERM-immune descendant (job control=$jobControl)',
        () async {
      final conn = await const PtyRunner().spawn(PtySpawnRequest(
        executable: '/bin/bash',
        arguments: [
          '--noprofile',
          '--norc',
          '-c',
          '${jobControl ? 'set -m;' : ''} '
              r'''sh -c 'trap "" TERM HUP; echo PID $$; while :; do sleep 30; done' & wait'''
        ],
        environment: const {'PATH': '/usr/bin:/bin'},
      ));
      addTearDown(() => conn.close(grace: Duration.zero));
      final ready = Completer<int>();
      var output = '';
      final sub = conn.output.listen((bytes) {
        output += utf8.decode(bytes, allowMalformed: true);
        final match = RegExp(r'PID (\d+)').firstMatch(output);
        if (match != null && !ready.isCompleted)
          ready.complete(int.parse(match[1]!));
      });
      final descendant = await ready.future.timeout(const Duration(seconds: 5));
      addTearDown(() {
        Process.killPid(descendant, ProcessSignal.sigkill);
      });
      expect(await alive(descendant), isTrue);
      expect(ChildProcessRegistry.instance.isTracking(conn.pid), isTrue);
      final watch = Stopwatch()..start();
      final code = await conn
          .close(grace: const Duration(milliseconds: 400))
          .timeout(const Duration(seconds: 5));
      expect(code, isNonNegative);
      expect(watch.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 400)));
      expect(await alive(descendant), isFalse);
      expect(ChildProcessRegistry.instance.isTracking(conn.pid), isFalse);
      await sub.cancel();
    });
  }

  test('application registry awaits PTY-specific cleanup', () async {
    final conn = await const PtyRunner().spawn(const PtySpawnRequest(
      executable: '/bin/sh',
      arguments: ['-c', 'sleep 30'],
      environment: {'PATH': '/usr/bin:/bin'},
    ));
    conn.output.listen((_) {});
    await ChildProcessRegistry.instance.reapAll(grace: Duration.zero);
    expect(await conn.done, isNonNegative);
    expect(await alive(conn.pid), isFalse);
  });
}
