import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_tools/src/read_only_commands.dart';
import 'package:tina_tools/tina_tools.dart';

const systemPath = '/usr/bin:/bin';

ProcessRequest request(String program, List<String> args,
        {String? cwd, Map<String, String>? environment}) =>
    (
      command: program,
      arguments: args,
      workingDirectory: cwd,
      environment: environment,
      stdin: null,
      timeout: null
    );

class _Recorder implements ProcessRunner {
  final requests = <ProcessRequest>[];
  final controls = <ProcessControl?>[];
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    requests.add(request);
    controls.add(control);
    return const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
  }
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('read-only-process-'));
  tearDown(() => root.deleteSync(recursive: true));

  SandboxedProcessRunner runner(ProcessRunner inner,
          {Future<Approval> Function(ProcessRequest, CommandApproval)? review,
          String searchPath = systemPath}) =>
      SandboxedProcessRunner(
          inner: inner,
          mode: PermissionMode.readOnly,
          executableSearchPath: searchPath,
          commandApprover: review);

  test('the reported ls and grep argv run without an execution approval',
      () async {
    final inner = _Recorder();
    final gate = runner(inner,
        review: (_, __) => throw StateError('unexpected approval'));
    for (final (program, args) in [
      (
        'ls',
        ['/mnt/sdd_1tb/instarig/packaging', '/mnt/sdd_1tb/instarig/tests']
      ),
      (
        'grep',
        [
          '-rn',
          'head_neck_from_cage',
          '--include=*.py',
          '/mnt/sdd_1tb/instarig'
        ]
      ),
      (
        'grep',
        [
          '-rln',
          r'dijkstra\|MeshGraph\|KDTree',
          '--include=*.py',
          '/mnt/sdd_1tb/instarig/_vendor/shared'
        ]
      ),
      ('ls', ['-la', '.']),
      ('grep', ['-n', '-e', '--pre=literal pattern', 'file.py']),
      ('grep', ['-A40', 'class CancelToken', 'file.dart']),
      ('grep', ['--', '-literal pattern', 'file.py']),
    ]) {
      final call = request(program, args, cwd: root.path);
      final result = await gate.run(call);
      expect(result, isA<CommandCompleted>());
      expect((result as CommandCompleted).note,
          contains('read-only system command'));
      expect(inner.requests.last.command,
          readOnlyExecutable(call, searchPath: systemPath));
      expect(inner.requests.last.arguments, args, reason: 'argv stays literal');
      expect(inner.controls.last!.networkAllowed, false);
    }
    expect(gate.grants.isEmpty, true,
        reason: 'a reader creates no session grant');
  });

  test('system absolute paths also work, with no basename-only trust', () {
    for (final program in ['/bin/ls', '/usr/bin/grep']) {
      expect(readOnlyExecutable(request(program, [])), isNotNull);
    }
    for (final program in [
      '${root.path}/ls',
      './grep',
      '/usr/local/bin/grep',
      'sh',
      'bash',
      'env',
      'sed',
      'find',
      'rg',
      'git'
    ]) {
      expect(readOnlyExecutable(request(program, ['file'])), isNull);
    }
  });

  test('PATH shadowing, relative PATH and custom environments need review',
      () async {
    final fake = File('${root.path}/grep')
      ..writeAsStringSync('#!/bin/sh\ntouch "${root.path}/WRITTEN"\n');
    expect((await Process.run('/bin/chmod', ['+x', fake.path])).exitCode, 0);
    final inner = _Recorder();
    var asks = 0;
    final gate = runner(inner, searchPath: '${root.path}:$systemPath',
        review: (_, __) async {
      asks++;
      return Approval.no;
    });
    expect(await gate.run(request('grep', ['pattern', 'file'], cwd: root.path)),
        isA<CommandRefused>());
    expect(
        readOnlyExecutable(request('grep', [], cwd: root.path),
            searchPath: ':$systemPath'),
        isNull);
    expect(
        readOnlyExecutable(request('grep', [], cwd: root.path),
            searchPath: '.:$systemPath'),
        isNull);
    for (final env in <Map<String, String>>[
      {},
      {'PATH': root.path},
      {'LD_PRELOAD': '/tmp/inject.so'}
    ]) {
      expect(await gate.run(request('/usr/bin/grep', [], environment: env)),
          isA<CommandRefused>());
    }
    expect(asks, 4);
    expect(inner.requests, isEmpty);
    expect(File('${root.path}/WRITTEN').existsSync(), false);
  });

  test('unknown options, shell strings and edits still ask in read-only',
      () async {
    final inner = _Recorder();
    var asks = 0;
    final gate = runner(inner, review: (_, __) async {
      asks++;
      return Approval.no;
    });
    for (final call in [
      request('grep', ['--pre=touch WRITTEN', 'pattern', '.']),
      request('ls', ['--unrecognized-option']),
      request('grep', ['-f']),
      request('/bin/sh', ['-c', 'ls .; touch WRITTEN']),
      request('sed', ['-i', 's/before/after/', 'file']),
    ]) {
      expect(await gate.run(call), isA<CommandRefused>());
    }
    expect(asks, 5);
    expect(inner.requests, isEmpty);
  });

  test('reader certification does not bypass other modes', () async {
    for (final mode in [
      PermissionMode.ask,
      PermissionMode.allowEdits,
      PermissionMode.auto
    ]) {
      final inner = _Recorder();
      final gate = runner(inner, review: (_, __) async => Approval.no)
        ..mode = mode;
      expect(await gate.run(request('ls', [])), isA<CommandRefused>());
      expect(inner.requests, isEmpty);
    }
  });

  test(
      'network and unconfined permissions are reviewed separately from reading',
      () async {
    final inner = _Recorder();
    final reviews = <CommandApproval>[];
    final gate = runner(inner, review: (_, review) async {
      reviews.add(review);
      return Approval.always;
    });
    final call = request('ls', [root.path]);
    const online = ProcessControl(
        networkRequested: true, networkReason: 'network fixture');
    expect(await gate.run(call, control: online), isA<CommandCompleted>());
    expect(reviews.single.missingPermissions, {ProcessPermission.network});
    expect(reviews.single.requiredPermissions,
        {ProcessPermission.execution, ProcessPermission.network});
    expect(gate.grants.coversRequest(call), false);
    await gate.run(call, control: online);
    expect(reviews, hasLength(1));
    await gate.run(call);
    expect(inner.controls.last!.networkAllowed, false);
    const outside =
        ProcessControl(outsideSandboxRequested: true, sandboxReason: 'fixture');
    await gate.run(call, control: outside);
    expect(reviews.last.missingPermissions, {ProcessPermission.unconfined});
    expect(inner.controls.last!.outsideSandboxAllowed, true);
    gate.mode = PermissionMode.ask;
    await gate.run(call);
    expect(reviews.last.missingPermissions, {ProcessPermission.execution});
  });

  test('real grep receives shell-looking patterns literally and cannot edit',
      () async {
    final marker = File('${root.path}/WRITTEN');
    final pattern = '\$(touch ${marker.path}); > ${marker.path}';
    final file = File('${root.path}/notes.txt')
      ..writeAsStringSync('$pattern\n');
    final gate = runner(const IoProcessRunner());
    final result = await gate.run(request('grep', ['-F', pattern, file.path]));
    expect(result, isA<CommandCompleted>());
    expect((result as CommandCompleted).exitCode, 0);
    expect(result.stdout.trim(), pattern);
    expect(marker.existsSync(), false);
  });
}
