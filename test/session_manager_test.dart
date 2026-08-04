import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:tina/conversation.dart';
import 'package:tina/session_manager.dart';
import 'package:test/test.dart';

import 'helpers/fake_agent_sink.dart';
import 'helpers/fake_host_interface.dart';
import 'helpers/fake_provider.dart';

/// The host of [c], cast back to the fake so assertions can read its recorded
/// active/detach state — the UI-agnostic equivalent of peeking at a chat
/// region's `isDetached`.
FakeHostInterface hostOf(Conversation c) => c.host as FakeHostInterface;

void main() {
  group('SessionManager', () {
    Conversation makeConversation(String id, LlmProvider provider,
        {bool active = true}) {
      final policy = PermissionPolicy();
      final host = FakeHostInterface()..setActive(active);
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
        label: provider.model,
        agent: agent,
        provider: provider,
        host: host,
        policy: policy,
      );
    }

    SessionManager build({HostFactory? hostFactory}) {
      final initial =
          makeConversation('s1', FakeProvider.always(model: 'model-a'));

      HostInterface defaultHostFactory({
        required String conversationId,
        required bool isActive,
      }) =>
          FakeHostInterface()..setActive(isActive);

      final sm = SessionManager(
        initialConversation: initial,
        initialProviderId: 'anthropic',
        initialApiKey: 'key',
        providerFactory: (kind, key, model, baseUrl) =>
            FakeProvider.always(model: model),
        hostFactory: hostFactory ?? defaultHostFactory,
        agentBuilder: ({
          required String conversationId,
          required LlmProvider provider,
          required HostInterface host,
          required PermissionPolicy policy,
        }) =>
            Agent(
          provider: provider,
          tools: ToolRegistry(const []),
          sink: FakeAgentSink(),
          policy: policy,
          asker: host.askPermission,
          system: 'sys',
        ),
      );
      // Idle spinner animation timers are started on switch; clean them up.
      addTearDown(sm.closeAll);
      return sm;
    }

    test('starts with the initial conversation active', () {
      final sm = build();
      expect(sm.count, 1);
      expect(sm.activeConversation.id, 's1');
      expect(sm.activeConversation.label, 'model-a');
    });

    test('hasActiveSession is true once constructed, false after closeAll', () {
      final sm = build();
      expect(sm.hasActiveSession, isTrue);
      sm.closeAll();
      expect(sm.hasActiveSession, isFalse);
      // closeAll is idempotent (no-ops on an empty map), so the addTearDown
      // call running it a second time is harmless.
    });

    test('createSession adds a detached background session without switching',
        () async {
      final sm = build();
      final s2 = await sm.createSession(model: 'model-b');
      expect(sm.count, 2);
      expect(sm.activeConversation.id, 's1',
          reason: 'createSession must not switch');
      expect(hostOf(s2.activeConversation).isDetached, isTrue);
      expect(s2.activeConversation.provider.model, 'model-b');
    });

    test(
        'createSession gives the new conversation an independent permission policy',
        () async {
      final sm = build();
      // Pollute the active conversation's policy with a remembered rule.
      sm.activeConversation.policy
          .remember('bash', 'rm *', PermissionDecision.deny);
      expect(sm.activeConversation.policy.sessionRules, isNotEmpty,
          reason: 'sanity: the active conversation has a remembered rule');

      final s2 = await sm.createSession(model: 'model-b');
      expect(s2.activeConversation.policy,
          isNot(same(sm.activeConversation.policy)));
      expect(s2.activeConversation.policy.sessionRules, isEmpty);
      expect(s2.activeConversation.policy.defaults,
          equals(sm.activeConversation.policy.defaults));
    });

    test('switchSession repoints the active host and detaches the old',
        () async {
      final sm = build();
      final s1Id = sm.activeId;
      final s2 = await sm.createSession(model: 'model-b');
      sm.switchSession(s2.id);

      expect(sm.activeId, s2.id);
      expect(hostOf(sm.activeConversation).isActive, isTrue);
      final s1 = sm.all.firstWhere((x) => x.id == s1Id);
      expect(hostOf(s1.activeConversation).isDetached, isTrue);
      expect(hostOf(s2.activeConversation).isDetached, isFalse);
    });

    test('cannot close the active session', () {
      final sm = build();
      expect(() => sm.close(sm.activeId), throwsStateError);
    });

    test('close removes a background session', () async {
      final sm = build();
      final s2 = await sm.createSession();
      expect(sm.count, 2);
      sm.close(s2.id);
      expect(sm.count, 1);
      expect(sm.all.map((s) => s.id), isNot(contains(s2.id)));
    });

    test('createSession invokes the host factory for the new conversation',
        () async {
      final built = <String>[];
      final sm = build(hostFactory: ({
        required String conversationId,
        required bool isActive,
      }) {
        built.add(conversationId);
        return FakeHostInterface()..setActive(isActive);
      });
      final s2 = await sm.createSession();
      expect(built, contains(s2.activeConversation.id));
    });

    test('handleResize reconciles every conversation without throwing',
        () async {
      final sm = build();
      await sm.createSession();
      expect(sm.handleResize, returnsNormally);
    });

    test('listSessions reports exactly one active session', () async {
      final sm = build();
      await sm.createSession(model: 'model-b');
      final list = sm.listSessions();
      expect(list.length, 2);
      expect(list.where((s) => s.isActive).length, 1);
    });

    test(
        'createConversation adds a conversation to the active session '
        'without switching', () async {
      final sm = build();
      final c2 = await sm.createConversation(model: 'model-c');
      expect(sm.active.conversationCount, 2);
      expect(sm.activeConversation.id, 's1', reason: 'must not switch');
      expect(hostOf(c2).isDetached, isTrue);
      expect(c2.provider.model, 'model-c');
    });

    test('switchConversation routes the new conversation to the active host',
        () async {
      final sm = build();
      final c1 = sm.activeConversation;
      final c2 = await sm.createConversation(model: 'model-c');
      await sm.switchConversation(c2.id);

      expect(sm.activeConversation.id, c2.id);
      expect(hostOf(c2).isActive, isTrue);
      expect(hostOf(c1).isDetached, isTrue);
      expect(hostOf(c2).isDetached, isFalse);
    });

    test('switchConversation persists the active conversation', () async {
      final tmp = await Directory.systemTemp.createTemp('tina_sm_test_');
      final store = JsonlSessionStore(tmp);
      late SessionManager sm;
      try {
        final sid = await store.createSession(providerId: 'anthropic');
        final cid = await store.createConversation(sid);
        final initial =
            makeConversation(cid, FakeProvider.always(model: 'model-a'));
        sm = SessionManager(
          initialConversation: initial,
          initialSessionId: sid,
          initialProviderId: 'anthropic',
          initialApiKey: 'key',
          providerFactory: (kind, key, model, baseUrl) =>
              FakeProvider.always(model: model),
          hostFactory: ({
            required String conversationId,
            required bool isActive,
          }) =>
              FakeHostInterface()..setActive(isActive),
          agentBuilder: ({
            required String conversationId,
            required LlmProvider provider,
            required HostInterface host,
            required PermissionPolicy policy,
          }) =>
              Agent(
            provider: provider,
            tools: ToolRegistry(const []),
            sink: FakeAgentSink(),
            policy: policy,
            asker: host.askPermission,
            system: 'sys',
          ),
          sessionStore: store,
        );

        final c2 = await sm.createConversation(model: 'model-c');
        // Write through c2's recorder to trigger lazy init, then switch.
        await c2.recorder!.append(
            const Message(role: Role.user, content: [TextBlock('hello')]));
        await sm.switchConversation(c2.id);

        final manifest = await store.loadSession(sid);
        expect(manifest.activeConversationId, c2.id);
      } finally {
        sm.closeAll();
        await tmp.delete(recursive: true);
      }
    });
  });
}
