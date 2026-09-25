import 'package:tina_app/tina_app.dart';

import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina/platform/terminal_geometry.dart';

import 'package:tina/tui_coordinator.dart' show SpawnTree;
import 'package:tina/tui/spawn_panel_close.dart';
import 'package:tina/tui/conversation_panel_coordinator.dart';
import 'package:tina/tui/panel_manager.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_provider.dart';
import '../helpers/fake_stdio.dart';
import '../helpers/fake_terminal_geometry.dart';

/// Ctrl+X (editor.onClosePanel → [SpawnPanelCloseController]): closing a
/// focused spawned conversation panel — sub-agent, /spawn, /branch — tears
/// down frame, binding, and conversation in one gesture, restores focus/input
/// to the primary, and un-splits the layout when the last panel goes. The
/// primary is never closable; Ctrl+X with nothing closable focused is a
/// no-op (declined, never typed).
void main() {
  late FakeStdio io;
  late Screen screen;
  late FocusManager focusManager;
  late LineEditor editor;
  late TerminalGeometry geometry;
  late PanelFrame primaryFrame;
  late PanelManager panelManager;
  late SpawnTree tree;
  late _RecordingSessionManager sessionManager;
  late ConversationPanelCoordinator coordinator;
  late SpawnPanelCloseController closeController;
  var layoutCalls = 0;

  setUp(() {
    io = FakeStdio()..columns = 120;
    final layout = ScreenLayout.fromSize(120, 24, split: true);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    focusManager = FocusManager();
    editor = LineEditor(screen: screen);
    geometry = const FakeTerminalGeometry(columns: 120, lines: 24);
    primaryFrame = PanelFrame(
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
    );
    sessionManager = _RecordingSessionManager(
      initialConversation: _dummyConversation('primary', detached: false),
    );
    coordinator = ConversationPanelCoordinator(
      panelManager: panelManager,
      sessionManager: sessionManager,
      editor: editor,
      primaryHost: sessionManager.initialHost,
    );
    coordinator.bindPrimary(conversationId: 'primary');
    focusManager
      ..register(primaryFrame)
      ..home = primaryFrame;
    panelManager.layout();
    coordinator.relayContent();

    layoutCalls = 0;
    closeController = SpawnPanelCloseController(
      sessionManager: sessionManager,
      panelManager: panelManager,
      contentCoordinator: coordinator,
      refreshLayout: () {
        layoutCalls++;
        panelManager.applyScreenLayout(
          split: panelManager.hasSpawnedFrames,
          drawInfoFrame: !panelManager.hasSpawnedFrames,
        );
        panelManager.layout();
        coordinator.relayContent();
      },
    );
    editor.onClosePanel = closeController.closeFocused;
  });

  tearDown(() {
    editor.onClosePanel = null;
    coordinator.dispose();
    panelManager.dispose();
    editor.close();
    io.close();
  });

  /// Bind a spawned conversation panel the way [_buildSpawnPanel] does
  /// (coordinator bind + tree edge), then focus it so Ctrl+X targets it.
  PanelFrame bindFocusedSpawn(String id) {
    final conv = _dummyConversation(id);
    sessionManager.register(conv);
    final frame = coordinator.bindSpawned(
      host: conv.host as TuiConversationHost,
      label: 'side ($id)',
    );
    tree.parentOf[id] = 'primary';
    tree.baseLabel[id] = 'side ($id)';
    focusManager.focusPanel(frame);
    return frame;
  }

  test('Ctrl+X on a focused spawned panel closes it end to end', () {
    final frame = bindFocusedSpawn('side');
    expect(focusManager.focused, same(frame));

    expect(closeController.closeFocused(), isTrue);

    // The frame is gone from the tiling list and the ring; focus and the
    // shared input came home to the primary.
    expect(panelManager.spawnedFrames, isNot(contains(frame)));
    expect(focusManager.focused, same(primaryFrame));
    expect(panelManager.focusManager.home, same(primaryFrame));

    // The conversation left the session (the harness overrides
    // closeConversation to record instead of defer-release; the call and the
    // in-memory removal are what this controller owns).
    expect(sessionManager.closedConversations, [
      (sessionId: sessionManager.active.id, conversationId: 'side'),
    ]);
    expect(sessionManager.active.conversationById('side'), isNull);

    // The frame↔host binding was dropped (a live agent can no longer repaint
    // the dead frame) and the tree forgot the edge + label.
    expect(frame.onFocus, isNull);
    expect(frame.onScroll, isNull);
    expect(frame.inputPrompt, isNull);
    expect(tree.parentOf.containsKey('side'), isFalse);
    expect(tree.baseLabel.containsKey('side'), isFalse);

    // The canonical relayout ran (un-split on the last panel).
    expect(layoutCalls, 1);
  });

  test('relayout attaches the surviving panels only', () {
    final a = bindFocusedSpawn('a');
    bindFocusedSpawn('b');
    // Both bound; 'b' holds focus (bound second). Close 'b'.
    expect(closeController.closeFocused(), isTrue);
    expect(panelManager.spawnedFrames, [a]);
    expect(tree.parentOf['a'], 'primary');
    expect(tree.baseLabel.containsKey('b'), isFalse);
    // The surviving panel's chat is still attached (relaid into its slot).
    final hostA =
        sessionManager.active.conversationById('a')!.host
            as TuiConversationHost;
    expect(hostA.chat.isDetached, isFalse);
  });

  test('Ctrl+X on the primary is declined — it is never closable', () {
    focusManager.focusPanel(primaryFrame);
    expect(closeController.closeFocused(), isFalse);
    expect(sessionManager.closedConversations, isEmpty);
    expect(panelManager.spawnedFrames, isEmpty);
  });

  test('Ctrl+X with nothing focused is a no-op', () {
    // Unregister the primary so the ring holds no focus at all
    // (FocusManager reports null) — the controller's first guard.
    focusManager.unregister(primaryFrame);
    expect(focusManager.focused, isNull);
    expect(closeController.closeFocused(), isFalse);
    expect(sessionManager.closedConversations, isEmpty);
  });

  test('a frame with no session conversation is not closable', () {
    // The host-only panel shape (e.g. the first-load environment panel):
    // bound by id but never registered as a Conversation.
    final host = TuiConversationHost(
      conversationId: 'host-only',
      chat: ScrollingTextRegion(screen)..detach(),
      spinner: Spinner(enabled: false),
      screen: screen,
      primary: false,
    );
    final frame = coordinator.bindSpawned(host: host, label: 'env');
    focusManager.focusPanel(frame);
    expect(closeController.closeFocused(), isFalse);
    expect(panelManager.spawnedFrames, contains(frame));
    frame.dispose();
  });

  test('binding a replacement panel after a close works (ids are free)', () {
    final first = bindFocusedSpawn('side');
    expect(closeController.closeFocused(), isTrue);
    final again = bindFocusedSpawn('side');
    expect(panelManager.spawnedFrames, [again]);
    expect(first, isNot(same(again)));
  });
}

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

  final TuiConversationHost initialHost;

  final List<({String sessionId, String conversationId})> closedConversations =
      [];

  /// Register a background conversation so focus→active switching can reach it.
  void register(Conversation c) => active.addConversation(c);

  @override
  void closeConversation(String sessionId, String conversationId) {
    closedConversations.add((
      sessionId: sessionId,
      conversationId: conversationId,
    ));
    // The real closeConversation _deferReleases provider/host/turn futures —
    // heavyweight for a unit test. Reproduce only the in-memory removal the
    // controller's teardown depends on (removeConversation re-anchors the
    // session's active id away from a removed conversation).
    active.removeConversation(conversationId);
  }
}

HostInterface _hostFactory({
  required String conversationId,
  required bool isActive,
}) => TuiConversationHost(
  conversationId: conversationId,
  chat: ScrollingTextRegion(
    Screen(io: FakeStdio(), layout: ScreenLayout.fromSize(80, 24)),
  )..detach(),
  spinner: Spinner(enabled: false),
  screen: Screen(io: FakeStdio(), layout: ScreenLayout.fromSize(80, 24)),
  active: isActive,
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

Conversation _dummyConversation(String id, {bool detached = true}) {
  final host = TuiConversationHost(
    conversationId: id,
    chat: ScrollingTextRegion(
      Screen(io: FakeStdio(), layout: ScreenLayout.fromSize(80, 24)),
    )..detach(),
    spinner: Spinner(enabled: false),
    screen: Screen(io: FakeStdio(), layout: ScreenLayout.fromSize(80, 24)),
    primary: false,
  );
  final conv = Conversation(
    id: id,
    label: id,
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
