import 'package:tina_app/tina_app.dart';

import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina/platform/terminal_geometry.dart';
import 'package:tina/pipeline/workflow_permission_asker.dart';

import 'package:tina/tui_coordinator.dart';
import 'package:tina/tui/conversation_panel_coordinator.dart';
import 'package:tina/tui/conversation_style.dart';
import 'package:tina/tui/panel_manager.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_provider.dart';
import '../helpers/fake_stdio.dart';
import 'package:tina/config/terminal_config.dart';
import '../helpers/fake_environment.dart';
import '../helpers/fake_terminal_geometry.dart';
import '../helpers/memory_session_store.dart';

/// Unit tests for [ConversationPanelCoordinator]: the Phase 5 binding layer that
/// knows about both panel chrome and conversations. Driving it directly (no
/// coordinator, no overlays, no chat) is the point of the extraction — the
/// behavior used to be scattered across the `create()`-local `_panelContents`
/// map, the `onPanelFocused` closure, and the host's `panel` back-reference.
void main() {
  // The real Screen/PanelManager give the frames real bounds; content relay
  // reads the frame's interior, so geometry must match the manager tests.
  late FakeStdio io;
  late Screen screen;
  late FocusManager focusManager;
  late LineEditor editor;
  late TerminalGeometry geometry;
  late _RecordingPanelFrame primaryFrame;
  late PanelManager panelManager;
  late SpawnTree tree;
  late _RecordingSessionManager sessionManager;
  late ConversationPanelCoordinator coordinator;

  void configure({bool showSidebar = false, PluginScope? pluginScope}) {
    io = FakeStdio()..columns = 120;
    final layout = ScreenLayout.fromSize(
      120,
      24,
      split: true,
      drawInfoFrame: false,
    );
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    focusManager = FocusManager();
    editor = LineEditor(screen: screen);
    geometry = _Geometry(columns: 120, lines: 24);
    primaryFrame = _RecordingPanelFrame(
      screen: screen,
      label: 'primary',
      conversationId: 'primary',
    );
    tree = SpawnTree(rootId: 'primary');
    panelManager = PanelManager(
      screen: screen,
      focusManager: focusManager,
      editor: editor,
      primaryFrame: primaryFrame,
      terminalGeometry: geometry,
      menuBarEnabled: false,
      tree: tree,
      showSidebar: showSidebar,
    );
    sessionManager = _RecordingSessionManager(
      // The primary chat is shared screen.chat: attached, not buffered.
      initialConversation: _dummyConversation('primary', detached: false),
    );
    coordinator = ConversationPanelCoordinator(
      panelManager: panelManager,
      sessionManager: sessionManager,
      editor: editor,
      primaryHost: sessionManager.initialHost,
      pluginScope: pluginScope,
    );
    coordinator.bindPrimary(conversationId: 'primary');
  }

  setUp(configure);

  test(
    'live prompt and border plugins preserve drafts and approval input',
    () async {
      editor.close();
      coordinator.dispose();
      panelManager.dispose();
      final scope = PluginScope('test');
      final childScope = PluginScope('child', parent: scope);
      configure(pluginScope: childScope);
      addTearDown(() async {
        coordinator.dispose();
        editor.close();
        panelManager.dispose();
        await childScope.dispose();
        await scope.dispose();
        io.close();
      });
      sessionManager.activeConversation.modelReference = 'test/first';
      focusManager
        ..register(primaryFrame)
        ..home = primaryFrame;
      panelManager.layout();
      coordinator.relayContent();
      focusManager.focusPanel(primaryFrame);
      coordinator.relocateInput(force: true);
      final line = editor.readLine('> ');
      await pumpEventQueue();
      editor.loadEditState('unsent draft', 4);
      expect(primaryFrame.border, isFalse);
      expect(screen.input.prompt, contains('first > '));

      sessionManager.activeConversation.modelReference = 'test/second';
      primaryFrame.relabel('main (second)');
      expect(screen.input.prompt, contains('second > '));
      final registration = scope.registerContribution(
        pluginId: 'test',
        id: 'prompt',
        contribution: _Prompt(),
      );
      final style = scope.registerContribution(
        pluginId: 'test',
        id: 'style',
        contribution: const ConversationStyle(border: true),
      );
      await pumpEventQueue();
      expect(primaryFrame.border, isTrue);
      expect(screen.input.prompt, contains('custom second > '));
      expect(editor.editState, (buffer: 'unsent draft', cursor: 4));

      await style.dispose();
      await registration.dispose();
      await pumpEventQueue();
      expect(primaryFrame.border, isFalse);
      expect(screen.input.bounds.row, primaryFrame.inputRect.row);
      expect(screen.input.bounds.col, primaryFrame.inputRect.col);
      expect(screen.input.bounds.width, primaryFrame.inputRect.width);
      expect(screen.input.prompt, contains('second > '));

      final approval = editor.readKey(globalKeys: true);
      await pumpEventQueue();
      screen.input.render(prompt: 'Review rule: ', buffer: 'rule', cursor: 4);
      sessionManager.initialHost.setActivity(true);
      for (var i = 0; i < 3; i++) primaryFrame.advanceBusyTick();
      final replacement = scope.registerContribution(
        pluginId: 'test',
        id: 'prompt',
        contribution: _Prompt(),
      );
      await pumpEventQueue();
      expect(screen.input.prompt, 'Review rule: ');
      expect(screen.input.buffer, 'rule');
      await replacement.dispose();
      await pumpEventQueue();
      editor.inject(ControlKey(ControlCode.enter));
      await approval;
      sessionManager.initialHost.setActivity(false);
      editor.refresh();
      expect(editor.editState, (buffer: 'unsent draft', cursor: 4));
      expect(screen.input.prompt, contains('second > '));
      editor.inject(ControlKey(ControlCode.enter));
      expect(await line, 'unsent draft');
    },
  );

  for (final sidebar in [false, true]) {
    test(
      'panel-owned input preserves drafts and survives resize (sidebar: $sidebar)',
      () async {
        if (sidebar) {
          editor.close();
          coordinator.dispose();
          panelManager.dispose();
          configure(showSidebar: true);
        }
        focusManager
          ..register(primaryFrame)
          ..home = primaryFrame;
        editor.focusManager = focusManager;
        panelManager.layout();
        coordinator.relayContent();
        editor.readLine('> ');
        await pumpEventQueue();
        editor.loadEditState('saved draft', 5);
        final content = _PlainContent();
        final frame = PanelFrame(
          screen: screen,
          label: 'Custom',
          conversationId: 'custom',
          inputMode: PanelInputMode.exclusive,
        );
        coordinator.bindExtra(frame: frame, content: content);
        panelManager.layout();
        coordinator.relayContent();
        focusManager.focusPanel(frame);
        expect(screen.input.bounds.isEmpty, isTrue);
        expect(sessionManager.activeConversationId, 'primary');
        expect(content.isDetached, isFalse);
        expect(frame.reservesInput, isFalse);
        coordinator.relocateInput(force: true);
        expect(
          screen.input.bounds.isEmpty,
          isTrue,
          reason: 'resize must not reveal the conversation editor',
        );
        editor.inject(CharInput('panel input'));
        expect(editor.editState.buffer, 'saved draft');
        focusManager.focusPanel(primaryFrame);
        expect(screen.input.bounds.isEmpty, isFalse);
        expect(editor.editState, (buffer: 'saved draft', cursor: 5));
        if (sidebar) expect(content.isDetached, isTrue);
        focusManager.focusPanel(frame);
        expect(content.isDetached, isFalse);
        expect(content.fits.last.width, greaterThan(0));
        coordinator.unbindExtra(frame);
        panelManager.removeFrame(frame);
        coordinator.relocateInput(force: true);
        expect(focusManager.focused, same(primaryFrame));
        expect(screen.input.bounds.isEmpty, isFalse);
        expect(editor.editState, (buffer: 'saved draft', cursor: 5));
        editor.close();
        coordinator.dispose();
        panelManager.dispose();
      },
    );
  }

  group('bindPrimary', () {
    test('reserves the primary frame input row', () {
      expect(primaryFrame.reservesInput, isTrue);
    });

    test('wires the primary host focus handler through the coordinator', () {
      // Focusing the primary is a no-op switch (already active) but must not
      // throw and must repoint the input onto the primary frame.
      primaryFrame.focus();
      expect(sessionManager.switchCalls, isEmpty);
    });

    test('keeps the panel back-reference for clear()/relabel', () {
      expect(sessionManager.initialHost.panel, same(primaryFrame));
    });

    test('inverts the busy cue onto onBusyChanged', () {
      final host = sessionManager.initialHost;
      expect(
        host.onBusyChanged,
        isNotNull,
        reason:
            'busy cue must reach the frame via the callback, '
            'not panel.setBusy directly',
      );
      // The callback drives the frame's comet through its setBusy: the
      // recording frame captures every setBusy the coordinator wires up.
      expect(primaryFrame.busyCalls, isEmpty);
      host.onBusyChanged!(true);
      host.onBusyChanged!(false);
      expect(primaryFrame.busyCalls, [true, false]);
    });
  });

  group('relayContent', () {
    test(
      'fits content into every frame interior and attaches detached ones',
      () {
        // The primary chat starts attached; relayContent must not detach it.
        final primaryChat = sessionManager.initialHost.chat;
        expect(primaryChat.isDetached, isFalse);
        coordinator.relayContent();
        expect(
          primaryChat.isDetached,
          isFalse,
          reason: 'relayContent never detaches — it only ever attaches',
        );

        // A background conversation's chat starts detached; relayContent must
        // attach it once its frame is laid out.
        final conv = _dummyConversation('side');
        sessionManager.register(conv);
        final host = conv.host as TuiConversationHost;
        final frame = coordinator.bindSpawned(
          host: host,
          label: sideLabel('side'),
        );
        panelManager.layout();
        expect(
          host.chat.isDetached,
          isTrue,
          reason: 'background chat detached',
        );
        coordinator.relayContent();
        expect(
          host.chat.isDetached,
          isFalse,
          reason: 'relayContent attaches the laid-out frame\'s content',
        );
        frame.dispose();
      },
    );

    test('relayContent never detaches the primary when a side panel shows', () {
      // Regression guard for the primary-stays-visible invariant the host's
      // stayAttachedWhenInactive preserves: relayContent only ever fits and
      // attaches, so the primary chat is never detached by a resize/relay.
      final conv = _dummyConversation('side2');
      sessionManager.register(conv);
      final host = conv.host as TuiConversationHost;
      final frame = coordinator.bindSpawned(
        host: host,
        label: sideLabel('side2'),
      );
      panelManager.layout();
      coordinator.relayContent();
      expect(
        sessionManager.initialHost.chat.isDetached,
        isFalse,
        reason: 'primary must stay attached through relayContent',
      );
      frame.dispose();
    });
  });

  group('bindSpawed', () {
    test('registers the frame in the tiling list + focus ring', () {
      final conv = _dummyConversation('side');
      sessionManager.register(conv);
      final host = conv.host as TuiConversationHost;
      final frame = coordinator.bindSpawned(
        host: host,
        label: sideLabel('side'),
      );
      expect(panelManager.spawnedFrames, contains(frame));
      // Registered in the focus ring -> focusable directly.
      focusManager.focusPanel(frame);
      expect(focusManager.focused, same(frame));
      frame.dispose();
    });

    test('wires the secondary host busy cue via onBusyChanged', () {
      final conv = _dummyConversation('side');
      sessionManager.register(conv);
      final host = conv.host as TuiConversationHost;
      final frame = coordinator.bindSpawned(
        host: host,
        label: sideLabel('side'),
      );
      expect(
        host.onBusyChanged,
        isNotNull,
        reason:
            'the busy cue is inverted onto the callback for secondary '
            'hosts too, never reaching into a frame directly',
      );
      // The frame created by bindSpawed is driven by that callback; capture
      // the wiring by reading the bound closure back through a recording frame
      // is not possible, so assert the callback is the inversion seam itself
      // and that invoking it against the panel does not throw.
      expect(() => host.onBusyChanged!(true), returnsNormally);
      expect(() => host.onBusyChanged!(false), returnsNormally);
      frame.dispose();
    });
  });

  group('onFrameFocused (focus wiring)', () {
    test('focusing a side panel routes input to it WITHOUT moving the '
        'manifest anchor', () {
      final conv = _dummyConversation('side');
      sessionManager.register(conv);
      final host = conv.host as TuiConversationHost;
      final frame = coordinator.bindSpawned(
        host: host,
        label: sideLabel('side'),
      );
      panelManager.layout();

      coordinator.onFrameFocused(frame);

      // In-memory active follows focus (the side conversation)...
      expect(sessionManager.active.activeConversationId, 'side');
      // ...but the switch is explicitly persisted:false so the manifest anchor
      // stays the primary — side panels must never become the anchor.
      expect(sessionManager.switchCalls.single.persist, isFalse);
      expect(sessionManager.switchCalls.single.id, 'side');
      frame.dispose();
    });

    test('focusing the already-active panel only repoints input', () {
      coordinator.onFrameFocused(primaryFrame);
      expect(
        sessionManager.switchCalls,
        isEmpty,
        reason: 'the primary is already active — no switch, just relocate',
      );
    });

    test(
      'a focused environment panel accepts approvals but blocks chat input',
      () async {
        final host = _RecordingHost('env-approval');
        final frame = coordinator.bindSpawned(host: host, label: 'Environment');
        panelManager.layout();
        focusManager.focusPanel(frame);
        editor.focusManager = focusManager;
        final asker = WorkflowPermissionAsker(
          sink: host,
          screen: screen,
          editor: editor,
        );
        for (final (key, expected) in [
          ('y', PermissionResponse.allowOnce),
          ('n', PermissionResponse.denyOnce),
          ('a', PermissionResponse.allowAlways),
          ('d', PermissionResponse.denyAlways),
        ]) {
          final response = asker.ask(
            PermissionPrompt('bash', {'command': 'pwd'}),
          );
          await pumpEventQueue();
          expect(editor.isReadingKey, isTrue);
          io.feedBytes(key.codeUnits);
          final actual = await response.timeout(const Duration(seconds: 2));
          expect(actual.decision, expected.decision);
          expect(actual.remember, expected.remember);
        }
        expect(host.messages.join(), isNot(contains('input disabled')));
        // Outside an approval, text still cannot become a main-chat draft.
        expect(frame.handleEvent(CharInput('h')), isTrue);
        expect(host.messages.last, contains('input disabled'));
        editor.close();
        frame.dispose();
      },
    );

    test('focusing a host-only panel keeps input on the primary instead of '
        'throwing', () {
      // The first-load environment agent's panel: bound via bindSpawned by its
      // host's synthetic id ('env-…'), but no Conversation is ever registered
      // in the session. Focusing it must not attempt the conversation switch
      // (which would throw 'Unknown conversation') — it behaves like an extra
      // panel and leaves the shared input on the primary chat.
      final host = _RecordingHost('env-123');
      final frame = coordinator.bindSpawned(
        host: host,
        label: 'Environment (model)',
      );
      panelManager.layout();

      coordinator.onFrameFocused(frame);

      expect(
        sessionManager.switchCalls,
        isEmpty,
        reason: 'no Conversation exists — there is nothing to switch to',
      );
      expect(
        sessionManager.active.activeConversationId,
        'primary',
        reason: 'focus on a host-only panel never moves the active pointer',
      );

      // Text keystrokes are consumed with a single notice — never routed to
      // the shared editor (which would silently type into the main panel).
      expect(frame.handleEvent(CharInput('h')), isTrue);
      expect(frame.handleEvent(CharInput('i')), isTrue);
      expect(frame.handleEvent(PasteInput('pasted')), isTrue);
      expect(frame.handleEvent(ControlKey(ControlCode.enter)), isTrue);
      expect(
        host.messages.length,
        1,
        reason: 'the notice is shown once per focus gain, not per key',
      );
      expect(host.messages.single, contains('input disabled'));

      // Navigation keys keep working: PgUp and the wheel are consumed by the
      // frame's own scroll handler (wired by _wireScrollback at bind time),
      // and everything else — Esc (cancel turn), Ctrl+C, Alt+letter — falls
      // through to the editor untouched.
      expect(
        frame.handleEvent(ArrowKey(ArrowDirection.pageUp)),
        isTrue,
        reason: 'PgUp still scrolls the panel\'s transcript',
      );
      expect(
        frame.handleEvent(ScrollEvent(up: true)),
        isTrue,
        reason: 'the wheel still scrolls the panel\'s transcript',
      );
      expect(
        frame.handleEvent(EscapeKey()),
        isFalse,
        reason: 'Esc still falls through to cancel the active turn',
      );
      expect(
        frame.handleEvent(ControlKey(ControlCode.ctrlC)),
        isFalse,
        reason: 'Ctrl+C still falls through to the editor (exit path)',
      );
      expect(
        host.messages.length,
        1,
        reason: 'navigation keys never post the input-disabled notice',
      );
      frame.dispose();
    });
  });

  group('surfaceOf', () {
    test('returns the chat surface for the focused panel', () {
      expect(
        coordinator.surfaceOf('primary'),
        same(sessionManager.initialHost.chat.surface),
      );
    });
  });
  group('a live-panelized delegated session runs through the driver seam', () {
    test(
      'a live-panelized delegated session runs through the driver seam',
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
          ..register(
            ProviderDescriptor(
              id: 'test',
              name: 'Test',
              authSources: const [],
              defaultBaseUrl: 'https://example.test',
              builder: (options) => FakeProvider.done(model: options.model),
            ),
          );

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
          terminalGeometry: const FakeTerminalGeometry(columns: 120, lines: 40),
          terminal: const TerminalConfig(backend: BackendChoice.ansi),
        );
        addTearDown(coordinator.controller.shutdown);

        final main = coordinator.sessionManager.activeConversation;
        coordinator.controller.turns.submit(
          main.id,
          'Delegate a scoped inspection.',
        );
        await coordinator.controller.turns.whenIdle(main.id);

        // One delegated child became a live panel — a first-class session.
        expect(coordinator.spawnedPanels, hasLength(1));
        expect(coordinator.sessionManager.active.conversationCount, 2);

        // The panel conversation exists and its driver is the scripted one.
        final conversations = coordinator.sessionManager.active.conversations;
        final panel = conversations.firstWhere((c) => c.id != main.id);
        expect(
          panel.driver,
          isA<_PanelScriptedDriver>(),
          reason: 'the panel session runs the replacement driver',
        );
        expect(
          factory.created,
          hasLength(1),
          reason: 'the delegated panel build consulted the seam',
        );
        expect(
          factory.requests,
          2,
          reason: 'main agent build + delegated panel build',
        );

        // The scripted driver actually owned the delegated turn.
        final scripted = panel.driver as _PanelScriptedDriver;
        expect(scripted.runInputs, contains('probe the seam'));

        // Focus wiring still works: the spawned panel can become the active
        // conversation (the bindSpawned contract).
        final frame = coordinator.spawnedPanels.single;
        coordinator.focusManager.focusPanel(frame);
        expect(coordinator.sessionManager.activeConversation, same(panel));
      },
    );
  });
}

String sideLabel(String id) => 'role ($id)';

/// A detached, full-width screen for background-host chats that are never
/// rendered in these tests — only their region's attach/detached state and
/// surface are inspected.
Screen _backgroundScreen() => Screen(
  io: FakeStdio()..columns = 120,
  layout: ScreenLayout.fromSize(120, 24),
);

/// Minimal [TerminalGeometry] backed by fixed columns/lines for tests.
class _Geometry implements TerminalGeometry {
  _Geometry({required this.columns, required this.lines});

  @override
  final int columns;

  @override
  final int lines;

  @override
  bool get hasTerminal => false;
}

/// Records handleResize + switchConversation and tracks the active conversation,
/// so the coordinator tests can assert focus→active wiring.
class _RecordingSessionManager extends SessionManager {
  _RecordingSessionManager({required Conversation initialConversation})
    : initialHost = initialConversation.host as TuiConversationHost,
      super(
        initialConversation: initialConversation,
        initialProviderId: 'test',
        initialApiKey: '',
        providerFactory: (id, key, model, url) => FakeProvider.done(),
        hostFactory: _hostFactory,
        agentBuilder: _agentBuilder,
      );

  /// The primary host (built for the initial conversation before this manager
  /// exists), exposed so the coordinator can bind it.
  final TuiConversationHost initialHost;

  final List<({String id, bool persist})> switchCalls = [];

  /// Register a background conversation so focus→active switching can reach it.
  void register(Conversation c) => active.addConversation(c);

  @override
  Future<void> persistSelection(
    ConversationSelection selection, {
    bool persist = true,
  }) async {
    switchCalls.add((id: selection.next.id, persist: persist));
    await super.persistSelection(selection, persist: persist);
  }
}

HostInterface _hostFactory({
  required String conversationId,
  required bool isActive,
}) => TuiConversationHost(
  conversationId: conversationId,
  chat: ScrollingTextRegion(_backgroundScreen())..detach(),
  spinner: Spinner(enabled: false),
  screen: _backgroundScreen(),
  active: isActive,
  // background conversations get their own (detached) screen reference;
  // the host's chat region is what matters for relayContent.
);

AgentDriver _agentBuilder({
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
    asker: (_) async => PermissionResponse.denyOnce,
    system: 'sys',
  ),
);

class _Prompt extends Renderer<ConversationPrompt> {
  @override
  List<RenderLine> render(ConversationPrompt value, RenderContext context) => [
    RenderLine(
      runs: [RenderRun('custom ${value.model.split('/').last} > ', null)],
    ),
  ];
}

Conversation _dummyConversation(String id, {bool detached = true}) {
  // Background conversation chats start detached (buffered) exactly like the
  // real hostFactory's; the primary chat is the exception (shared screen.chat,
  // attached) and is built with detached: false.
  final host = TuiConversationHost(
    conversationId: id,
    chat: ScrollingTextRegion(_backgroundScreen())..detach(),
    spinner: Spinner(enabled: false),
    screen: _backgroundScreen(),
    primary: false,
  );
  final conv = Conversation(
    id: id,
    label: sideLabel(id),
    driver: _agentBuilder(
      conversationId: id,
      provider: FakeProvider.done(),
      host: host,
      policy: PermissionPolicy(),
    ),
    provider: FakeProvider.done(),
    host: host,
    policy: PermissionPolicy(),
  );
  if (!detached) host.chat.attach();
  return conv;
}

/// A host whose [showMessage] calls are recorded, so read-only-input tests
/// can assert the notice without a rendered screen.
class _RecordingHost extends TuiConversationHost {
  _RecordingHost(String id)
    : super(
        conversationId: id,
        chat: ScrollingTextRegion(_backgroundScreen())..detach(),
        spinner: Spinner(enabled: false),
        screen: _backgroundScreen(),
        primary: false,
      );

  final List<String> messages = [];

  @override
  void showMessage(
    String message, {
    HostMessageStyle style = HostMessageStyle.normal,
  }) {
    messages.add(message);
  }
}

/// Records every [PanelFrame.setBusy] the coordinator drives, so tests can
/// verify the busy cue reaches the frame through the inverted callback.
class _RecordingPanelFrame extends PanelFrame {
  _RecordingPanelFrame({
    required super.screen,
    required String label,
    required super.conversationId,
  }) : super(label: label);

  final List<bool> busyCalls = [];

  @override
  void setBusy(bool busy) {
    busyCalls.add(busy);
    super.setBusy(busy);
  }
}

class _PlainContent implements PanelContent {
  final fits = <Rect>[];
  @override
  bool isDetached = true;
  @override
  BackendSurface? get surface => null;
  @override
  void fit(Rect interior, {required bool reserveInputRow}) =>
      fits.add(interior);
  @override
  void attach() => isDetached = false;
  @override
  void detach() => isDetached = true;
  @override
  void bindSurface(BackendSurface? surface) {}
  @override
  void repaint() {}
}

/// PR #49 regression: a live-panelized delegated sub-agent session must run
/// through the composition's driver seam. The coordinator's
/// [SubAgentSessionFactory] resolves its panel build through
/// [SubAgentScheduler.driverFor] and registers the panel [Conversation]
/// around the resulting driver, so a replacement [AgentDriverFactory] drives
/// the session's turns and surfaces as the conversation's driver. Before the
/// fix the factory built a bare [Agent] and the conversation defaulted to the
/// plain adapter — the scripted driver never saw the panel turn.

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
  @override
  PermissionPolicy get policy => PermissionPolicy();
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
    HistoryAppendObserver? onHistoryAppend,
    HistoryReplaceObserver? onHistoryReplace,
  }) async {
    runInputs.add(userInput);
    history.add(
      const Message(
        role: Role.assistant,
        content: [TextBlock('scripted reply')],
      ),
    );
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
  }) async => false;
}
