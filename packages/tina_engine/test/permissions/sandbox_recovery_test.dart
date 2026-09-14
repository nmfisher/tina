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
        projectRoot: temp.path,
        inner: inner,
        backend: SandboxBackend.bwrap,
        accessPolicy: SandboxAccessPolicy());
    bash = BashTool(projectRoot: temp.path, processRunner: runner);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, dynamic> retry() => {'command': command, 'retrySafety': safety};
  Future<List<Message>> run(
      List<List<Map<String, dynamic>>> steps, PermissionAsker asker,
      {Future<void>? cancelSignal,
      FakeAgentSink? sink,
      PermissionMode mode = PermissionMode.ask}) async {
    final history = <Message>[];
    await Agent(
      provider: _Provider(steps),
      tools: ToolRegistry([bash]),
      sink: sink ?? FakeAgentSink(),
      system: 'test',
      asker: asker,
      policy: PermissionPolicy(mode: mode, rules: const [
        PermissionRule(
            toolName: 'bash', pattern: '*', decision: PermissionDecision.allow)
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
        projectRoot: temp.path,
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
    final result = await bash.execute({'command': wrapped}) as BashToolResult;
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
        projectRoot: temp.path,
        inner: MemoryProcessRunner((_, __) =>
            MemoryRunningProcess(stderrChunks: ['Read-only file system\n'])),
        backend: SandboxBackend.bwrap,
        accessPolicy: SandboxAccessPolicy());
    final result = await bash.execute({'command': 'build'}) as BashToolResult;
    expect(result.sandboxWarning, isNotNull);
    expect(result.sandboxFailure, isNull);
    expect(result.isError, isFalse);
  });

  test('pass-through execution does not diagnose sandbox failures', () async {
    bash.processRunner = SandboxedProcessRunner(
        projectRoot: temp.path,
        inner: MemoryProcessRunner((_, __) =>
            MemoryRunningProcess(stderrChunks: ['Read-only file system\n'])),
        backend: SandboxBackend.passThrough);
    final result =
        await bash.execute({'command': 'read-log'}) as BashToolResult;
    expect(result.sandboxWarning, isNull);
    expect(result.sandboxFailure, isNull);
  });

  test('first failure explains the exact path and requires safety review',
      () async {
    final sink = FakeAgentSink();
    final history = await run([
      [
        {'command': command}
      ]
    ], (_) async => fail('no blind retry'), sink: sink);
    expect(inner.starts, hasLength(1));
    final result = results(history).single;
    expect(result.content, contains('${cache.path}/engine.stamp.tmp.42'));
    expect(result.content,
        contains('earlier command approval did not grant write access'));
    expect(result.content, contains('retrySafety'));
    expect(sink.notices.map((n) => n.message).join(),
        contains('Read-only file system'));
  });

  test('reviewed retry prompts with failure context and grants only cache',
      () async {
    final prompts = <PermissionPrompt>[];
    final history = await run([
      [
        {'command': command}
      ],
      [retry()]
    ], (p) async {
      prompts.add(p);
      return PermissionResponse.allowOnce;
    });
    final prompt = prompts.single;
    expect(prompt.sandboxAccess!.paths, [cache.resolveSymbolicLinksSync()]);
    expect(prompt.retryExplanation, contains('Read-only file system'));
    expect(prompt.accessDescription,
        contains('Allow these directories so the command can be retried?'));
    expect(prompt.accessDescription, contains(safety));
    expect(results(history).last.isError, isFalse);
    expect(inner.starts, hasLength(2));
    expect(inner.starts.last.arguments,
        contains(cache.resolveSymbolicLinksSync()));
    expect(runner.accessPolicy.writablePaths, isEmpty);
  });

  test(
      'retry re-requests earlier once grants together with newly blocked paths',
      () async {
    final dependencies = Directory('${temp.path}/dependencies')..createSync();
    final prompts = <PermissionPrompt>[];
    await run([
      [
        {
          'command': command,
          'writablePaths': [dependencies.path],
          'accessReason': 'dependency cache'
        }
      ],
      [retry()],
    ], (prompt) async {
      prompts.add(prompt);
      return PermissionResponse.allowOnce;
    });
    expect(prompts, hasLength(2));
    expect(
        prompts.last.sandboxAccess!.paths,
        containsAll([
          dependencies.resolveSymbolicLinksSync(),
          cache.resolveSymbolicLinksSync(),
        ]));
    expect(
        inner.starts.last.arguments,
        containsAll([
          dependencies.resolveSymbolicLinksSync(),
          cache.resolveSymbolicLinksSync(),
        ]));
    expect(runner.accessPolicy.writablePaths, isEmpty);
  });

  test('retry without partial-effects assessment does not execute or ask',
      () async {
    final history = await run([
      [
        {'command': command}
      ],
      [
        {'command': command}
      ]
    ], (_) async => fail('must inspect first'));
    expect(inner.starts, hasLength(1));
    expect(results(history).last.content, contains('retrySafety'));
  });

  test(
      'precomputed retry in the failed batch cannot claim to have inspected it',
      () async {
    final history = await run([
      [
        {'command': command},
        retry()
      ]
    ], (_) async => fail('must wait for result'));
    expect(inner.starts, hasLength(1));
    expect(results(history).last.content, contains('subsequent step'));
  });

  test('inspection tools can run between failure and retry', () async {
    final history = await run([
      [
        {'command': command}
      ],
      [
        {'command': 'cat cache-state'}
      ],
      [retry()]
    ], (_) async => PermissionResponse.allowOnce);
    expect(inner.starts, hasLength(3));
    expect(results(history).last.isError, isFalse);
  });

  test('denial suppresses further prompts and execution for this retry',
      () async {
    var asks = 0;
    final history = await run([
      [
        {'command': command}
      ],
      [retry()],
      [retry()]
    ], (_) async {
      asks++;
      return PermissionResponse.denyOnce;
    });
    expect(asks, 1);
    expect(inner.starts, hasLength(1));
    expect(results(history).last.content,
        contains('user denied this sandbox retry'));
  });

  test('renaming a retry command does not reprompt for a denied directory',
      () async {
    var asks = 0;
    final history = await run([
      [
        {'command': command}
      ],
      [retry()],
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

  test('cancellation during retry approval does not run or remember it',
      () async {
    final cancel = Completer<void>();
    await run([
      [
        {'command': command}
      ],
      [retry()]
    ], (_) async {
      cancel.complete();
      await Future<void>.delayed(Duration.zero);
      return PermissionResponse.allowAlways;
    }, cancelSignal: cancel.future);
    expect(inner.starts, hasLength(1));
    expect(runner.accessPolicy.writablePaths, isEmpty);
  });

  test('a failed approved retry does not start an approval loop', () async {
    inner = MemoryProcessRunner((_, __) => MemoryRunningProcess(
        exitCodeValue: 1,
        stderrChunks: ['${cache.path}/stamp: Read-only file system\n']));
    bash.processRunner = SandboxedProcessRunner(
        projectRoot: temp.path,
        inner: inner,
        backend: SandboxBackend.bwrap,
        accessPolicy: SandboxAccessPolicy());
    var asks = 0;
    final history = await run([
      [
        {'command': command}
      ],
      [retry()],
      [retry()]
    ], (_) async {
      asks++;
      return PermissionResponse.allowOnce;
    });
    expect(inner.starts, hasLength(2));
    expect(asks, 1);
    expect(results(history).last.content,
        contains('approved sandbox retry also failed'));
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

  test('real Linux logging wrapper masks the exit but still warns', () async {
    bash.processRunner =
        SandboxedProcessRunner(projectRoot: cache.path, sandboxReadOnly: true);
    final log = '${temp.path}/output.log';
    final actual = '''/bin/sh -c 'echo written > "${cache.path}/probe"' '''
        '> "$log" 2>&1; echo "exit=\$?"; tail -4 "$log"';
    final result = await bash.execute({'command': actual}) as BashToolResult;
    expect(result.isError, isFalse);
    expect(result.content, contains('exit: 0'));
    expect(result.content, contains('Read-only file system'));
    expect(result.sandboxWarning, isNotNull);
    expect(result.sandboxFailure, isNull);
    expect(File('${cache.path}/probe').existsSync(), isFalse);
  }, skip: !bwrapAvailable ? 'requires Linux bwrap' : false);

  test(
      'real Linux first failure offers an approval and a reviewed retry succeeds',
      () async {
    bash.processRunner =
        SandboxedProcessRunner(projectRoot: cache.path, sandboxReadOnly: true);
    // Cache is read-only even though its parent is in writable /tmp.
    final actual = 'echo written > "${cache.path}/probe"';
    var asks = 0;
    final history = await run([
      [
        {'command': actual}
      ],
      [
        {
          'command': actual,
          'retrySafety':
              'The shell failed opening the sole output file; no earlier commands ran.'
        }
      ]
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
  _Provider(this.steps) : super('scripted');
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
          ToolUseBlock(id: 'u$index-$i', name: 'bash', input: calls[i])
      ], stopReason: 'tool_use');
    }
  }
}
