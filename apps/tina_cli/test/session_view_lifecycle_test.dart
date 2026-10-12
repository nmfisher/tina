import 'package:tina/session.dart';
import 'package:tina/tui.dart';
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart' show PanelsView;
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_tui/tina_tui.dart';
import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show ControlledProvider, waitFor;

/// A view owns presentation resources. The embedded application separately
/// owns cancellation, draining active work and closing the session.
void main() {
  late Directory root, workspace;
  setUp(() {
    root = Directory.systemTemp.createTempSync('session-view-lifecycle-');
    workspace = Directory('${root.path}/workspace')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('clear confirmation follows the history reset in every attached view',
      () async {
    final session = TuiSession.wrap(SessionAssembly.start(
        providerFactory: (_) => ScriptedProvider([scriptedReply('old reply')]),
        options: AssemblyOptions(
            configPath: '${root.path}/global',
            workingDirectory: workspace.path,
            plugins: ['tina/chat-tui', 'tina/session-controls'])));
    final screens = [_Presentation(), _Presentation()];
    final views = [session.createView(), session.createView()];
    addTearDown(() async {
      for (final view in views) view.close();
      await session.shutdown();
      for (final screen in screens) screen.dispose();
    });
    for (var i = 0; i < views.length; i++) {
      views[i].attachConsole(screens[i].context);
    }
    await views.first.submit('old input');
    expect(screens.every((s) => s.transcript.contains('old reply')), isTrue);
    await views.first.submit('/clear');
    await Future<void>.delayed(Duration.zero);
    for (final screen in screens) {
      expect(screen.transcript, contains('Conversation cleared.'));
      expect(screen.transcript, isNot(contains('old reply')));
      expect(screen.transcript, isNot(contains('old input')));
    }
  });

  test('quit is local to its view and another view can keep submitting',
      () async {
    final provider = _TrackedProvider();
    final session = TuiSession.wrap(SessionAssembly.start(
        providerFactory: (_) => provider,
        options: AssemblyOptions(
            configPath: '${root.path}/global',
            workingDirectory: workspace.path,
            plugins: ['tina/chat-tui'])));
    final first = session.createView(), second = session.createView();
    addTearDown(() async {
      first.close();
      second.close();
      await session.shutdown();
    });
    await first.submit('/quit');
    expect(first.quitRequested, isTrue);
    expect(second.quitRequested, isFalse);
    expect(session.assembly.quitRequested, isFalse);
    first.close();
    final turn = second.submit('continue here');
    await waitFor(() => provider.requests.isNotEmpty);
    provider.requests.single.add(const MessageComplete(
        content: [TextBlock('still alive')], stopReason: 'end_turn'));
    await provider.requests.single.close();
    await turn;
    expect(session.host.session.lastReply, 'still alive');
    expect(provider.closes, 0);
  });

  for (final closedIndex in [0, 1]) {
    test('closing view $closedIndex preserves the shared turn and persistence',
        () async {
      final provider = _TrackedProvider();
      final session = TuiSession.wrap(SessionAssembly.start(
        providerFactory: (_) => provider,
        options: AssemblyOptions(
          configPath: '${root.path}/global',
          workingDirectory: workspace.path,
          plugins: ['tina/chat-tui', 'tina/persistence'],
        ),
      ));
      final views = [session.createView(), session.createView()];
      final screens = [_Presentation(), _Presentation()];
      Future<bool>? turn;
      addTearDown(() async {
        for (final view in views) view.close();
        session.cancel();
        if (turn != null) await turn.timeout(const Duration(seconds: 3));
        session.close();
        for (final screen in screens) screen.dispose();
      });
      for (var i = 0; i < views.length; i++) {
        views[i].attachConsole(screens[i].context);
      }
      turn = session.runLine('keep working', renderReply: false);
      await waitFor(() => provider.requests.length == 1);
      provider.requests.single.add(const TextDelta('before close'));
      await waitFor(
          () => screens.every((s) => s.transcript.contains('before close')));

      final closed = views[closedIndex];
      final remaining = screens[1 - closedIndex];
      final terminal = session.terminal as SessionTerminal;
      var answered = false;
      final question = terminal.ask('Still waiting?').then((answer) {
        answered = true;
        return answer;
      });
      closed.close();
      closed.close();
      closed.cancel(); // Stale UI callbacks cannot cancel the shared turn.
      await Future<void>.delayed(Duration.zero);
      expect(answered, isFalse);
      expect(provider.closes, 0);
      expect(session.host.session.loop.running, isTrue);
      expect(closed.contributions, isEmpty);
      expect(closed.offerInput('stale input'), isFalse);
      expect(closed.offerCommand('/quit'), isNull);
      await expectLater(closed.submit('stale submit'), throwsStateError);
      expect(() => closed.attachConsole(screens[closedIndex].context),
          throwsStateError);

      final frozen = screens[closedIndex].transcript;
      provider.requests.single.add(const TextDelta(' after close'));
      await waitFor(() => remaining.transcript.contains('after close'));
      expect(screens[closedIndex].transcript, frozen);
      final responder = terminal.questions.connect();
      expect(responder.answer(responder.pending.single.id, 'yes'), isTrue);
      responder.close();
      expect(await question, 'yes');
      provider.requests.single.add(const MessageComplete(
          content: [TextBlock('before close after close')],
          stopReason: 'end_turn'));
      await provider.requests.single.close();
      await turn;
      final store = SessionStore.open(defaultSessionStorePath(workspace.path));
      try {
        expect(store.checkGaps(session.host.session.id), isEmpty);
        expect(
            store.readEntries(session.host.session.id).map((e) => e.toJson()),
            session.host.session.loop.log.map((e) => e.toJson()));
      } finally {
        store.close();
      }

      // Even the final view is not the owner. Explicit owner teardown still
      // cancels the next turn and closes the provider after the turn settles.
      views[1 - closedIndex].close();
      expect(provider.closes, 0);
      turn = session.runLine('owner will stop this', renderReply: false);
      await waitFor(() => provider.requests.length == 2);
      session.cancel();
      await turn;
      session.close();
      expect(provider.closes, 1);
      expect(session.host.session.turns.last.stopReason, StopReason.cancelled);
      expect(session.host.session.loop.running, isFalse);
    });
  }

  test(
      'borrowed workspace closes panels and exits without waiting for shared work',
      () async {
    final provider = _TrackedProvider();
    final session = TuiSession.wrap(SessionAssembly.start(
      providerFactory: (_) => provider,
      options: AssemblyOptions(
        configPath: '${root.path}/global',
        workingDirectory: workspace.path,
        plugins: ['tina/chat-tui'],
      ),
    ));
    final independent = _Presentation();
    final observer = session.createView()..attachConsole(independent.context);
    final panelScreen = _Presentation();
    final panels = PanelsView();
    final initial = session.createView();
    final spawned = <SessionView>[];
    final app = panels.runConsole(panelScreen.context, initial, (_) async {
      final view = session.createView();
      spawned.add(view);
      return view;
    });
    addTearDown(() async {
      panelScreen.editor.inject(ControlKey(ControlCode.ctrlC));
      session.cancel();
      await app.timeout(const Duration(seconds: 3));
      await waitFor(() => !session.host.session.loop.running);
      observer.close();
      session.close();
      independent.dispose();
      panelScreen.dispose();
    });
    await waitFor(() => panelScreen.editor.isEditing);
    panelScreen.io.feedBytes('/spawn\r'.codeUnits);
    await waitFor(() => spawned.length == 1 && panelScreen.editor.isEditing);
    panelScreen.io.feedBytes('shared input\r'.codeUnits);
    await waitFor(() => provider.requests.length == 1);
    panelScreen.io.feedBytes('/close\r'.codeUnits);
    await waitFor(() => spawned.single.contributions.isEmpty);
    expect(provider.closes, 0);
    expect(session.host.session.loop.running, isTrue);
    provider.requests.single
        .add(const TextDelta('continues after panel close'));
    await waitFor(
        () => independent.transcript.contains('continues after panel close'));

    // Ctrl+C on an empty draft exits this client. It must not wait for the
    // borrowed session's turn or cancel work visible in the other client.
    panelScreen.editor.inject(ControlKey(ControlCode.ctrlC));
    expect(await app.timeout(const Duration(seconds: 3)), 0);
    expect(initial.contributions, isEmpty);
    expect(session.host.session.loop.running, isTrue);
    expect(provider.closes, 0);
    provider.requests.single.add(const MessageComplete(
        content: [TextBlock('finished with one remaining observer')],
        stopReason: 'end_turn'));
    await provider.requests.single.close();
    await waitFor(() => !session.host.session.loop.running);
    expect(independent.transcript,
        contains('finished with one remaining observer'));
  });

  test('detaching a view preserves steering, persistence and later rendering',
      () async {
    final provider = ControlledProvider();
    final session = TuiSession.wrap(SessionAssembly.start(
      providerFactory: (_) => provider,
      options: AssemblyOptions(
        configPath: '${root.path}/global',
        workingDirectory: workspace.path,
        plugins: ['tina/chat-tui', 'tina/persistence'],
      ),
    ));
    final view = session.createView();
    final first = _Presentation();
    final replacement = _Presentation();
    Future<bool>? turn;
    addTearDown(() async {
      session.cancel();
      if (turn != null) await turn.timeout(const Duration(seconds: 3));
      view.detachConsole();
      session.close();
      replacement.dispose();
      first.dispose();
    });

    view.attachConsole(first.context);
    turn = session.runLine('first input', renderReply: false);
    await waitFor(() => provider.requests.length == 1);
    provider.requests.single.add(const TextDelta('partial first answer'));
    await waitFor(() => first.screen.chat
        .snapshotLines()
        .join('\n')
        .contains('partial first answer'));

    view.detachConsole();
    expect(session.host.session.loop.running, isTrue);
    expect(session.host.session.loop.log.whereType<TurnEndedEntry>(), isEmpty);
    expect(session.offerInput('steered input'), isTrue);
    await waitFor(() => provider.requests.length == 2);
    provider.requests.last.add(const MessageComplete(
      content: [TextBlock('answer while detached')],
      stopReason: 'end_turn',
    ));
    await provider.requests.last.close();
    expect(await turn.timeout(const Duration(seconds: 3)), isFalse);
    expect(session.inputHistory, ['first input', 'steered input']);
    expect(session.host.session.loop.log.whereType<TurnEndedEntry>(),
        hasLength(2));

    final store = SessionStore.open(defaultSessionStorePath(workspace.path));
    try {
      expect(store.checkGaps(session.host.session.id), isEmpty);
      expect(
        store
            .readEntries(session.host.session.id)
            .map((entry) => entry.toJson()),
        session.host.session.loop.log.map((entry) => entry.toJson()),
      );
    } finally {
      store.close();
    }

    view.attachConsole(replacement.context);
    final transcript = replacement.screen.chat.snapshotLines().join('\n');
    expect(transcript, contains('partial first answer'));
    expect(transcript, contains('steered input'));
    expect(transcript, contains('answer while detached'));
  });

  test('closing a view leaves an external approval active and correlated',
      () async {
    final channel = StreamApprovalChannel(id: 'acme/messages');
    final requested = Completer<ApprovalRequest>();
    final subscription = channel.requests.listen(requested.complete);
    final target = File('${root.path}/outside.txt');
    final session = TuiSession.wrap(SessionAssembly.start(
      providerFactory: (_) => ScriptedProvider([
        scriptedReply('', calls: [
          ToolUseBlock(id: 'write', name: 'write', input: {
            'filePath': target.path,
            'content': 'approved externally',
          }),
        ]),
        scriptedReply('write finished'),
      ]),
      options: AssemblyOptions(
        configPath: '${root.path}/global',
        workingDirectory: workspace.path,
        plugins: ['tina/chat-tui', 'tina/persistence'],
        approvalChannel: channel.id,
      ),
      registerPlugins: (registry) => registry.registerDefinition(
        PluginDefinition<SessionPluginContext>(channel.id, (_) => channel,
            provides: [approvalChannel], description: 'External test channel.'),
      ),
    ));
    final view = session.createView();
    final presentation = _Presentation();
    Future<bool>? turn;
    addTearDown(() async {
      session.cancel();
      if (turn != null) await turn.timeout(const Duration(seconds: 3));
      view.detachConsole();
      session.close();
      await subscription.cancel();
      presentation.dispose();
    });

    view.attachConsole(presentation.context);
    turn = session.runLine('write outside the workspace', renderReply: false);
    final request = await requested.future.timeout(const Duration(seconds: 3));
    expect(target.existsSync(), isFalse);

    view.close();
    final approvals = session.host.plugins.whereType<ApprovalsPlugin>().single;
    expect(approvals.pending.map((pending) => pending.id), [request.id]);
    expect(session.host.session.loop.running, isTrue);
    expect(target.existsSync(), isFalse);
    expect(channel.respond(request.id, ApprovalDecision.allow), isTrue);

    expect(await turn.timeout(const Duration(seconds: 3)), isFalse);
    expect(target.readAsStringSync(), 'approved externally');
    expect(session.host.session.lastReply, 'write finished');
    expect(approvals.pending, isEmpty);
    expect(channel.respond(request.id, ApprovalDecision.allow), isFalse);
  });
}

final class _Presentation {
  final io = FakeIo();
  late final screen = fakeScreen(io);
  late final editor = LineEditor(screen: screen);
  late final context = ConsoleContext(screen: screen, editor: editor);

  String get transcript => screen.chat.snapshotLines().join('\n');

  void dispose() {
    editor.close(reportLatency: false);
    screen.dispose();
    io.closeInput();
  }
}

final class _TrackedProvider implements LlmProvider {
  final requests = <StreamController<StreamEvent>>[];
  int closes = 0;
  @override
  String get model => 'tracked';
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    final request = StreamController<StreamEvent>();
    requests.add(request);
    return request.stream;
  }

  @override
  void close() {
    closes++;
    for (final request in requests) unawaited(request.close());
  }
}
