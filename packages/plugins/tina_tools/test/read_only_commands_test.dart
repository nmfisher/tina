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
      (
        'grep',
        [
          '-rn',
          '-E',
          'themeSetting|onSettingsChanged',
          '/Volumes/T7/projects/tina/packages/tina_tui/lib',
          '/Volumes/T7/projects/tina/packages/tina_engine_2/lib',
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

  test('reader certification does not bypass ask or auto modes', () async {
    for (final mode in [PermissionMode.ask, PermissionMode.auto]) {
      final inner = _Recorder();
      final gate = runner(inner, review: (_, __) async => Approval.no)
        ..mode = mode;
      expect(await gate.run(request('ls', [])), isA<CommandRefused>());
      expect(inner.requests, isEmpty);
    }
  });

  for (final mode in [PermissionMode.readOnly, PermissionMode.allowEdits]) {
    test('$mode allows verified readers and the reported compound read',
        () async {
      final inner = _Recorder();
      final gate = runner(inner,
          review: (_, __) => throw StateError('unexpected approval'))
        ..mode = mode;
      expect(await gate.run(request('grep', ['-n', 'class', 'models.dart'])),
          isA<CommandCompleted>());
      const script =
          r'''grep -n "class.*Question\|abstract\|enum" packages/classification/lib/src/judgments/models.dart | head; echo ---; head -30 packages/classification/pubspec.yaml''';
      expect(await gate.run(request('/bin/sh', ['-c', script], cwd: root.path)),
          isA<CommandCompleted>());
      final spawned = inner.requests.last;
      expect(spawned.command, '/bin/sh');
      expect(spawned.arguments.last, contains("'/usr/bin/grep'"));
      expect(spawned.arguments.last,
          contains("'class.*Question\\|abstract\\|enum'"));
      expect(spawned.arguments.last, contains("| '/usr/bin/head'"));
      final echo =
          readOnlyExecutable(request('echo', []), searchPath: systemPath);
      expect(spawned.arguments.last, contains("; '$echo' '---' ;"));
      expect(gate.grants.isEmpty, true);
      expect(inner.controls.last!.networkAllowed, false);
    });

    test('$mode runs output-only redirects without asking', () async {
      final inner = _Recorder();
      final gate = runner(inner,
          review: (_, __) => throw StateError('unexpected approval'))
        ..mode = mode;
      for (final script in [
        'cat file',
        'grep needle file 2>/dev/null | head',
        'grep needle file 2>/dev/null | head 2>/dev/null',
        'cat file 2>&1 | head',
        'cat file | head 2>&1',
        'cat file; head file 2>/dev/null',
        'grep needle file 2>&1 2>/dev/null | head',
        'grep needle file >/dev/null 2>&1 | head',
        'grep needle file &>/dev/null | head',
        'grep needle file 2>>/dev/null | head',
      ]) {
        expect(
            await gate.run(
                request('/bin/sh', ['-c', script], cwd: root.path)),
            isA<CommandCompleted>(),
            reason: script);
      }
      final spawned = inner.requests.last;
      expect(spawned.command, '/bin/sh');
      expect(spawned.arguments.last, contains("2>>/dev/null"));
      // Redirects attach to their own segment, not the last one.
      expect(inner.requests[inner.requests.length - 2].arguments.last,
          contains("'file' &>/dev/null | '/usr/bin/head'"));
      expect(gate.grants.isEmpty, true);
    });

    test('$mode rejects unsafe or unsupported shell components', () async {
      final inner = _Recorder();
      var asks = 0;
      final gate = runner(inner, review: (_, __) async {
        asks++;
        return Approval.no;
      })
        ..mode = mode;
      for (final script in [
        'grep needle file | tee written',
        'cat file; touch written',
        'echo ok && rm file',
        'cat file > written',
        'cat file 2> written',
        'cat file 2>> written',
        'cat file &> written',
        'cat file >/dev/zero',
        'cat file 2>&3',
        'cat file 2>&1x',
        r'cat $(touch written)',
        r'echo "$HOME"',
        r'echo `touch written`',
        'cat *',
        'cat file &',
        'cat file || cat other',
        'cat file |',
        'cat file; ; cat other',
        'cat < file',
        'cat file\ntouch written',
        'env cat file',
        'head --unsupported file',
      ]) {
        expect(
            await gate.run(request('/bin/sh', ['-c', script], cwd: root.path)),
            isA<CommandRefused>(),
            reason: script);
      }
      expect(asks, 22);
      expect(inner.requests, isEmpty);
    });

    test('$mode compound readers still review network and unconfined access',
        () async {
      final inner = _Recorder();
      final reviews = <CommandApproval>[];
      final gate = runner(inner, review: (_, review) async {
        reviews.add(review);
        return Approval.no;
      })
        ..mode = mode;
      final call = request('/bin/sh', ['-c', 'cat file | head; echo ---']);
      expect(
          await gate.run(call,
              control: const ProcessControl(
                networkRequested: true,
                networkReason: 'fixture',
              )),
          isA<CommandRefused>());
      expect(reviews.last.missingPermissions, {ProcessPermission.network});
      expect(
          await gate.run(call,
              control: const ProcessControl(
                outsideSandboxRequested: true,
                sandboxReason: 'fixture',
              )),
          isA<CommandRefused>());
      expect(reviews.last.missingPermissions,
          {ProcessPermission.network, ProcessPermission.unconfined});
      expect(inner.requests, isEmpty);
    });
  }

  test('certified shell reads preserve regexes and literal shell-looking text',
      () async {
    File('${root.path}/models.dart').writeAsStringSync(
        'class Question {}\nabstract class Base {}\nenum Kind { one }\n');
    File('${root.path}/pubspec.yaml')
        .writeAsStringSync('name: fixture\nversion: 1\n');
    final gate = runner(const IoProcessRunner(),
        review: (_, __) => throw StateError('unexpected approval'))
      ..mode = PermissionMode.allowEdits;
    final outcome = await gate.run(request(
        '/bin/sh',
        [
          '-c',
          r'''grep -n "class.*Question\|abstract\|enum" models.dart | head; echo ---; head -30 pubspec.yaml'''
        ],
        cwd: root.path));
    expect(outcome, isA<CommandCompleted>());
    expect((outcome as CommandCompleted).exitCode, 0);
    expect(outcome.stdout, contains('1:class Question {}'));
    expect(outcome.stdout, contains('2:abstract class Base {}'));
    expect(outcome.stdout, contains('---\nname: fixture'));
    final literal = await gate.run(request('/bin/sh',
        ['-c', r'''echo '$(touch WRITTEN)' && echo 'literal; | text' | cat'''],
        cwd: root.path));
    expect((literal as CommandCompleted).stdout,
        contains('\$(touch WRITTEN)\nliteral; | text'));
    expect(File('${root.path}/WRITTEN').existsSync(), false);
  }, skip: Platform.isWindows);

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
