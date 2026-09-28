import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

ProcessRequest request(String script, {Duration? timeout, String? input}) => (
      command: '/bin/sh',
      arguments: ['-c', script],
      workingDirectory: null,
      environment: null,
      stdin: input,
      timeout: timeout,
    );

Future<bool> alive(int pid) async {
  final result = await Process.run('ps', ['-o', 'stat=', '-p', '$pid']);
  final state = (result.stdout as String).trim();
  return result.exitCode == 0 && state.isNotEmpty && !state.startsWith('Z');
}

void main() {
  test('stdin is delivered and both output streams arrive before exit',
      () async {
    final output = <String>[];
    final result = await const IoProcessRunner().run(
      request('cat; echo stderr >&2', input: 'stdin works\n'),
      control: ProcessControl(onOutput: (text, {isError = false}) {
        output.add('${isError ? 'err' : 'out'}:$text');
      }),
    ) as CommandCompleted;
    expect(result.stdout, contains('stdin works'));
    expect(result.stderr, contains('stderr'));
    expect(output.join(), contains('out:stdin works'));
    expect(output.join(), contains('err:stderr'));
  });

  for (final timeout in [false, true]) {
    test(
        '${timeout ? 'timeout' : 'cancel'} kills a shell and its stubborn child, retaining output',
        () async {
      final ready = Completer<void>();
      final cancel = Completer<void>();
      var output = '';
      final run = const IoProcessRunner().run(
        request(
            "sh -c 'trap \"\" TERM; echo child:\$\$; while :; do sleep 1; done' & echo root:\$\$; wait",
            timeout: timeout
                ? const Duration(seconds: 1)
                : const Duration(seconds: 10)),
        control: ProcessControl(
            isCancelled: () => cancel.isCompleted,
            whenCancelled: cancel.future,
            onOutput: (text, {isError = false}) {
              output += text;
              if (output.contains('child:') &&
                  output.contains('root:') &&
                  !ready.isCompleted) ready.complete();
            }),
      );
      await ready.future.timeout(const Duration(seconds: 3));
      final pids = RegExp(r'(?:root|child):(\d+)')
          .allMatches(output)
          .map((match) => int.parse(match[1]!))
          .toList();
      addTearDown(() {
        for (final pid in pids) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
      });
      expect(pids, hasLength(2));
      if (!timeout) cancel.complete();
      final result =
          await run.timeout(const Duration(seconds: 5)) as CommandCompleted;
      expect(result.cancelled, !timeout);
      expect(result.timedOut, timeout);
      expect(result.stdout, contains('child:'));
      for (final pid in pids) {
        expect(await alive(pid), false,
            reason: 'process $pid must be stopped before returning');
      }
      final next = await const IoProcessRunner().run(request('echo next'))
          as CommandCompleted;
      expect(next.stdout.trim(), 'next');
      expect(next.cancelled, false);
    });
  }

  test('already cancelled invocations never spawn', () async {
    final result = await const IoProcessRunner().run(
        request('echo should-not-run'),
        control: ProcessControl(isCancelled: () => true)) as CommandCompleted;
    expect(result.cancelled, true);
    expect(result.stdout, isEmpty);
    expect(result.timedOut, false);
  });
}
