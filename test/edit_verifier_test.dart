import 'package:test/test.dart';
import 'package:tina/composition/edit_verifier.dart';
import 'package:tina_engine/tina_engine.dart';
import '../packages/tina_engine/test/helpers/memory_process_runner.dart';

/// A [ProcessRunner] whose `run` always throws — the spawn-failure shape the
/// verifier must swallow (return null) rather than propagate into the agent.
class _ThrowingRunner implements ProcessRunner {
  int attempts = 0;

  @override
  Future<RunningProcess> start(String executable, List<String> arguments,
          {String? workingDirectory}) async =>
      throw StateError('no spawning here');

  @override
  Future<RunResult> run(String executable, List<String> arguments,
      {String? workingDirectory}) async {
    attempts++;
    throw StateError('spawn failed');
  }
}

void main() {
  group('DartAnalyzeVerifier (#22a)', () {
    MemoryProcessRunner scripted(String stdout,
        {String stderr = '', int exit = 0}) {
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
          '  warning - /tmp/scratch.dart:2:1 - unused thing  - warn_code');
      final v = DartAnalyzeVerifier(processRunner: runner);
      expect(await v('edit', {'filePath': '/tmp/scratch.dart'}), isNull);
    });

    test('.txt path → null; runner never invoked', () async {
      final runner = scripted(err1);
      final v = DartAnalyzeVerifier(processRunner: runner);
      expect(await v('edit', {'filePath': 'notes.txt'}), isNull);
      expect(runner.runs, isEmpty,
          reason: 'non-.dart paths must never invoke the runner');
    });

    test('non-edit tool name → null; runner never invoked', () async {
      final runner = scripted(err1);
      final v = DartAnalyzeVerifier(processRunner: runner);
      expect(await v('read', {'filePath': 'a.dart'}), isNull);
      expect(runner.runs, isEmpty,
          reason: 'only edit/write gate; reads never analyze');
    });

    test('runner throws → null; no crash into the agent loop', () async {
      final runner = _ThrowingRunner();
      final v = DartAnalyzeVerifier(processRunner: runner);
      expect(await v('edit', {'filePath': 'a.dart'}), isNull);
      expect(runner.attempts, 1);
    });

    test('more than 5 errors truncates with a "... (K more)" tail', () async {
      final lines = List.generate(7, (i) => err1.replaceFirst(':3:5', ':${i + 1}:1'));
      final block = DartAnalyzeVerifier.blockFor(
        stdout: lines.join('\n'),
        stderr: '',
        filePath: '/tmp/scratch.dart',
      );
      expect(block, isNotNull);
      expect(block, contains('7 error(s)'));
      expect(block, contains('... (2 more)'));
    });

    test('blockFor parses real analyzer output, skipping info/warning lines',
        () {
      final stdout = '''
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
    });
  });
}
