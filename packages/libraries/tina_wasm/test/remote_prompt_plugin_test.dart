import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_wasm/src/remote_prompt_plugin.dart';

final class _HostBridge implements PromptPluginHostBridge {
  var _next = 1;
  final calls = <String, int>{};
  final closed = <String>[];
  Completer<PromptBridgeResult<String>>? pendingResponse;
  bool deny = false;

  @override
  PromptBridgeResult<String> open() {
    final lease = 'lease-${_next++}';
    calls[lease] = 0;
    return PromptBridgeResult<String>.ok(lease);
  }

  @override
  Future<PromptBridgeResult<String>> onPrompt({
    required String lease,
    required String sessionId,
    required String model,
  }) async {
    if (deny || !calls.containsKey(lease)) {
      return const PromptBridgeResult<String>.error(PromptBridgeFailure.denied);
    }
    final run = calls.update(lease, (n) => n + 1);
    final pending = pendingResponse;
    if (pending != null) return pending.future;
    return PromptBridgeResult<String>.ok(
      'plugin session=$sessionId model=$model run=$run',
    );
  }

  @override
  PromptBridgeResult<void> close({required String lease}) {
    if (calls.remove(lease) == null) {
      return const PromptBridgeResult<void>.error(PromptBridgeFailure.denied);
    }
    closed.add(lease);
    return const PromptBridgeResult<void>.ok(null);
  }
}

void main() {
  test(
    'Tina Host applies prompt section, unloads, continues, and reloads fresh',
    () async {
      final bridge = _HostBridge();
      final provider = ScriptedProvider([
        scriptedReply('one'),
        scriptedReply('two'),
        scriptedReply('three'),
        scriptedReply('four'),
      ]);
      final host = Host.start(
        HostConfig(
          model: 'model-a',
          workingDirectory: '.',
          plugins: [RemotePromptPlugin(bridge)],
          providerFactory: (_) => provider,
        ),
        sessionId: 'tina-session-42',
      );
      try {
        await host.send('turn one');
        expect(
          provider.requests[0].systemPrompt,
          contains('plugin session=tina-session-42 model=model-a run=1'),
        );

        host.switchModel('model-b');
        await host.send('turn two');
        expect(
          provider.requests[1].systemPrompt,
          contains('plugin session=tina-session-42 model=model-b run=2'),
        );

        host.detachPlugin(RemotePromptPlugin.pluginId);
        expect(bridge.closed, ['lease-1']);
        await host.send('turn three');
        expect(
          provider.requests[2].systemPrompt,
          isNot(contains('plugin session=')),
        );

        host.attachPlugin(RemotePromptPlugin(bridge));
        await host.send('turn four');
        expect(
          provider.requests[3].systemPrompt,
          contains('plugin session=tina-session-42 model=model-b run=1'),
        );
        expect(bridge.calls.keys, contains('lease-2'));
        expect(host.session.loop.log.length, greaterThan(0));
      } finally {
        await host.shutdown();
      }
      expect(bridge.closed, ['lease-1', 'lease-2']);
    },
  );

  test(
    'denied host operation fails closed before a provider request',
    () async {
      final bridge = _HostBridge()..deny = true;
      final provider = ScriptedProvider([
        scriptedReply('must not be requested'),
      ]);
      final host = Host.start(
        HostConfig(
          model: 'model-a',
          workingDirectory: '.',
          plugins: [RemotePromptPlugin(bridge)],
          providerFactory: (_) => provider,
        ),
        sessionId: 'denied-session',
      );
      try {
        final outcome = await host.send('no side effect');
        expect(outcome.stopReason, StopReason.error);
        expect(provider.callCount, 0);
      } finally {
        await host.shutdown();
      }
      expect(bridge.closed, ['lease-1']);
    },
  );

  test('retired pending prompt cannot write into a new lease', () async {
    final bridge = _HostBridge()..pendingResponse = Completer();
    final plugin = RemotePromptPlugin(bridge);
    final session = PluginSession(
      id: 'pending-session',
      workingDirectory: '.',
      model: 'model-a',
      notifyChanged: () {},
    );
    plugin.openSession(session);
    final sections = <String>[];
    final context = TurnContext(
      CancelToken(),
      input: const Input('input', id: 'input-1'),
      messages: const [],
      promptSections: sections,
      pinnedTools: const [],
    );
    final pending = plugin.onPrompt(context);
    await Future<void>.delayed(Duration.zero);
    plugin.closeSession();
    plugin.openSession(session);
    bridge.pendingResponse!.complete(
      const PromptBridgeResult<String>.ok('late section'),
    );
    await expectLater(pending, throwsStateError);
    expect(sections, isEmpty);
    plugin.closeSession();
    expect(bridge.closed, ['lease-1', 'lease-2']);
  });

  test(
    'cancelled pending prompt is ignored and repeated close is safe',
    () async {
      final bridge = _HostBridge()..pendingResponse = Completer();
      final plugin = RemotePromptPlugin(bridge);
      final session = PluginSession(
        id: 'cancelled-session',
        workingDirectory: '.',
        model: 'model-a',
        notifyChanged: () {},
      );
      plugin.openSession(session);
      final sections = <String>[];
      final context = TurnContext(
        CancelToken(),
        input: const Input('input', id: 'input-2'),
        messages: const [],
        promptSections: sections,
        pinnedTools: const [],
      );
      final pending = plugin.onPrompt(context);
      await Future<void>.delayed(Duration.zero);
      context.cancel('cancelled');
      bridge.pendingResponse!.complete(
        const PromptBridgeResult<String>.ok('cancelled section'),
      );
      await pending;
      expect(sections, isEmpty);

      plugin.closeSession();
      plugin.closeSession();
      expect(bridge.closed, ['lease-1']);
    },
  );
}
