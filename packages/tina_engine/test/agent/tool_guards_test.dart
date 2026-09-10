import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_tool.dart';

void main() {
  group('combineGuardBlocks', () {
    test('runs guards in order and the FIRST non-null block wins', () {
      final first = _ScriptedGuard({'bash': 'first says no'});
      final second = _ScriptedGuard({'bash': 'second says no'});
      final block = combineGuardBlocks(
          [first, second], 'bash', const {'command': 'ls'});
      expect(block, 'first says no');
      // The first guard's denial short-circuits: later guards are not even
      // consulted.
      expect(second.calls, isEmpty);
    });

    test('a later guard runs (and can deny) when earlier guards allow', () {
      final first = _ScriptedGuard(const {});
      final second = _ScriptedGuard({'bash': 'second says no'});
      final block = combineGuardBlocks(
          [first, second], 'bash', const {'command': 'ls'});
      expect(block, 'second says no');
      expect(first.calls, ['bash']);
    });

    test('over an empty guard list returns null (nothing blocks)', () {
      expect(combineGuardBlocks(const [], 'bash', const {'command': 'ls'}),
          isNull);
    });

    test('a throwing guard rejects the call (fail closed)', () {
      final throwing = _ThrowingGuard();
      final after = _ScriptedGuard({'bash': 'never reached'});
      final block = combineGuardBlocks(
          [throwing, after], 'bash', const {'command': 'ls'});
      expect(block, startsWith('execution guard failed:'));
      expect(block, contains('guard exploded'));
      expect(after.calls, isEmpty);
    });
  });

  group('extra execution guard (Agent level)', () {
    test('a guard that denies bash rejects the call: no ask, no execute',
        () async {
      final asked = <PermissionPrompt>[];
      final executed = <String>[];
      final provider = FakeProvider([
        [
          const MessageComplete(
            content: [
              ToolUseBlock(id: 'u1', name: 'bash', input: {'command': 'ls'}),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const TextDelta('done'),
          const MessageComplete(
              content: [TextBlock('done')], stopReason: 'end_turn'),
        ],
      ]);
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('bash', (_) async {
            executed.add('bash');
            return const ToolResult('should not run');
          }),
        ]),
        sink: FakeAgentSink(),
        system: 'sys',
        policy: PermissionPolicy(
            defaults: {'bash': PermissionDecision.allow}),
        asker: (prompt) async {
          asked.add(prompt);
          return PermissionResponse.denyOnce;
        },
        executionGuards: [
          _ScriptedGuard({'bash': 'tool use is frozen this turn'}),
        ],
      );

      final history = <Message>[];
      await agent.run(history: history, userInput: 'go');

      expect(asked, isEmpty,
          reason: 'the guard denies before the permission ask');
      expect(executed, isEmpty, reason: 'the guard denies before execution');
      final blocks = [for (final m in history) ...m.content];
      final result = blocks
          .whereType<ToolResultBlock>()
          .where((b) => b.toolUseId == 'u1')
          .single;
      expect(result.isError, isTrue);
      expect(result.content, 'tool use is frozen this turn');
    });

    test('a policy denial wins over a later extra guard', () async {
      final asked = <PermissionPrompt>[];
      final executed = <String>[];
      // The policy guard's denial comes from the hard mode boundary
      // (executionBlock only blocks in read-all mode).
      final policy = PermissionPolicy(mode: PermissionMode.readAll);
      final guard = _ScriptedGuard({'bash': 'extra guard denies too'});
      final provider = FakeProvider([
        [
          const MessageComplete(
            content: [
              ToolUseBlock(id: 'u1', name: 'bash', input: {'command': 'ls'}),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const TextDelta('done'),
          const MessageComplete(
              content: [TextBlock('done')], stopReason: 'end_turn'),
        ],
      ]);
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('bash', (_) async {
            executed.add('bash');
            return const ToolResult('should not run');
          }),
        ]),
        sink: FakeAgentSink(),
        system: 'sys',
        policy: policy,
        asker: (prompt) async {
          asked.add(prompt);
          return PermissionResponse.denyOnce;
        },
        executionGuards: [guard],
      );

      final history = <Message>[];
      await agent.run(history: history, userInput: 'go');

      expect(executed, isEmpty);
      final blocks = [for (final m in history) ...m.content];
      final result = blocks
          .whereType<ToolResultBlock>()
          .where((b) => b.toolUseId == 'u1')
          .single;
      // FIRST non-null block wins: the policy guard runs before the extra
      // guard, so its denial text (not the guard's) becomes the result — and
      // the extra guard is never consulted.
      expect(result.content, policy.executionBlock('bash', const {
        'command': 'ls',
      }));
      expect(guard.calls, isEmpty);
      expect(asked, isEmpty, reason: 'a static deny never reaches the asker');
    });

    test('a guard that throws rejects the call (fail closed)', () async {
      final asked = <PermissionPrompt>[];
      final executed = <String>[];
      final provider = FakeProvider([
        [
          const MessageComplete(
            content: [
              ToolUseBlock(id: 'u1', name: 'bash', input: {'command': 'ls'}),
            ],
            stopReason: 'tool_use',
          ),
        ],
        [
          const TextDelta('done'),
          const MessageComplete(
              content: [TextBlock('done')], stopReason: 'end_turn'),
        ],
      ]);
      final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('bash', (_) async {
            executed.add('bash');
            return const ToolResult('should not run');
          }),
        ]),
        sink: FakeAgentSink(),
        system: 'sys',
        policy: PermissionPolicy(
            defaults: {'bash': PermissionDecision.allow}),
        asker: (prompt) async {
          asked.add(prompt);
          return PermissionResponse.denyOnce;
        },
        executionGuards: [_ThrowingGuard()],
      );

      final history = <Message>[];
      await agent.run(history: history, userInput: 'go');

      expect(executed, isEmpty,
          reason: 'a broken guard must not skip its check');
      expect(asked, isEmpty);
      final blocks = [for (final m in history) ...m.content];
      final result = blocks
          .whereType<ToolResultBlock>()
          .where((b) => b.toolUseId == 'u1')
          .single;
      expect(result.isError, isTrue);
      expect(result.content, startsWith('execution guard failed:'));
      expect(result.content, contains('guard exploded'));
    });
  });

  group('guard plugins + toolGuardsFromScope', () {
    test('returns contributions in declared registration order', () async {
      final thirdGuard = _ScriptedGuard(const {});
      final runtime = PluginRuntime(
        name: 'guard-plugins',
        plugins: [
          policyGuardPlugin(PermissionPolicy()),
          phaseGuardPlugin(ToolRegistry(const [])),
          PluginDescriptor(
            id: 'tina.guard.third',
            factory: FnPluginFactory((context) {
              context.register(thirdGuard, id: 'tina.guard.third');
              return thirdGuard;
            }),
          ),
        ],
      );
      await runtime.activate();

      final guards = toolGuardsFromScope(runtime.scope);
      expect(guards, hasLength(3));
      expect(guards[0], isA<PolicyToolGuard>());
      expect(guards[1], isA<RegistryPhaseGuard>());
      expect(guards[2], same(thirdGuard));
    });
  });
}

/// A [ToolGuard] denying the tool names in [denials], recording every call.
class _ScriptedGuard implements ToolGuard {
  final Map<String, String> denials;
  final List<String> calls = [];

  _ScriptedGuard(this.denials);

  @override
  String? block(String toolName, Map<String, dynamic> input) {
    calls.add(toolName);
    return denials[toolName];
  }
}

/// A [ToolGuard] that always throws — for the fail-closed path.
class _ThrowingGuard implements ToolGuard {
  final List<String> calls = [];

  @override
  String? block(String toolName, Map<String, dynamic> input) {
    calls.add(toolName);
    throw StateError('guard exploded');
  }
}
