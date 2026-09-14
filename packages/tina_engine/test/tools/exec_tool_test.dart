import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/memory_process_runner.dart';

void main() {
  test('direct arguments are literal and stdout/stderr/status are preserved',
      () async {
    final result = await ExecTool().execute({
      'executable': '/usr/bin/printf',
      'args': ['%s', r'$HOME; echo success | cat'],
    }) as ProcessToolResult;
    expect(result.exitCode, 0);
    expect(result.shell, false);
    expect(result.content, contains(r'$HOME; echo success | cat'));
    final failed = await ExecTool().execute({
      'executable': '/bin/sh',
      'args': ['-c', 'echo out; echo err >&2; exit 69'],
    }) as ProcessToolResult;
    expect(failed.exitCode, 69);
    expect(failed.isError, true);
    expect(failed.content, contains('stderr:\nerr'));
  });

  test('effective environment is a detached snapshot, with literal overrides',
      () async {
    final env = {
      'PATH': '/usr/bin:/bin',
      'HOME': '/original',
      'PUB_CACHE': '/original/cache'
    };
    final tool = ExecTool(environment: env);
    env['PUB_CACHE'] = '/changed';
    final result = await tool.execute({
      'executable': 'printenv',
      'args': ['HOME', 'PUB_CACHE'],
      'environment': {'PUB_CACHE': '/explicit/cache'}
    });
    expect(result.isError, false);
    expect(result.content, contains('/original\n/explicit/cache'));
    expect(result.content, isNot(contains('/changed')));
  });

  test('cancellation uses the shared process lifecycle', () async {
    final proc = MemoryRunningProcess(hangUntilKilled: true);
    final cancel = Completer<void>();
    final run = ExecTool(processRunner: MemoryProcessRunner.always(proc))
        .execute({'executable': '/bin/sh'}, cancelSignal: cancel.future);
    cancel.complete();
    final result = await run as ProcessToolResult;
    expect(result.cancelled, true);
    expect(result.isError, true);
    expect(proc.killed, true);
  });

  test('approval seals argv, cwd, and environment before awaiting the user',
      () async {
    final input = <String, dynamic>{
      'executable': '/usr/bin/printenv',
      'args': ['TINA_EXEC_TEST'],
      'environment': {'TINA_EXEC_TEST': 'approved'}
    };
    final sink = FakeAgentSink();
    final history = <Message>[];
    await Agent(
        provider: _Provider([input]),
        tools: ToolRegistry([ExecTool()]),
        sink: sink,
        system: 'test',
        policy: PermissionPolicy(),
        asker: (prompt) async {
          expect(prompt.execution!.environment['TINA_EXEC_TEST'], 'approved');
          expect(prompt.execution!.workingDirectory, Directory.current.path);
          expect(() => prompt.execution!.arguments.add('bad'),
              throwsUnsupportedError);
          (input['environment'] as Map)['TINA_EXEC_TEST'] = 'changed';
          (input['args'] as List).add('HOME');
          return PermissionResponse.allowOnce;
        }).run(history: history, userInput: 'run');
    final result =
        history.expand((m) => m.content).whereType<ToolResultBlock>().single;
    expect(result.content, contains('approved'));
    expect(result.content, isNot(contains('changed')));
  });

  test('read-all rejects exec even with remembered allow; schemas stay stable',
      () {
    final policy = PermissionPolicy()
      ..remember('exec', '*', PermissionDecision.allow);
    final scope = ProjectToolScope.unconfined();
    final before = jsonEncode(scope
        .buildTools()
        .schemas
        .map((s) => [s.name, s.description, s.inputSchema])
        .toList());
    policy.mode = PermissionMode.readAll;
    expect(policy.check('exec', {'executable': '/bin/sh'}),
        PermissionDecision.deny);
    expect(policy.check('execution_info', {}), PermissionDecision.allow);
    expect(
        jsonEncode(scope
            .buildTools()
            .schemas
            .map((s) => [s.name, s.description, s.inputSchema])
            .toList()),
        before);
    expect(scope.buildTools(safeMode: true)['exec'], isNull);
  });

  test('remembered exec approval is exact, including cwd and environment', () {
    final policy = PermissionPolicy();
    final input = <String, dynamic>{
      'executable': 'dart',
      'args': ['test', '*'],
      'cwd': '/project',
      'environment': {'PUB_CACHE': '/cache'}
    };
    policy.remember(
        'exec',
        PermissionPolicy.defaultAlwaysPatternFor('exec', input),
        PermissionDecision.allow);
    expect(policy.check('exec', input), PermissionDecision.allow);
    expect(
        policy.check('exec', {
          ...input,
          'args': ['test', 'anything']
        }),
        PermissionDecision.ask);
    expect(policy.check('exec', {...input, 'cwd': '/other'}),
        PermissionDecision.ask);
    expect(
        policy.check('exec', {
          ...input,
          'environment': {'PUB_CACHE': '/other'}
        }),
        PermissionDecision.ask);
  });

  test(
      'diagnostics distinguish failed dependency/network from masked shell status',
      () {
    expect(
        diagnoseExecution(
                output: 'Got socket error trying to find package test',
                exitCode: 69,
                shell: false)
            .single
            .kind,
        ExecutionDiagnosticKind.network);
    expect(
        diagnoseExecution(
                output: 'version solving failed.', exitCode: 69, shell: false)
            .single
            .kind,
        ExecutionDiagnosticKind.dependency);
    expect(
        diagnoseExecution(output: 'exit: 69', exitCode: 0, shell: true)
            .single
            .kind,
        ExecutionDiagnosticKind.nestedFailure);
    expect(diagnoseExecution(output: 'exit: 69', exitCode: 0, shell: false),
        isEmpty);
  });

  test(
      'execution_info omits secrets and reports cache location without granting it',
      () async {
    final info = ExecutionInfoTool(
        projectRoot: Directory.current.path,
        environment: {'HOME': '/home/test', 'API_KEY': 'secret-value'},
        runner: SandboxedProcessRunner(
            projectRoot: Directory.current.path,
            backend: SandboxBackend.bwrap,
            accessPolicy: SandboxAccessPolicy()));
    final result = await info.execute({});
    final data = jsonDecode(result.content) as Map;
    expect(data['pubCache'], '/home/test/.pub-cache');
    expect(data['writableDirectories'], isEmpty);
    expect(result.content, isNot(contains('secret-value')));
    expect(result.content, isNot(contains('API_KEY')));
  });

  for (final remember in [false, true]) {
    test(
        'exec directory approval shares only session grants (remember=$remember)',
        () async {
      final temp = Directory.systemTemp.createTempSync('tina-exec-grant-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final cache = Directory('${temp.path}/cache')..createSync();
      final inner = MemoryProcessRunner(
          (_, __) => MemoryRunningProcess(stdoutChunks: ['ok']));
      final runner = SandboxedProcessRunner(
          projectRoot: temp.path,
          inner: inner,
          backend: SandboxBackend.bwrap,
          accessPolicy: SandboxAccessPolicy());
      final tool = ExecTool(processRunner: runner, projectRoot: temp.path);
      final sibling = ExecTool(processRunner: runner, projectRoot: temp.path);
      final input = <String, dynamic>{
        'executable': '/bin/sh',
        'args': ['-c', 'true'],
        'writablePaths': [cache.path],
        'accessReason': 'update cache'
      };
      var asks = 0;
      await Agent(
          provider: _Provider([input]),
          tools: ToolRegistry([tool]),
          sink: FakeAgentSink(),
          system: 'test',
          policy: PermissionPolicy(allowAllByDefault: true),
          asker: (prompt) async {
            asks++;
            expect(prompt.sandboxAccess!.paths,
                [cache.resolveSymbolicLinksSync()]);
            expect(sibling.requestAccess(input), isNotNull,
                reason: 'pending grants cannot leak');
            return remember
                ? PermissionResponse.allowAlways
                : PermissionResponse.allowOnce;
          }).run(history: [], userInput: 'run');
      expect(asks, 1,
          reason: 'command allow does not waive directory approval');
      expect(inner.starts, hasLength(1));
      expect(runner.accessPolicy.allows(cache.path), remember);
      expect(sibling.requestAccess(input) == null, remember);
    });
  }

  test(
      'exec recovery requires assessment and a new explicit approval; denial stops retries',
      () async {
    final temp = Directory.systemTemp.createTempSync('tina-exec-retry-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final cache = Directory('${temp.path}/cache')..createSync();
    final inner = MemoryProcessRunner((_, __) => MemoryRunningProcess(
        exitCodeValue: 1,
        stderrChunks: ['${cache.path}/stamp: Read-only file system\n']));
    final tool = ExecTool(
        projectRoot: temp.path,
        processRunner: SandboxedProcessRunner(
            projectRoot: temp.path,
            inner: inner,
            backend: SandboxBackend.bwrap,
            accessPolicy: SandboxAccessPolicy()));
    final input = <String, dynamic>{
      'executable': '/bin/sh',
      'args': ['-c', 'true']
    };
    final retry = {
      ...input,
      'retrySafety': 'Inspected output; setup failed before tests began.'
    };
    var asks = 0;
    final history = <Message>[];
    await Agent(
        provider: _Provider([input, input, retry, retry]),
        tools: ToolRegistry([tool]),
        sink: FakeAgentSink(),
        system: 'test',
        policy: PermissionPolicy(allowAllByDefault: true),
        asker: (prompt) async {
          asks++;
          expect(prompt.retryExplanation, contains('${cache.path}/stamp'));
          expect(prompt.retrySafety, retry['retrySafety']);
          return PermissionResponse.denyOnce;
        }).run(history: history, userInput: 'run');
    expect(asks, 1);
    expect(inner.starts, hasLength(1));
    final results =
        history.expand((m) => m.content).whereType<ToolResultBlock>().toList();
    expect(results[1].content, contains('retrySafety'));
    expect(results.last.content, contains('user denied this sandbox retry'));
  });

  test('changing mode while exec approval is pending prevents execution',
      () async {
    final inner = MemoryProcessRunner((_, __) => MemoryRunningProcess());
    final policy = PermissionPolicy();
    await Agent(
        provider: _Provider([
          {'executable': '/bin/sh'}
        ]),
        tools: ToolRegistry([ExecTool(processRunner: inner)]),
        sink: FakeAgentSink(),
        system: 'test',
        policy: policy,
        asker: (_) async {
          policy.mode = PermissionMode.readAll;
          return PermissionResponse.allowAlways;
        }).run(history: [], userInput: 'run');
    expect(inner.starts, isEmpty);
    expect(policy.sessionRules, isEmpty);
  });
}

class _Provider extends LlmProvider {
  final List<Map<String, dynamic>> steps;
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
      yield MessageComplete(content: [
        ToolUseBlock(id: 'e${index++}', name: 'exec', input: steps[index - 1])
      ], stopReason: 'tool_use');
    }
  }
}
