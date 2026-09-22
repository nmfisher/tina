import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_tool.dart';
import '../helpers/fake_provider.dart';
import '../helpers/agent_test_fixtures.dart';
import '../helpers/memory_process_runner.dart';

class Check extends ToolCheck {
  final Future<String?> Function(ToolCheckContext) work;
  @override
  final Duration timeout;
  @override
  String get id => 'test';
  Check(this.work, {this.timeout = const Duration(seconds: 5)});
  @override
  Future<String?> check(ToolCheckContext context) => work(context);
}

void main() {
  late FakeTool tool;
  late PermissionPolicy policy;
  late Completer<void> stop;
  late int executed;
  setUp(() {
    executed = 0;
    tool = FakeTool('fake', (_) async {
      executed++;
      return const ToolResult('ran');
    });
    policy = PermissionPolicy(defaults: {'fake': PermissionDecision.allow});
    stop = Completer<void>();
  });

  Future<ToolCallOutcome> run(List<ToolCheck> checks) => ToolExecutor(
        policy: policy,
        asker: (_) async => PermissionResponse.allowOnce,
        sink: FakeAgentSink(),
        state: ToolCallState(),
        cancelSignal: stop.future,
        toolChecks: checks,
      ).execute(
        use: const ToolUseBlock(id: 'call', name: 'fake', input: {
          'nested': {'value': 1}
        }),
        stepTools: ToolRegistry([tool]).forStep(),
        step: 0,
        isCancelled: () => stop.isCompleted,
      );

  test('awaited checks see sealed input; first block prevents execution',
      () async {
    final entered = Completer<void>();
    final release = Completer<String?>();
    var second = false;
    final pending = run([
      Check((context) {
        expect(() => (context.input['nested'] as Map)['value'] = 2,
            throwsUnsupportedError);
        expect(context.outsideSandbox, isFalse);
        entered.complete();
        return release.future;
      }),
      Check((_) async {
        second = true;
        return null;
      }),
    ]);
    await entered.future;
    expect(executed, 0);
    release.complete('blocked');
    await pending;
    expect(executed, 0);
    expect(second, isFalse);
  });

  test('pass executes once; no contributions preserve dispatch', () async {
    await run([Check((_) async => null)]);
    await run([]);
    expect(executed, 2);
  });

  test('permission changes during a check are rechecked before dispatch',
      () async {
    await run([
      Check((_) async {
        policy.mode = PermissionMode.readAll;
        return null;
      })
    ]);
    expect(executed, 0);
  });

  test(
      'cancel releases an uncooperative check and late success cannot dispatch',
      () async {
    final entered = Completer<ToolCheckContext>();
    final release = Completer<String?>();
    final pending = run([
      Check((context) {
        entered.complete(context);
        return release.future;
      })
    ]);
    final context = await entered.future;
    stop.complete();
    await pending.timeout(const Duration(seconds: 1));
    await context.cancelSignal;
    release.complete(null);
    await pumpEventQueue();
    expect(executed, 0);
  });

  test('timeout and exceptions block and close the check lifetime', () async {
    ToolCheckContext? context;
    await run([
      Check((value) {
        context = value;
        return Completer<String?>().future;
      }, timeout: const Duration(milliseconds: 10))
    ]);
    await context!.cancelSignal;
    await run([Check((_) async => throw StateError('failure'))]);
    expect(executed, 0);
  });

  test('a mounted check reaches the delegated driver and agent executor',
      () async {
    var checked = 0;
    final scheduler = testScheduler(ProviderRegistry(env: const {}),
        pipeline: defaultTestPipeline);
    scheduler.mountScopeContributions(toolChecks: [
      Check((_) async {
        checked++;
        return 'blocked by check';
      })
    ]);
    addTearDown(scheduler.dispose);
    final driver = scheduler.driverFor(AgentDriverRequest(
      provider: FakeProvider([
        [
          const MessageComplete(
              content: [ToolUseBlock(id: 'call', name: 'fake', input: {})],
              stopReason: 'tool_use')
        ],
        answerEvents('done'),
      ]),
      tools: ToolRegistry([tool]),
      sink: FakeAgentSink(),
      policy: policy,
      asker: (_) async => PermissionResponse.allowOnce,
      maxSteps: 3,
      budget: null,
      pauseGate: null,
      system: 'test',
    ));
    await driver.run(history: [], userInput: 'go');
    expect(checked, 1);
    expect(executed, 0);
  });

  test('outside-sandbox retry runs checks again with the prepared request',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina_check_retry_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final cache = Directory('${dir.path}/cache')..createSync();
    final inner = MemoryProcessRunner((_, __) => MemoryRunningProcess(
          exitCodeValue: 1,
          stderrChunks: [
            '/sdk/update_engine_version.sh: line 71: ${cache.path}/engine.stamp.tmp.42: Read-only file system\n'
          ],
        ));
    final runner = SandboxedProcessRunner(
        workspaceRoot: dir.path,
        inner: inner,
        backend: SandboxBackend.bwrap,
        accessPolicy: SandboxAccessPolicy());
    final seen = <bool>[];
    final executor = ToolExecutor(
      policy: PermissionPolicy(defaults: {'bash': PermissionDecision.allow}),
      asker: (_) async => PermissionResponse.allowOnce,
      sink: FakeAgentSink(),
      state: ToolCallState(),
      toolChecks: [
        Check((context) async {
          seen.add(context.outsideSandbox);
          expect(context.execution!.workingDirectory,
              dir.resolveSymbolicLinksSync());
          expect(context.execution!.arguments.last, 'dart test');
          return context.outsideSandbox ? 'blocked retry' : null;
        })
      ],
    );
    await executor.execute(
      use: const ToolUseBlock(
          id: 'call', name: 'bash', input: {'command': 'dart test'}),
      stepTools:
          ToolRegistry([BashTool(workspaceRoot: dir.path, processRunner: runner)])
              .forStep(),
      step: 0,
      isCancelled: () => false,
    );
    expect(seen, [false, true]);
    expect(inner.starts, hasLength(1));
  });

  test('removing an earlier check while a later check waits prevents dispatch',
      () async {
    final scope = PluginScope('checks');
    final plugin = PluginContext(
        plugin: PluginDescriptor(
            id: 'test', factory: FnPluginFactory((_) => Object())),
        scope: scope);
    final registration = plugin.register(Check((_) async => null), id: 'first');
    plugin.register(Check((_) async {
      await registration.dispose();
      return null;
    }), id: 'second');
    await run(toolChecksFromScope(scope));
    expect(executed, 0);
    await scope.dispose();
  });

  test('removing a plugin during a check blocks the pending dispatch',
      () async {
    final scope = PluginScope('checks');
    final context = PluginContext(
        plugin: PluginDescriptor(
            id: 'test', factory: FnPluginFactory((_) => Object())),
        scope: scope);
    final entered = Completer<void>();
    final registration = context.register(Check((_) {
      entered.complete();
      return Completer<String?>().future;
    }), id: 'check');
    final pending = run(toolChecksFromScope(scope));
    await entered.future;
    await registration.dispose();
    await pending.timeout(const Duration(seconds: 1));
    expect(executed, 0);
    await scope.dispose();
  });
}
