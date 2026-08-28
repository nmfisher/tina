import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/tmux/tmux_support.dart';
import 'package:test/test.dart';

import '../../packages/tina_engine/test/helpers/memory_process_runner.dart';

/// A [ProcessRunner] that records every [run] and then throws — the
/// missing-binary / spawn-failure shape the support must swallow and surface
/// as a detach error rather than propagate into exit.
class _ThrowingRunner implements ProcessRunner {
  int attempts = 0;

  @override
  Future<RunningProcess> start(String executable, List<String> arguments,
          {String? workingDirectory}) async =>
      throw StateError('start is not used by TmuxSupport');

  @override
  Future<RunResult> run(String executable, List<String> arguments,
      {String? workingDirectory}) async {
    attempts++;
    throw StateError('spawn failed');
  }
}

/// A [ProcessRunner] whose `run` throws the exact [ProcessException] a
/// missing `tmux` binary produces — the shape `detach` must catch and report.
class _ProcessExceptionRunner implements ProcessRunner {
  @override
  Future<RunningProcess> start(String executable, List<String> arguments,
          {String? workingDirectory}) async =>
      throw StateError('start is not used by TmuxSupport');

  @override
  Future<RunResult> run(String executable, List<String> arguments,
      {String? workingDirectory}) async =>
      throw const ProcessException(
          'tmux', ['detach-client'], 'No such file', 127);
}

void main() {
  group('TmuxSupport — inTmux', () {
    test('true when \$TMUX is set', () {
      expect(
          TmuxSupport(env: {'TMUX': '/tmp/tmux-1000/default,12345,0'}).inTmux,
          isTrue);
    });

    test('false when \$TMUX is unset', () {
      expect(TmuxSupport(env: {}).inTmux, isFalse);
    });

    test('false when \$TMUX is the empty string', () {
      expect(TmuxSupport(env: {'TMUX': ''}).inTmux, isFalse);
    });
  });

  group('TmuxSupport — attachTarget / attachLine', () {
    test('named socket: /tmp/tmux-1000/default,12345,0 → default', () {
      final t = TmuxSupport(env: {'TMUX': '/tmp/tmux-1000/default,12345,0'});
      expect(t.attachTarget, 'default');
      expect(t.attachLine, 'tmux attach -t default');
    });

    test('numeric socket: /tmp/tmux-1000/1,4242,3 → 1', () {
      final t = TmuxSupport(env: {'TMUX': '/tmp/tmux-1000/1,4242,3'});
      expect(t.attachTarget, '1');
      expect(t.attachLine, 'tmux attach -t 1');
    });

    test('session name with an inner comma: /t/my,weird,9,0 → my', () {
      final t = TmuxSupport(env: {'TMUX': '/t/my,weird,9,0'});
      expect(t.attachTarget, 'my');
    });

    test('socket path without a comma: /tmp/tmux-1000/work → work', () {
      final t = TmuxSupport(env: {'TMUX': '/tmp/tmux-1000/work'});
      expect(t.attachTarget, 'work');
      expect(t.attachLine, 'tmux attach -t work');
    });

    test('socket name starting with a comma: /t/,9,0 → empty target', () {
      final t = TmuxSupport(env: {'TMUX': '/t/,9,0'});
      expect(t.attachTarget, isEmpty);
      expect(t.attachLine, isEmpty);
    });

    test('absent \$TMUX: no target, no line', () {
      final t = TmuxSupport(env: {});
      expect(t.attachTarget, isEmpty);
      expect(t.attachLine, isEmpty);
    });
  });

  group('TmuxSupport — detach', () {
    MemoryProcessRunner scripted({
      String stdout = '',
      String stderr = '',
      int exit = 0,
    }) {
      return MemoryProcessRunner.always(MemoryRunningProcess(
        stdoutChunks: stdout.isEmpty ? const [] : [stdout],
        stderrChunks: stderr.isEmpty ? const [] : [stderr],
        exitCodeValue: exit,
      ));
    }

    test('spawns tmux detach-client with no arguments', () async {
      final runner = scripted();
      final t = TmuxSupport(
        env: {'TMUX': '/tmp/tmux-1000/default,1,0'},
        processRunner: runner,
      );
      final r = await t.detach();
      expect(r.ok, isTrue);
      expect(r.error, isNull);
      expect(runner.runs, hasLength(1));
      expect(runner.runs.single.executable, 'tmux');
      expect(runner.runs.single.arguments, ['detach-client']);
    });

    test('nonzero exit surfaces the stderr as the error', () async {
      final runner = scripted(
          stderr: 'no server running on /tmp/tmux-1000/default', exit: 1);
      final t = TmuxSupport(
        env: {'TMUX': '/tmp/tmux-1000/default,1,0'},
        processRunner: runner,
      );
      final r = await t.detach();
      expect(r.ok, isFalse);
      expect(r.error, contains('no server running'));
    });

    test('nonzero exit with empty stderr reports the code', () async {
      final runner = scripted(exit: 2);
      final t = TmuxSupport(
        env: {'TMUX': '/tmp/tmux-1000/default,1,0'},
        processRunner: runner,
      );
      final r = await t.detach();
      expect(r.ok, isFalse);
      expect(r.error, 'tmux detach-client exited 2');
    });

    test('missing binary (ProcessException) is reported, never thrown',
        () async {
      // MemoryProcessRunner can only return a scripted process, so the
      // missing-binary shape — a thrown ProcessException — gets its own
      // one-method runner.
      final t = TmuxSupport(
        env: {'TMUX': '/tmp/tmux-1000/default,1,0'},
        processRunner: _ProcessExceptionRunner(),
      );
      final r = await t.detach();
      expect(r.ok, isFalse);
      expect(r.error, contains('No such file'));
    });

    test('a runner that throws otherwise is swallowed the same way', () async {
      final runner = _ThrowingRunner();
      final t = TmuxSupport(
        env: {'TMUX': '/tmp/tmux-1000/default,1,0'},
        processRunner: runner,
      );
      final r = await t.detach();
      expect(r.ok, isFalse);
      expect(r.error, isNotNull);
      expect(runner.attempts, 1);
    });

    test('without \$TMUX, no spawn happens at all', () async {
      final runner = scripted();
      final t = TmuxSupport(env: {}, processRunner: runner);
      final r = await t.detach();
      expect(r.ok, isFalse);
      expect(r.error, TmuxSupport.notInTmuxHint);
      expect(runner.runs, isEmpty);
    });
  });

  group('TmuxSupport — notInTmuxHint', () {
    test('is the ticket string', () {
      expect(
          TmuxSupport.notInTmuxHint,
          startsWith(
              'not running in tmux — start tina with: tmux new -s tina'));
    });
  });

  group('TmuxSupport — once-per-install notice', () {
    late Directory tinaDir;

    setUp(() {
      tinaDir = Directory.systemTemp.createTempSync('tina-tmux-test.');
    });

    tearDown(() {
      tinaDir.deleteSync(recursive: true);
    });

    TmuxSupport support() => TmuxSupport(
          env: {'TMUX': '/tmp/tmux-1000/default,1,0'},
          tinaDir: tinaDir,
        );

    test('shown on first run in tmux on the notcurses backend', () {
      final t = support();
      expect(t.tmuxNoticeShown, isFalse);
      final notice = t.tmuxAttachNotice(notcursesBackend: true);
      expect(notice, isNotNull);
      expect(notice, contains('--backend ansi'));
      expect(notice, contains('tmux'));
    });

    test('suppressed on the ansi backend', () {
      final t = support();
      expect(t.tmuxAttachNotice(notcursesBackend: false), isNull);
    });

    test('suppressed outside tmux', () {
      final t = TmuxSupport(env: {}, tinaDir: tinaDir);
      expect(t.tmuxAttachNotice(notcursesBackend: true), isNull);
    });

    test('marker file suppresses the notice on the next run', () {
      final first = support();
      expect(first.tmuxAttachNotice(notcursesBackend: true), isNotNull);
      first.markTmuxNoticeShown();

      // A fresh instance (a new process) sees the marker and stays quiet.
      final second = support();
      expect(second.tmuxNoticeShown, isTrue);
      expect(second.tmuxAttachNotice(notcursesBackend: true), isNull);
    });

    test('marking writes the marker under the tina dir', () {
      final t = support();
      t.markTmuxNoticeShown();
      expect(t.markerFile.path,
          p.join(tinaDir.path, '.tmux_notice_shown'));
      expect(t.markerFile.existsSync(), isTrue);
      expect(t.markerFile.readAsStringSync(), isNotEmpty);
    });

    test('marking is idempotent and never throws on a missing parent', () {
      final nested = Directory(p.join(tinaDir.path, 'new', 'tina'));
      final t = TmuxSupport(
        env: {'TMUX': '/tmp/tmux-1000/default,1,0'},
        tinaDir: nested,
      );
      t.markTmuxNoticeShown();
      t.markTmuxNoticeShown();
      expect(t.tmuxNoticeShown, isTrue);
    });
  });
}