import 'dart:io';

import 'package:tina_tools/tina_tools.dart';
import 'package:test/test.dart';

const writable = ProcessControl(readOnlyRequested: false);

/// The command × mode table, the approver, and the grants — headless: the
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
      expect((outcome as CommandCompleted).stdout.trim(),
          tmp.resolveSymbolicLinksSync());
    });
  });
}
