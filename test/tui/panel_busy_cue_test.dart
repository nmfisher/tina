import 'dart:async';

import 'package:attractor/attractor.dart';
import 'package:tina/conversation.dart';
import 'package:tina/host/tui_conversation_host.dart';
import 'package:tina/pipeline/workflow_supervisor.dart';
import 'package:tina/platform/terminal_geometry.dart';
import 'package:tina/session_controller.dart';
import 'package:tina/session_manager.dart';
import 'package:tina/tui_coordinator.dart' show SpawnTree;
import 'package:tina/tui/conversation_panel_coordinator.dart';
import 'package:tina/tui/panel_manager.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_stdio.dart';

/// tin-y4qn regression tests: the panel busy cue (the border comet) must track
/// the panel's own conversation activity, NOT which panel is focused.
///
/// The harness mirrors the real TUI wiring at 1:1 fidelity for the two-panel
/// case: a real [Screen] over [FakeStdio], a real [PanelManager] +
/// [ConversationPanelCoordinator] binding the primary and a spawned side panel
/// to real [PanelFrame]s, and a real [SessionController] driving turns. The
/// busy cue is recorded by wrapping each host's `onBusyChanged` after the
/// coordinator binds it — the exact signal the frame's comet consumes.
///
/// The provider is gate-controlled so a test can hold a turn mid-flight while
/// focus moves, then complete it deterministically.
void main() {
  late FakeStdio io;
  late Screen screen;
  late FocusManager focusManager;
  late LineEditor editor;
  late PanelManager panelManager;
  late ConversationPanelCoordinator coordinator;
  late SessionManager sessionManager;
  late SessionController controller;
  late _FakeReadLine rl;
  late _GateProvider mainGate;
  late _GateProvider sideGate;
  late Conversation mainConv;
  late Conversation sideConv;
  late TuiConversationHost mainHost;
  late TuiConversationHost sideHost;
  late PanelFrame sideFrame;
  late List<bool> mainCue;
  late List<bool> sideCue;

  setUp(() {
    io = FakeStdio()..columns = 120;
    screen = Screen(
      io: io,
      layout: ScreenLayout.fromSize(120, 24, split: true, drawInfoFrame: false),
      ansi: AnsiCapable.yes,
    );
    focusManager = FocusManager();
    editor = LineEditor(screen: screen);
    mainGate = _GateProvider('main');
    sideGate = _GateProvider('side');

    mainHost = TuiConversationHost(
      conversationId: 'main',
      chat: screen.chat,
      screen: screen,
      spinner: Spinner(enabled: false, region: screen.status),
      editor: editor,
      active: true,
    );
    // Side panels share the screen: the primary stays attached (visible) when
    // focus moves away — the production configuration once a panel is spawned.
    mainHost.stayAttachedWhenInactive = true;
    mainConv = _conversation('main', mainGate, mainHost);

    sessionManager = SessionManager(
      initialConversation: mainConv,
      initialProviderId: 'test',
      initialApiKey: '',
      providerFactory: (id, key, model, url) => _GateProvider('bg'),
      hostFactory: _unusedHostFactory,
      agentBuilder: _agentBuilder,
    );

    final tree = SpawnTree(rootId: 'main');
    panelManager = PanelManager(
      screen: screen,
      focusManager: focusManager,
      editor: editor,
      primaryFrame: PanelFrame(
        screen: screen,
        label: 'main',
        conversationId: 'main',
      ),
      terminalGeometry: _Geometry(columns: 120, lines: 24),
      menuBarEnabled: false,
      tree: tree,
    );
    coordinator = ConversationPanelCoordinator(
      panelManager: panelManager,
      sessionManager: sessionManager,
      editor: editor,
      primaryHost: mainHost,
    );
    coordinator.bindPrimary(conversationId: 'main');

    sideHost = TuiConversationHost(
      conversationId: 'side',
      chat: ScrollingTextRegion(screen)..detach(),
      screen: screen,
      spinner: Spinner(enabled: false),
      editor: editor,
      primary: false,
    );
    sideConv = _conversation('side', sideGate, sideHost);
    sessionManager.active.addConversation(sideConv);
    sideFrame = coordinator.bindSpawned(host: sideHost, label: 'role (side)');

    // Real geometry + content relay so both panels actually render.
    panelManager.layout();
    coordinator.relayContent();

    // Record the busy cue at the host seam (after the coordinator wired it),
    // forwarding to the real frame so rendering stays live.
    mainCue = <bool>[];
    final mainInner = mainHost.onBusyChanged!;
    mainHost.onBusyChanged = (busy) {
      mainCue.add(busy);
      mainInner(busy);
    };
    sideCue = <bool>[];
    final sideInner = sideHost.onBusyChanged!;
    sideHost.onBusyChanged = (busy) {
      sideCue.add(busy);
      sideInner(busy);
    };

    rl = _FakeReadLine();
    controller = SessionController(
      sessionManager: sessionManager,
      readLine: rl.call,
      onActiveFocusChanged: () {},
    );
  });

  tearDown(() {
    panelManager.dispose();
  });

  // Pump [pred] until it holds; turns run fire-and-forget so tests pump until
  // the observable they care about has landed.
  Future<void> pumpUntil(bool Function() pred,
      {int iterations = 300}) async {
    for (var i = 0; i < iterations; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      if (pred()) return;
    }
    fail('pumpUntil timed out');
  }

  /// A finished (completed) workflow run handed to [injectWorkflowResult] for
  /// [conversationId] — the production path that wakes ANY conversation (not
  /// just the focused one) with a synthetic turn.
  WorkflowRun finishedRun(String conversationId) => WorkflowRun(
        id: '1',
        workflowName: 'default',
        conversationId: conversationId,
        goal: null,
        input: 'task',
        cancel: Completer<void>(),
      )
    ..status = WorkflowRunStatus.completed
    ..outcome = const Outcome.success(text: 'all green');

  test(
      'a turn that ends while its panel is unfocused still clears the busy cue',
      () async {
    rl.enqueue('go');
    final runFuture = controller.run();
    await pumpUntil(() => mainConv.isRunning);
    expect(mainCue, contains(true),
        reason: 'a focused running turn raises its own panel cue');

    // Cycle focus to the side panel — the real Ctrl+G path. The main turn
    // keeps running in the background (its panel stays visible).
    final cueAfterStart = mainCue.length;
    coordinator.onFrameFocused(sideFrame);
    await pumpUntil(() => sessionManager.activeConversationId == 'side');

    // Complete the main turn while it is unfocused.
    mainGate.release();
    await pumpUntil(() => !mainConv.isRunning);

    // Two producers may clear (Agent.run's finally, then the session
    // controller's turn-level clear) — hosts treat repeats as idempotent, so
    // what's pinned is the settled state: nothing re-raised, and the cue
    // cleared on every path.
    expect(mainCue.skip(cueAfterStart), isNotEmpty);
    expect(mainCue.skip(cueAfterStart), everyElement(isFalse),
        reason: 'the turn ended unfocused: the busy cue must clear (and stay '
            'cleared) so an idle panel shows a static border (tin-y4qn)');
    rl.close();
    await runFuture;
  });

  test(
      'a turn that starts while its panel is unfocused still raises (and '
      'clears) the busy cue', () async {
    // The side conversation is never focused here — active stays 'main'.
    controller.injectWorkflowResult(finishedRun('side'));
    await pumpUntil(() => sideConv.isRunning);

    // Nested producers both raise (the controller's turn-level signal plus
    // Agent.run's own) — idempotent at the host. The invariant: raised while
    // the turn is in flight, never cleared before it ends.
    expect(sideCue, isNotEmpty);
    expect(sideCue, everyElement(isTrue),
        reason: 'a turn in flight raises its panel busy cue regardless of '
            'focus (tin-y4qn)');

    // The comet actually renders on the unfocused panel: one manual animation
    // step must emit comet-head cells into the byte stream.
    final before = io.written.length;
    sideFrame.advanceBusyTick();
    expect(io.written.toString().substring(before).contains('━'), isTrue,
        reason: 'the busy unfocused panel paints the comet on its rails');

    sideGate.release();
    await pumpUntil(() => !sideConv.isRunning);
    expect(sideCue.last, isFalse,
        reason: 'cue clears when the unfocused turn completes');
    expect(sessionManager.activeConversationId, 'main',
        reason: 'focus never moved — the turn ran entirely in the background');
  });

  test(
      'an unfocused conversation keeps progressing: streams, completes, and '
      'drains its queue without focus', () async {
    controller.injectWorkflowResult(finishedRun('side'));
    await pumpUntil(() => sideConv.isRunning);

    // The streamed delta lands in the side host's chat while unfocused.
    await pumpUntil(() => io.written.toString().contains('working'));
    // Queued input for the background conversation waits, then drains: the
    // follow-up turn starts a second provider call — without focus.
    sideConv.messageQueue.enqueue('follow-up');
    sideGate.release();
    await pumpUntil(() => sideGate.callCount >= 2);
    sideGate.release();
    // Both exchanges complete; the conversation settles idle.
    await pumpUntil(() =>
        sideConv.history
            .where((m) =>
                m.role == Role.assistant &&
                m.content.any((b) => b is TextBlock && b.text == 'done'))
            .length >=
        2);
    await pumpUntil(() => !sideConv.isRunning);

    expect(sideConv.history.any((m) =>
        m.role == Role.assistant &&
        m.content.any((b) => b is TextBlock && b.text == 'done')), isTrue,
        reason: 'the unfocused turn completed');
    expect(sessionManager.activeConversationId, 'main',
        reason: 'all of this happened while another panel held focus');
  });

  test('an idle panel shows a static border (no comet cells)', () async {
    // Nothing is running; neither panel has ever been busy. Force a chrome
    // repaint and assert the rails carry no comet head.
    final before = io.written.length;
    panelManager.primaryFrame.render();
    expect(io.written.toString().substring(before).contains('━'), isFalse,
        reason: 'an idle panel waiting for input must not animate');
    expect(mainCue, isEmpty,
        reason: 'no turn has run: no busy signal may ever have been raised');
  });
}

HostInterface _unusedHostFactory({
  required String conversationId,
  required bool isActive,
}) =>
    // Background conversations minted by the manager are not exercised here;
    // fail loudly if one appears.
    throw StateError('unexpected hostFactory call in panel busy cue harness');

Conversation _conversation(
    String id, LlmProvider provider, TuiConversationHost host) {
  final policy = PermissionPolicy();
  return Conversation(
    id: id,
    label: id,
    agent: _agentBuilder(
      conversationId: id,
      provider: provider,
      host: host,
      policy: policy,
    ),
    provider: provider,
    host: host,
    policy: policy,
  );
}

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
      asker: host.askPermission,
      system: 'sys',
    );

/// A provider whose streams stay open until the test releases them, so a turn
/// can be held mid-flight and completed deterministically.
class _GateProvider extends LlmProvider {
  _GateProvider(String name) : super(name);

  final _gates = <Completer<void>>[];
  int _calls = 0;

  int get callCount => _calls;

  void release() {
    if (_gates.isNotEmpty) _gates.removeAt(0).complete();
  }

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    _calls++;
    final gate = Completer<void>();
    _gates.add(gate);
    yield const TextDelta('working');
    await gate.future;
    yield const MessageComplete(
        content: [TextBlock('done')], stopReason: 'end_turn');
  }
}

/// Scriptable readLine (mirrors the session_controller_test fake).
class _FakeReadLine {
  final _queue = <String?>[];
  Completer<String?>? _waiter;

  void enqueue(String line) {
    if (_waiter != null && !_waiter!.isCompleted) {
      _waiter!.complete(line);
      _waiter = null;
    } else {
      _queue.add(line);
    }
  }

  void close() {
    if (_waiter != null && !_waiter!.isCompleted) {
      _waiter!.complete(null);
      _waiter = null;
    } else {
      _queue.add(null);
    }
  }

  Future<String?> call(String prompt) async {
    if (_queue.isNotEmpty) return _queue.removeAt(0);
    _waiter = Completer<String?>();
    return _waiter!.future;
  }
}

/// Fixed geometry for tests.
class _Geometry implements TerminalGeometry {
  _Geometry({required this.columns, required this.lines});

  @override
  final int columns;

  @override
  final int lines;

  @override
  bool get hasTerminal => false;
}
