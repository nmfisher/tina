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
          writableSet: WritableSet()..add('/'),
        ),
      );
      final res = await tool.execute({'command': 'echo hi'});
      expect(res.isError, isTrue);
      expect(res.content, contains('read-only mode'));
    });

    test('a shell string is never certified silently: it asks, and an '
        'approval runs it', () async {
      final asker = _ApprovingAsker();
      final inner = _RecordingRunner(_done(0, 'ran', ''));
      final tool = BashTool(
        runner: SandboxedProcessRunner(
          inner: inner,
          writableSet: WritableSet()..add('/'),
          asker: asker.call,
        ),
      );
      final res = await tool.execute({'command': 'echo hi > /tmp/ws/out'});
      expect(res.isError, isFalse);
      expect(asker.asked, 1, reason: 'the string itself triggered the ask');
      expect(inner.command, '/bin/sh');
    });

    test('missing command is a validation error', () async {
      final tool = BashTool(runner: _RecordingRunner(_done(0, '', '')));
      final res = await tool.execute({});
      expect(res.isError, isTrue);
      expect(res.content, contains('command is required'));
    });

    test('a non-zero exit is a normal result, not an error', () async {
      final asker = _ApprovingAsker();
      final tool = BashTool(
        runner: SandboxedProcessRunner(
          inner: _RecordingRunner(_done(2, '', 'boom')),
          writableSet: WritableSet()..add('/'),
          asker: asker.call,
        ),
      );
      final res = await tool.execute({'command': 'false'});
      expect(res.isError, isFalse, reason: 'a failing command is a result');
      expect(res.content, contains('exit code: 2'));
      expect(res.content, contains('boom'));
    });

    test('end-to-end on the real runner: stdout captured', () async {
      final asker = _ApprovingAsker();
      final tool = BashTool(
        runner: SandboxedProcessRunner(
          inner: const IoProcessRunner(),
          writableSet: WritableSet()..add('/'),
          asker: asker.call,
        ),
      );
      final res = await tool.execute({'command': 'echo roundtrip'});
      expect(res.isError, isFalse);
      expect(res.content, contains('roundtrip'));
    });
  });

  group('exec tool', () {
    test('model values arrive fenced: after --, never as options', () async {
      final inner = _RecordingRunner(_done(0, '', ''));
      final tool = ExecTool(runner: inner, workingDirectory: '/tmp/ws');
      final res = await tool.execute({
        'program': 'grep',
        'args': ['--pre=rm -rf /', '/tmp/ws/x.txt'],
      });
      expect(res.isError, isFalse);
      // The assertion the brief asks for: the argv the runner actually
      // received. Every model value is after the fence.
      expect(inner.command, 'grep');
      expect(inner.arguments, ['--', '--pre=rm -rf /', '/tmp/ws/x.txt']);
      // And no model value sits before the fence.
      final argv = List.of(inner.arguments ?? const <String>[]);
      expect(argv.indexOf('--'), 0,
          reason: 'the tool emitted no options of its own, so the fence '
              'opens at argv[0]');
    });

    test('tool options would precede the fence; model values never', () async {
      final inner = _RecordingRunner(_done(0, '', ''));
      // Drive the same builder the tool uses, with a tool-derived option,
      // to pin the ordering rule itself.
      final argv = (FencedArguments()
            ..flag('--no-heading')
            ..option('--glob', '*.dart') // tool-derived, one token
            ..value('--pre=rm -rf /')) // model value
          .build();
      expect(argv,
          ['--no-heading', '--glob=*.dart', '--', '--pre=rm -rf /']);
      // The runner receives exactly this shape:
      inner.play(_done(0, '', ''));
      await ExecTool(runner: inner)
          .execute({'program': 'rg', 'args': ['--pre=rm -rf /']});
      final argv2 = List.of(inner.arguments ?? const <String>[]);
      expect(argv2.last, '--pre=rm -rf /');
      expect(argv2.indexOf('--'), lessThan(argv2.indexOf('--pre=rm -rf /')));
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
          writableSet: WritableSet()..add('/tmp/ws'),
        ),
      );
      final res = await tool.execute({
        'program': 'cat',
        'args': ['/etc/hostname'],
      });
      // /etc/hostname is path-shaped and outside the writable set → ask →
      // no asker wired → deny.
      expect(res.isError, isTrue);
      expect(res.content, contains('no asker'));
    });

    test('end-to-end on the real runner: the fence holds for real', () async {
      final tool = ExecTool(
        runner: SandboxedProcessRunner(
          inner: const IoProcessRunner(),
          writableSet: WritableSet()..add('/'),
        ),
      );
      // `echo` with a hostile "option": it must arrive as data and be
      // echoed back verbatim, not interpreted by anything.
      final res = await tool.execute({
        'program': 'echo',
        'args': ['--pre=rm -rf /'],
      });
      expect(res.isError, isFalse);
      expect(res.content, contains('--pre=rm -rf /'));
    });
  });

  group('no tool carries a declaration', () {
    test('the same BashTool and ExecTool flip with the runner\'s mode',
        () async {
      final inner = _RecordingRunner(_done(0, '', ''));
      final asker = _ApprovingAsker();
      final sandbox = SandboxedProcessRunner(
        inner: inner,
        writableSet: WritableSet()..add('/'),
        asker: asker.call,
      );
      final bash = BashTool(runner: sandbox);
      final exec = ExecTool(runner: sandbox);

      expect((await bash.execute({'command': 'echo a'})).isError, isFalse);
      expect(
          (await exec.execute({'program': 'echo', 'args': ['b']})).isError,
          isFalse);

      sandbox.mode = PermissionMode.readOnly;
      final bashRefused = await bash.execute({'command': 'echo c'});
      expect(bashRefused.isError, isTrue);
      expect(bashRefused.content, contains('read-only mode'));
      final execRefused =
          await exec.execute({'program': 'echo', 'args': ['d']});
      expect(execRefused.isError, isTrue);
      expect(execRefused.content, contains('read-only mode'));
    });
  });
}

final class _ApprovingAsker {
  int asked = 0;
  Future<FileAskAnswer> call(FileOperation op, String reason) async {
    asked++;
    return FileAskAnswer.yes;
  }
}

CommandCompleted _done(int code, String out, String err) =>
    CommandCompleted(exitCode: code, stdout: out, stderr: err);

/// Records exactly what the tool handed the runner, then plays one outcome.
final class _RecordingRunner implements ProcessRunner {
  CommandOutcome _next;
  String? command;
  List<String>? arguments;
  String? workingDirectory;
  Map<String, String>? environment;

  _RecordingRunner(this._next);

  void play(CommandOutcome outcome) => _next = outcome;

  String get commandLine =>
      [command ?? '', ...(arguments ?? const [])].join(' ').trim();

  @override
  Future<RunOutcome> run(ProcessRequest request) async {
    command = request.command;
    arguments = List.of(request.arguments);
    workingDirectory = request.workingDirectory;
    environment = request.environment;
    return _next;
  }
}

typedef CommandOutcome = CommandCompleted;
