import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:tina/conversation.dart';
import 'package:tina/session.dart';
import 'package:test/test.dart';

import 'helpers/fake_agent_sink.dart';
import 'helpers/fake_host_interface.dart';
import 'helpers/fake_provider.dart';

void main() {
  Conversation makeConversation(String id) {
    final provider = FakeProvider.always(model: 'model-$id');
    final policy = PermissionPolicy();
    final host = FakeHostInterface();
    final agent = Agent(
      provider: provider,
      tools: ToolRegistry(const []),
      sink: FakeAgentSink(),
      policy: policy,
      asker: (_) async => PermissionResponse.denyOnce,
      system: 'sys',
    );
    return Conversation(
      id: id,
      label: 'label-$id',
      agent: agent,
      provider: provider,
      host: host,
      policy: policy,
    );
  }

  Session makeSession(Conversation initial) => Session(
        id: 'sess',
        label: 'session',
        providerId: 'anthropic',
        apiKey: 'key',
        baseUrl: null,
        initialConversation: initial,
      );

  group('Session', () {
    test('initial conversation is active', () {
      final c = makeConversation('c1');
      final s = makeSession(c);
      expect(s.conversationCount, 1);
      expect(s.activeConversation, same(c));
      expect(s.activeConversationId, 'c1');
      expect(s.conversationById('c1'), same(c));
      expect(s.conversationById('nope'), isNull);
    });

    test('addConversation does not steal focus from the active one', () {
      final c1 = makeConversation('c1');
      final s = makeSession(c1);
      final c2 = makeConversation('c2');
      s.addConversation(c2);
      expect(s.conversationCount, 2);
      expect(s.activeConversation, same(c1), reason: 'adding must not switch');
    });

    test('setActiveConversation switches the active conversation', () {
      final c1 = makeConversation('c1');
      final s = makeSession(c1);
      final c2 = makeConversation('c2');
      s.addConversation(c2);
      s.setActiveConversation('c2');
      expect(s.activeConversation, same(c2));
      expect(s.activeConversationId, 'c2');
    });

    test('setActiveConversation rejects an unknown id', () {
      final s = makeSession(makeConversation('c1'));
      expect(() => s.setActiveConversation('ghost'), throwsArgumentError);
    });

    test('removeConversation falls back to another member when removing active',
        () {
      final c1 = makeConversation('c1');
      final s = makeSession(c1);
      final c2 = makeConversation('c2');
      s.addConversation(c2);
      s.setActiveConversation('c1');
      s.removeConversation('c1');
      expect(s.conversationCount, 1);
      expect(s.activeConversation, same(c2));
    });

    test('isRunning tracks the active conversation only', () {
      final c1 = makeConversation('c1');
      final s = makeSession(c1);
      final c2 = makeConversation('c2');
      s.addConversation(c2);

      // A background conversation running must not read as the session running.
      c2.cancelCompleter = Completer<void>();
      expect(s.isRunning, isFalse, reason: 'active c1 is idle');

      // The active conversation in flight reads as running.
      c1.cancelCompleter = Completer<void>();
      expect(s.isRunning, isTrue);

      c1.cancelCompleter = null;
      expect(s.isRunning, isFalse);
    });
  });
}
