import 'package:tina/conversation.dart';
import 'package:tina/chat_agent_sink.dart';
import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina/platform/terminal_geometry.dart';
import 'package:tina/session_manager.dart';
import 'package:tina/tui_coordinator.dart' show SpawnTree;
import 'package:tina/tui/conversation_panel_coordinator.dart';
import 'package:tina/tui/panel_host.dart';
import 'package:tina/tui/panel_manager.dart';
import 'package:tina/tui/resize_coordinator.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_provider.dart';
import '../helpers/fake_stdio.dart';
import '../helpers/fake_terminal_geometry.dart';

/// Pins [PanelHost] — the panel-provider seam (design of record §4.4) — for
/// the workflow run panel it currently serves: the handle is synchronous and
/// sink-bearing, open/close mirror each other (first-panel split, last-panel
/// unsplit), the spec's label/conversationId flow through untouched, and the
/// read-only key wiring (s stop / x close / consumed text) keeps its meaning.
void main() {
  late FakeStdio io;
  late Screen screen;
  late FocusManager focusManager;
  late LineEditor editor;
  late TerminalGeometry geometry;
  late PanelFrame primaryFrame;
  late SpawnTree tree;
  late PanelManager panelManager;
  late _RecordingSessionManager sessionManager;
  late ConversationPanelCoordinator contentCoordinator;
  late ResizeCoordinator resizeCoordinator;
  late TuiConversationHost initialHost;
  late PanelHost panelHost;

  /// A spawned-style host over a fresh background screen — the same shape
  /// the coordinator's factory builds (detached region, inactive host).
  TuiConversationHost makeSinkHost(String conversationId) {
    final layout = ScreenLayout.fromSize(120, 24, split: true);
    final bg = Screen(
        io: FakeStdio()..columns = 120, layout: layout, ansi: AnsiCapable.yes);
    return TuiConversationHost(
      conversationId: conversationId,
      chat: ScrollingTextRegion(bg, bounds: bg.layout.info)..detach(),
      spinner: Spinner(enabled: false),
      screen: bg,
      editor: editor,
      active: false,
      primary: false,
    );
  }

  setUp(() {    io = FakeStdio()..columns = 120;
    final layout =
        ScreenLayout.fromSize(120, 24, split: true, drawInfoFrame: false);
    screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
    focusManager = FocusManager();
    editor = LineEditor(screen: screen);
    geometry = const FakeTerminalGeometry(columns: 120, lines: 24);
    primaryFrame = PanelFrame(
      screen: screen,
      label: 'primary',
      conversationId: 'primary',
    )..setReservesInput(true);
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
    initialHost = sessionManager.initialHost;
    contentCoordinator = ConversationPanelCoordinator(
      panelManager: panelManager,
      sessionManager: sessionManager,
      editor: editor,
      primaryHost: initialHost,
    );
    contentCoordinator.bindPrimary(conversationId: 'primary');
    resizeCoordinator = ResizeCoordinator(
      sessionManager: sessionManager,
      menuBar: MenuBar(screen, const []),
      editor: editor,
      panelManager: panelManager,
      relayContent: contentCoordinator.relayContent,
      relocateInput: contentCoordinator.relocateInput,
    );
    panelHost = PanelHost(
      screen: screen,
      panelManager: panelManager,
      contentCoordinator: contentCoordinator,
      resizeCoordinator: resizeCoordinator,
      tree: tree,
      initialHost: initialHost,
      makeSinkHost: makeSinkHost,
    );
  });

  /// The spec every test opens with (the coordinator's run-panel spec).
  PanelSpec spec() => (
        label: 'wf deploy [run r-1]',
        conversationId: 'wf-run-r-1',
        placement: PanelPlacement.sideColumn,
      );

  /// Open with bookkeeping sinks + actions, returning what was wired.
  ({OpenedPanel handle, TuiConversationHost? sink, bool Function() closed})
      open({
    String label = 'wf deploy [run r-1]',
    String conversationId = 'wf-run-r-1',
  }) {
    var sinkHost;
    var closed = false;
    final handle = panelHost.openPanel(
      (
        label: label,
        conversationId: conversationId,
        placement: PanelPlacement.sideColumn,
      ),
      installSink: (host) => sinkHost = host,
      onStop: () {},
      onClose: () => closed = true,
    );
    return (
      handle: handle,
      sink: sinkHost,
      closed: () => closed,
    );
  }

  group('openPanel', () {
    test('returns a synchronous, sink-bearing handle', () {
      // `installSink` must run before openPanel returns — the supervisor's
      // onLaunch contract: the run's stream sink is in place before the
      // launch stream can start.
      final r = open();
      expect(r.sink, same(r.handle.host),
          reason: 'the handle\'s host is what the caller installs as sink');
      expect(panelHost.panelFor('wf-run-r-1'), same(r.handle));
    });

    test('flows the spec label and conversationId through untouched', () {
      final r = open(
          label: 'wf e2e [run 7f3a]',
          conversationId: 'wf-run-7f3a');
      expect(r.handle.frame.label, 'wf e2e [run 7f3a]');
      expect(r.handle.frame.conversationId, 'wf-run-7f3a');
      // The tree edge is depth-1 under the root, with the clean label.
      expect(tree.parentOf['wf-run-7f3a'], tree.rootId);
      expect(tree.baseLabel['wf-run-7f3a'], 'wf e2e [run 7f3a]');
    });

    test('the panel content is a read-only extra that does not reserve input',
        () {
      final r = open();
      expect(r.handle.frame.reservesInput, isFalse,
          reason: 'the frame never binds the shared editor');
      // Focusing the read-only panel repoints the shared input at the
      // primary chat (there is no conversation here to route input to).
      r.handle.frame.focus();
      final b = screen.input.bounds;
      expect(b.row, primaryFrame.inputRect.row);
      expect(b.col, primaryFrame.inputRect.col);
      expect(b.width, primaryFrame.inputRect.width);
      expect(b.height, primaryFrame.inputRect.height);
      r.handle.frame.dispose();
    });

    test('first open splits the layout; an already-open second panel tiles',
        () {
      expect(panelManager.hasSpawnedFrames, isFalse);
      expect(screen.layout.isSplit, isTrue); // split:true layout — info box
      final first = open(conversationId: 'wf-run-a');
      expect(initialHost.stayAttachedWhenInactive, isTrue,
          reason: 'first panel keeps the chat visible beside the column');
      expect(panelManager.spawnedFrames, hasLength(1));

      final second = open(
          label: 'wf test [run b]',
          conversationId: 'wf-run-b');
      expect(second.sink, isNotNull);
      expect(panelManager.spawnedFrames, hasLength(2));
      // stayAttachedWhenInactive stays set while panels remain.
      expect(initialHost.stayAttachedWhenInactive, isTrue);
      second.handle.frame.dispose();
      first.handle.frame.dispose();
    });
  });

  group('closePanel', () {
    test('removes the frame and detaches the content, panel-by-panel', () {
      final first = open(conversationId: 'wf-run-a');
      final second = open(
          label: 'wf test [run b]',
          conversationId: 'wf-run-b');

      panelHost.closePanel(first.handle);
      expect(panelManager.spawnedFrames, hasLength(1));
      expect(panelHost.panelFor('wf-run-a'), isNull);
      expect(tree.parentOf.containsKey('wf-run-a'), isFalse,
          reason: 'the tree edge is dropped with the frame');
      expect(tree.baseLabel.containsKey('wf-run-a'), isFalse);
      expect(first.handle.content.isDetached, isTrue,
          reason: 'the transcript parks (detached) until the region dies');
      // The column still has a panel: no unsplit yet.
      expect(initialHost.stayAttachedWhenInactive, isTrue);

      panelHost.closePanel(second.handle);
      expect(panelManager.spawnedFrames, isEmpty);
    });

    test('closing exactly the last panel unsplits (split-flag mirror)', () {
      final r = open();
      expect(initialHost.stayAttachedWhenInactive, isTrue);

      panelHost.closePanel(r.handle);

      expect(initialHost.stayAttachedWhenInactive, isFalse,
          reason: 'last close mirrors the first-panel split');
      expect(panelManager.spawnedFrames, isEmpty);
      expect(panelHost.panelFor('wf-run-r-1'), isNull);
    });

    test('an already-closed handle is a no-op (idempotent close)', () {
      final r = open();
      panelHost.closePanel(r.handle);
      final framesAfterFirst = panelManager.spawnedFrames.length;
      panelHost.closePanel(r.handle);
      expect(panelManager.spawnedFrames.length, framesAfterFirst);
      expect(r.closed(), isFalse,
          reason: 'the close action belongs to the caller; closePanel only '
              'tears down');
    });

    test('the close path keeps working for open→close→open (same id)', () {
      final first = open();
      panelHost.closePanel(first.handle);

      final second = open();
      expect(panelHost.panelFor('wf-run-r-1'), same(second.handle));
      expect(panelManager.spawnedFrames, hasLength(1));
      expect(second.sink, same(second.handle.host));
      expect(initialHost.stayAttachedWhenInactive, isTrue);
      second.handle.frame.dispose();
    });

    test('open→close→open→close leaves the host registry consistent', () {
      for (var i = 0; i < 2; i++) {
        final r = open();
        expect(panelManager.spawnedFrames, hasLength(1));
        panelHost.closePanel(r.handle);
        expect(panelManager.spawnedFrames, isEmpty);
        expect(panelHost.panelFor('wf-run-r-1'), isNull);
      }
    });
  });

  group('read-only keys', () {
    test("'s' invokes the stop action and is consumed", () {
      var stopped = false;
      final handle = panelHost.openPanel(
        spec(),
        installSink: (_) {},
        onStop: () => stopped = true,
        onClose: () {},
      );
      final consumed = handle.frame.onPanelKey!(CharInput('s'));
      expect(consumed, isTrue);
      expect(stopped, isTrue);
      expect(panelHost.panelFor('wf-run-r-1'), same(handle),
          reason: 'stop does not close the panel');
      handle.frame.dispose();
    });

    test("'x' invokes the close action and is consumed", () {
      var closed = false;
      final handle = panelHost.openPanel(
        spec(),
        installSink: (_) {},
        onStop: () {},
        onClose: () => closed = true,
      );
      final consumed = handle.frame.onPanelKey!(CharInput('x'));
      expect(consumed, isTrue);
      expect(closed, isTrue);
      handle.frame.dispose();
    });

    test('text is consumed with a one-time dim notice; navigation falls through',
        () {
      final handle = panelHost.openPanel(
        spec(),
        installSink: (_) {},
        onStop: () {},
        onClose: () {},
      );
      expect(handle.frame.onPanelKey!(CharInput('a')), isTrue);
      expect(handle.frame.onPanelKey!(CharInput('b')), isTrue);
      // The dim notice renders in the run panel's own transcript (its host's
      // chat), exactly like the pre-refactor site.
      final transcript = handle.host.chat.snapshotLines().join('\n');
      expect(transcript, contains('input disabled'));
      // One-time: exactly one notice even after more text keys.
      expect(handle.frame.onPanelKey!(CharInput('c')), isTrue);
      expect(
        'input disabled'
            .allMatches(handle.host.chat.snapshotLines().join('\n')),
        hasLength(1),
      );

      // Navigation events are not consumed — PgUp/PgDn reach the frame's
      // scroll hook, and other keys fall through to the editor.
      expect(handle.frame.onPanelKey!(ScrollEvent(up: true)), isFalse);
      expect(handle.frame.onWheel, isNotNull, reason: 'wheel scrolls too');
      handle.frame.dispose();
    });

    test('scroll hooks drive the transcript scrollback and its badge', () {
      final r = open();
      final handle = r.handle;
      // Stream some content so there is history to scroll through, then
      // scroll a page back via the frame hook.
      final sink = ChatAgentSink(handle.host.chat, Spinner(enabled: false));
      sink.notice('▶ intake');
      for (var i = 0; i < 40; i++) {
        sink.text('line $i of the transcript');
        sink.newline();
      }
      handle.frame.onScroll!(-1);
      expect(handle.host.chat.debugScrollOffset, greaterThan(0),
          reason: 'PgUp-equivalent scrolled back into history');
      // The counter accrues only when a row advances while the window is
      // anchored up in history — stream one more line now that we are.
      sink.text('late arrival');
      sink.newline();
      expect(handle.host.chat.newWhileScrolled, isNonZero,
          reason: 'content arrived while scrolled up');
      // The scrollback hook mirrors that counter onto the frame badge.
      handle.host.chat.onScrollbackChanged!();
      expect(io.written.toString(), contains('new'),
          reason: 'the frame title carries the ↓ N new badge');

      // The wheel hook scrolls by rows (delta rows per tick).
      handle.frame.onWheel!(2);
      expect(handle.host.chat.debugScrollOffset,
          greaterThan(0));
      handle.frame.dispose();
    });

    test('setFinished settles the busy cue hook for the run completion', () {
      final r = open();
      // The coordinator wires run.onFinished = handle.setFinished; it must
      // be callable after close without touching a dead frame's geometry.
      r.handle.setFinished();
      panelHost.closePanel(r.handle);
      r.handle.setFinished(); // no throw
    });
  });
}

/// A session manager over one real (fake-provider) conversation, mirroring
/// the coordinator test's recording stub.
class _RecordingSessionManager extends SessionManager {
  _RecordingSessionManager({required Conversation initialConversation})
      : initialHost = initialConversation.host as TuiConversationHost,
        super(
          initialConversation: initialConversation,
          initialProviderId: 'test',
          initialApiKey: '',
          providerFactory: (id, key, model, url) => FakeProvider.done(),
          hostFactory: _backgroundHostFactory,
          agentBuilder: _agentBuilder,
        );

  /// The primary host (built for the initial conversation before this
  /// manager exists), exposed so the coordinator can bind it.
  final TuiConversationHost initialHost;
}

HostInterface _backgroundHostFactory({
  required String conversationId,
  required bool isActive,
}) =>
    TuiConversationHost(
      conversationId: conversationId,
      chat: ScrollingTextRegion(_backgroundScreen())..detach(),
      spinner: Spinner(enabled: false),
      screen: _backgroundScreen(),
      active: isActive,
      primary: false,
    );

Screen _backgroundScreen() => Screen(
    io: FakeStdio()..columns = 120,
    layout: ScreenLayout.fromSize(120, 24));

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
  final host = TuiConversationHost(
    conversationId: id,
    chat: ScrollingTextRegion(_backgroundScreen())..detach(),
    spinner: Spinner(enabled: false),
    screen: _backgroundScreen(),
    primary: false,
  );
  final conv = Conversation(
    id: id,
    label: id,
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
