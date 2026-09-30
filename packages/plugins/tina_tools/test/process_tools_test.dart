import 'dart:io';
import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

/// The two process tools. The runner is scripted (a fake inner runner behind
/// the real sandbox) so every assertion is on what the tool *asked the runner
/// to run* or on the tool result it returned — headless by construction.
void main() {
  group('bash tool', () {
    test('the command string reaches the runner as shell -c argv', () async {
      final inner = _RecordingRunner(_done(0, '', ''));
      final tool = BashTool(runner: inner, workingDirectory: '/tmp/ws');
      final res = await tool.execute({'command': 'echo hi | wc -c'});
      expect(res.isError, isFalse);
      expect(inner.command, '/bin/sh');
      expect(inner.arguments, ['-c', 'echo hi | wc -c']);
      expect(inner.workingDirectory, '/tmp/ws');
    });

    test('a refusal becomes an error result carrying the reason', () async {
      final tool = BashTool(
        runner: SandboxedProcessRunner(
          inner: _RecordingRunner(_done(0, '', '')),
          mode: PermissionMode.readOnly,
          writableDirectories: WritableDirectories()..add('/'),
        ),
      );
      final res = await tool.execute({'command': 'echo hi'});
      expect(res.isError, isTrue);
      expect(res.content, contains('read-only mode'));
    });

    test(
        'a shell string is never certified silently: it asks, and an '
        'approval runs it', () async {
      final approver = _Approving();
      final inner = _RecordingRunner(_done(0, 'ran', ''));
      final tool = BashTool(
        runner: SandboxedProcessRunner(
          inner: inner,
          writableDirectories: WritableDirectories()..add('/'),
          approver: approver.call,
        ),
      );
      final res = await tool.execute({'command': 'echo hi > /tmp/ws/out'});
      expect(res.isError, isFalse);
      expect(approver.asked, 1, reason: 'the string itself triggered the ask');
      expect(inner.command, '/bin/sh');
    });

    test('missing command is a validation error', () async {
      final tool = BashTool(runner: _RecordingRunner(_done(0, '', '')));
      final res = await tool.execute({});
      expect(res.isError, isTrue);
      expect(res.content, contains('command is required'));
    });

    test('nonzero exit is reported as a failed tool result', () async {
      final approver = _Approving();
      final tool = BashTool(
        runner: SandboxedProcessRunner(
          inner: _RecordingRunner(_done(2, '', 'boom')),
          writableDirectories: WritableDirectories()..add('/'),
          approver: approver.call,
        ),
      );
      final res = await tool.execute({'command': 'false'});
      expect(res.isError, isTrue);
      expect(res.content, contains('exit code: 2'));
      expect(res.content, contains('boom'));
    });

    test('end-to-end on the real runner: stdout captured', () async {
      final approver = _Approving();
      final tool = BashTool(
        runner: SandboxedProcessRunner(
          inner: const IoProcessRunner(),
          writableDirectories: WritableDirectories()..add('/'),
          approver: approver.call,
        ),
      );
      final res = await tool.execute({'command': 'echo roundtrip'});
      expect(res.isError, isFalse);
      expect(res.content, contains('roundtrip'));
    });
  });

  group('exec tool', () {
    test('network is denied without an explicit approval and requires a reason',
        () async {
      final inner = _RecordingRunner(_done(0, '', ''));
      final tool = ExecTool(runner: inner);
      expect((await tool.execute({'program': 'git', 'network': true})).isError,
          isTrue);
      expect(
          (await tool.execute({
            'program': 'git',
            'network': true,
            'network_reason': 'push branch'
          }))
              .isError,
          isTrue);
      expect(inner.command, isNull);
    });
    test('network approval survives job ownership and applies to one call only',
        () async {
      final inner = _RecordingRunner(_done(0, '', ''));
      final jobs = ProcessJobs(inner);
      addTearDown(jobs.close);
      var asks = 0;
      final tool = ExecTool(
          runner: jobs,
          approveNetwork: (request, reason) async {
            asks++;
            expect(request.arguments, ['push', 'origin']);
            expect(reason, 'push branch');
            return true;
          });
      await tool.execute({
        'program': 'git',
        'args': ['push', 'origin'],
        'network': true,
        'network_reason': 'push branch'
      });
      expect(asks, 1);
      expect(inner.receivedControl!.networkAllowed, isTrue);
      await tool.execute({
        'program': 'git',
        'args': ['status']
      });
      expect(inner.receivedControl!.networkAllowed, isFalse);
      expect(asks, 1);
    });

    test('passes options, subcommands and explicit separators unchanged',
        () async {
      for (final args in [
        ['rev-parse', '--abbrev-ref', 'HEAD'],
        ['-n', '--', 'two words', 'file.txt'],
        ['-n', '1,3p', 'file.txt'],
        ['.', '-name', '*.dart'],
      ]) {
        final inner = _RecordingRunner(_done(0, '', ''));
        await ExecTool(runner: inner)
            .execute({'program': 'program', 'args': args});
        expect(inner.arguments, args);
      }
    });

    test('direct git subcommands run without a wrapper', () async {
      final project = Directory.systemTemp.createTempSync('tina_exec_git_');
      addTearDown(() => project.deleteSync(recursive: true));
      expect((await Process.run('git', ['init', project.path])).exitCode, 0);
      final result = await ExecTool(
              runner: const IoProcessRunner(), workingDirectory: project.path)
          .execute({
        'program': 'git',
        'args': ['rev-parse', '--git-dir'],
      });
      expect(result.isError, isFalse, reason: result.content);
      expect(result.content, contains('.git'));
    });

    test('no model values → no fence at all', () async {
      final inner = _RecordingRunner(_done(0, '', ''));
      await ExecTool(runner: inner).execute({'program': 'true'});
      expect(inner.arguments, isEmpty);
    });

    test('non-string args are a validation error, not a spawn', () async {
      final inner = _RecordingRunner(_done(0, '', ''));
      final tool = ExecTool(runner: inner);
      final res = await tool.execute({
        'program': 'grep',
        'args': [42],
      });
      expect(res.isError, isTrue);
      expect(res.content, contains('args must be a list of strings'));
      expect(inner.command, isNull, reason: 'nothing was run');
    });

    test('missing program is a validation error', () async {
      final tool = ExecTool(runner: _RecordingRunner(_done(0, '', '')));
      final res = await tool.execute({});
      expect(res.isError, isTrue);
      expect(res.content, contains('program is required'));
    });

    test('a refusal reaches the tool result with the reason', () async {
      final tool = ExecTool(
        runner: SandboxedProcessRunner(
          inner: _RecordingRunner(_done(0, '', '')),
          writableDirectories: WritableDirectories()..add('/tmp/ws'),
        ),
      );
      final res = await tool.execute({
        'program': 'cat',
        'args': ['/etc/hostname'],
      });
      // /etc/hostname is path-shaped and outside the writable directories → ask →
      // no approver wired → deny.
      expect(res.isError, isTrue);
      expect(res.content, contains('no approver'));
    });

    test('literal shell syntax is not interpreted by exec', () async {
      final tool = ExecTool(
        runner: SandboxedProcessRunner(
          inner: const IoProcessRunner(),
          approver: (_, __) async => Approval.yes,
          writableDirectories: WritableDirectories()..add('/'),
        ),
      );
      // Shell metacharacters remain literal arguments without a shell.
      final res = await tool.execute({
        'program': 'printf',
        'args': ['%s', r'$(echo expanded) | cat > file'],
      });
      expect(res.isError, isFalse);
      expect(res.content, contains(r'$(echo expanded) | cat > file'));
    });
  });

  group('no tool carries a declaration', () {
    test('the same BashTool and ExecTool flip with the runner\'s mode',
        () async {
      final inner = _RecordingRunner(_done(0, '', ''));
      final approver = _Approving();
      final sandbox = SandboxedProcessRunner(
        inner: inner,
        writableDirectories: WritableDirectories()..add('/'),
        approver: approver.call,
      );
      final bash = BashTool(runner: sandbox);
      final exec = ExecTool(runner: sandbox);

      expect((await bash.execute({'command': 'echo a'})).isError, isFalse);
      expect(
          (await exec.execute({
            'program': 'echo',
            'args': ['b']
          }))
              .isError,
          isFalse);

      sandbox.mode = PermissionMode.readOnly;
      final bashRefused = await bash.execute({'command': 'echo c'});
      expect(bashRefused.isError, isTrue);
      expect(bashRefused.content, contains('read-only mode'));
      final execRefused = await exec.execute({
        'program': 'echo',
        'args': ['d']
      });
      expect(execRefused.isError, isTrue);
      expect(execRefused.content, contains('read-only mode'));
    });
  });
}

final class _Approving {
  int asked = 0;
  Future<Approval> call(FileOperation op, String reason) async {
    asked++;
    return Approval.yes;
  }
}

CommandCompleted _done(int code, String out, String err) =>
    CommandCompleted(exitCode: code, stdout: out, stderr: err);

/// Records exactly what the tool handed the runner, then plays one outcome.
final class _RecordingRunner implements ProcessRunner {
  CommandOutcome _next;
  ProcessControl? receivedControl;
  String? command;
  List<String>? arguments;
  String? workingDirectory;
  Map<String, String>? environment;

  _RecordingRunner(this._next);

  void play(CommandOutcome outcome) => _next = outcome;

  String get commandLine =>
      [command ?? '', ...(arguments ?? const [])].join(' ').trim();

  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    receivedControl = control;
    command = request.command;
    arguments = List.of(request.arguments);
    workingDirectory = request.workingDirectory;
    environment = request.environment;
    return _next;
  }
}

typedef CommandOutcome = CommandCompleted;
