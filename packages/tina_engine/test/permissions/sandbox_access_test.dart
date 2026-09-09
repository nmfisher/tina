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

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tina-access-');
    cache = Directory('${temp.path}/cache')..createSync();
    inner = MemoryProcessRunner(
        (_, __) => MemoryRunningProcess(stdoutChunks: ['ok']));
    runner = SandboxedProcessRunner(
      projectRoot: temp.path,
      inner: inner,
      backend: SandboxBackend.bwrap,
      // Model an external directory despite keeping test fixtures in /tmp.
      accessPolicy: SandboxAccessPolicy(),
    );
    bash = BashTool(processRunner: runner, projectRoot: temp.path);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Map<String, dynamic> input() => {
        'command': 'echo test',
        'writablePaths': [cache.path],
        'accessReason': 'The launcher updates its cache metadata.',
      };

  Future<List<Message>> run(
      List<Map<String, dynamic>> calls, PermissionAsker asker,
      {PermissionPolicy? policy, Future<void>? cancelSignal}) async {
    final agent = Agent(
      provider: _Provider(calls),
      tools: ToolRegistry([bash]),
      sink: FakeAgentSink(),
      system: 'test',
      asker: asker,
      policy: policy ??
          PermissionPolicy(rules: const [
            PermissionRule(
                toolName: 'bash',
                pattern: '*',
                decision: PermissionDecision.allow),
          ]),
    );
    final history = <Message>[];
    await agent.run(
        history: history, userInput: 'test', cancelSignal: cancelSignal);
    return history;
  }

  test('remembered command allow still asks for additional write access',
      () async {
    final prompts = <PermissionPrompt>[];
    await run([input()], (p) async {
      prompts.add(p);
      return PermissionResponse.allowOnce;
    });
    expect(prompts.single.sandboxAccess!.paths,
        [cache.resolveSymbolicLinksSync()]);
    expect(prompts.single.accessDescription, contains('launcher updates'));
    expect(prompts.single.approvalRow, contains('[a] session directories'));
    expect(inner.starts.single.arguments,
        contains(cache.resolveSymbolicLinksSync()));
    expect(runner.accessPolicy.writablePaths, isEmpty);
  });

  test('once grant does not reach a later command', () async {
    var asks = 0;
    await run([
      input(),
      {'command': 'echo later'},
      input()
    ], (_) async {
      return ++asks == 1
          ? PermissionResponse.allowOnce
          : PermissionResponse.denyOnce;
    });
    expect(asks, 2);
    expect(inner.starts, hasLength(2));
    expect(inner.starts.last.arguments,
        isNot(contains(cache.resolveSymbolicLinksSync())));
  });

  test('session grant is shared with another agent but not command rules',
      () async {
    final policy = PermissionPolicy();
    await run([input()], (_) async => PermissionResponse.allowAlways,
        policy: policy);
    expect(policy.check('bash', input()), PermissionDecision.ask);
    final secondAsks = <PermissionPrompt>[];
    await run([input()], (p) async {
      secondAsks.add(p);
      return PermissionResponse.allowOnce;
    }, policy: policy);
    expect(secondAsks.single.sandboxAccess, isNull,
        reason: 'only command permission remains');
    expect(inner.starts, hasLength(2));
    expect(inner.starts.last.arguments,
        contains(cache.resolveSymbolicLinksSync()));
  });

  test('denying directories does not install an ordinary command rule',
      () async {
    final policy = PermissionPolicy();
    await run([input()], (_) async => PermissionResponse.denyAlways,
        policy: policy);
    expect(policy.sessionRules, isEmpty);
    expect(inner.starts, isEmpty);
    expect(runner.accessPolicy.writablePaths, isEmpty);
  });

  test('static command deny cannot be overridden by a directory approval',
      () async {
    await run([input()], (_) async => fail('must not ask'),
        policy: PermissionPolicy(rules: const [
          PermissionRule(
              toolName: 'bash',
              pattern: '*',
              decision: PermissionDecision.deny),
        ]));
    expect(inner.starts, isEmpty);
  });

  test('cancellation during approval neither executes nor remembers grants',
      () async {
    final cancel = Completer<void>();
    await run([input()], (_) async {
      cancel.complete();
      await Future<void>.delayed(Duration.zero);
      return PermissionResponse.allowAlways;
    }, cancelSignal: cancel.future);
    expect(inner.starts, isEmpty);
    expect(runner.accessPolicy.writablePaths, isEmpty);
  });

  test('direct execute cannot bypass the access gate', () async {
    final result = await bash.execute(input());
    expect(result.isError, isTrue);
    expect(result.content, contains('explicit user approval'));
    expect(inner.starts, isEmpty);
  });

  test('concurrent invocation cannot see another invocation once grant',
      () async {
    final request = bash.requestAccess(input())!;
    final invocation = bash.withApprovedAccess(request, remember: false);
    final results = await Future.wait([
      invocation.execute(input()),
      bash.execute(input()),
      bash.execute({'command': 'echo normal'}),
    ]);
    expect(results.map((r) => r.isError), [false, true, false]);
    expect(
        inner.starts.where((call) =>
            call.arguments.contains(cache.resolveSymbolicLinksSync())),
        hasLength(1));
  });

  test('invalid paths and reasons fail before approval or execution', () async {
    for (final fields in [
      {'writablePaths': 'bad'},
      {
        'writablePaths': [42]
      },
      {'writablePaths': null},
      {
        'writablePaths': ['relative']
      },
      {
        'writablePaths': ['/']
      },
      {
        'writablePaths': ['${temp.path}/missing']
      },
      {
        'writablePaths': ['${cache.path}\nspoof']
      },
      {'accessReason': ''},
      {'accessReason': 'line\nspoof'},
    ]) {
      final history = await run([
        {...input(), ...fields}
      ], (_) async => fail('invalid input must not ask'));
      final result =
          history.expand((m) => m.content).whereType<ToolResultBlock>().single;
      expect(result.isError, isTrue, reason: '$fields');
    }
    expect(inner.starts, isEmpty);
  });

  test('retargeting an approved canonical directory fails closed', () async {
    final original = cache.path;
    final moved = '${cache.path}-moved';
    final other = Directory('${temp.path}/other')..createSync();
    final history = await run([input()], (_) async {
      cache.renameSync(moved);
      Link(original).createSync(other.path);
      return PermissionResponse.allowAlways;
    });
    expect(
        history
            .expand((m) => m.content)
            .whereType<ToolResultBlock>()
            .single
            .content,
        contains('Approved writable directory changed'));
    expect(inner.starts, isEmpty);
    expect(runner.accessPolicy.writablePaths, isEmpty);
  });

  test('symlinks are displayed canonically and descendant grants stay narrow',
      () {
    final link = Link('${temp.path}/alias')..createSync(cache.path);
    final request = bash.requestAccess({
      ...input(),
      'writablePaths': [link.path]
    })!;
    expect(request.paths, [cache.resolveSymbolicLinksSync()]);
    runner.accessPolicy.grantForSession(request);
    expect(runner.accessPolicy.allows('${cache.path}/child'), isTrue);
    expect(runner.accessPolicy.allows('${cache.path}-sibling'), isFalse);
    expect(runner.accessPolicy.allows(temp.path), isFalse);
  });

  test('a removed session directory is revoked and can be requested again', () {
    final path = cache.resolveSymbolicLinksSync();
    runner.accessPolicy.grantForSession(SandboxAccessRequest([path], 'cache'));
    cache.renameSync('${cache.path}-old');
    expect(runner.accessPolicy.writablePaths, isEmpty);
    cache.createSync();
    expect(bash.requestAccess(input())!.paths, [path]);
  });

  test('a retargeted session directory never grants access to the new target',
      () {
    final path = cache.resolveSymbolicLinksSync();
    runner.accessPolicy.grantForSession(SandboxAccessRequest([path], 'cache'));
    cache.renameSync('${cache.path}-old');
    final other = Directory('${temp.path}/other')..createSync();
    Link(path).createSync(other.path);
    expect(runner.accessPolicy.writablePaths, isEmpty);
    expect(
        bash.requestAccess(input())!.paths, [other.resolveSymbolicLinksSync()]);
  });

  test('read-only project inside temp still needs explicit access', () {
    final confined = BashTool(
        processRunner: SandboxedProcessRunner(
            projectRoot: temp.path,
            sandboxReadOnly: true,
            backend: SandboxBackend.bwrap));
    expect(confined.requestAccess(input()), isNotNull);
  });

  test('macOS receives the same invocation-only grant', () async {
    final mac = SandboxedProcessRunner(
        projectRoot: temp.path,
        inner: inner,
        backend: SandboxBackend.sandboxExec,
        accessPolicy: SandboxAccessPolicy());
    final request =
        SandboxAccessRequest([cache.resolveSymbolicLinksSync()], 'cache');
    await mac.withApprovedAccess(request, remember: false).run('true', []);
    expect(inner.runs.single.arguments[1],
        contains('(subpath "${cache.resolveSymbolicLinksSync()}")'));
    expect(mac.accessPolicy.writablePaths, isEmpty);
  });

  test('sandbox failures offer access request guidance without retrying',
      () async {
    inner = MemoryProcessRunner((_, __) => MemoryRunningProcess(
        stderrChunks: ['Read-only file system'], exitCodeValue: 1));
    final tool = BashTool(
        processRunner: SandboxedProcessRunner(
            projectRoot: temp.path,
            inner: inner,
            backend: SandboxBackend.bwrap));
    final result = await tool.execute({'command': 'echo test'});
    expect(result.content, contains('writablePaths'));
    expect(result.content, contains('partial effects'));
    expect(inner.starts, hasLength(1));
  });

  test('Linux actually confines writes before and after a once grant',
      () async {
    final native =
        SandboxedProcessRunner(projectRoot: temp.path, sandboxReadOnly: true);
    final path = cache.resolveSymbolicLinksSync();
    final args = ['-c', 'echo written > "$path/probe"'];
    expect((await native.run('/bin/sh', args)).exitCode, isNot(0));
    final invocation = native.withApprovedAccess(
        SandboxAccessRequest([path], 'write test'),
        remember: false);
    expect((await invocation.run('/bin/sh', args)).exitCode, 0);
    expect(File('$path/probe').readAsStringSync(), 'written\n');
    expect((await native.run('/bin/sh', args)).exitCode, isNot(0));
  },
      skip:
          !bwrapAvailable ? 'requires Linux bwrap and user namespaces' : false);
}

class _Provider extends LlmProvider {
  final List<Map<String, dynamic>> calls;
  bool sent = false;
  _Provider(this.calls) : super('scripted');

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    if (sent) {
      yield const MessageComplete(
          content: [TextBlock('done')], stopReason: 'end_turn');
    } else {
      sent = true;
      yield MessageComplete(content: [
        for (var i = 0; i < calls.length; i++)
          ToolUseBlock(id: 'u$i', name: 'bash', input: calls[i]),
      ], stopReason: 'tool_use');
    }
  }
}
