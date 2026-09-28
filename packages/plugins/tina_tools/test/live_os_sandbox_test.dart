// The live escape test: run a real command inside the real OS sandbox and
// try to write outside the project. It needs an actual confinement
// backend (bwrap or sandbox-exec) and is skipped wherever none exists —
// plain `dart test` never runs it. Run it explicitly:
//
//     dart test --tags live-os-sandbox --run-skipped
//
// Everything else about the sandbox is tested headlessly in tina_tools.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

bool get _backendAvailable =>
    resolveSandboxBackend() != SandboxBackend.passThrough;

void main() {
  test('a command inside the jail cannot write outside the project',
      timeout: const Timeout(Duration(minutes: 2)),
      tags: 'live-os-sandbox', () async {
    if (!_backendAvailable) {
      // With --run-skipped on a machine without a backend this reports
      // honestly; without the return the body would keep running.
      markTestSkipped('no OS sandbox backend on this host');
      return;
    }
    final ws = Directory.systemTemp.createTempSync('tina_escape_ws_');
    addTearDown(() => ws.deleteSync(recursive: true));
    final plan = SandboxPlan(workspaceRoot: ws.path);
    final runner = OsSandboxRunner(
      inner: const IoProcessRunner(),
      plan: plan,
    );

    // Sanity: a write inside the workspace succeeds inside the jail.
    final inside = await runner.run((
      command: 'touch',
      arguments: ['inside.txt'],
      workingDirectory: ws.path,
      environment: null,
      stdin: null,
      timeout: null,
    ));

    // Escape attempt: /usr/share is outside every writable path the
    // layout grants — read-only bind on Linux, no write grant on macOS.
    final outside = await runner.run((
      command: 'touch',
      arguments: ['/usr/share/tina-escape-probe'],
      workingDirectory: ws.path,
      environment: null,
      stdin: null,
      timeout: null,
    ));

    expect(inside, isA<CommandCompleted>(),
        reason: 'the project itself is writable');
    expect((inside as CommandCompleted).exitCode, 0);
    // Either the kernel stopped it (CommandBlocked — what the classifier
    // should make of an EROFS) or it failed some other way; in every
    // case the escape must not read as success and must not have
    // happened.
    if (outside is CommandCompleted) {
      expect(outside.exitCode, isNot(0),
          reason: 'escaping the jail must not look like success');
    } else {
      expect(outside, isA<CommandBlocked>());
    }
    expect(
      File('/usr/share/tina-escape-probe').existsSync(),
      isFalse,
      reason: 'the sandbox must hold: nothing outside the project',
    );
  });
}
