import 'package:tina/config/terminal_config.dart';
import 'package:tina/tui_coordinator.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_environment.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';
import '../helpers/fake_stdio.dart';
import '../helpers/fake_terminal_geometry.dart';
import '../helpers/memory_session_store.dart';

/// PR #49 regression: a live-panelized delegated sub-agent session must run
/// through the composition's driver seam. The coordinator's
/// [SubAgentSessionFactory] resolves its panel build through
/// [SubAgentScheduler.driverFor] and registers the panel [Conversation]
/// around the resulting driver, so a replacement [AgentDriverFactory] drives
/// the session's turns and surfaces as the conversation's driver. Before the
/// fix the factory built a bare [Agent] and the conversation defaulted to the
/// plain adapter — the scripted driver never saw the panel turn.
void main() {
  test('a live-panelized delegated session runs through the driver seam',
      () async {
    // The main provider answers with one delegate call, then ends the turn.
    final provider = FakeProvider([
      [
        MessageComplete(
          content: [
            ToolUseBlock(
              id: 'delegate-panel',
              name: 'delegate',
              input: {
                'delegations': [
                  {'task': 'probe the seam'},
                ],
              },
            ),
          ],
          stopReason: 'tool_use',
        ),
      ],
      [
        MessageComplete(
          content: [TextBlock('delegation finished')],
          stopReason: 'end_turn',
        ),
      ],
    ], model: 'main-model');

    final registry = ProviderRegistry(env: const {})
      ..register(ProviderDescriptor(
        id: 'test',
        name: 'Test',
        authSources: const [],
        defaultBaseUrl: 'https://example.test',
        builder: (options) => FakeProvider.done(model: options.model),
      ));

    final factory = _PanelCountingFactory();
    final config = RuntimeConfig(provider: 'test', model: 'main-model');
    final app = await buildAppComposition(
      config: config,
      registry: registry,
      provider: provider,
      store: MemorySessionStore(),
      environment: FakeEnvironment(),
      driverFactory: factory,
    );
    addTearDown(app.dispose);

    final coordinator = await TuiCoordinator.create(
      app: app,
      io: FakeStdio()..hasTerminalValue = false,
      terminalGeometry:
          const FakeTerminalGeometry(columns: 120, lines: 40),
      terminal: const TerminalConfig(backend: BackendChoice.ansi),
    );
    addTearDown(coordinator.controller.shutdown);

    final main = coordinator.sessionManager.activeConversation;
    await coordinator.controller.runEnvironment(main);
    await coordinator.controller.turns.whenIdle(main.id);

    // One delegated child became a live panel — a first-class session.
    expect(coordinator.spawnedPanels, hasLength(1));
    expect(coordinator.sessionManager.active.conversationCount, 2);

    // The panel conversation exists and its driver is the scripted one.
    final conversations =
        coordinator.sessionManager.active.conversations;
    final panel = conversations.firstWhere((c) => c.id != main.id);
    expect(panel.driver, isA<_PanelScriptedDriver>(),
        reason: 'the panel session runs the replacement driver');
    expect(factory.created, hasLength(1),
        reason: 'the delegated panel build consulted the seam');
    expect(factory.requests, 2,
        reason: 'main agent build + delegated panel build');

    // The scripted driver actually owned the delegated turn.
    final scripted = panel.driver as _PanelScriptedDriver;
    expect(scripted.runInputs, contains('probe the seam'));

    // Focus wiring still works: the spawned panel can become the active
    // conversation (the bindSpawned contract).
    final frame = coordinator.spawnedPanels.single;
    coordinator.focusManager.focusPanel(frame);
    expect(coordinator.sessionManager.activeConversation, same(panel));
  });
}

class _PanelCountingFactory implements AgentDriverFactory {
  final created = <_PanelScriptedDriver>[];

  /// Every seam consultation: request 1 is the MAIN agent's build (made once
  /// at composition/coordinator root) — it must keep its default adapter, or
  /// the main turn could never issue the delegate call. Request 2 is the
  /// delegated panel build; that one gets the replacement driver.
  int requests = 0;
  final _default = const DefaultAgentDriverFactory();

  @override
  AgentDriver create(AgentDriverRequest request) {
    requests++;
    if (requests == 1) return _default.create(request);
    final driver = _PanelScriptedDriver();
    created.add(driver);
    return driver;
  }
}

class _PanelScriptedDriver implements AgentDriver {
  final runInputs = <String>[];

  @override
  LlmProvider provider = FakeProvider(const []);

  @override
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
    Future<void>? toolInterruptSignal,
    ToolRegistry? turnTools,
  }) async {
    runInputs.add(userInput);
    history.add(const Message(
        role: Role.assistant, content: [TextBlock('scripted reply')]));
  }

  @override
  String? get abortedReason => null;

  @override
  AbortedKind get abortedKind => AbortedKind.none;

  @override
  String get system => 'scripted';

  @override
  ToolRegistry get tools => ToolRegistry(const []);

  @override
  Future<bool> compact(
    List<Message> history, {
    int preserveRecent = 0,
    int preserveRecentMessages = 0,
    Future<void>? cancelSignal,
  }) async =>
      false;
}
