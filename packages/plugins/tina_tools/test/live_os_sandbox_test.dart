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
import 'package:crypto/crypto.dart';

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

bool get _backendAvailable =>
    resolveSandboxBackend() != SandboxBackend.passThrough;

void main() {
  test('trusted readers cannot write project or shared cache contents',
      tags: 'live-os-sandbox', () async {
    if (!_backendAvailable) {
      markTestSkipped('no OS sandbox backend on this host');
      return;
    }
    final fixture = Directory.systemTemp.createTempSync('readonly-reader-');
    addTearDown(() => fixture.deleteSync(recursive: true));
    final project = Directory('${fixture.path}/project')..createSync();
    final cache = Directory('${fixture.path}/cache')..createSync();
    final reports = Directory('${project.path}/reports')..createSync();
    final reader = File('${project.path}/rg')..writeAsStringSync('''#!/bin/sh
echo forbidden > '${project.path}/forbidden'
echo forbidden > '${cache.path}/forbidden'
echo reader-finished
''');
    Process.runSync('/bin/chmod', ['+x', reader.path]);
    final plan = SandboxPlan(
        workspaceRoot: project.resolveSymbolicLinksSync(),
        writablePaths: [cache.resolveSymbolicLinksSync()]);
    final gate = SandboxedProcessRunner(
        inner: OsSandboxRunner(inner: const IoProcessRunner(), plan: plan),
        plan: plan,
        mode: PermissionMode.ask);
    gate.trustedReaderExecutables = () => {
          reader.resolveSymbolicLinksSync():
              sha256.convert(reader.readAsBytesSync()).toString()
        };
    final result = await gate.run((
      command: reader.path,
      arguments: ['--files'],
      workingDirectory: project.path,
      environment: null,
      stdin: null,
      timeout: null
    ));
    expect(result, isA<CommandCompleted>());
    expect((result as CommandCompleted).stdout, contains('reader-finished'));
    expect(File('${project.path}/forbidden').existsSync(), isFalse);
    expect(File('${cache.path}/forbidden').existsSync(), isFalse);
    gate.outputWritePermission = plan.canWrite;
    final output = await gate.run((
      command: '/bin/sh',
      arguments: ['-c', "echo report > '${reports.path}/result'"],
      workingDirectory: project.path,
      environment: null,
      stdin: null,
      timeout: null
    ));
    expect(output, isA<CommandBlocked>());
    expect(File('${reports.path}/result').existsSync(), false);
  });

  test('invocation directory grants expire and preserve protected paths',
      tags: 'live-os-sandbox', () async {
    if (!_backendAvailable) {
      markTestSkipped('no OS sandbox backend on this host');
      return;
    }
    final fixture = Directory(Directory('${Directory.current.path}/.dart_tool')
        .createTempSync('invocation-grant-')
        .resolveSymbolicLinksSync());
    addTearDown(() => fixture.deleteSync(recursive: true));
    final project = Directory('${fixture.path}/project')..createSync();
    final home = Directory('${fixture.path}/home')..createSync();
    final input = Directory('${home.path}/input')..createSync();
    final output = Directory('${home.path}/output')..createSync();
    final protected = Directory('${output.path}/protected')..createSync();
    File('${input.path}/source').writeAsStringSync('content');
    final plan = SandboxPlan(
        workspaceRoot: project.path,
        realHome: home.path,
        protectedPaths: [protected.path]);
    final os = OsSandboxRunner(inner: const IoProcessRunner(), plan: plan);
    var approve = true;
    final gate = SandboxedProcessRunner(
        inner: os,
        plan: plan,
        mode: PermissionMode.auto,
        commandApprover: (_, review) async =>
            approve ? Approval.yes : Approval.no);
    ProcessRequest shell(String script) => (
          command: '/bin/sh',
          arguments: ['-c', script],
          workingDirectory: project.path,
          environment: null,
          stdin: null,
          timeout: const Duration(seconds: 10)
        );
    final requested = ProcessControl(
        readDirectories: [input.path], writeDirectories: [output.path]);
    final success = await gate.run(
        shell('cat "${input.path}/source" > "${output.path}/result"'),
        control: requested);
    expect(success, isA<CommandCompleted>());
    expect((success as CommandCompleted).exitCode, 0, reason: success.stderr);
    expect(File('${output.path}/result').readAsStringSync(), 'content');
    approve = false;
    for (final target in [
      '${input.path}/forbidden',
      '${protected.path}/forbidden'
    ]) {
      final failed =
          await gate.run(shell('echo bad > "$target"'), control: requested);
      expect(
          failed is CommandRefused ||
              failed is CommandBlocked ||
              failed is CommandCompleted && failed.exitCode != 0,
          true,
          reason: '$failed');
      expect(File(target).existsSync(), false);
    }
    final later = await gate.run(shell('echo bad > "${output.path}/later"'));
    expect(
        later is CommandRefused ||
            later is CommandBlocked ||
            later is CommandCompleted && later.exitCode != 0,
        true,
        reason: '$later');
    expect(File('${output.path}/later').existsSync(), false);
    expect(plan.canWrite(output.path), false);
  });

  test('saved directory writes update the live jail and retain Tina protection',
      tags: 'live-os-sandbox', () async {
    if (!_backendAvailable) {
      markTestSkipped('no OS sandbox backend on this host');
      return;
    }
    // Keep the external target outside the sandbox's already-writable temp roots.
    final fixture = Directory(Directory('${Directory.current.path}/.dart_tool')
        .createTempSync('write-grant-')
        .resolveSymbolicLinksSync());
    addTearDown(() => fixture.deleteSync(recursive: true));
    final project = Directory('${fixture.path}/project')..createSync();
    final external = Directory('${fixture.path}/external')..createSync();
    final other = Directory('${fixture.path}/other')..createSync();
    final tina = Directory('${external.path}/.tina')..createSync();
    final writes = WriteDirectories();
    final runner = OsSandboxRunner(
        inner: const IoProcessRunner(),
        plan: SandboxPlan(
            workspaceRoot: project.path,
            tinaDir: tina.path,
            writeDirectories: writes));
    Future<RunOutcome> touch(String target) => runner.run((
          command: 'touch',
          arguments: [target],
          workingDirectory: project.path,
          environment: null,
          stdin: null,
          timeout: null
        ));
    Future<void> blocked(String path, {bool syntheticParent = false}) async {
      final result = await touch(path);
      // bwrap creates empty namespace parents for the Tina bind. Writes in
      // those private directories can succeed without modifying the host.
      if (!syntheticParent || runner.backend != SandboxBackend.bwrap) {
        expect(
            result is CommandBlocked ||
                result is CommandCompleted && result.exitCode != 0,
            isTrue,
            reason: '$result');
      }
      expect(File(path).existsSync(), isFalse);
    }

    await blocked('${external.path}/before', syntheticParent: true);
    writes.replace([external.path]);
    final allowed = await touch('${external.path}/allowed');
    expect(allowed, isA<CommandCompleted>());
    expect((allowed as CommandCompleted).exitCode, 0, reason: allowed.stderr);
    expect(File('${external.path}/allowed').existsSync(), isTrue);
    await blocked('${other.path}/blocked');
    await blocked('${tina.path}/blocked');
    writes.replace([]);
    await blocked('${external.path}/revoked', syntheticParent: true);
  });

  test('explicit outside approval and startup disable actually remove the jail',
      tags: 'live-os-sandbox', () async {
    if (!_backendAvailable) {
      markTestSkipped('no OS sandbox backend on this host');
      return;
    }
    final root = Directory(Directory.systemTemp
        .createTempSync('tina_unconfined_')
        .resolveSymbolicLinksSync());
    addTearDown(() => root.deleteSync(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var connections = 0;
    server.listen((request) {
      connections++;
      request.response.write('outside works');
      request.response.close();
    });
    final request = (
      command: 'curl',
      arguments: [
        '--noproxy',
        '*',
        '--max-time',
        '3',
        '--fail',
        '--silent',
        'http://127.0.0.1:${server.port}'
      ],
      workingDirectory: root.path,
      environment: null,
      stdin: null,
      timeout: null,
    );
    final jail = OsSandboxRunner(
        inner: const IoProcessRunner(),
        plan: SandboxPlan(workspaceRoot: root.path));
    var approve = false;
    final reviews = <CommandApproval>[];
    final gate = SandboxedProcessRunner(
        inner: jail,
        commandApprover: (_, review) async {
          reviews.add(review);
          return approve ? Approval.always : Approval.no;
        });
    const outside = ProcessControl(
        outsideSandboxRequested: true,
        sandboxReason: 'contact host fixture outside the network namespace');
    expect(await gate.run(request, control: outside), isA<CommandRefused>());
    expect(connections, 0);
    approve = true;
    final allowed = await gate.run(request, control: outside);
    expect(allowed, isA<CommandCompleted>());
    expect((allowed as CommandCompleted).exitCode, 0, reason: allowed.stderr);
    expect(allowed.stdout, 'outside works');
    expect(connections, 1);
    final normal = await gate.run(request);
    expect(
        normal is CommandBlocked ||
            normal is CommandCompleted && normal.exitCode != 0,
        true);
    expect(connections, 1,
        reason: 'exact outside grant cannot open normal calls');
    expect(reviews, hasLength(2));
    expect(reviews.last.requiredPermissions, {
      ProcessPermission.execution,
      ProcessPermission.network,
      ProcessPermission.unconfined
    });
    final disabled = SandboxedProcessRunner(
        inner: OsSandboxRunner(
            inner: const IoProcessRunner(),
            enabled: false,
            plan: SandboxPlan(workspaceRoot: root.path)));
    expect(await disabled.run(request), isA<CommandRefused>());
    expect(connections, 1);
    disabled.commandApprover = (_, __) async => Approval.yes;
    final global = await disabled.run(request);
    expect((global as CommandCompleted).exitCode, 0, reason: global.stderr);
    expect(global.stdout, 'outside works');
    expect(connections, 2);
  });

  test('Linux executes a hidden host script after separate outside approval',
      tags: 'live-os-sandbox', () async {
    if (resolveSandboxBackend() != SandboxBackend.bwrap) {
      markTestSkipped('requires Linux with bwrap');
      return;
    }
    final root = Directory.systemTemp.createTempSync('tina_hidden_host_');
    addTearDown(() => root.deleteSync(recursive: true));
    final workspace = Directory('${root.path}/project')..createSync();
    final hidden = File('${root.path}/blender')
      ..writeAsStringSync('#!/bin/sh\nprintf "host program ran"\n');
    expect((await Process.run('chmod', ['+x', hidden.path])).exitCode, 0);
    final jail = OsSandboxRunner(
        inner: const IoProcessRunner(),
        plan: SandboxPlan(workspaceRoot: workspace.path),
        hostLayout: () => SandboxHostLayout.inspect(
            readOnlyDirectories: kSandboxReadOnlyBinds,
            temporaryDirectories: []));
    final gate = SandboxedProcessRunner(
        inner: jail, commandApprover: (_, __) async => Approval.yes);
    final request = (
      command: hidden.path,
      arguments: <String>[],
      workingDirectory: workspace.path,
      environment: null,
      stdin: null,
      timeout: null
    );
    final confined = await gate.run(request);
    expect(confined, isA<CommandBlocked>());
    expect((confined as CommandBlocked).reason, contains(hidden.path));
    final outside = await gate.run(request,
        control: const ProcessControl(
            outsideSandboxRequested: true,
            sandboxReason: 'host script hidden from subprocess mounts'));
    expect(outside, isA<CommandCompleted>());
    expect((outside as CommandCompleted).exitCode, 0, reason: outside.stderr);
    expect(outside.stdout, 'host program ran');
  });

  test(
      'network approval reaches a local server while outside writes stay blocked',
      tags: 'live-os-sandbox', () async {
    if (!_backendAvailable) {
      markTestSkipped('no OS sandbox backend on this host');
      return;
    }
    final root = Directory(Directory.systemTemp
        .createTempSync('tina_network_')
        .resolveSymbolicLinksSync());
    addTearDown(() => root.deleteSync(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var connections = 0;
    server.listen((request) {
      connections++;
      request.response.write('network works');
      request.response.close();
    });
    final sandbox = OsSandboxRunner(
        inner: const IoProcessRunner(),
        plan: SandboxPlan(workspaceRoot: root.path));
    final reviews = <CommandApproval>[];
    final runner = SandboxedProcessRunner(
        inner: sandbox,
        commandApprover: (_, review) async {
          reviews.add(review);
          return Approval.always;
        });
    final request = (
      command: 'curl',
      arguments: [
        '--noproxy',
        '*',
        '--max-time',
        '3',
        '--fail',
        '--silent',
        'http://127.0.0.1:${server.port}'
      ],
      workingDirectory: root.path,
      environment: null,
      stdin: null,
      timeout: null
    );
    final denied = await runner.run(request);
    expect(
        denied is CommandBlocked ||
            denied is CommandCompleted && denied.exitCode != 0,
        isTrue);
    expect(connections, 0);
    const network = ProcessControl(
        networkRequested: true, networkReason: 'contact local fixture server');
    final allowed = await runner.run(request, control: network);
    expect(allowed, isA<CommandCompleted>());
    expect((allowed as CommandCompleted).exitCode, 0, reason: allowed.stderr);
    expect(allowed.stdout, 'network works');
    expect(reviews, hasLength(2));
    expect(reviews.last.requiredPermissions, {
      ProcessPermission.execution,
      ProcessPermission.workspaceWrite,
      ProcessPermission.network
    });
    expect(reviews.last.missingPermissions, {ProcessPermission.network});
    final remembered = await runner.run(request, control: network);
    expect((remembered as CommandCompleted).stdout, 'network works');
    expect(reviews, hasLength(2));
    expect(connections, 2);
    final offline = await runner.run(request);
    expect(
        offline is CommandBlocked ||
            offline is CommandCompleted && offline.exitCode != 0,
        true);
    expect(connections, 2,
        reason: 'a stored network grant does not open an offline invocation');
    final outside = await runner.run((
      command: 'touch',
      arguments: ['/usr/share/tina-network-escape-probe'],
      workingDirectory: root.path,
      environment: null,
      stdin: null,
      timeout: null
    ), control: network);
    expect(
        outside is CommandBlocked ||
            outside is CommandCompleted && outside.exitCode != 0,
        isTrue);
    expect(File('/usr/share/tina-network-escape-probe').existsSync(), isFalse);
  });

  test('sandboxed git status and local fetch can write to /dev/null',
      tags: 'live-os-sandbox',
      timeout: const Timeout(Duration(minutes: 2)), () async {
    if (!_backendAvailable) {
      markTestSkipped('no OS sandbox backend on this host');
      return;
    }
    final root = Directory(Directory.systemTemp
        .createTempSync('tina_git_sandbox_')
        .resolveSymbolicLinksSync());
    addTearDown(() => root.deleteSync(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final origin = '${root.path}/origin.git';
    for (final args in [
      ['init', '--bare', origin],
      ['init', project.path],
      ['-C', project.path, 'remote', 'add', 'origin', origin]
    ]) {
      final setup = await Process.run('git', args);
      expect(setup.exitCode, 0, reason: '${setup.stderr}');
    }
    final home =
        SandboxHome(realHome: root.path, stateRoot: '${root.path}/state');
    addTearDown(home.close);
    final runner = OsSandboxRunner(
        inner: const IoProcessRunner(),
        plan: SandboxPlan(
            workspaceRoot: root.path, home: home, isolateNetwork: false));
    for (final args in [
      ['status', '--porcelain=v1', '-b'],
      ['fetch', 'origin']
    ]) {
      final result = await runner.run((
        command: 'git',
        arguments: args,
        workingDirectory: project.path,
        environment: null,
        stdin: null,
        timeout: null
      ));
      expect(result, isA<CommandCompleted>(),
          reason: result is CommandBlocked ? result.reason : '$result');
      final completed = result as CommandCompleted;
      expect(completed.exitCode, 0, reason: completed.stderr);
    }
  });

  test('a command inside the jail cannot write outside the project',
      timeout: const Timeout(Duration(minutes: 2)),
      tags: 'live-os-sandbox', () async {
    if (!_backendAvailable) {
      // With --run-skipped on a machine without a backend this reports
      // honestly; without the return the body would keep running.
      markTestSkipped('no OS sandbox backend on this host');
      return;
    }
    final ws = Directory(Directory.systemTemp
        .createTempSync('tina_escape_ws_')
        .resolveSymbolicLinksSync());
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

  test('yolo mode: permission checks off, the OS jail still holds',
      timeout: const Timeout(Duration(minutes: 2)),
      tags: 'live-os-sandbox', () async {
    if (!_backendAvailable) {
      // With --run-skipped on a machine without a backend this reports
      // honestly; without the return the body would keep running.
      markTestSkipped('no OS sandbox backend on this host');
      return;
    }
    final ws = Directory(Directory.systemTemp
        .createTempSync('tina_yolo_ws_')
        .resolveSymbolicLinksSync());
    addTearDown(() => ws.deleteSync(recursive: true));
    // The yolo preset authorizes requested capabilities. OS confinement is
    // still enabled, with additional directories limited to each invocation.
    final plan = SandboxPlan(workspaceRoot: ws.path);
    final runner = OsSandboxRunner(
      inner: const IoProcessRunner(),
      plan: plan,
    );
    final gate = SandboxedProcessRunner(
      inner: runner,
      plan: plan,
      mode: PermissionMode.yolo,
      commandApprover: (_, review) async => Approval.yes,
    );

    // Sanity: inside the workspace yolo writes freely.
    final inside = await gate.run((
      command: 'touch',
      arguments: ['inside.txt'],
      workingDirectory: ws.path,
      environment: null,
      stdin: null,
      timeout: null,
    ));
    expect(inside, isA<CommandCompleted>(),
        reason: 'yolo is unrestricted inside the jail: $inside');

    // An opaque shell command does not request any additional directories.
    // Probe a host-writable sibling so failure proves confinement rather than
    // relying on ownership or a system volume's own write protection.
    final external = Directory.systemTemp.createTempSync('tina_yolo_outside_');
    addTearDown(() => external.deleteSync(recursive: true));
    final target = File('${external.path}/escape');
    final outside = await gate.run((
      command: '/bin/sh',
      arguments: ['-c', r'printf escaped > "$1"', 'probe', target.path],
      workingDirectory: ws.path,
      environment: null,
      stdin: null,
      timeout: null,
    ));
    expect(
      outside is CommandBlocked ||
          outside is CommandCompleted && outside.exitCode != 0,
      isTrue,
      reason: 'yolo must not read as success outside the jail: $outside',
    );
    expect(target.existsSync(), isFalse,
        reason: 'the kernel jail must hold under yolo');

    // Changing shell syntax does not add directory access either.
    final shell = await gate.run((
      command: '/bin/sh',
      arguments: ['-c', 'touch /usr/share/tina-yolo-shell-probe'],
      workingDirectory: ws.path,
      environment: null,
      stdin: null,
      timeout: null,
    ));
    expect(
      shell is CommandBlocked ||
          shell is CommandCompleted && shell.exitCode != 0,
      isTrue,
      reason: 'shell strings enjoy no extra freedom: $shell',
    );
    expect(File('/usr/share/tina-yolo-shell-probe').existsSync(), isFalse);

    // The documented sharp edge, pinned so it cannot change silently: in
    // yolo the launch preset authorizes requested host capabilities, so
    // an outside_sandbox request is auto-authorized by the gate — no
    // classifier, no human — and genuinely runs on the host. The startup
    // banner warns about exactly this. Everything here is a loopback
    // fixture; nothing real is touched.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var connections = 0;
    server.listen((request) {
      connections++;
      request.response.write('yolo reached the host');
      request.response.close();
    });
    final escalated = await gate.run((
      command: 'curl',
      arguments: [
        '--noproxy',
        '*',
        '--max-time',
        '3',
        '--fail',
        '--silent',
        'http://127.0.0.1:${server.port}'
      ],
      workingDirectory: ws.path,
      environment: null,
      stdin: null,
      timeout: null,
    ),
        control: const ProcessControl(
          outsideSandboxRequested: true,
          sandboxReason: 'yolo escalation probe against a loopback fixture',
        ));
    expect(escalated, isA<CommandCompleted>(),
        reason: 'yolo auto-authorizes unconfined requests: $escalated');
    expect((escalated as CommandCompleted).exitCode, 0,
        reason: escalated.stderr);
    expect(escalated.stdout, 'yolo reached the host');
    expect(connections, 1);
  });
}
