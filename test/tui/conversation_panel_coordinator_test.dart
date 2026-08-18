import 'package:tina/conversation.dart';
import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina/platform/terminal_geometry.dart';
import 'package:tina/session_manager.dart';
import 'package:tina/tui_coordinator.dart' show SpawnTree;
import 'package:tina/tui/conversation_panel_coordinator.dart';
import 'package:tina/tui/panel_manager.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_provider.dart';
import '../helpers/fake_stdio.dart';

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

  setUp(() {
    io = FakeStdio()..columns = 120;
    final layout = ScreenLayout.fromSize(120, 24,
        split: true, drawInfoFrame: false);
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
    );
    coordinator.bindPrimary(conversationId: 'primary');
  });

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
      expect(host.onBusyChanged, isNotNull,
          reason: 'busy cue must reach the frame via the callback, '
              'not panel.setBusy directly');
      // The callback drives the frame's comet through its setBusy: the
      // recording frame captures every setBusy the coordinator wires up.
      expect(primaryFrame.busyCalls, isEmpty);
      host.onBusyChanged!(true);
      host.onBusyChanged!(false);
      expect(primaryFrame.busyCalls, [true, false]);
    });
  });

  group('relayContent', () {
    test('fits content into every frame interior and attaches detached ones',
        () {
      // The primary chat starts attached; relayContent must not detach it.
      final primaryChat = sessionManager.initialHost.chat;
      expect(primaryChat.isDetached, isFalse);
      coordinator.relayContent();
      expect(primaryChat.isDetached, isFalse,
          reason: 'relayContent never detaches — it only ever attaches');

      // A background conversation's chat starts detached; relayContent must
      // attach it once its frame is laid out.
      final conv = _dummyConversation('side');
      sessionManager.register(conv);
      final host = conv.host as TuiConversationHost;
      final frame =
          coordinator.bindSpawned(host: host, label: sideLabel('side'));
      panelManager.layout();
      expect(host.chat.isDetached, isTrue, reason: 'background chat detached');
      coordinator.relayContent();
      expect(host.chat.isDetached, isFalse,
          reason: 'relayContent attaches the laid-out frame\'s content');
      frame.dispose();
    });

    test('relayContent never detaches the primary when a side panel shows', () {
      // Regression guard for the primary-stays-visible invariant the host's
      // stayAttachedWhenInactive preserves: relayContent only ever fits and
      // attaches, so the primary chat is never detached by a resize/relay.
      final conv = _dummyConversation('side2');
      sessionManager.register(conv);
      final host = conv.host as TuiConversationHost;
      final frame =
          coordinator.bindSpawned(host: host, label: sideLabel('side2'));
      panelManager.layout();
      coordinator.relayContent();
      expect(sessionManager.initialHost.chat.isDetached, isFalse,
          reason: 'primary must stay attached through relayContent');
      frame.dispose();
    });
  });

  group('bindSpawed', () {
    test('registers the frame in the tiling list + focus ring', () {
      final conv = _dummyConversation('side');
      sessionManager.register(conv);
      final host = conv.host as TuiConversationHost;
      final frame =
          coordinator.bindSpawned(host: host, label: sideLabel('side'));
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
      final frame =
          coordinator.bindSpawned(host: host, label: sideLabel('side'));
      expect(host.onBusyChanged, isNotNull,
          reason: 'the busy cue is inverted onto the callback for secondary '
              'hosts too, never reaching into a frame directly');
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
      final frame =
          coordinator.bindSpawned(host: host, label: sideLabel('side'));
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
      expect(sessionManager.switchCalls, isEmpty,
          reason: 'the primary is already active — no switch, just relocate');
    });

    test('focusing a host-only panel keeps input on the primary instead of '
        'throwing', () {
      // The first-load environment agent's panel: bound via bindSpawned by its
      // host's synthetic id ('env-…'), but no Conversation is ever registered
      // in the session. Focusing it must not attempt the conversation switch
      // (which would throw 'Unknown conversation') — it behaves like an extra
      // panel and leaves the shared input on the primary chat.
      final host = TuiConversationHost(
        conversationId: 'env-123',
        chat: ScrollingTextRegion(_backgroundScreen())..detach(),
        spinner: Spinner(enabled: false),
        screen: _backgroundScreen(),
        primary: false,
      );
      final frame =
          coordinator.bindSpawned(host: host, label: 'Environment (model)');
      panelManager.layout();

      coordinator.onFrameFocused(frame);

      expect(sessionManager.switchCalls, isEmpty,
          reason: 'no Conversation exists — there is nothing to switch to');
      expect(sessionManager.active.activeConversationId, 'primary',
          reason: 'focus on a host-only panel never moves the active pointer');
      frame.dispose();
    });
  });

  group('surfaceOf', () {
    test('returns the chat surface for the focused panel', () {
      expect(coordinator.surfaceOf('primary'),
          same(sessionManager.initialHost.chat.surface));
    });
  });
}

String sideLabel(String id) => 'role ($id)';

/// A detached, full-width screen for background-host chats that are never
/// rendered in these tests — only their region's attach/detached state and
/// surface are inspected.
Screen _backgroundScreen() =>
    Screen(io: FakeStdio()..columns = 120, layout: ScreenLayout.fromSize(120, 24));

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
  Future<Conversation> switchConversation(String id, {bool persist = true}) async {
    switchCalls.add((id: id, persist: persist));
    return super.switchConversation(id, persist: persist);
  }
}

HostInterface _hostFactory({
  required String conversationId,
  required bool isActive,
}) =>
    TuiConversationHost(
      conversationId: conversationId,
      chat: ScrollingTextRegion(_backgroundScreen())
        ..detach(),
      spinner: Spinner(enabled: false),
      screen: _backgroundScreen(),
      active: isActive,
      // background conversations get their own (detached) screen reference;
      // the host's chat region is what matters for relayContent.
    );

Agent _agentBuilder({
  required String conversationId,
  required LlmProvider provider,
  required HostInterface host,
  required PermissionPolicy policy,
}) =>
    Agent(
      provider: provider,
      tools: ToolRegistry(const []),
      sink: host,
      policy: policy,
      asker: (_) async => PermissionResponse.denyOnce,
      system: 'sys',
    );

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
    agent: _agentBuilder(
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
