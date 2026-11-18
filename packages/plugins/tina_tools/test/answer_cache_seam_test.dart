import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

/// The tina_tools answer-cache seams (issue 94 phase 2 wiring): a
/// certified read-only search can be SERVED from a resolver before it
/// runs, and CAPTURED after it succeeds with its verified operands.
ProcessRequest _grep(String args) => (
      command: '/usr/bin/grep',
      arguments: args.split(' '),
      workingDirectory: Directory.current.path,
      environment: null,
      stdin: null,
      timeout: null,
    );

void main() {
  late Recorder inner;
  late SandboxedProcessRunner runner;

  setUp(() {
    inner = Recorder();
    runner = SandboxedProcessRunner(
      inner: inner,
      mode: PermissionMode.yolo,
      executableSearchPath: '/usr/bin:/bin',
      commandApprover: (_, __) async => Approval.yes,
    );
  });

  test('a resolver answer replaces the run; nothing spawns', () async {
    runner.readOnlySearchResolver =
        (program, arguments) => '<memory-answer-cache>paths: lib/a.dart</memory-answer-cache>';
    final outcome = await runner.run(_grep('needle lib'));
    expect(outcome, isA<CommandCompleted>());
    expect((outcome as CommandCompleted).stdout, contains('memory-answer-cache'));
    expect(inner.requests, isEmpty, reason: 'the search never ran');
  });

  test('capture fires after a successful read-only search', () async {
    var seen = (program: '', args: <String>[], files: <String>[]);
    runner.onReadOnlySearchCompleted = (program, args, files) {
      seen = (program: program, args: args, files: files);
    };
    await runner.run(_grep('needle pubspec.yaml'));
    expect(inner.requests, hasLength(1), reason: 'no resolver: it ran');
    expect(seen.program, 'grep');
    expect(seen.args, ['needle', 'pubspec.yaml']);
    expect(seen.files.first, endsWith('pubspec.yaml'),
        reason: 'the verified read operands are the resolved paths');
  });

  test('a failed search does not capture', () async {
    inner.outcome =
        const CommandCompleted(exitCode: 1, stdout: '', stderr: 'no match');
    var captured = false;
    runner.onReadOnlySearchCompleted = (_, __, ___) => captured = true;
    await runner.run(_grep('needle'));
    expect(captured, isFalse);
  });

  test('seams are inert unless wired (no behavior change)', () async {
    final outcome = await runner.run(_grep('needle'));
    expect(outcome, isA<CommandCompleted>());
    expect(inner.requests, hasLength(1));
  });
}

final class Recorder implements ConfinedProcessRunner {
  @override
  bool get confinesFilesystem => true;
  final requests = <ProcessRequest>[];
  RunOutcome outcome = const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
  @override
  Future<RunOutcome> run(ProcessRequest request, {ProcessControl? control}) async {
    requests.add(request);
    return outcome;
  }
}
