// The gate as wired: SandboxedProcessRunner + BoxModelGate over a
// recording confined runner. Boxes 1 and 2 execute with no approval round
// trip; box 3 falls through to the existing ask path; the report batch
// accumulates one line per silent box-2 run.
//
// Run: dart test
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

class RecordingRunner implements ConfinedProcessRunner {
  @override
  bool get confinesFilesystem => true;
  final requests = <ProcessRequest>[];
  final controls = <ProcessControl?>[];

  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    requests.add(request);
    controls.add(control);
    return const CommandCompleted(exitCode: 0, stdout: 'done', stderr: '');
  }
}

ProcessRequest _exec(String program, List<String> arguments) => (
      command: program,
      arguments: arguments,
      workingDirectory: '/workspace',
      environment: null,
      stdin: null,
      timeout: null,
    );

ProcessRequest _shell(String script) => _exec('/bin/sh', ['-c', script]);

SandboxedProcessRunner _runner(RecordingRunner inner,
    {BoxModelGate? boxes,
    ProcessCommandApprover? approver,
    PermissionMode mode = PermissionMode.ask}) {
  final runner = SandboxedProcessRunner(
      inner: inner,
      mode: mode,
      workspaceRoot: '/workspace',
      plan: const SandboxPlan(workspaceRoot: '/workspace'),
      commandApprover: approver);
  runner.boxes = boxes ??
      BoxModelGate(
          plan: const SandboxPlan(workspaceRoot: '/workspace'),
          workspaceRoot: '/workspace',
          enabled: () => true);
  return runner;
}

void main() {
  test('an inactive gate leaves the existing pipeline in charge', () async {
    final inner = RecordingRunner();
    var asks = 0;
    final runner = _runner(inner,
        boxes: BoxModelGate(
            plan: const SandboxPlan(workspaceRoot: '/workspace'),
            workspaceRoot: '/workspace',
            enabled: () => false),
        approver: (_, __) async {
      asks++;
      return Approval.yes;
    });
    final outcome = await runner.run(_shell("python3 -c 'print(1)'"));
    // The pre-box behavior, unchanged: with a confining backend the
    // enforced read-only profile runs silently; nothing reports.
    expect(outcome, isA<CommandCompleted>());
    expect(asks, 0);
    expect(inner.controls.single!.readOnly, isTrue);
    expect(runner.boxes!.drainReports(), isEmpty);
  });

  test('box 1 runs silently with read-only enforcement', () async {
    final inner = RecordingRunner();
    var asks = 0;
    final runner = _runner(inner, approver: (_, __) async {
      asks++;
      return Approval.yes;
    });
    final outcome = await runner.run(_shell('cat README.md | wc -l'));
    expect(outcome, isA<CommandCompleted>());
    expect(asks, 0);
    expect(inner.controls.single!.readOnly, isTrue);
    expect(inner.controls.single!.networkAllowed, isFalse);
    // Box 1 is fully silent: no report line.
    expect(runner.boxes!.drainReports(), isEmpty);
  });

  test('box 2 runs silently in the sorted profile and reports once',
      () async {
    final inner = RecordingRunner();
    var asks = 0;
    final runner = _runner(inner, approver: (_, __) async {
      asks++;
      return Approval.yes;
    });
    final outcome = await runner.run(_shell("python3 -c 'print(1)'"));
    expect(outcome, isA<CommandCompleted>());
    expect((outcome as CommandCompleted).note, contains('scripts'));
    expect(asks, 0);
    expect(inner.controls.single!.readOnly, isTrue); // scripts: ro workspace
    final reports = runner.boxes!.drainReports();
    expect(reports, hasLength(1));
    expect(reports.single, contains('python3 -c'));
    expect(reports.single, contains('profile scripts'));
    expect(runner.boxes!.drainReports(), isEmpty);
  });

  test('a build-family command gets a writable, offline profile', () async {
    final inner = RecordingRunner();
    final runner = _runner(inner);
    await runner.run(_exec('dart', ['test', 'packages/tina_core']));
    expect(inner.controls.single!.readOnly, isFalse);
    expect(inner.controls.single!.networkAllowed, isFalse);
    final reports = runner.boxes!.drainReports();
    expect(reports.single, contains('profile build'));
  });

  test('an allowlist rule grants its named profile without asking',
      () async {
    final fixture = Directory.systemTemp.createTempSync('box-gate-');
    addTearDown(() => fixture.deleteSync(recursive: true));
    final inner = RecordingRunner();
    var asks = 0;
    final allowlist = BoxAllowlist.load(
        project: File('${fixture.path}/box_allowlist'))
      ..remember('curl*', Box.contained, boxProfilePackages);
    final runner = _runner(inner,
        boxes: BoxModelGate(
          plan: const SandboxPlan(workspaceRoot: '/workspace'),
          workspaceRoot: '/workspace',
          allowlist: allowlist,
          enabled: () => true,
        ),
        approver: (_, __) async {
      asks++;
      return Approval.yes;
    });
    // No network declaration at all: the stored rule is the authorization.
    final outcome = await runner.run(_exec('curl', ['https://example.com']));
    expect(outcome, isA<CommandCompleted>());
    expect(asks, 0);
    expect(inner.controls.single!.networkAllowed, isTrue);
    expect(runner.boxes!.drainReports().single, contains('packages'));
  });

  test('a declared network command asks through the existing path',
      () async {
    final inner = RecordingRunner();
    final reviews = <CommandApproval>[];
    final runner = _runner(inner, approver: (request, review) async {
      reviews.add(review);
      return Approval.yes;
    });
    final outcome = await runner.run(_exec('curl', ['https://example.com']),
        control: const ProcessControl(
            networkRequested: true, networkReason: 'fetch a page'));
    expect(outcome, isA<CommandCompleted>());
    expect(reviews, hasLength(1));
    expect(reviews.single.requiredPermissions,
        contains(ProcessPermission.network));
    expect(runner.boxes!.drainReports(), isEmpty);
  });

  test('destructive commands never get a writable box profile', () async {
    final inner = RecordingRunner();
    final runner = _runner(inner);
    await runner.run(_exec('rm', ['-rf', 'build/']));
    // The box model routed box 3; the existing path ran its enforced
    // read-only profile (a real sandbox blocks the deletion there).
    expect(inner.controls.single!.readOnly, isTrue);
    expect(runner.boxes!.drainReports(), isEmpty);
  });

  test('read-only mode keeps box 1 and blocks writable profiles', () async {
    final inner = RecordingRunner();
    final runner = _runner(inner, mode: PermissionMode.readOnly);
    // Box 1 still runs.
    expect(await runner.run(_shell('cat README.md')), isA<CommandCompleted>());
    // A build-family command with a declared write falls through; the
    // read-only mode ceiling refuses it through the existing path.
    final outcome = await runner.run(_exec('dart', ['test']),
        control: const ProcessControl(writeDirectories: ['/workspace/x']));
    expect(outcome, isA<CommandRefused>());
  });

  test('a script with declared workspace writes runs in the build profile',
      () async {
    // Declared directories must exist (the shared directory-access rule).
    final workspace = Directory.systemTemp.createTempSync('box-ws-')
      ..createSync(recursive: true);
    addTearDown(() => workspace.deleteSync(recursive: true));
    final site = Directory('${workspace.path}/site')..createSync();
    final inner = RecordingRunner();
    final runner = SandboxedProcessRunner(
        inner: inner,
        mode: PermissionMode.ask,
        workspaceRoot: workspace.path,
        plan: SandboxPlan(workspaceRoot: workspace.path));
    runner.boxes = BoxModelGate(
        plan: SandboxPlan(workspaceRoot: workspace.path),
        workspaceRoot: workspace.path,
        enabled: () => true);
    await runner.run(
        (command: 'python3', arguments: ['build_site.py'],
         workingDirectory: workspace.path, environment: null,
         stdin: null, timeout: null),
        control: ProcessControl(writeDirectories: [site.path]));
    expect(inner.controls.single!.readOnly, isFalse);
    expect(runner.boxes!.drainReports().single, contains('profile build'));
  });

  test('unconfined backends never take the silent path', () async {
    final inner = _PassThroughRunner();
    var asks = 0;
    final runner = SandboxedProcessRunner(
        inner: inner,
        mode: PermissionMode.ask,
        workspaceRoot: '/workspace',
        commandApprover: (_, __) async {
          asks++;
          return Approval.yes;
        });
    runner.boxes = BoxModelGate(
        plan: const SandboxPlan(workspaceRoot: '/workspace'),
        workspaceRoot: '/workspace',
        enabled: () => true);
    await runner.run(_shell("python3 -c 'print(1)'"));
    expect(asks, 1); // fell through to the existing pipeline
  });
}

class _PassThroughRunner implements ProcessRunner {
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    return const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
  }
}
