import 'dart:io';

import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

/// The command × mode table, the asker, and the grants — headless: the
/// runner is scripted except where a test says `real:`, and nothing here
/// opens a terminal or needs an OS sandbox.
void main() {
  group('process runner seam', () {
    test('a real command round-trips: exit code, stdout, stderr', () async {
      final outcome = await IoProcessRunner().run((
        command: '/bin/sh',
        arguments: ['-c', 'echo out-hello; echo err-hello 1>&2; exit 3'],
        workingDirectory: null,
        environment: null,
        stdin: null,
        timeout: null,
      ));
      expect(outcome, isA<CommandCompleted>());
      final done = outcome as CommandCompleted;
      expect(done.exitCode, 3);
      expect(done.stdout, contains('out-hello'));
      expect(done.stderr, contains('err-hello'));
    });

    test('non-zero exit is a normal result, not a refusal', () async {
      final outcome = await IoProcessRunner().run((
        command: 'false',
        arguments: [],
        workingDirectory: null,
        environment: null,
        stdin: null,
        timeout: null,
      ));
      expect(outcome, isA<CommandCompleted>());
      expect((outcome as CommandCompleted).exitCode, isNonZero);
    });

    test('a missing program is a completed run (spawn failed), not a refusal',
        () async {
      final outcome = await IoProcessRunner().run((
        command: 'definitely-not-a-real-program-42',
        arguments: [],
        workingDirectory: null,
        environment: null,
        stdin: null,
        timeout: null,
      ));
      expect(outcome, isA<CommandCompleted>());
      expect((outcome as CommandCompleted).exitCode, 127);
    });

    test('the runner passes argv literally and honours cwd and timeout',
        () async {
      final tmp = Directory.systemTemp.createTempSync('tina_tools_proc_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final outcome = await IoProcessRunner().run((
        command: '/bin/sh',
        arguments: ['-c', 'pwd'],
        workingDirectory: tmp.path,
        environment: null,
        stdin: null,
        timeout: const Duration(seconds: 5),
      ));
      expect((outcome as CommandCompleted).stdout.trim(), tmp.path);
    });
  });

  group('command x mode table (decideCommand)', () {
    ProcessRequest req(String line) => (
          command: line.split(' ').first,
          arguments: line.split(' ').skip(1).toList(),
          workingDirectory: null,
          environment: null,
          stdin: null,
          timeout: null,
        );

    test('readOnly refuses every command, with the reason saying so', () {
      for (final line in ['git status', 'ls', 'echo hi', 'rm -rf /']) {
        final d = decideCommand(req(line), PermissionMode.readOnly,
            writableSet: WritableSet()..add('/'),
            networkOff: false);
        expect(d.verdict, ToolVerdict.deny, reason: line);
        expect(d.reason, contains('read-only mode'), reason: line);
      }
    });

    test('normal allows what stays inside the writable set', () {
      final ws = WritableSet()..add('/tmp/ws');
      final d = decideCommand(
          (
            command: 'cat',
            arguments: ['/tmp/ws/notes.txt'],
            workingDirectory: '/tmp/ws',
            environment: null,
            stdin: null,
            timeout: null,
          ),
          PermissionMode.normal,
          writableSet: ws,
          networkOff: true);
      expect(d.verdict, ToolVerdict.allow);
      expect(d.reason, contains('writable set'));
    });

    test('normal asks when a path argument lands outside the set', () {
      final ws = WritableSet()..add('/tmp/ws');
      final d = decideCommand(
          (
            command: 'cat',
            arguments: ['/etc/passwd'],
            workingDirectory: '/tmp/ws',
            environment: null,
            stdin: null,
            timeout: null,
          ),
          PermissionMode.normal,
          writableSet: ws,
          networkOff: true);
      expect(d.verdict, ToolVerdict.ask);
      expect(d.reason, contains('outside the session'));
    });

    test('`..` in a path argument is never certified — it asks', () {
      final ws = WritableSet()..add('/tmp/ws');
      final d = decideCommand(
          (
            command: 'cat',
            arguments: ['../escape.txt'],
            workingDirectory: '/tmp/ws',
            environment: null,
            stdin: null,
            timeout: null,
          ),
          PermissionMode.normal,
          writableSet: ws,
          networkOff: true);
      expect(d.verdict, ToolVerdict.ask);
    });

    test('a fetch-shaped command asks while network is off', () {
      final ws = WritableSet()..add('/');
      for (final line in ['curl https://x.example', 'git push']) {
        final d = decideCommand(req(line), PermissionMode.normal,
            writableSet: ws, networkOff: true);
        expect(d.verdict, ToolVerdict.ask, reason: line);
      }
      // And with network on, the same commands are ordinary.
      for (final line in ['curl https://x.example', 'git push']) {
        final d = decideCommand(req(line), PermissionMode.normal,
            writableSet: ws, networkOff: false);
        expect(d.verdict, ToolVerdict.allow, reason: line);
      }
    });

    test('a session grant short-circuits the ask', () {
      final grants = CommandGrants()..remember('git status');
      final d = decideCommand(req('git status'), PermissionMode.normal,
          writableSet: WritableSet(), networkOff: true, grants: grants);
      expect(d.verdict, ToolVerdict.allow);
      expect(d.reason, contains('session grant'));
    });
  });

  group('SandboxedProcessRunner', () {
    test('an allowed command runs on the inner runner', () async {
      final inner = _ScriptedRunner([_done(0, 'ok', '')]);
      final runner = SandboxedProcessRunner(
        inner: inner,
        writableSet: WritableSet()..add('/tmp/ws'),
      );
      final outcome = await runner.run(_req('cat /tmp/ws/f.txt'));
      expect(outcome, isA<CommandCompleted>());
      expect(inner.requests.single.arguments, ['/tmp/ws/f.txt']);
      expect((outcome as CommandCompleted).note, isNotNull);
    });

    test('readOnly refuses; the asker is never called; nothing runs',
        () async {
      var asked = 0;
      final inner = _ScriptedRunner(const []);
      final runner = SandboxedProcessRunner(
        inner: inner,
        mode: PermissionMode.readOnly,
        writableSet: WritableSet()..add('/'),
        asker: (_, __) async {
          asked++;
          return FileAskAnswer.yes;
        },
      );
      final outcome = await runner.run(_req('git status'));
      expect(outcome, isA<CommandRefused>());
      expect((outcome as CommandRefused).reason, contains('read-only mode'));
      expect(asked, 0, reason: 'read-only never asks');
      expect(inner.requests, isEmpty, reason: 'nothing ran');
    });

    test('normal: outside the set asks — no denies, yes runs', () async {
      var answers = [FileAskAnswer.no, FileAskAnswer.yes];
      var asked = 0;
      final inner = _ScriptedRunner([_done(0, 'ran', '')]);
      final runner = SandboxedProcessRunner(
        inner: inner,
        writableSet: WritableSet()..add('/tmp/ws'),
        asker: (request, reason) async {
          asked++;
          expect(reason, contains('outside the session'));
          expect(request.path, '/tmp/ws');
          return answers.removeAt(0);
        },
      );
      final refused = await runner.run(_req('cat /etc/hosts'));
      expect(refused, isA<CommandRefused>());
      expect((refused as CommandRefused).reason, contains('denied by the user'));
      expect(asked, 1);

      final allowed = await runner.run(_req('cat /etc/hosts'));
      expect(allowed, isA<CommandCompleted>());
      expect(asked, 2);
    });

    test('no asker wired → deny, fail closed', () async {
      final inner = _ScriptedRunner(const []);
      final runner = SandboxedProcessRunner(
        inner: inner,
        writableSet: WritableSet()..add('/tmp/ws'),
      );
      final outcome = await runner.run(_req('cat /etc/hosts'));
      expect(outcome, isA<CommandRefused>());
      expect((outcome as CommandRefused).reason, contains('no asker'));
      expect(inner.requests, isEmpty);
    });

    test('an "always" answer remembers the command line — no second ask',
        () async {
      var asked = 0;
      final inner = _ScriptedRunner(
          [_done(0, 'v1', ''), _done(0, 'v2', ''), _done(0, 'v3', '')]);
      final runner = SandboxedProcessRunner(
        inner: inner,
        writableSet: WritableSet()..add('/tmp/ws'),
        asker: (_, __) async {
          asked++;
          return FileAskAnswer.always;
        },
      );
      await runner.run(_req('cat /etc/hosts'));
      await runner.run(_req('cat /etc/hosts'));
      expect(asked, 1, reason: 'the second identical command skips the asker');
      // The grant was recorded as the exact command line.
      expect(runner.grants.patterns, ['cat /etc/hosts']);
      // But a different command still asks.
      await runner.run(_req('cat /etc/passwd'));
      expect(asked, 2);
    });

    test('the inner runner refusing is surfaced as a refusal, not masked',
        () async {
      final inner = _ScriptedRunner([_refused('host-level fence said no')]);
      final runner = SandboxedProcessRunner(
        inner: inner,
        writableSet: WritableSet()..add('/'),
      );
      final outcome = await runner.run(_req('ls /'));
      expect(outcome, isA<CommandRefused>());
      expect((outcome as CommandRefused).reason, 'host-level fence said no');
    });
  });
}

ProcessRequest _req(String line) => (
      command: line.split(' ').first,
      arguments: line.split(' ').skip(1).toList(),
      workingDirectory: '/tmp/ws',
      environment: null,
      stdin: null,
      timeout: null,
    );

CommandCompleted _done(int code, String out, String err) =>
    CommandCompleted(exitCode: code, stdout: out, stderr: err);

CommandRefused _refused(String reason) => CommandRefused(reason);

/// A scripted [ProcessRunner]: plays back one outcome per call and records
/// every request that reached it — the seam's test double.
final class _ScriptedRunner implements ProcessRunner {
  final List<RunOutcome> outcomes;
  final List<ProcessRequest> requests = [];

  _ScriptedRunner(this.outcomes);

  @override
  Future<RunOutcome> run(ProcessRequest request) async {
    requests.add(request);
    if (outcomes.isEmpty) {
      throw StateError('no scripted outcome for ${requests.length}');
    }
    return outcomes.removeAt(0);
  }
}
