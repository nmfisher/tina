// The eight required scenarios, one `group` each. The scripted provider
// plays back responses; tests assert on the recorded requests.
//
// Run: dart test
library;

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import '../example/example_plugins.dart';

Tool _tool(String name) =>
    Tool(name, 'test tool $name', {'type': 'object', 'properties': {}});

AgentPlugin _plugin(String id,
        {int order = 100,
        List<Tool> tools = const [],
        String? Function(Context)? section}) =>
    _P(id, order, tools, section);

final class _P extends AgentPlugin {
  _P(this.id, this.order, this.tools, this.section);
  @override
  final String id;
  @override
  final int order;
  @override
  final List<Tool> tools;
  final String? Function(Context)? section;
  @override
  String? systemSection(Context c) => section?.call(c);
}

void main() {
  group('1. single input -> tool call -> result -> completion', () {
    test('appends user, reply, result, final reply; stops complete', () async {
      final provider = ScriptedProvider([
        ProviderResponse(toolCalls: [
          ToolCall('c1', 'echo', {'text': 'hi'})
        ]),
        ProviderResponse(text: 'all done'),
      ]);
      final loop = AgentLoop(
          provider: provider, plugins: [const ToolProviderPlugin()]);
      loop.registerExecutor(
          'echo', (args) async => args['text']?.toString() ?? '');

      final outcome = await loop.runTurn(const Input('hello', id: 'i1'));

      expect(outcome.stopReason, StopReason.complete);
      expect(outcome.detail, 'all done');
      expect(provider.callCount, 2);
      final kinds = [for (final m in outcome.messages) m.kind];
      expect(kinds, [
        MessageKind.user,
        MessageKind.assistant,
        MessageKind.toolResult,
        MessageKind.assistant
      ]);
      expect(outcome.messages[2].result!.callId, 'c1');
      expect(outcome.messages[2].result!.ok, isTrue);
      // Pairing visible in the second request: user, reply, result.
      final second = provider.requests[1];
      expect(second.messages[2].kind, MessageKind.toolResult);
    });
  });

  group('2. multi-step: two tool rounds then stop', () {
    test('loops until the model asks for no tools', () async {
      final provider = ScriptedProvider([
        ProviderResponse(toolCalls: [ToolCall('c1', 't1', {})]),
        ProviderResponse(toolCalls: [ToolCall('c2', 't2', {})]),
        ProviderResponse(text: 'finished'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _plugin('a', tools: [_tool('t1')]),
        _plugin('b', tools: [_tool('t2')]),
      ]);
      loop
        ..registerExecutor('t1', (_) async => 'one')
        ..registerExecutor('t2', (_) async => 'two');

      final outcome = await loop.runTurn(const Input('go', id: 'i2'));

      expect(outcome.stopReason, StopReason.complete);
      expect(provider.callCount, 3);
      final results = [
        for (final m in outcome.messages)
          if (m.kind == MessageKind.toolResult) m.result!
      ];
      expect([for (final r in results) r.toolName], ['t1', 't2']);
    });
  });

  group('3. ordering: sections and transforms run in order', () {
    test('sections ascending by (order, id), core joins with blank lines',
        () async {
      final provider = ScriptedProvider([ProviderResponse(text: 'ok')]);
      final loop = AgentLoop(provider: provider, plugins: [
        _plugin('b.late', section: (_) => 'LATE'),
        _plugin('a.early', section: (_) => 'EARLY'),
        _plugin('m.mid', order: 10, section: (_) => 'MID'),
      ]);
      await loop.runTurn(const Input('x', id: 'i3'));

      final prompt = provider.requests.first.systemPrompt;
      expect(
          prompt,
          'You are tina, a terminal coding agent.\n\n'
          'MID\n\n'
          'EARLY\n\n'
          'LATE');
    });

    test('request transforms run in order and compose', () async {
      final provider = ScriptedProvider([ProviderResponse(text: 'ok')]);
      final loop = AgentLoop(provider: provider, plugins: [
        const RequestTransformerPlugin(suffix: '|2nd', /* order 300 */),
        _T('z.first-transform', order: 1, mark: '|1st'),
      ]);
      await loop.runTurn(const Input('x', id: 'i3b'));

      // order 1 runs before order 300, so |1st lands before |2nd.
      expect(provider.requests.first.systemPrompt, endsWith('|1st|2nd'));
    });
  });

  group('4. guard: deny blocks execution, result recorded', () {
    test('denied call never runs; pairing kept; reason recorded', () async {
      final provider = ScriptedProvider([
        ProviderResponse(toolCalls: [ToolCall('c1', 'rm_rf', {})]),
        ProviderResponse(text: 'fine'),
      ]);
      final ran = <String>[];
      final loop = AgentLoop(
          provider: provider,
          plugins: [
            const GuardPlugin('rm_rf', reason: 'too dangerous'),
            _plugin('owner', tools: [_tool('rm_rf')]),
          ]);
      loop.registerExecutor('rm_rf', (_) async {
        ran.add('ran!');
        return '';
      });

      final outcome = await loop.runTurn(const Input('do it', id: 'i4'));

      expect(ran, isEmpty);
      expect(outcome.stopReason, StopReason.complete);
      final result = outcome.messages
          .firstWhere((m) => m.kind == MessageKind.toolResult)
          .result!;
      expect(result.ok, isFalse);
      expect(result.content, contains('denied'));
      expect(result.meta['deniedBy'], 'example.guard');
    });

    test('ask with no UI resolves to deny, recorded as ask-unresolved',
        () async {
      final provider = ScriptedProvider([
        ProviderResponse(toolCalls: [ToolCall('c1', 't', {})]),
        ProviderResponse(text: 'ok'),
      ]);
      final ran = <String>[];
      final loop = AgentLoop(provider: provider, plugins: [
        _Ask('asker'),
        _plugin('owner', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async {
        ran.add('ran!');
        return '';
      });

      final outcome = await loop.runTurn(const Input('x', id: 'i4b'));

      expect(ran, isEmpty);
      final result = outcome.messages
          .firstWhere((m) => m.kind == MessageKind.toolResult)
          .result!;
      expect(result.meta['denied'], 'ask-unresolved');
    });
  });

  group('5. plugin throws: turn continues, contribution absent', () {
    test('throwing guard is ignored; tool runs; section omitted', () async {
      final provider = ScriptedProvider([
        ProviderResponse(toolCalls: [ToolCall('c1', 't', {})]),
        ProviderResponse(text: 'done'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _Throw('bad.guard', throwIn: 'beforeTool'),
        _Throw('bad.section', throwIn: 'systemSection'),
        _plugin('owner', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async => 'ran');

      final outcome = await loop.runTurn(const Input('x', id: 'i5'));

      expect(outcome.stopReason, StopReason.complete);
      final result = outcome.messages
          .firstWhere((m) => m.kind == MessageKind.toolResult)
          .result!;
      expect(result.ok, isTrue);
      expect(provider.requests.first.systemPrompt, isNot(contains('BOOM')));
    });

    test('throwing beforeInvocation / beforeRequest / onTurnEnd isolated',
        () async {
      final provider = ScriptedProvider([ProviderResponse(text: 'done')]);
      final loop = AgentLoop(provider: provider, plugins: [
        _Throw('bad.invocation', throwIn: 'beforeInvocation'),
        _Throw('bad.request', throwIn: 'beforeRequest'),
        _Throw('bad.end', throwIn: 'onTurnEnd'),
      ]);
      final outcome = await loop.runTurn(const Input('original', id: 'i5b'));

      expect(outcome.stopReason, StopReason.complete);
      expect(outcome.messages.first.text, 'original');
      expect(provider.requests.first.systemPrompt, isNot(contains('|BOOM')));
    });
  });

  group('6. cancellation: stops promptly, records why', () {
    test('cancel before the turn -> no model call', () async {
      final provider = ScriptedProvider([]);
      final loop = AgentLoop(provider: provider, plugins: []);
      loop.cancel('user said stop');

      final outcome = await loop.runTurn(const Input('x', id: 'i6a'));

      expect(outcome.stopReason, StopReason.cancelled);
      expect(provider.callCount, 0);
      expect(outcome.detail, contains('user said stop'));
    });

    test('cancel from a plugin mid-turn -> stops before next model call',
        () async {
      final provider = ScriptedProvider([
        ProviderResponse(toolCalls: [ToolCall('c1', 't', {})]),
        ProviderResponse(text: 'never reached'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _CancelFromTool('canceller'),
        _plugin('owner', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async => 'ran');

      final outcome = await loop.runTurn(const Input('x', id: 'i6b'));

      expect(outcome.stopReason, StopReason.cancelled);
      expect(provider.callCount, 1);
      expect(outcome.detail, contains('plugin-cancelled'));
    });
  });

  group('7. plugin removal: pending call skipped, turn continues', () {
    test('removed plugin tool -> skipped result, then completion', () async {
      final provider = ScriptedProvider([
        ProviderResponse(toolCalls: [ToolCall('c1', 't', {})]),
        ProviderResponse(text: 'done'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        _plugin('vanishing', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async => 'ran');
      // Remove from a hook, mid-turn — the brief's liveness rule is about a
      // plugin leaving while its pending call is in flight. The remover has
      // order 1, so it removes before the vanishing tool runs.
      loop.addPlugin(_Remover('remover', order: 1, loop: loop,
          target: 'vanishing'));

      final outcome = await loop.runTurn(const Input('x', id: 'i7'));

      expect(outcome.stopReason, StopReason.complete);
      final result = outcome.messages
          .firstWhere((m) => m.kind == MessageKind.toolResult)
          .result!;
      expect(result.ok, isFalse);
      expect(result.content, contains('plugin vanishing left'));
    });
  });

  group('8. invariants: snapshots, pairing, pinning, duplicate ids', () {
    test('plugin mutation of a snapshot does not touch the transcript',
        () async {
      final provider = ScriptedProvider([ProviderResponse(text: 'ok')]);
      final loop = AgentLoop(provider: provider, plugins: [_Mutate('mutator')]);
      await loop.runTurn(const Input('keep me', id: 'i8a'));

      final seen = provider.requests.first.messages;
      expect(seen.first.text, 'keep me');
      expect(seen.first.kind, MessageKind.user);
    });

    test('every tool_use gets a matching tool_result, denied included',
        () async {
      final provider = ScriptedProvider([
        ProviderResponse(toolCalls: [
          ToolCall('c1', 'denied-tool', {}),
          ToolCall('c2', 'good', {}),
        ]),
        ProviderResponse(text: 'done'),
      ]);
      final loop = AgentLoop(provider: provider, plugins: [
        const GuardPlugin('denied-tool'),
        _plugin('owner', tools: [_tool('denied-tool'), _tool('good')]),
      ]);
      loop.registerExecutor('good', (_) async => 'ran');

      final outcome = await loop.runTurn(const Input('x', id: 'i8b'));

      final calls = provider.requests.first.tools;
      expect([for (final t in calls) t.name], containsAll(['denied-tool']));
      final results = [
        for (final m in outcome.messages)
          if (m.kind == MessageKind.toolResult) m.result!
      ];
      expect([for (final r in results) r.callId], ['c1', 'c2']);
      expect(results[0].ok, isFalse);
      expect(results[1].ok, isTrue);
    });

    test('pinned tools stay stable; mid-turn change rejects the turn',
        () async {
      final provider = ScriptedProvider([
        ProviderResponse(toolCalls: [ToolCall('c1', 't', {})]),
        ProviderResponse(text: 'done'),
      ]);
      final shifter = _Shift('shifter');
      final loop = AgentLoop(provider: provider, plugins: [
        shifter,
        _plugin('owner', tools: [_tool('t')]),
      ]);
      loop.registerExecutor('t', (_) async => 'ran');
      // Shift from inside a hook, mid-turn: the pinning invariant is about
      // the set changing while the turn is running.
      loop.addPlugin(_ShiftOnCall('shifter-trigger', shifter));

      final outcome = await loop.runTurn(const Input('x', id: 'i8c'));

      expect(outcome.stopReason, StopReason.error);
      expect(outcome.detail, 'tools-changed mid-turn');
    });

    test('duplicate plugin id throws at registration', () {
      final loop = AgentLoop(
          provider: ScriptedProvider([]), plugins: [_plugin('dup')]);
      expect(() => loop.addPlugin(_plugin('dup')), throwsArgumentError);
    });
  });
}

/// A guard that asks (no UI in this package).
final class _Ask extends AgentPlugin {
  _Ask(this.id);
  @override
  final String id;
  @override
  Decision beforeTool(Context c, ToolCall call) => Decision.ask('unsure');
}

/// Throws in one chosen hook.
final class _Throw extends AgentPlugin {
  _Throw(this.id, {required this.throwIn});
  @override
  final String id;
  final String throwIn;
  Never boom() => throw StateError('BOOM');
  @override
  Input? beforeInvocation(Context c, Input input) =>
      throwIn == 'beforeInvocation' ? boom() : null;
  @override
  String? systemSection(Context c) =>
      throwIn == 'systemSection' ? boom() : null;
  @override
  Request? beforeRequest(Context c, Request request) =>
      throwIn == 'beforeRequest' ? boom() : Request(systemPrompt: '', messages: [], tools: []);
  @override
  Decision beforeTool(Context c, ToolCall call) =>
      throwIn == 'beforeTool' ? boom() : const Decision.allow();
  @override
  void onTurnEnd(Context c, Outcome outcome) {
    if (throwIn == 'onTurnEnd') boom();
  }
}

/// Removes another plugin from `beforeRequest`: the model has asked for the
/// target's tool, but by dispatch time the owner is gone.
final class _Remover extends AgentPlugin {
  _Remover(this.id, {required this.order, required this.loop, required this.target});
  @override
  final String id;
  @override
  final int order;
  final AgentLoop loop;
  final String target;
  @override
  Request? beforeRequest(Context c, Request request) {
    loop.removePlugin(target);
    return null;
  }
}

/// Cancels from `afterTool`.
final class _CancelFromTool extends AgentPlugin {
  _CancelFromTool(this.id);
  @override
  final String id;
  @override
  Object? afterTool(Context c, ToolResult result) {
    c.cancel('plugin-cancelled');
    return null;
  }
}

/// Mutates whatever snapshot it is handed.
final class _Mutate extends AgentPlugin {
  _Mutate(this.id);
  @override
  final String id;
  @override
  Request? beforeRequest(Context c, Request request) {
    request.messages.clear(); // must throw: read-only
    return null;
  }
}

/// Adds a tool when [shiftFromHook] is set.
final class _Shift extends AgentPlugin {
  _Shift(this.id);
  @override
  final String id;
  bool shiftFromHook = false;
  @override
  List<Tool> get tools => shiftFromHook
      ? [_tool('t'), _tool('late-tool')]
      : [_tool('t')];
}

/// Flips the shifter from `beforeTool`, mid-turn.
final class _ShiftOnCall extends AgentPlugin {
  _ShiftOnCall(this.id, this.shifter);
  @override
  final String id;
  final _Shift shifter;
  @override
  Decision beforeTool(Context c, ToolCall call) {
    shifter.shiftFromHook = true;
    return const Decision.allow();
  }
}

/// A request transformer with its own order.
final class _T extends AgentPlugin {
  _T(this.id, {required this.order, required this.mark});
  @override
  final String id;
  @override
  final int order;
  final String mark;
  @override
  Request? beforeRequest(Context c, Request request) => Request(
      systemPrompt: request.systemPrompt + mark,
      messages: request.messages,
      tools: request.tools);
}
