import 'dart:io';
import 'package:classification/plugin.dart';
import 'package:test/test.dart';
import 'package:tina/src/console_catalog.dart';
import 'package:tina/src/snapshot_catalog.dart';
import 'package:tina_classification_tui/tina_classification_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_context_tui/tina_context_tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_plans/tina_plans.dart';
import 'package:tina_plans_tui/tina_plans_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show ControlledProvider, waitFor;

class _Terminal implements Terminal {
  @override
  void writeln([String? text]) {}
  @override
  Future<String> ask(String prompt) => throw UnimplementedError();
}

class _History extends AgentPlugin {
  _History(this.entries);
  final List<SessionEntry> entries;
  @override
  String get id => 'test/history';
  @override
  SessionSeed openSession(PluginSession session) =>
      SessionSeed(log: entries, details: SessionDetails());
}

class _Panels implements ConsolePanels {
  @override
  Future<void> spawn([String? model]) async {}
  @override
  Future<void> closeFocused() async {}
  @override
  List<String> describe() => [];
}

class _View<T extends ConsoleContribution> {
  _View(Host host, AgentPlugin plugin)
    : connection = host.connect(role: SessionRole.observer) {
    view = createConsoleView(plugin, connection: connection)! as T;
    addTearDown(close);
  }
  final SessionConnection connection;
  late final T view;
  final io = FakeIo();
  late final screen = fakeScreen(io);
  late final editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
  late final console = ConsoleContext(screen: screen, editor: editor).forView(
    chat: screen.chat,
    isActive: () => true,
    activate: () {},
    panels: _Panels(),
  );
  ConsoleAttachment? attachment;
  void attach() => attachment = ConsoleAttachment.attach(view, console);
  void detach() {
    attachment?.dispose();
    attachment = null;
  }

  void close() {
    detach();
    connection.close();
    editor.close(reportLatency: false);
    screen.dispose();
    io.closeInput();
  }
}

Host _host(
  List<AgentPlugin> plugins, {
  List<SessionEntry> history = const [],
  LlmProvider? provider,
}) {
  final host = Host.start(
    HostConfig(
      workingDirectory: '.',
      plugins: [_History(history), ...plugins],
      providerFactory: (_) =>
          provider ?? ScriptedProvider([scriptedReply('answer')]),
      snapshotFeatureFor: snapshotFeatureFor,
    ),
  );
  addTearDown(host.shutdown);
  return host;
}

Message _message(String text) =>
    Message(role: Role.user, content: [TextBlock(text)]);
List<SessionEntry> _history() => [
  const TurnStartedEntry(turnId: 'old', seq: 0),
  MessageAppendedEntry(
    turnId: 'old',
    seq: 1,
    message: _message('original history'),
  ),
  const TurnEndedEntry(turnId: 'old', seq: 2, reason: TurnStopReason.complete),
];

void main() {
  test(
    'plans coalesce updates and preserve independent selection across detach',
    () async {
      final plans = PlansPlugin(terminal: _Terminal());
      final host = _host([plans]);
      void update(String childState) => plans.store.update(host.session.loop, [
        PlanEntryItem(
          'parent',
          state: 'pending',
          summary: 'parent details',
          children: [PlanEntryItem('child', state: childState)],
        ),
      ], approval: PlanApproval.requested);
      update('pending');
      final first = _View<PlansView>(host, plans)..attach();
      final second = _View<PlansView>(host, plans)..attach();
      expect(first.view.plans, isA<ConnectionPlanObservation>());
      expect(first.view.plans.unavailableReason, isNull);
      expect(first.view.plans.state.items.single.text, 'parent');
      first.view.overlay!.focus();
      first.view.overlay!.handleEvent(ArrowKey(ArrowDirection.right));
      first.view.overlay!.handleEvent(ArrowKey(ArrowDirection.down));
      expect(first.view.overlay!.selectedItem!.text, 'child');
      expect(second.view.overlay!.selectedItem, isNull);
      for (var i = 0; i < 20; i++) update(i == 19 ? 'done' : 'pending');
      await waitFor(
        () =>
            second.view.plans.state.items.single.children.single.state ==
            'done',
      );
      expect(first.view.overlay!.selectedItem!.text, 'child');
      expect(first.view.plans.state.approval, PlanApproval.requested);
      expect(second.view.overlay!.selectedItem, isNull);
      expect(
        () => first.view.plans.state.items.clear(),
        throwsUnsupportedError,
      );
      first.detach();
      update('in_progress');
      await waitFor(
        () =>
            second.view.plans.state.items.single.children.single.state ==
            'in_progress',
      );
      expect(first.view.plans.state.items.single.children.single.state, 'done');
      first.attach();
      expect(
        first.view.plans.state.items.single.children.single.state,
        'in_progress',
      );
      expect(first.connection.canControl, isFalse);
      expect(host.plugins.any((p) => p.id == 'tina/chat-tui'), isFalse);

      first.detach();
      second.detach();
      host.detachPlugin(plans.id);
      final replacement = PlansPlugin(terminal: _Terminal());
      late _View<PlansView> reloaded;
      host.attachPlugin(
        replacement,
        activate: (_) {
          reloaded = _View<PlansView>(host, replacement)..attach();
        },
      );
      expect(reloaded.view.plans.state.items.single.text, 'parent');
      expect(
        reloaded.view.plans.state.items.single.children.single.state,
        'in_progress',
      );
    },
  );

  test(
    'classification reconnects during diagnostics without sharing panel state',
    () async {
      final classification = ClassificationPlugin(
        terminal: _Terminal(),
        open: () => null,
      );
      final host = _host([classification]);
      final root = classification.trace.begin(
        inputId: 'one',
        title: 'Root stage',
        request: 'request',
        questions: {
          'q': {'type': 'noul', 'instructions': 'Question'},
        },
      );
      final child = classification.trace.begin(
        inputId: 'one',
        title: 'Child stage',
        parentId: root.id,
        request: 'child request',
      );
      final first = _View<ClassificationView>(host, classification)..attach();
      final second = _View<ClassificationView>(host, classification)..attach();
      expect(
        first.view.classification,
        isA<ConnectionClassificationObservation>(),
      );
      first.view.panel!.show(hierarchy: true);
      expect(first.view.panel!.hierarchy, isTrue);
      expect(second.view.panel!.hierarchy, isFalse);
      for (var i = 0; i < 30; i++) root.append('part $i\n');
      await waitFor(
        () => second.view.classification.trace.exchanges.first.response
            .contains('part 29'),
      );
      final frozen = first.view.classification.trace;
      expect(frozen.exchanges.last.parentId, root.id);
      expect(
        () => frozen.exchanges.first.questions.clear(),
        throwsUnsupportedError,
      );
      first.detach();
      root.recordAnswers({
        'q': {'value': 1},
      });
      root.complete('final response');
      root.recordOutcome(const ClassificationOutcome('project question'));
      child.fail('cancelled', cancelled: true);
      await waitFor(
        () =>
            second.view.classification.trace.exchanges.last.phase ==
            ClassificationExchangePhase.cancelled,
      );
      expect(first.view.classification.trace, same(frozen));
      first.attach();
      final projected = first.view.classification.trace;
      expect(projected.exchanges.first.response, 'final response');
      expect(projected.exchanges.first.outcome!.label, 'project question');
      expect(projected.exchanges.first.answers, {
        'q': {'value': 1},
      });
      expect(projected.exchanges.first.elapsed, isNotNull);
      expect(projected.exchanges.every((e) => !e.pending), isTrue);
      expect(frozen.exchanges.first.pending, isTrue);
      final before = host.session.loop.log.length;
      first.view.panel!.focus();
      first.view.panel!.handleEvent(CharInput('h'));
      expect(host.session.loop.log.length, before);

      first.detach();
      second.detach();
      host.detachPlugin(classification.id);
      final replacement = ClassificationPlugin(
        terminal: _Terminal(),
        open: () => null,
      );
      replacement.trace.begin(
        inputId: 'new',
        title: 'Reloaded classifier',
        request: {},
      );
      late _View<ClassificationView> reloaded;
      host.attachPlugin(
        replacement,
        activate: (_) {
          reloaded = _View<ClassificationView>(host, replacement)..attach();
        },
      );
      expect(
        reloaded.view.classification.trace.exchanges.single.title,
        'Reloaded classifier',
      );
    },
  );

  test(
    'context uses committed history, preserves edits on resume and only observes mirror status',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'tina-context-connection-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final mirror = File('${directory.path}/context.json');
      final context = ContextPlugin(mirrorFile: mirror);
      final presentation = PresentationPlugin(
        id: 'tina/context-tui',
        source: context.observation,
      );
      final host = _host([context, presentation], history: _history());
      for (var i = 0; i < 300; i++) {
        host.session.loop.recordUsage(const UsageRecordedEntry(turnId: 'old'));
      }
      final first = _View<ContextView>(host, presentation)..attach();
      final second = _View<ContextView>(host, presentation)..attach();
      expect(first.view.context, isA<ConnectionContextObservation>());
      first.view.toggle();
      expect(first.view.visibleLines.join('\n'), contains('original history'));
      expect(second.view.isOpen, isFalse);
      final original = context.workingContext;
      context.replaceWorkingContext(
        expectedRevision: original.revision,
        expectedThroughSeq: original.throughSeq,
        messages: [_message('accepted summary')],
      );
      first.view.repaintConsole();
      second.view.toggle();
      expect(first.view.visibleLines.join('\n'), contains('accepted summary'));
      expect(
        second.view.context.workingContext.messages.single.toJson(),
        _message('accepted summary').toJson(),
      );
      expect(
        first.view.context.latestChange!.before.messages.single.toJson(),
        _message('original history').toJson(),
      );
      expect(
        first.view.context.latestChange!.after.messages.single.toJson(),
        _message('accepted summary').toJson(),
      );
      final count = host.session.loop.log.length;
      final draft = first.editor.readLine('> ');
      first.editor.inject(CharInput('t'));
      await waitFor(
        () => first.view.visibleLines.join('\n').contains('[Changes]'),
      );
      expect(second.view.visibleLines.join('\n'), contains('[Context]'));
      first.editor.inject(EscapeKey());
      first.editor.inject(ControlKey(ControlCode.enter));
      await draft;
      first.view.toggle();
      mirror.writeAsStringSync('{pending invalid edit');
      first.view.repaintConsole();
      expect(
        first.view.visibleLines.join('\n'),
        contains('Edits awaiting validation'),
      );
      expect(mirror.readAsStringSync(), '{pending invalid edit');
      expect(host.session.loop.log.length, count);
      expect(
        first.view.visibleLines.join('\n'),
        isNot(contains('{pending invalid edit')),
      );
      first.detach();
      mirror.deleteSync();
      second.view.repaintConsole();
      expect(
        second.view.visibleLines.join('\n'),
        contains('Context file unavailable'),
      );
      expect(mirror.existsSync(), isFalse);
      first.attach();
      first.view.toggle();
      expect(first.view.visibleLines.join('\n'), contains('accepted summary'));

      final resumedContext = ContextPlugin();
      final resumedPresentation = PresentationPlugin(
        id: 'tina/context-tui',
        source: resumedContext.observation,
      );
      final resumed = _host([
        resumedContext,
        resumedPresentation,
      ], history: host.session.loop.log);
      final replay = _View<ContextView>(resumed, resumedPresentation)..attach();
      replay.view.toggle();
      expect(
        replay.view.context.latestChange!.before.messages.single.toJson(),
        _message('original history').toJson(),
      );
      expect(
        replay.view.context.workingContext.messages.single.toJson(),
        _message('accepted summary').toJson(),
      );
      resumed.session.loop.clearHistory();
      replay.view.repaintConsole();
      expect(replay.view.context.workingContext.messages, isEmpty);
      expect(replay.view.context.latestChange, isNull);
    },
  );

  test(
    'context attaches during a turn and catches up after detaching',
    () async {
      final context = ContextPlugin();
      final presentation = PresentationPlugin<void>(
        id: 'tina/context-tui',
        source: null,
      );
      final provider = ControlledProvider();
      final host = _host([context, presentation], provider: provider);
      final turn = host.send('active request');
      await waitFor(() => provider.requests.isNotEmpty);
      final client = _View<ContextView>(host, presentation)..attach();
      client.view.toggle();
      expect(client.view.context.includePendingTurn, isTrue);
      expect(client.view.visibleLines.join('\n'), contains('active request'));
      client.detach();
      provider.requests.single.add(const TextDelta('answer'));
      provider.requests.single.add(
        MessageComplete(content: [TextBlock('answer')], stopReason: 'end_turn'),
      );
      await provider.requests.single.close();
      await turn;
      client.attach();
      client.view.toggle();
      expect(client.view.context.includePendingTurn, isFalse);
      expect(client.view.context.workingContext.messages, hasLength(2));
      expect(client.view.visibleLines.join('\n'), contains('answer'));
      expect(client.view.context.budgetUsage, isNotNull);
      context.applyCompaction((from: 0, to: 1, summary: 'compacted summary'));
      client.view.repaintConsole();
      expect(
        client.view.visibleLines.join('\n'),
        contains('compacted summary'),
      );
      expect(client.view.context.latestChange!.before.messages, hasLength(2));
    },
  );

  test(
    'a failed publication cannot expose an unconfirmed plan or context edit',
    () async {
      final plans = PlansPlugin(terminal: _Terminal());
      final context = ContextPlugin();
      final presentation = PresentationPlugin(
        id: 'tina/context-tui',
        source: context.observation,
      );
      final host = _host([plans, context, presentation], history: _history());
      final planView = _View<PlansView>(host, plans)..attach();
      final contextView = _View<ContextView>(host, presentation)..attach();
      contextView.view.toggle();
      final initial = context.workingContext;
      final broken = host.session.loop.subscribe((entry, event) {
        if (event == LogEvent.appended) throw StateError('write failed');
      });
      addTearDown(() => host.session.loop.unsubscribe(broken));
      expect(
        () => context.replaceWorkingContext(
          expectedRevision: initial.revision,
          expectedThroughSeq: initial.throughSeq,
          messages: [_message('unconfirmed secret')],
        ),
        throwsA(isA<ContextPersistenceFailure>()),
      );
      await waitFor(() => planView.view.plans.unavailableReason != null);
      contextView.view.repaintConsole();
      expect(
        contextView.view.visibleLines.join('\n'),
        contains('Accepted context is unavailable'),
      );
      expect(
        contextView.view.visibleLines.join('\n'),
        isNot(contains('unconfirmed secret')),
      );
      expect(planView.view.plans.state.items, isEmpty);
    },
  );
}
