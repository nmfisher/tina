// The live box-model run: real commands through the real runner stack
// (IoProcessRunner → OsSandboxRunner → SandboxedProcessRunner + the box
// gate), with a recording command approver. Needs an actual confinement
// backend to exercise the silent path and is skipped wherever none
// exists — plain `dart test` never runs it. Run it explicitly and capture
// the transcript:
//
//     dart test --tags live-boxes --run-skipped
//
// Without a backend the transcript still records the sorter verdicts and
// the fall-through: the gate declines, the existing pipeline asks.
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

const _tags = 'live-boxes';

bool get _backendAvailable =>
    resolveSandboxBackend() != SandboxBackend.passThrough;

ProcessRequest _shell(String script, String cwd) => (
      command: '/bin/sh',
      arguments: ['-c', script],
      workingDirectory: cwd,
      environment: null,
      stdin: null,
      timeout: null,
    );

ProcessRequest _exec(String program, List<String> arguments, String cwd) => (
      command: program,
      arguments: arguments,
      workingDirectory: cwd,
      environment: null,
      stdin: null,
      timeout: null,
    );

void main() {
  test('a python script, a dart test and a network command through the boxes',
      tags: _tags, () async {
    final fixture = Directory.systemTemp.createTempSync('box-live-');
    addTearDown(() {
      try {
        fixture.deleteSync(recursive: true);
      } catch (_) {}
    });
    final workspace = Directory(path.join(fixture.path, 'project'))
      ..createSync();
    final dart = _onPath('dart')!;
    print('live-boxes: backend=${resolveSandboxBackend().name} '
        'bwrap-on-path=${_present('bwrap')} workspace=${workspace.path}');

    // A real test suite for the dart run: a self-contained package whose
    // only dependency is the SDK, pre-resolved so the jailed run needs no
    // network.
    final package = Directory(path.join(workspace.path, 'pkg'))..createSync();
    File(path.join(package.path, 'pubspec.yaml')).writeAsStringSync('''
name: box_live
environment:
  sdk: ^3.0.0
''');
    Directory(path.join(package.path, 'test')).createSync();
    File(path.join(package.path, 'test', 'box_live_test.dart'))
        .writeAsStringSync('''
import 'package:test/test.dart';
void main() {
  test('two plus two', () => expect(2 + 2, 4));
}
''');
    final resolve = await Process.run(dart, ['pub', 'get', '--offline'],
        workingDirectory: package.path);
    print('live-boxes: fixture pub get --offline exit=${resolve.exitCode}');

    File(path.join(workspace.path, 'script.py')).writeAsStringSync('''
import pathlib, sys
print('python script ran')
target = pathlib.Path('${fixture.path}/outside.txt')
try:
    target.write_text('escaped')
    print(f'WRITE-OUTSIDE-RESULT: succeeded (NOT contained!)')
except OSError as error:
    print(f'WRITE-OUTSIDE-RESULT: blocked ({error})')
''');

    final plan = SandboxPlan(
      workspaceRoot: workspace.path,
      isolateNetwork: true,
      home: SandboxHome(
        realHome: Platform.environment['HOME'] ?? fixture.path,
        stateRoot: path.join(fixture.path, 'homes'),
        caches: const ['.pub-cache'],
      ),
      childEnvironment: {
        'PATH': [
          path.dirname(dart),
          SandboxPlan.defaultSearchPath,
        ].join(':'),        'HOME': path.join(fixture.path, 'homes', 'session'),
        'TMPDIR': '/tmp',
        'LANG': 'C.UTF-8',
      },
    );
    final asks = <String>[];
    final runner = SandboxedProcessRunner(
      inner: OsSandboxRunner(inner: const IoProcessRunner(), plan: plan),
      mode: PermissionMode.ask,
      workspaceRoot: workspace.path,
      plan: plan,
      commandApprover: (request, review) async {
        asks.add(approvalCommandText(request));
        return Approval.no;
      },
    );
    runner.boxes = BoxModelGate(
      plan: plan,
      workspaceRoot: workspace.path,
      enabled: () => true,
    );
    BoxDecision verdict(String label, ProcessRequest request,
        {ProcessControl? control}) {
      final decision = sortBox(request,
          context: (
            workspaceRoot: workspace.path,
            confined: true,
            networkRequested: control?.networkRequested ?? false,
            readOnlyRequested: control?.readOnlyRequested,
            outsideSandboxRequested: false,
            declaredReads: const [],
            declaredWrites: const [],
            certifiedReadOnly: false,
            verifiedReads: const [],
            canRead: plan.canRead,
            canWrite: (value) => plan.canWrite(value),
            allowlist: null,
          ));
      print('live-boxes: sort[$label] -> box ${decision.box.label}'
          '${decision.profile == null ? '' : ' profile ${decision.profile}'}'
          ' (${decision.reason})');
      return decision;
    }

    Future<void> run(String label, ProcessRequest request,
        {ProcessControl? control}) async {
      final outcome = await runner.run(request, control: control);
      final description = switch (outcome) {
        CommandCompleted(:final exitCode, :final stdout, :final note) =>
          'exit=$exitCode note=$note stdout=${stdout.trim().split('\n').take(3).join(' | ')}',
        CommandRefused(:final reason) => 'REFUSED: $reason',
        CommandBlocked(:final reason) => 'BLOCKED: $reason',
        CommandRunning() => 'RUNNING',
      };
      print('live-boxes: run[$label] $description');
    }

    // 1. A python script.
    verdict('python-script', _shell('python3 script.py', workspace.path));
    await run('python-script', _shell('python3 script.py', workspace.path));

    // 2. A dart test.
    verdict('dart-test', _exec('dart', ['test'], package.path));
    await run('dart-test', _exec('dart', ['test'], package.path));

    // 3. A network command (declared network, as the tools require).
    verdict('network-curl',
        _exec('curl', ['-sI', 'https://example.com'], workspace.path));
    await run('network-curl',
        _exec('curl', ['-sI', 'https://example.com'], workspace.path),
        control: const ProcessControl(
            networkRequested: true, networkReason: 'live transcript probe'));

    print('live-boxes: asks=${asks.length} ${asks.take(4).toList()}');
    print('live-boxes: box-2 report lines=${runner.boxes!.drainReports()}');
    print('live-boxes: outside-write landed='
        '${File(path.join(fixture.path, 'outside.txt')).existsSync()}');
    if (!_backendAvailable) {
      // Without a backend no box can contain anything: every command fell
      // through to the existing approval path. That is the correct,
      // fail-closed behavior — assert it held.
      expect(asks, hasLength(3));
      expect(File(path.join(fixture.path, 'outside.txt')).existsSync(),
          isFalse,
          reason: 'nothing ran silently without a confinement backend');
    }
  }, skip: false);

  test('an allowlist rule runs its box without asking', tags: _tags,
      () async {
    if (!_backendAvailable) {
      markTestSkipped('no OS sandbox backend on this host');
      return;
    }
    final fixture = Directory.systemTemp.createTempSync('box-live-rule-');
    addTearDown(() {
      try {
        fixture.deleteSync(recursive: true);
      } catch (_) {}
    });
    final workspace = Directory(path.join(fixture.path, 'project'))
      ..createSync();
    final allowlist = BoxAllowlist.load(
        project: File(path.join(workspace.path, '.tina', 'box_allowlist')))
      ..remember('curl*', Box.contained, boxProfilePackages);
    print('live-boxes: allowlist file: ${allowlist.rules}');
    final plan = SandboxPlan(workspaceRoot: workspace.path);
    var asks = 0;
    final runner = SandboxedProcessRunner(
      inner: OsSandboxRunner(inner: const IoProcessRunner(), plan: plan),
      mode: PermissionMode.ask,
      workspaceRoot: workspace.path,
      plan: plan,
      commandApprover: (_, __) async {
        asks++;
        return Approval.no;
      },
    );
    runner.boxes = BoxModelGate(
        plan: plan,
        workspaceRoot: workspace.path,
        allowlist: allowlist,
        enabled: () => true);
    final outcome = await runner.run(
        _exec('curl', ['-sI', 'https://example.com'], workspace.path));
    print('live-boxes: rule-run outcome=$outcome asks=$asks');
    expect(asks, 0, reason: 'the stored rule answers the ask');
    expect(runner.boxes!.drainReports().single, contains('packages'));
  });
}

bool _present(String executable) {
  return _onPath(executable) != null;
}

String? _onPath(String executable) {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    final file = File(path.join(dir, executable));
    if (file.existsSync()) return file.path;
  }
  return null;
}
