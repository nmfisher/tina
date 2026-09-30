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
    expect(reviews.last.requiredPermissions,
        {ProcessPermission.execution, ProcessPermission.network});
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
    final runner = OsSandboxRunner(
        inner: const IoProcessRunner(),
        plan: SandboxPlan(workspaceRoot: root.path, isolateNetwork: false));
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
      expect(result, isA<CommandCompleted>(), reason: '$result');
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
}
