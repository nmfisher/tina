import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina/tui/session_id_status.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';
import '../helpers/memory_session_store.dart';

/// The session-id strip indicator: a pull-style source over the session
/// manager. It must show the *active* session's id at render time (switching
/// sessions flips what [SessionIdStatusSource.read] returns without any push
/// notification), and hide entirely for conversations with no recorder.
void main() {
  late MemorySessionStore store;
  late SessionManager sm;

  setUp(() {
    store = MemorySessionStore();
    FakeHostInterface hostFactory({
      required String conversationId,
      required bool isActive,
    }) => FakeHostInterface()..setActive(isActive);
    FakeProvider providerFactory(
      String kind,
      String key,
      String model,
      String? baseUrl,
    ) => FakeProvider.done();
    AgentDriver agentBuilder({
      required String conversationId,
      required LlmProvider provider,
      required HostInterface host,
      required PermissionPolicy policy,
    }) => AgentDriverAdapter(
      Agent(
        provider: provider,
        tools: ToolRegistry(const []),
        sink: host,
        policy: policy,
        asker: host.askPermission,
        system: 'sys',
      ),
    );
    final conv = Conversation(
      id: 'c1',
      label: 'main',
      driver: agentBuilder(
        conversationId: 'c1',
        provider: FakeProvider.done(),
        host: FakeHostInterface()..setActive(true),
        policy: PermissionPolicy(),
      ),
      provider: FakeProvider.done(),
      host: FakeHostInterface()..setActive(true),
      policy: PermissionPolicy(),
      recorder: SessionRecorder(
        store,
        '20260925-120000-ab12',
        'c1',
        providerId: 'fake',
      ),
    );
    sm = SessionManager(
      initialConversation: conv,
      initialProviderId: 'fake',
      initialApiKey: '',
      providerFactory: providerFactory,
      hostFactory: hostFactory,
      agentBuilder: agentBuilder,
      sessionStore: store,
    );
  });

  test('read snapshots the active session id; switching flips it', () async {
    final source = SessionIdStatusSource(sm);
    expect(source.read('c1'), isA<SessionIdSnapshot>());
    expect(
      (source.read('c1') as SessionIdSnapshot).sessionId,
      '20260925-120000-ab12',
    );

    // Switch: a fresh session (built in the background) becomes active; the
    // pull source now reports the new active session's id without any push
    // notification.
    final session = await sm.createSession();
    sm.selectSession(session.id);
    expect(sm.activeId, isNot('20260925-120000-ab12'));
    expect(
      (source.read('c1') as SessionIdSnapshot).sessionId,
      sm.activeConversation.recorder!.sessionId,
      reason: 'the pull source always mirrors the active session',
    );
  });

  test('no recorder: the line is declined (null)', () {
    final bareHost = FakeHostInterface()..setActive(true);
    final bare = Conversation(
      id: 'c2',
      label: 'main',
      driver: AgentDriverAdapter(
        Agent(
          provider: FakeProvider.done(),
          tools: ToolRegistry(const []),
          sink: bareHost,
          policy: PermissionPolicy(),
          asker: bareHost.askPermission,
          system: 'sys',
        ),
      ),
      provider: FakeProvider.done(),
      host: bareHost,
      policy: PermissionPolicy(),
    );
    final sm2 = SessionManager(
      initialConversation: bare,
      initialProviderId: 'fake',
      initialApiKey: '',
      providerFactory: (kind, key, model, baseUrl) => FakeProvider.done(),
      hostFactory: ({required String conversationId, required bool isActive}) =>
          FakeHostInterface()..setActive(isActive),
      agentBuilder:
          ({
            required String conversationId,
            required LlmProvider provider,
            required HostInterface host,
            required PermissionPolicy policy,
          }) => AgentDriverAdapter(
            Agent(
              provider: provider,
              tools: ToolRegistry(const []),
              sink: host,
              policy: policy,
              asker: host.askPermission,
              system: 'sys',
            ),
          ),
    );
    final source = SessionIdStatusSource(sm2);
    expect(source.read('c2'), isNull);
  });

  test('the renderer paints `session <id>`', () {
    const renderer = SessionIdStatusRenderer();
    final lines = renderer.render(
      const SessionIdSnapshot('20260925-120000-ab12'),
      const RenderContext(width: 100, theme: Theme.defaults()),
    );
    expect(lines, hasLength(1));
    expect(
      lines.first.runs.map((r) => r.text).join(),
      'session 20260925-120000-ab12',
    );
  });

  test(
    'changes is an empty stream (pull-style; refresh comes from the strip host)',
    () {
      final source = SessionIdStatusSource(sm);
      expect(source.changes, emitsDone);
    },
  );
}
