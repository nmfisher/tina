import 'package:test/test.dart';
import 'package:tina/composition/edit_verifier.dart';
import 'package:tina_engine/tina_engine.dart';
import '../packages/tina_engine/test/helpers/memory_process_runner.dart';

/// A [ProcessRunner] whose `run` always throws — the spawn-failure shape the
/// verifier must swallow (return null) rather than propagate into the agent.
class _ThrowingRunner implements ProcessRunner {
  int attempts = 0;

  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async => throw StateError('no spawning here');

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    attempts++;
    throw StateError('spawn failed');
  }
}

void main() {
  group('DartAnalyzeVerifier (#22a)', () {
    MemoryProcessRunner scripted(
      String stdout, {
      String stderr = '',
      int exit = 0,
    }) {
      return MemoryProcessRunner.always(
        MemoryRunningProcess(
          stdoutChunks: [stdout],
          stderrChunks: stderr.isNotEmpty ? [stderr] : const [],
          exitCodeValue: exit,
        ),
      );
    }

    // Real analyzer shape (probed live): two leading spaces, `error - `,
    // path:line:col, message, then the diagnostic code after `  - `.
    const err1 = '  error - /tmp/scratch.dart:3:5 - first message  - code_a';
    const err2 = '  error - /tmp/scratch.dart:7:1 - second message  - code_b';

    test('2 errors → block with count and both file:line refs', () async {
      final runner = scripted('$err1\n$err2');
      final v = DartAnalyzeVerifier(processRunner: runner);
      final block = await v('edit', {'filePath': '/tmp/scratch.dart'});
      expect(block, isNotNull);
      expect(block, contains('[analyze] /tmp/scratch.dart: 2 error(s)'));
      expect(block, contains('scratch.dart:3:5 - first message'));
      expect(block, contains('scratch.dart:7:1 - second message'));
      expect(runner.runs, hasLength(1));
      expect(runner.runs.first.executable, 'dart');
      expect(runner.runs.first.arguments, ['analyze', '/tmp/scratch.dart']);
    });

    test('clean analyze → null (runner still invoked)', () async {
      final runner = scripted('');
      final v = DartAnalyzeVerifier(processRunner: runner);
      final block = await v('edit', {'filePath': '/tmp/scratch.dart'});
      expect(block, isNull);
      expect(runner.runs, hasLength(1));
    });

    test('warnings only → null', () async {
      final runner = scripted(
        '  warning - /tmp/scratch.dart:2:1 - unused thing  - warn_code',
      );
      final v = DartAnalyzeVerifier(processRunner: runner);
      expect(await v('edit', {'filePath': '/tmp/scratch.dart'}), isNull);
    });

    test('.txt path → null; runner never invoked', () async {
      final runner = scripted(err1);
      final v = DartAnalyzeVerifier(processRunner: runner);
      expect(await v('edit', {'filePath': 'notes.txt'}), isNull);
      expect(
        runner.runs,
        isEmpty,
        reason: 'non-.dart paths must never invoke the runner',
      );
    });

    test('non-edit tool name → null; runner never invoked', () async {
      final runner = scripted(err1);
      final v = DartAnalyzeVerifier(processRunner: runner);
      expect(await v('read', {'filePath': 'a.dart'}), isNull);
      expect(
        runner.runs,
        isEmpty,
        reason: 'only edit/write gate; reads never analyze',
      );
    });

    test('runner throws → null; no crash into the agent loop', () async {
      final runner = _ThrowingRunner();
      final v = DartAnalyzeVerifier(processRunner: runner);
      expect(await v('edit', {'filePath': 'a.dart'}), isNull);
      expect(runner.attempts, 1);
    });

    test('more than 5 errors truncates with a "... (K more)" tail', () async {
      final lines = List.generate(
        7,
        (i) => err1.replaceFirst(':3:5', ':${i + 1}:1'),
      );
      final block = DartAnalyzeVerifier.blockFor(
        stdout: lines.join('\n'),
        stderr: '',
        filePath: '/tmp/scratch.dart',
      );
      expect(block, isNotNull);
      expect(block, contains('7 error(s)'));
      expect(block, contains('... (2 more)'));
    });

    test(
      'blockFor parses real analyzer output, skipping info/warning lines',
      () {
        final stdout =
            '''
Analyzing scratch.dart...
  info - /tmp/scratch.dart:1:1 - info message  - info_code
$err1
  warning - /tmp/scratch.dart:2:1 - warn message  - warn_code
$err2
''';
        final block = DartAnalyzeVerifier.blockFor(
          stdout: stdout,
          stderr: '',
          filePath: '/tmp/scratch.dart',
        );
        expect(block, isNotNull);
        expect(block, contains('2 error(s)'));
        expect(block, contains('scratch.dart:3:5 - first message'));
        expect(block, contains('scratch.dart:7:1 - second message'));
        // Warnings and info lines are excluded from the error-only block.
        expect(block, isNot(contains('warn message')));
        expect(block, isNot(contains('info message')));
        // Diagnostic codes don't leak into the remediation block.
        expect(block, isNot(contains('code_a')));
      },
    );
  });

  group('DartAnalyzeVerifier.projectCheck (#22b)', () {
    // MemoryProcessRunner records only {executable, arguments} — not the
    // workingDirectory it was handed — so this local fake records all three
    // and scripts the RunResult directly.
    var scriptedResult = const RunResult(exitCode: 0, stdout: '', stderr: '');
    late _RecordingRunner runner;

    setUp(() {
      scriptedResult = const RunResult(exitCode: 0, stdout: '', stderr: '');
      runner = _RecordingRunner(() => scriptedResult);
    });

    const err1 = '  error - lib/main.dart:3:5 - first message  - code_a';

    test('clean output → null', () async {
      scriptedResult = const RunResult(
        exitCode: 0,
        stdout: 'Analyzing tina...\nNo issues found!',
        stderr: '',
      );
      final v = DartAnalyzeVerifier(processRunner: runner);
      expect(await v.projectCheck(), isNull);
      expect(runner.runs, hasLength(1));
    });

    test('warnings-only output → null', () async {
      scriptedResult = const RunResult(
        exitCode: 0,
        stdout: '  warning - lib/main.dart:2:1 - unused thing  - warn_code',
        stderr: '',
      );
      final v = DartAnalyzeVerifier(processRunner: runner);
      expect(await v.projectCheck(), isNull);
    });

    test('error output → [tree-health] notice with count, capped lines, '
        'and a "... (K more)" tail', () async {
      final lines = List.generate(
        7,
        (i) => err1.replaceFirst(':3:5', ':${i + 1}:1'),
      );
      scriptedResult = RunResult(
        exitCode: 65,
        stdout: lines.join('\n'),
        stderr: '',
      );
      final v = DartAnalyzeVerifier(processRunner: runner);
      final notice = await v.projectCheck();
      expect(notice, isNotNull);
      expect(
        notice,
        startsWith(
          '[tree-health] the working tree does not compile: '
          '7 error(s) — fix these FIRST:',
        ),
      );
      expect(notice, contains('main.dart:1:1 - first message'));
      expect(notice, contains('main.dart:5:1 - first message'));
      expect(
        notice,
        isNot(contains('main.dart:6:1')),
        reason: 'only maxErrorLines lines are shown',
      );
      expect(notice, contains('... (2 more)'));
      // Same severity-trim contract as blockFor: no diagnostic codes.
      expect(notice, isNot(contains('code_a')));
    });

    test(
      'passes workingDirectory through; analyzes with no file argument',
      () async {
        scriptedResult = const RunResult(
          exitCode: 65,
          stdout: err1,
          stderr: '',
        );
        final v = DartAnalyzeVerifier(processRunner: runner);
        await v.projectCheck(cwd: '/tmp/some-project');
        expect(runner.runs, hasLength(1));
        expect(runner.runs.first.executable, 'dart');
        expect(runner.runs.first.arguments, [
          'analyze',
        ], reason: 'the whole project, not one file');
        expect(runner.runs.first.workingDirectory, '/tmp/some-project');

        await v.projectCheck();
        expect(
          runner.runs.last.workingDirectory,
          isNull,
          reason: 'null cwd = the process cwd',
        );
      },
    );

    test('runner throws → null; never throws into the caller', () async {
      final thrower = _ThrowingRunner();
      final v = DartAnalyzeVerifier(processRunner: thrower);
      expect(await v.projectCheck(), isNull);
      expect(thrower.attempts, 1);
    });
  });

  group('wrapTreeHealth / editActionable (#27)', () {
    test(
      'actionable true → notice unchanged (the fix-first framing stays)',
      () {
        final notice = '[tree-health] 3 errors — fix these FIRST:\n  ...';
        final wrapped = DartAnalyzeVerifier.wrapTreeHealth(
          notice,
          editActionable: true,
        );
        expect(wrapped, notice);
        expect(wrapped, isNot(contains('do NOT have edit permission')));
      },
    );

    test('actionable false → notice gains do-not-try line (#27)', () {
      final notice = '[tree-health] 3 errors — fix these FIRST:\n  ...';
      final wrapped = DartAnalyzeVerifier.wrapTreeHealth(
        notice,
        editActionable: false,
      );
      expect(wrapped, contains('do NOT have edit permission'));
      expect(wrapped, contains('Treat them as pre-existing context'));
      expect(wrapped, contains('read-only tools'));
      expect(
        wrapped,
        contains(notice),
        reason: 'original notice must stay intact',
      );
    });

    test('editActionable uses the policy edit decision on a scratch file', () {
      // A read-only default (no allow rule for edit) → false.
      expect(
        DartAnalyzeVerifier.editActionable(PermissionPolicy()),
        isFalse,
        reason: 'default ask mode has no edit allow, so not actionable',
      );
      // An explicit allow for the scratch directory → true.
      expect(
        DartAnalyzeVerifier.editActionable(
          PermissionPolicy(
            rules: const [
              PermissionRule(
                toolName: 'edit',
                pattern: '**',
                decision: PermissionDecision.allow,
              ),
            ],
          ),
        ),
        isTrue,
        reason: 'an allow rule that covers the scratch file = actionable',
      );
    });
  });
}

/// A [ProcessRunner] that records every [run]'s executable, arguments, AND
/// workingDirectory (which [MemoryProcessRunner] does not capture), returning
/// a scripted [RunResult].
class _RecordingRunner implements ProcessRunner {
  final RunResult Function() result;

  final List<
    ({String executable, List<String> arguments, String? workingDirectory})
  >
  runs = [];

  _RecordingRunner(this.result);

  @override
  Future<RunningProcess> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    throw UnimplementedError('projectCheck uses run only');
  }

  @override
  Future<RunResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    runs.add((
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
    ));
    return result();
  }
}
