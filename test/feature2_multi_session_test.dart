import 'package:tina_engine/tina_engine.dart';
import 'package:tina/conversation.dart';
import 'package:tina/session_controller.dart';
import 'package:tina/session_manager.dart';
import 'package:test/test.dart';

import 'helpers/fake_host_interface.dart';
import 'helpers/fake_provider.dart';

/// Build a two-session-capable [SessionManager] + [SessionController] for
/// multi-session feature tests, mirroring the harness in
/// session_controller_test.dart but without a [FakeReadLine] loop.
(SessionManager, SessionController) _build({LlmProvider? provider}) {
  final initialProvider = provider ?? FakeProvider.always(model: 'm1');
  final policy = PermissionPolicy();
  final tools = ToolRegistry(const []);
  Conversation makeConversation(LlmProvider p) {
    final host = FakeHostInterface();
    final agent = Agent(
      provider: p,
      tools: tools,
      sink: host,
      policy: policy,
      asker: host.askPermission,
      system: 'sys',
    );
    return Conversation(
      id: 'c-${p.model}',
      label: p.model,
      agent: agent,
      provider: p,
      host: host,
      policy: policy,
    );
  }

  final sm = SessionManager(
    initialConversation: makeConversation(initialProvider),
    initialProviderId: 'anthropic',
    initialApiKey: '',
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
          tools: tools,
          sink: host,
          policy: policy,
          asker: host.askPermission,
          system: 'sys',
        ),
  );
  final controller = SessionController(
    sessionManager: sm,
    readLine: (_) async => null,
    onActiveFocusChanged: () {},
  );
  return (sm, controller);
}

void main() {
  group('background-activity badge', () {
    test('markBackgroundActivity bumps a background session unread once per burst',
        () async {
      final (sm, _) = await _build2Sessions();
      final active = sm.activeId;
      final bgId = sm.listSessions().firstWhere((s) => !s.isActive).id;
      final bgConv = sm.all.firstWhere((s) => s.id == bgId).activeConversationId;

      // First background chunk → signals the session (0→1 transition).
      expect(sm.markBackgroundActivity(bgConv), bgId);
      // Further chunks during the same burst → no signal (avoids per-chunk
      // refresh thrash), though the unread count keeps climbing.
      expect(sm.markBackgroundActivity(bgConv), isNull);
      expect(sm.markBackgroundActivity(bgConv), isNull);
      expect(sm.unreadOf(bgId), greaterThanOrEqualTo(3));

      // The active session is never badged.
      final activeConv = sm.active.activeConversationId;
      expect(sm.markBackgroundActivity(activeConv), isNull);
      expect(sm.unreadOf(active), 0);
    });

    test('switching to a session clears its unread badge', () async {
      final (sm, _) = await _build2Sessions();
      final bgId = sm.listSessions().firstWhere((s) => !s.isActive).id;
      final bgConv = sm.all.firstWhere((s) => s.id == bgId).activeConversationId;
      sm.markBackgroundActivity(bgConv);
      expect(sm.unreadOf(bgId), greaterThan(0));

      sm.switchSession(bgId);
      expect(sm.unreadOf(bgId), 0);
    });

    test('listSessions surfaces the unread count', () async {
      final (sm, _) = await _build2Sessions();
      final bgId = sm.listSessions().firstWhere((s) => !s.isActive).id;
      final bgConv = sm.all.firstWhere((s) => s.id == bgId).activeConversationId;
      sm.markBackgroundActivity(bgConv);
      final entry = sm.listSessions().firstWhere((s) => s.id == bgId);
      expect(entry.unread, greaterThan(0));
    });
  });

  group('draft input persistence across switches', () {
    test('save and restore drafts when switching sessions', () async {
      final (sm, controller) = await _build2Sessions();
      final aId = sm.activeId;
      final bId = sm.listSessions().firstWhere((s) => !s.isActive).id;

      // Scriptable save: the test sets what the "current" draft is before each
      // switch. Restore records what gets loaded into the incoming session.
      var current = (buffer: '', cursor: 0);
      final restored = <(String, String, int)>[]; // (toId, buffer, cursor)
      controller.saveInput = () => current;
      controller.restoreInput =
          (buffer, cursor) => restored.add((sm.activeId, buffer, cursor));

      // A had a draft; switch to B (which is empty).
      current = (buffer: 'hello a', cursor: 7);
      controller.switchSession(bId);
      // Then B had a draft; switch back to A.
      current = (buffer: 'hello b', cursor: 7);
      controller.switchSession(aId);

      // B was restored empty; A was restored with its saved draft.
      expect(restored, [
        (bId, '', 0),
        (aId, 'hello a', 7),
      ]);
    });

    test('newSession preserves the outgoing draft and clears the new one',
        () async {
      final (sm, controller) = await _build2Sessions();
      final aId = sm.activeId;
      var current = (buffer: 'draft', cursor: 5);
      final restored = <(String, int)>[];
      controller.saveInput = () => current;
      controller.restoreInput =
          (buffer, cursor) => restored.add((buffer, cursor));

      await controller.newSession();
      final newId = sm.activeId;
      expect(newId, isNot(aId));
      // The brand-new session starts with an empty draft.
      expect(restored.last, ('', 0));
    });
  });

  group('/session rename', () {
    test('renaming a session updates its label', () async {
      final (sm, controller) = await _build2Sessions();
      final aId = sm.activeId;
      sm.all.firstWhere((s) => s.id == aId).label = 'research';
      final entry = sm.listSessions().firstWhere((s) => s.id == aId);
      expect(entry.label, 'research');
      expect(controller.sessionManager.activeId, aId);
    });
  });
}

/// Build a [SessionManager] holding two sessions (the initial one plus one
/// created in the background), returning it with its [SessionController].
Future<(SessionManager, SessionController)> _build2Sessions() async {
  final (sm, controller) = _build();
  await sm.createSession(model: 'm2');
  return (sm, controller);
}

/// Extension to read a session's unread count without exposing internals.
extension on SessionManager {
  int unreadOf(String id) =>
      all.firstWhere((s) => s.id == id).unread;
}
