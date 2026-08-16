import 'package:tina/conversation.dart';
import 'package:tina/platform/terminal_geometry.dart';
import 'package:tina/session_manager.dart';
import 'package:tina/tui_coordinator.dart' show SpawnTree;
import 'package:tina/tui/panel_manager.dart';
import 'package:tina/tui/resize_coordinator.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_provider.dart';
import '../helpers/fake_stdio.dart';

/// Unit tests for [ResizeCoordinator]: the seam that Phase 4 collapsed the
/// duplicated resize sequence (SIGWINCH handler + the three first-spawn blocks)
/// into. Driving [ResizeCoordinator] directly (no coordinator, no overlays, no
/// chat) is the point of the extraction — the behavior used to be scattered
/// across create()-local closures that could only be exercised through the full
/// run() path.
void main() {
  // Records the canonical order so we can assert the load-bearing sequence
  // runs exactly once per resize, in the pinned order.
  late List<String> order;
  late Screen screen;

  setUp(() {
    order = <String>[];
    final io = FakeStdio()..columns = 120;
    final layout = ScreenLayout.fromSize(120, 24,
        split: true, drawInfoFrame: false);
    screen = _RecordingScreen(
      io: io,
      layout: layout,
      ansi: AnsiCapable.yes,
      order: order,
    );
  });

  ResizeCoordinator _coordinator() {
    final focusManager = FocusManager();
    final editor = _RecordingEditor(screen, order);
    final primary = PanelFrame(
      screen: screen,
      label: 'primary',
      conversationId: 'primary',
    )..setReservesInput(true);
    final tree = SpawnTree(rootId: primary.conversationId);
    final pm = PanelManager(
      screen: screen,
      focusManager: focusManager,
      editor: editor,
      primaryFrame: primary,
      terminalGeometry: _Geometry(columns: 120, lines: 24),
      menuBarEnabled: false,
      tree: tree,
    );
    return ResizeCoordinator(
      sessionManager: _RecordingSessionManager(order),
      menuBar: _RecordingMenuBar(screen, order),
      editor: editor,
      panelManager: _RecordingPanelManager(pm, order),
      relayContent: () => order.add('relayContent'),
      relocateInput: ({bool force = false}) => order.add('relocateInput'),
    );
  }

  group('canonical order', () {
    test('runs the pinned sequence exactly once per resize', () {
      _coordinator().handleResize(split: true, drawInfoFrame: false);

      expect(
        order,
        [
          'panelManager.applyScreenLayout',
          'sessionManager.handleResize',
          'menuBar.render',
          'editor.handleResize',
          'panelManager.layout',
          'relayContent',
          'relocateInput',
          'screen.refresh',
        ],
      );
    });

    test('passes split/drawInfoFrame through to applyScreenLayout', () {
      final pm = _RecordingPanelManager(
        PanelManager(
          screen: screen,
          focusManager: FocusManager(),
          editor: LineEditor(screen: screen),
          primaryFrame: PanelFrame(
            screen: screen,
            label: 'primary',
            conversationId: 'primary',
          ),
          terminalGeometry: _Geometry(columns: 120, lines: 24),
          menuBarEnabled: false,
          tree: SpawnTree(rootId: 'primary'),
        ),
        order,
      );
      final c = ResizeCoordinator(
        sessionManager: _RecordingSessionManager(order),
        menuBar: _RecordingMenuBar(screen, order),
        editor: _RecordingEditor(screen, order),
        panelManager: pm,
        relayContent: () => order.add('relayContent'),
        relocateInput: ({bool force = false}) => order.add('relocateInput'),
      );

      c.handleResize(split: true, drawInfoFrame: false);
      expect(pm.lastSplit, isTrue);
      expect(pm.lastDrawInfoFrame, isFalse);

      // Spawned panels keep the split; the info frame stays hidden and a later
      // no-split transition flips drawInfoFrame back to true.
      c.handleResize(split: true, drawInfoFrame: false);
      c.handleResize(split: false, drawInfoFrame: true);
      expect(pm.lastSplit, isFalse);
      expect(pm.lastDrawInfoFrame, isTrue);
    });
  });
}

/// Records the post-resize full re-emission ([Screen.refresh]) into the
/// shared [order] list, so the canonical sequence pins the refresh as the
/// final step of every resize (see ResizeCoordinator.handleResize).
class _RecordingScreen extends Screen {
  _RecordingScreen({
    required super.io,
    required super.layout,
    super.ansi,
    required this.order,
  });

  final List<String> order;

  @override
  void refresh() {
    order.add('screen.refresh');
    super.refresh();
  }
}

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

/// Records handleResize() into the shared [order] list.
class _RecordingSessionManager extends SessionManager {
  _RecordingSessionManager(this.order)
      : super(
          initialConversation: _dummyConversation,
          initialProviderId: 'test',
          initialApiKey: '',
          providerFactory: (id, key, model, url) => FakeProvider.done(),
          hostFactory: ({required String conversationId, required bool isActive}) =>
              HeadlessHost(),
          agentBuilder: ({
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
                asker: host.askPermission,
                system: 'sys',
              ),
        );

  final List<String> order;

  @override
  void handleResize() => order.add('sessionManager.handleResize');
}

/// Records render() into the shared [order] list.
class _RecordingMenuBar extends MenuBar {
  _RecordingMenuBar(Screen screen, this.order) : super(screen, const []);

  final List<String> order;

  @override
  void render() => order.add('menuBar.render');
}

/// Records handleResize() (then defers to the real editor).
class _RecordingEditor extends LineEditor {
  _RecordingEditor(Screen screen, this.order) : super(screen: screen);

  final List<String> order;

  @override
  void handleResize() {
    order.add('editor.handleResize');
    super.handleResize();
  }
}

/// Records applyScreenLayout() args + layout() (then defers to the real manager).
class _RecordingPanelManager extends PanelManager {
  _RecordingPanelManager(PanelManager delegate, this.order)
      : _delegate = delegate,
        super(
          screen: delegate.screen,
          focusManager: delegate.focusManager,
          editor: delegate.editor,
          primaryFrame: delegate.primaryFrame,
          terminalGeometry: delegate.terminalGeometry,
          menuBarEnabled: delegate.menuBarEnabled,
          tree: delegate.tree,
        );

  final PanelManager _delegate;
  final List<String> order;
  bool? lastSplit;
  bool? lastDrawInfoFrame;

  @override
  void applyScreenLayout({required bool split, required bool drawInfoFrame}) {
    lastSplit = split;
    lastDrawInfoFrame = drawInfoFrame;
    order.add('panelManager.applyScreenLayout');
    _delegate.applyScreenLayout(split: split, drawInfoFrame: drawInfoFrame);
  }

  @override
  void layout() {
    order.add('panelManager.layout');
    _delegate.layout();
  }
}

// A throwaway Conversation for the recording SessionManager's constructor — it's
// never exercised (handleResize is overridden), but the super constructor
// requires one.
final _dummyConversation = Conversation(
  id: 'dummy',
  label: 'dummy',
  agent: Agent(
    provider: FakeProvider.done(),
    tools: ToolRegistry(const []),
    sink: HeadlessHost(),
    policy: PermissionPolicy(),
    asker: (_) async => PermissionResponse.denyOnce,
    system: 'sys',
  ),
  provider: FakeProvider.done(),
  host: HeadlessHost(),
  policy: PermissionPolicy(),
);
