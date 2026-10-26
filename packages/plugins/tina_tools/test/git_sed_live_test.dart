import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

/// A runner that records the request handed to the inner real runner.
final class RecordingRunner implements ConfinedProcessRunner {
  RecordingRunner(this.inner);
  final ProcessRunner inner;
  @override
  bool get confinesFilesystem =>
      inner is ConfinedProcessRunner &&
      (inner as ConfinedProcessRunner).confinesFilesystem;
  final requests = <ProcessRequest>[];
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    requests.add(request);
    return inner.run(request, control: control);
  }
}

/// Live integration check: a certified reader runs against a real git repo
/// without an approval; a non-certified form is refused when no approver is
/// wired. Runs the pinned system git via IoProcessRunner.
void main() {
  const gitPath = '/usr/bin:/bin';
  late Directory repo;
  late SandboxHome home;
  RecordingRunner makeRecorder() => RecordingRunner(OsSandboxRunner(
      inner: const IoProcessRunner(),
      plan: SandboxPlan(
        workspaceRoot: repo.path,
        home: home,
        parentEnvironment: {'HOME': repo.path, 'PATH': gitPath},
      )));

  ProcessRequest request(List<String> args) => (
        command: 'git',
        arguments: args,
        workingDirectory: repo.path,
        environment: null,
        stdin: null,
        timeout: null,
      );

  setUp(() async {
    repo = Directory.systemTemp.createTempSync('git-reader-live-');
    home = SandboxHome(realHome: repo.path, stateRoot: '${repo.path}/.runtime');
    Future<void> git(List<String> args, {String? cwd}) async {
      final result = await Process.run(
        '/usr/bin/git',
        args,
        workingDirectory: cwd ?? repo.path,
        environment: {
          'GIT_AUTHOR_NAME': 'T',
          'GIT_AUTHOR_EMAIL': 't@example.com',
          'GIT_COMMITTER_NAME': 'T',
          'GIT_COMMITTER_EMAIL': 't@example.com'
        },
      );
      expect(result.exitCode, 0,
          reason: 'git ${args.join(' ')}: ${result.stderr}');
    }

    await git(['init', '-q']);
    await git(['config', 'user.email', 't@example.com']);
    await git(['config', 'user.name', 'T']);
    File('${repo.path}/runtime.py')
        .writeAsStringSync('line one\nline two\nline three\n');
    await git(['add', '.']);
    await git(['commit', '-qm', 'init']);
  });

  tearDown(() {
    home.close();
    try {
      repo.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('certified git readers run without approval against a real repo',
      () async {
    final recorder = makeRecorder();
    final gate = SandboxedProcessRunner(
      inner: recorder,
      mode: PermissionMode.readOnly,
      executableSearchPath: gitPath,
    );
    for (final args in [
      ['status'],
      ['log'],
      ['show', 'HEAD'],
      ['diff', 'HEAD'],
    ]) {
      final outcome = await gate.run(request(args));
      expect(outcome, isA<CommandCompleted>(), reason: 'git ${args.join(' ')}');
      expect((outcome as CommandCompleted).exitCode, 0, reason: outcome.stderr);
    }
    // The spawned git carries the optional-locks guard and the pinned path.
    expect(recorder.requests, isNotEmpty);
    for (final spawned in recorder.requests) {
      expect(spawned.command, startsWith('/usr/bin/git'));
      expect(spawned.environment?['GIT_OPTIONAL_LOCKS'], '0');
    }
  });

  test('print-only sed runs without approval; edits are refused', () async {
    ProcessRequest sed(List<String> args) => (
          command: 'sed',
          arguments: args,
          workingDirectory: repo.path,
          environment: null,
          stdin: null,
          timeout: null,
        );
    final recorder = makeRecorder();
    final gate = SandboxedProcessRunner(
      inner: recorder,
      mode: PermissionMode.ask,
      executableSearchPath: gitPath,
    );
    final ok = await gate.run(sed(['-n', '1,2p', 'runtime.py']));
    expect(ok, isA<CommandCompleted>());
    expect((ok as CommandCompleted).stdout, contains('line one'));
    // -i edit has no approver wired -> refused.
    expect(
      await gate.run(sed(['-i', 's/one/ONE/', 'runtime.py']),
          control: const ProcessControl(readOnlyRequested: false)),
      isA<CommandRefused>(),
    );
    expect(File('${repo.path}/runtime.py').readAsStringSync(),
        contains('line one'));
  });

  test('read-only rejects writable git requests without spawning', () async {
    final recorder = makeRecorder();
    final gate = SandboxedProcessRunner(
      inner: recorder,
      mode: PermissionMode.readOnly,
      executableSearchPath: gitPath,
    );
    for (final args in [
      ['push'],
      ['commit', '-m', 'x'],
      ['reset', '--hard'],
      ['branch', 'feature'],
      ['tag', 'v1.0.0'],
      ['log', '-S', 'needle'],
      ['tag', '--', 'v1.0.0'],
    ]) {
      expect(
          await gate.run(request(args),
              control: const ProcessControl(readOnlyRequested: false)),
          isA<CommandRefused>(),
          reason: 'git ${args.join(' ')}');
    }
    expect(recorder.requests, isEmpty, reason: 'nothing was spawned');
  });
}
