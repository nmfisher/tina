import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/memory_process_runner.dart';

void main() {
  late Directory temp;
  late Directory cache;
  late MemoryProcessRunner inner;
  late SandboxedProcessRunner runner;
  late BashTool bash;
  const command = 'dart test';
  const safety =
      'Checked the launcher output and cache: only metadata setup ran; tests never started.';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tina-recovery-');
    cache = Directory('${temp.path}/sdk cache')..createSync();
    var calls = 0;
    inner = MemoryProcessRunner((_, __) => ++calls == 1
        ? MemoryRunningProcess(exitCodeValue: 1, stderrChunks: [
            '/sdk/update_engine_version.sh: line 71: ${cache.path}/engine.stamp.tmp.42: Read-only file system\n',
            '/sdk/update_engine_version.sh: line 78: ${cache.path}/engine.realm: Read-only file system\n',
          ])
        : MemoryRunningProcess(stdoutChunks: ['success']));
    runner = SandboxedProcessRunner(
        workspaceRoot: temp.path,
        inner: inner,
        backend: SandboxBackend.bwrap,
        accessPolicy: SandboxAccessPolicy());
    bash = BashTool(workspaceRoot: temp.path, processRunner: runner);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<List<Message>> run(
      List<List<Map<String, dynamic>>> steps, PermissionAsker asker,
      {Future<void>? cancelSignal,
      FakeAgentSink? sink,
      PermissionMode mode = PermissionMode.ask,
      PermissionPolicy? permissions,
      bool allowCommand = true,
      String toolName = 'bash'}) async {
    final history = <Message>[];
    await Agent(
      provider: _Provider(steps, toolName: toolName),
      tools: ToolRegistry(
          [bash, ExecTool(workspaceRoot: temp.path, processRunner: runner)]),
      sink: sink ?? FakeAgentSink(),
      system: 'test',
      asker: asker,
      policy: permissions ??
          PermissionPolicy(mode: mode, rules: [
            if (allowCommand)
              PermissionRule(
                  toolName: toolName,
                  pattern: '*',
                  decision: PermissionDecision.allow)
          ]),
    ).run(history: history, userInput: 'test', cancelSignal: cancelSignal);
    return history;
  }

  List<ToolResultBlock> results(List<Message> history) =>
      history.expand((m) => m.content).whereType<ToolResultBlock>().toList();

  void successfulShellWithDiagnostics({bool repeat = false}) {
    var calls = 0;
    inner = MemoryProcessRunner((_, __) => ++calls == 1 || repeat
        ? MemoryRunningProcess(stdoutChunks: [
            'exit=1\n',
            '/sdk/update_engine_version.sh: line 71: ${cache.path}/engine.stamp.tmp.42: Read-only file system\n',
            '/sdk/update_engine_version.sh: line 78: ${cache.path}/engine.realm: Read-only file system\n',
          ])
        : MemoryRunningProcess(stdoutChunks: ['tests passed\n']));
    runner = SandboxedProcessRunner(
        workspaceRoot: temp.path,
        inner: inner,
        backend: SandboxBackend.bwrap,
        accessPolicy: SandboxAccessPolicy());
    bash.processRunner = runner;
  }

  test('wrapped test failure retains shell status and surfaces a warning',
      () async {
    successfulShellWithDiagnostics();
    const wrapped = 'cd /mnt/sdd_1tb/tina/packages/tina_engine && '
        'dart test test/llm/registry_build_test.dart > /tmp/tina_test_out.txt 2>&1; '
        'echo "exit=\$?"; tail -4 /tmp/tina_test_out.txt';
    final result =
        await bash.execute({'command': wrapped}) as ProcessToolResult;
    expect(result.isError, isFalse, reason: 'the final tail returned 0');
    expect(result.content, contains('exit: 0'));
    expect(result.content, contains('exit=1'));
    expect(result.sandboxFailure, isNull,
        reason: 'output is not fresh-denial evidence');
    expect(result.sandboxWarning, contains('nested command may have failed'));
    expect(result.content,
        contains('writablePaths, accessReason, and retrySafety'));
    expect(inner.starts.single.arguments.last, wrapped,
        reason: 'no shell rewriting');
    expect(runner.accessPolicy.writablePaths, isEmpty);
  });

  test(
      'old log reads warn visibly without arming recovery or asking for grants',
      () async {
    successfulShellWithDiagnostics(repeat: true);
    final sink = FakeAgentSink();
    const logRead =
        'head -30 /tmp/tina_test_out.txt; echo ---; wc -l /tmp/tina_test_out.txt';
    final history = await run([
      [
        {'command': logRead}
      ],
      [
        {'command': logRead}
      ],
    ], (_) async => fail('reading output must not infer an access request'),
        sink: sink, mode: PermissionMode.allowEdits);
    expect(inner.starts, hasLength(2),
        reason: 'no retrySafety gate from log text');
    expect(results(history).every((r) => !r.isError), isTrue);
    expect(sink.notices.where((n) => n.message.contains('shell exited 0')),
        hasLength(2));
    expect(
        sink.notices
            .where((n) => n.message.contains('shell exited 0'))
            .every((n) => n.kind == NoticeKind.warning),
        isTrue);
    expect(runner.accessPolicy.writablePaths, isEmpty);
  });

  for (final approve in [true, false]) {
    test(
        'confirmed masked failure requires explicit cache approval (approve=$approve)',
        () async {
      successfulShellWithDiagnostics();
      final prompts = <PermissionPrompt>[];
      final explicit = {
        'command': command,
        'writablePaths': [cache.path],
        'accessReason':
            'The test launcher needs to update its SDK metadata cache.',
        'retrySafety': safety,
      };
      final history = await run([
        [
          {'command': 'dart test > result.log 2>&1; tail -4 result.log'}
        ],
        [explicit],
        if (!approve) [explicit],
      ], (prompt) async {
        prompts.add(prompt);
        return approve
            ? PermissionResponse.allowOnce
            : PermissionResponse.denyOnce;
      }, mode: PermissionMode.allowEdits);
      final prompt = prompts.single;
      expect(prompt.sandboxAccess!.paths, [cache.resolveSymbolicLinksSync()]);
      expect(prompt.retryExplanation, isNull,
          reason: 'no inferred fresh failure');
      expect(prompt.accessDescription, contains(safety));
      expect(prompt.input['command'], command);
      expect(inner.starts, hasLength(approve ? 2 : 1));
      expect(results(history).last.isError, !approve);
      expect(runner.accessPolicy.writablePaths, isEmpty);
      if (approve) {
        expect(inner.starts.last.arguments,
            contains(cache.resolveSymbolicLinksSync()));
      } else {
        expect(
            results(history).last.content, contains('Do not request it again'));
      }
    });
  }

  test('a zero-exit EROFS without a path is only a warning', () async {
    bash.processRunner = SandboxedProcessRunner(
        workspaceRoot: temp.path,
        inner: MemoryProcessRunner((_, __) =>
            MemoryRunningProcess(stderrChunks: ['Read-only file system\n'])),
        backend: SandboxBackend.bwrap,
        accessPolicy: SandboxAccessPolicy());
    final result =
        await bash.execute({'command': 'build'}) as ProcessToolResult;
    expect(result.sandboxWarning, isNotNull);
    expect(result.sandboxFailure, isNull);
    expect(result.isError, isFalse);
  });

  test('pass-through execution does not diagnose sandbox failures', () async {
    bash.processRunner = SandboxedProcessRunner(
        workspaceRoot: temp.path,
        inner: MemoryProcessRunner((_, __) =>
            MemoryRunningProcess(stderrChunks: ['Read-only file system\n'])),
        backend: SandboxBackend.passThrough);
    final result =
        await bash.execute({'command': 'read-log'}) as ProcessToolResult;
    expect(result.sandboxWarning, isNull);
    expect(result.sandboxFailure, isNull);
  });

  for (final toolName in ['bash', 'exec']) {
    for (final answer in ['ALLOW', 'DENY']) {
      test('auto $answer controls the real $toolName outside-sandbox retry',
          () async {
        final policy = PermissionPolicy(
            mode: PermissionMode.auto, allowAllByDefault: true);
        final judge = _ApprovalProvider(answer);
        final asker = modeAwareAsker(
            policy: policy,
            classifier: PermissionClassifier(judge),
            fallback: (_) async => fail('classifier supplied a verdict'));
        final input = toolName == 'bash'
            ? <String, dynamic>{'command': command}
            : <String, dynamic>{
                'executable': '/bin/sh',
                'args': ['-c', command]
              };
        final history = await run([
          [input]
        ], asker, permissions: policy, toolName: toolName);
        expect(judge.calls, 1);
        expect(inner.starts.first.executable, contains('bwrap'));
        expect(inner.starts, hasLength(answer == 'ALLOW' ? 2 : 1));
        expect(results(history).single.isError, answer != 'ALLOW');
        if (answer == 'ALLOW') {
          expect(inner.starts.last.executable, '/bin/sh');
          await run([
            [input]
          ], asker, permissions: policy, toolName: toolName);
          expect(judge.calls, 1, reason: 'exact session approval is reused');
          expect(inner.starts, hasLength(3));
          expect(inner.starts.last.executable, '/bin/sh');
          policy.remember(toolName, PermissionPolicy.keyFor(toolName, input),
              PermissionDecision.deny);
          await run([
            [input]
          ], asker, permissions: policy, toolName: toolName);
          expect(inner.starts, hasLength(3),
              reason: 'an explicit deny still blocks the remembered grant');
        }
      });
    }
  }

  for (final toolName in ['bash', 'exec']) {
    test(
        '$toolName failure immediately asks separately and retries outside sandbox',
        () async {
      final prompts = <PermissionPrompt>[];
      final history = await run([
        [
          toolName == 'bash'
              ? {'command': command}
              : {
                  'executable': '/bin/sh',
                  'args': ['-c', command]
                }
        ],
      ], (prompt) async {
        prompts.add(prompt);
        if (!prompt.outsideSandbox) return PermissionResponse.allowAlways;
        expect(inner.starts, hasLength(1),
            reason: 'sandboxed attempt must fail first');
        expect(prompt.sandboxAccess, isNull);
        expect(prompt.accessDescription, contains('Are you definitely OK'));
        expect(prompt.accessDescription, contains('partial changes'));
        expect(prompt.retryExplanation, contains(cache.path));
        expect(prompt.execution, same(prompts.first.execution));
        return PermissionResponse.allowOnce;
      }, toolName: toolName, allowCommand: false);
      expect(prompts, hasLength(2));
      expect(prompts.first.outsideSandbox, isFalse);
      expect(prompts.last.outsideSandbox, isTrue);
      expect(inner.starts, hasLength(2));
      expect(inner.starts.first.executable, contains('bwrap'));
      expect(inner.starts.last.executable, '/bin/sh');
      expect(inner.starts.last.arguments, ['-c', command]);
      expect(prompts.last.execution!.workingDirectory, temp.path);
      expect(prompts.last.execution!.environment, bash.environment);
      expect(results(history).single.isError, isFalse);
      expect(runner.accessPolicy.writablePaths, isEmpty);
      expect(bash.processRunner, same(runner));
    });
  }

  for (final toolName in ['bash', 'exec']) {
    test(
        '$toolName session grant survives turns, matches exactly and is not persisted',
        () async {
      final policy = PermissionPolicy(allowAllByDefault: true);
      final input = toolName == 'bash'
          ? <String, dynamic>{'command': command}
          : <String, dynamic>{
              'executable': '/bin/sh',
              'args': ['-c', command]
            };
      var asks = 0;
      Future<PermissionResponse> approve(PermissionPrompt prompt) async {
        asks++;
        expect(prompt.outsideSandbox, isTrue);
        return PermissionResponse.allowAlways;
      }

      await run([
        [input]
      ], approve, permissions: policy, toolName: toolName);
      expect(asks, 1);
      expect(inner.starts, hasLength(2));
      await run([
        [input]
      ], approve, permissions: policy, toolName: toolName);
      expect(asks, 1);
      expect(inner.starts.last.executable, '/bin/sh');
      expect(inner.starts, hasLength(3), reason: 'no doomed sandbox attempt');
      final derived =
          PermissionPolicy(modeSource: policy, allowAllByDefault: true);
      await run([
        [input]
      ], approve, permissions: derived, toolName: toolName);
      expect(inner.starts.last.executable, '/bin/sh');
      final cwd = Directory('${temp.path}/other')..createSync();
      for (final changed in [
        {...input, 'cwd': cwd.path},
        {
          ...input,
          'environment': {'TINA_TEST_VALUE': 'different'}
        },
        toolName == 'bash'
            ? <String, dynamic>{'command': '$command --offline'}
            : <String, dynamic>{
                'executable': '/bin/sh',
                'args': ['-c', '$command --offline']
              },
      ]) {
        await run([
          [changed]
        ], approve, permissions: policy, toolName: toolName);
        expect(inner.starts.last.executable, contains('bwrap'));
      }
      final restored = PermissionPolicy.fromJson(policy.toJson());
      await run([
        [input]
      ], approve, permissions: restored, toolName: toolName);
      expect(inner.starts.last.executable, contains('bwrap'));
      expect(asks, 1);
      final starts = inner.starts.length;
      policy.mode = PermissionMode.readAll;
      await run([
        [input]
      ], approve, permissions: policy, toolName: toolName);
      expect(inner.starts, hasLength(starts));
      policy.mode = PermissionMode.ask;
      policy.remember(toolName, PermissionPolicy.keyFor(toolName, input),
          PermissionDecision.deny);
      await run([
        [input]
      ], approve, permissions: policy, toolName: toolName);
      expect(inner.starts, hasLength(starts));
    });
  }

  test('once approval leaves the next identical command sandboxed', () async {
    final policy = PermissionPolicy(allowAllByDefault: true);
    await run([
      [
        {'command': command}
      ]
    ], (_) async => PermissionResponse.allowOnce, permissions: policy);
    await run([
      [
        {'command': command}
      ]
    ], (_) async => fail('already allowed ordinary command'),
        permissions: policy);
    expect(inner.starts, hasLength(3));
    expect(inner.starts.last.executable, contains('bwrap'));
  });

  test('switching to read-all during outside approval prevents retry',
      () async {
    final policy =
        PermissionPolicy(mode: PermissionMode.allowEdits, rules: const [
      PermissionRule(
          toolName: 'bash', pattern: '*', decision: PermissionDecision.allow)
    ]);
    await run([
      [
        {'command': command}
      ]
    ], (_) async {
      policy.mode = PermissionMode.readAll;
      return PermissionResponse.allowOnce;
    }, permissions: policy);
    expect(inner.starts, hasLength(1));
  });

  for (final yolo in [false, true]) {
    test('auto/yolo ($yolo) still requires explicit outside approval',
        () async {
      var asks = 0;
      await run([
        [
          {'command': command}
        ]
      ], (prompt) async {
        if (!prompt.outsideSandbox) return PermissionResponse.allowOnce;
        asks++;
        return PermissionResponse.denyOnce;
      },
          permissions: PermissionPolicy(
              mode: PermissionMode.auto, allowAllByDefault: yolo),
          allowCommand: false);
      expect(asks, 1);
      expect(inner.starts, hasLength(1));
    });
  }

  test('denial blocks replay without asking again', () async {
    var asks = 0;
    final history = await run([
      [
        {'command': command}
      ],
      [
        {'command': command}
      ],
    ], (prompt) async {
      asks++;
      expect(prompt.outsideSandbox, isTrue);
      return PermissionResponse.denyOnce;
    });
    expect(asks, 1);
    expect(inner.starts, hasLength(1));
    expect(results(history).first.content, contains('retry was not executed'));
    expect(results(history).last.content,
        contains('user denied this sandbox retry'));
  });

  test('denial blocks a directory-grant workaround', () async {
    var asks = 0;
    final history = await run([
      [
        {'command': command}
      ],
      [
        {
          'command': '/sdk/bin/dart test',
          'writablePaths': [cache.path],
          'accessReason': 'Retry'
        }
      ],
    ], (_) async {
      asks++;
      return PermissionResponse.denyOnce;
    });
    expect(asks, 1);
    expect(inner.starts, hasLength(1));
    expect(results(history).last.content,
        contains('Do not request it again under another command'));
  });

  test('cancellation during outside approval prevents replay and grants',
      () async {
    final cancel = Completer<void>();
    await run([
      [
        {'command': command}
      ]
    ], (_) async {
      cancel.complete();
      await Future<void>.delayed(Duration.zero);
      return PermissionResponse.allowAlways;
    }, cancelSignal: cancel.future);
    expect(inner.starts, hasLength(1));
    expect(runner.accessPolicy.writablePaths, isEmpty);
  });

  test('a failed outside retry does not start an approval loop', () async {
    inner = MemoryProcessRunner((_, __) => MemoryRunningProcess(
        exitCodeValue: 1,
        stderrChunks: ['${cache.path}/stamp: Read-only file system\n']));
    bash.processRunner = SandboxedProcessRunner(
        workspaceRoot: temp.path,
        inner: inner,
        backend: SandboxBackend.bwrap,
        accessPolicy: SandboxAccessPolicy());
    var asks = 0;
    final history = await run([
      [
        {'command': command}
      ],
      [
        {'command': command}
      ],
    ], (_) async {
      asks++;
      return PermissionResponse.allowOnce;
    });
    expect(inner.starts, hasLength(2));
    expect(inner.starts.last.executable, '/bin/sh');
    expect(asks, 1);
    expect(results(history).last.content,
        contains('approved sandbox retry also failed'));
  });

  test('later commands remain sandboxed after outside approval', () async {
    await run([
      [
        {'command': command}
      ],
      [
        {'command': 'echo later'}
      ],
    ], (_) async => PermissionResponse.allowOnce);
    expect(inner.starts, hasLength(3));
    expect(inner.starts[1].executable, '/bin/sh');
    expect(inner.starts[2].executable, contains('bwrap'));
  });

  test('normal permission denied and unlocated EROFS never infer a directory',
      () {
    for (final output in [
      '${cache.path}/stamp: Permission denied',
      'Read-only file system',
      'command /sdk/bin/dart failed: Read-only file system',
      '${cache.path}/missing/child: Read-only file system',
    ]) {
      expect(SandboxWriteFailure.detect(output, runner), isNull,
          reason: output);
    }
  });

  test('recognizes quoted shell and Python errors without broadening parents',
      () {
    for (final output in [
      "touch: cannot touch '${cache.path}/stamp': Read-only file system",
      "OSError: [Errno 30] Read-only file system: '${cache.path}/stamp'",
      '/bin/sh: line 1: ${cache.path}/stamp: Read-only file system',
    ]) {
      final failure = SandboxWriteFailure.detect(output, runner)!;
      expect(failure.writablePaths, [cache.resolveSymbolicLinksSync()]);
      expect(failure.blockedPaths, ['${cache.path}/stamp']);
    }
  });

  test('already writable paths do not imply missing sandbox grants', () {
    runner.accessPolicy.grantForSession(
        SandboxAccessRequest([cache.resolveSymbolicLinksSync()], 'cache'));
    expect(
        SandboxWriteFailure.detect(
            '${cache.path}/stamp: Read-only file system', runner),
        isNull);
  });

  group('a command that refuses a file it thinks somebody else owns', () {
    // The shape a sandboxed ssh produces: the user namespace shows a
    // root-owned config as belonging to nobody, and OpenSSH refuses to read it
    // before it ever tries to connect.
    const refused = '/etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf';
    final sshOutput = 'Bad owner or permissions on $refused\n'
        'fatal: Could not read from remote repository.\n';

    test('the refusal is evidence, and names the file', () {
      final failure = SandboxOwnershipFailure.detect(sshOutput,
          isReadable: (path) => path == refused)!;
      expect(failure.refusedPaths, [refused]);
      expect(failure.explanation, contains(refused));
      expect(failure.explanation, contains('nobody'));
      expect(failure.recoveryInstructions, contains('outside the sandbox'));
    });

    test('a file we cannot read here is a permission problem, not evidence',
        () {
      // Nothing about a genuine ownership error becomes a sandbox claim: if the
      // file is not readable, the retry would fail the same way.
      expect(
          SandboxOwnershipFailure.detect(sshOutput, isReadable: (_) => false),
          isNull);
    });

    test('an id that is not the unmapped root is somebody\'s real file', () {
      expect(
          SandboxOwnershipFailure.detect(
                  '/etc/sudo.conf is owned by uid 65534, should be 0',
                  isReadable: (_) => true)!
              .refusedPaths,
          ['/etc/sudo.conf']);
      expect(
          SandboxOwnershipFailure.detect(
              '/etc/sudo.conf is owned by uid 1001, should be 0',
              isReadable: (_) => true),
          isNull);
    });

    test('ordinary output produces no evidence', () {
      for (final output in [
        'fatal: Could not read from remote repository.',
        'Bad owner or permissions on .ssh/config', // relative: nothing to check
        'rm: cannot remove \'/root/x\': Permission denied',
      ]) {
        expect(SandboxOwnershipFailure.detect(output, isReadable: (_) => true),
            isNull,
            reason: output);
      }
    });
  });

  group('an agent socket the sandbox cannot see', () {
    const sock = '/run/user/1000/keyring/ssh';
    const pushOutput =
        'Bad owner or permissions on /etc/ssh/ssh_config.d/20-systemd-ssh-proxy.conf\n'
        'git@github.com: Permission denied (publickey).\n'
        'fatal: Could not read from remote repository.\n';

    test('auth refusal + missing socket is a sandbox-mount gap', () {
      final failure = SandboxAgentSocketFailure.detect(pushOutput,
          sshAuthSock: sock, exists: (_) => false)!;
      expect(failure.socketPath, sock);
      expect(failure.parentDirectory, '/run/user/1000/keyring');
      expect(failure.recoveryInstructions, contains('/run/user/1000/keyring'));
      expect(failure.recoveryInstructions, contains('outside the sandbox'));
    });

    test('a reachable agent means plain bad credentials — no claim', () {
      expect(
          SandboxAgentSocketFailure.detect(pushOutput,
              sshAuthSock: sock, exists: (_) => true),
          isNull);
    });

    test('no SSH_AUTH_SOCK in the environment — no claim', () {
      expect(SandboxAgentSocketFailure.detect(pushOutput, sshAuthSock: null),
          isNull);
    });

    test('write failures and EROFS output do not claim the agent branch', () {
      const output = 'cp: cannot create \'/opt/x/y\': Read-only file system\n';
      expect(
          SandboxAgentSocketFailure.detect(output,
              sshAuthSock: sock, exists: (_) => false),
          isNull);
    });
  });

  group('a command that refuses a file it thinks somebody else owns (linux)',
      () {
    test('a sandboxed ssh failure asks to retry outside the sandbox', () async {
      final config = File('${temp.path}/ssh_config')..writeAsStringSync('');
      var calls = 0;
      inner = MemoryProcessRunner((_, __) => ++calls == 1
          ? MemoryRunningProcess(exitCodeValue: 1, stderrChunks: [
              'Bad owner or permissions on ${config.path}\n',
              'fatal: Could not read from remote repository.\n',
            ])
          : MemoryRunningProcess(stdoutChunks: ['pushed']));
      runner = SandboxedProcessRunner(
          workspaceRoot: temp.path,
          inner: inner,
          backend: SandboxBackend.bwrap,
          accessPolicy: SandboxAccessPolicy());
      bash.processRunner = runner;

      final prompts = <PermissionPrompt>[];
      final history = await run([
        [
          {'command': 'git push'}
        ],
      ], (prompt) async {
        prompts.add(prompt);
        return prompt.outsideSandbox
            ? PermissionResponse.allowOnce
            : PermissionResponse.allowAlways;
      }, allowCommand: false);

      expect(prompts, hasLength(2));
      expect(prompts.last.outsideSandbox, isTrue);
      expect(prompts.last.retryExplanation, contains(config.path));
      expect(prompts.last.retryExplanation, contains('refused to use a file'));
      // The retry runs the same command with the sandbox gone, which is the
      // whole point: the file's real owner is what the tool needed.
      expect(inner.starts.first.executable, contains('bwrap'));
      expect(inner.starts.last.executable, '/bin/sh');
      expect(results(history).single.isError, isFalse);
    });
  });

  test('real Linux logging wrapper masks the exit but still warns', () async {
    bash.processRunner = SandboxedProcessRunner(
        workspaceRoot: cache.path, sandboxReadOnly: true);
    final log = '${temp.path}/output.log';
    final actual = '''/bin/sh -c 'echo written > "${cache.path}/probe"' '''
        '> "$log" 2>&1; echo "exit=\$?"; tail -4 "$log"';
    final result = await bash.execute({'command': actual}) as ProcessToolResult;
    expect(result.isError, isFalse);
    expect(result.content, contains('exit: 0'));
    expect(result.content, contains('Read-only file system'));
    expect(result.sandboxWarning, isNotNull);
    expect(result.sandboxFailure, isNull);
    expect(File('${cache.path}/probe').existsSync(), isFalse);
  }, skip: !bwrapAvailable ? 'requires Linux bwrap' : false);

  test('real Linux first failure retries outside only after explicit approval',
      () async {
    bash.processRunner = SandboxedProcessRunner(
        workspaceRoot: cache.path, sandboxReadOnly: true);
    // Cache is read-only even though its parent is in writable /tmp.
    final actual = 'echo written > "${cache.path}/probe"';
    var asks = 0;
    final history = await run([
      [
        {'command': actual}
      ],
    ], (p) async {
      asks++;
      expect(p.retryExplanation, contains('Read-only file system'));
      return PermissionResponse.allowOnce;
    });
    expect(asks, 1);
    expect(results(history).last.isError, isFalse);
    expect(File('${cache.path}/probe').readAsStringSync(), 'written\n');
  }, skip: !bwrapAvailable ? 'requires Linux bwrap' : false);
}

class _Provider extends LlmProvider {
  final List<List<Map<String, dynamic>>> steps;
  int index = 0;
  final String toolName;
  _Provider(this.steps, {this.toolName = 'bash'}) : super('scripted');
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    if (index == steps.length) {
      yield const MessageComplete(
          content: [TextBlock('done')], stopReason: 'end_turn');
    } else {
      final calls = steps[index++];
      yield MessageComplete(content: [
        for (var i = 0; i < calls.length; i++)
          ToolUseBlock(id: 'u$index-$i', name: toolName, input: calls[i])
      ], stopReason: 'tool_use');
    }
  }
}

class _ApprovalProvider extends LlmProvider {
  final String answer;
  int calls = 0;
  _ApprovalProvider(this.answer) : super('test-judge');
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    calls++;
    yield TextDelta(answer);
  }
}
