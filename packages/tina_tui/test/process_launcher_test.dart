import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

void main() {
  setUpAll(() async {
    final library = (await Isolate.resolvePackageUri(
        Uri.parse('package:tina_tui/tina_tui.dart')))!;
    configureCapturedProcessLauncher(Platform.resolvedExecutable, [
      '--packages=${await Isolate.packageConfig}',
      library.resolve('../test/fixtures/process_launcher.dart').toFilePath(),
      '--internal-process-launch',
    ]);
  });

  ProcessRequest request(List<String> arguments,
          {String? cwd, Map<String, String>? environment, String? stdin}) =>
      (
        command: '/bin/sh',
        arguments: arguments,
        workingDirectory: cwd,
        environment: environment,
        stdin: stdin,
        timeout: const Duration(seconds: 10),
      );

  test('detached exec preserves literal argv, cwd, env, stdin and exit status',
      () async {
    final directory = Directory.systemTemp.createTempSync('tina-launch-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final done = await const IoProcessRunner().run(request(
        [
          '-c',
          r'pwd; printf "%s\n" "$1" "$FIXTURE"; cat; echo captured-error >&2; exit 7',
          'fixture',
          r'literal $(touch unexpected) ; $HOME',
        ],
        cwd: directory.path,
        environment: {'FIXTURE': 'isolated-env', 'PATH': '/bin:/usr/bin'},
        stdin: 'captured-input\n')) as CommandCompleted;
    expect(done.exitCode, 7);
    expect(done.stdout, contains(directory.resolveSymbolicLinksSync()));
    expect(done.stdout, contains(r'literal $(touch unexpected) ; $HOME'));
    expect(done.stdout, contains('isolated-env\ncaptured-input'));
    expect(done.stderr.trim(), 'captured-error');
    expect(File('${directory.path}/unexpected').existsSync(), false);
  }, skip: Platform.isWindows);

  test('missing program reports a captured failure rather than leaking',
      () async {
    final process = await startCapturedProcess('tina-missing-program-123', []);
    final stdout = process.stdout.transform(systemEncoding.decoder).join();
    final stderr = process.stderr.transform(systemEncoding.decoder).join();
    await process.stdin.close();
    expect(await process.exitCode, 127);
    expect(await stdout, isEmpty);
    expect(await stderr, contains('tina-missing-program-123'));
  }, skip: Platform.isWindows);

  test('cancelling detached exec kills descendants and retains both streams',
      () async {
    final cancel = Completer<void>();
    final ready = Completer<void>();
    var stdout = '';
    final running = const IoProcessRunner().run(
        request([
          '-c',
          "sh -c 'echo child:\$\$; while :; do sleep 1; done' & echo stderr-ready >&2; wait",
        ]),
        control: ProcessControl(
            whenCancelled: cancel.future,
            onOutput: (text, {isError = false}) {
              if (!isError) stdout += text;
              if (stdout.contains('child:') && !ready.isCompleted)
                ready.complete();
            }));
    await ready.future.timeout(const Duration(seconds: 10));
    final child = int.parse(RegExp(r'child:(\d+)').firstMatch(stdout)![1]!);
    addTearDown(() => Process.killPid(child, ProcessSignal.sigkill));
    cancel.complete();
    final done = await running as CommandCompleted;
    expect(done.cancelled, true);
    expect(done.stdout, contains('child:'));
    expect(done.stderr, contains('stderr-ready'));
    final state = await Process.run('ps', ['-o', 'stat=', '-p', '$child']);
    expect(
        state.exitCode != 0 || '${state.stdout}'.trim().startsWith('Z'), true);
  }, skip: Platform.isWindows);
}
