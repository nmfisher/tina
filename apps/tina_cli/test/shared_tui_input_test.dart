import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina/tui.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart' show PanelsView;
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_tui/tina_tui.dart';

import 'app_test.dart' show FakeIo, fakeScreen;
import 'turn_rendering_test.dart' show ControlledProvider, waitFor;

final class _Client {
  _Client(this.view, {required this.panels}) {
    done = runApp(
      view,
      screen: fakeScreen(io),
      editorFor: (screen) =>
          editor = LineEditor(screen: screen, escapeTimeout: Duration.zero),
      workspace: panels ? PanelsView() : null,
      createSession: (_) async => throw StateError('no spawned sessions'),
    );
  }
  final SessionView view;
  final bool panels;
  final io = FakeIo();
  late final LineEditor editor;
  late final Future<int> done;
  PanelFrame get frame => editor.focusManager!.home! as PanelFrame;
  void enter(String text) => io.feedBytes('$text\r'.codeUnits);
  Future<void> close() async {
    editor.inject(ControlKey(ControlCode.ctrlC));
    editor.inject(ControlKey(ControlCode.ctrlC));
    io.closeInput();
    await done.timeout(const Duration(seconds: 3));
  }
}

List<SessionRequestSnapshot> _receipts(SessionConnection connection) {
  final attachment = connection.attach();
  try {
    return attachment.initial.requests;
  } finally {
    attachment.close();
  }
}

void main() {
  late Directory root;
  late ControlledProvider provider;
  late TuiSession session;
  late SessionConnection inspector;
  final clients = <_Client>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('shared-tui-input-');
    provider = ControlledProvider();
    session = TuiSession.wrap(
      SessionAssembly.start(
        providerFactory: (_) => provider,
        options: AssemblyOptions(
          configPath: '${root.path}/config',
          workingDirectory: root.path,
          plugins: ['tina/chat-tui'],
        ),
      ),
    );
    inspector = session.host.connect();
  });
  tearDown(() async {
    for (final client in clients) await client.close();
    clients.clear();
    inspector.close();
    await session.shutdown();
    root.deleteSync(recursive: true);
  });

  Future<_Client> connect({required bool panels}) async {
    final client = _Client(session.createView(), panels: panels);
    clients.add(client);
    await waitFor(() => client.editor.isEditing);
    return client;
  }

  test(
    'closing a view discards unsent actions and settles their callers',
    () async {
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      session.host.commands.publish(
        Command(name: 'wait', description: '', handler: (_) => release.future),
      );
      var executions = 0;
      session.host.commands.publish(
        Command(name: 'later', description: '', handler: (_) => executions++),
      );
      final command = inspector.submitRequest(
        '/wait',
        id: inspector.requestWindow.id('external-command'),
      );
      final view = session.createView();
      addTearDown(view.close);
      final input = view.submit('unsent input');
      final deferredCommand = view.submit('/later');
      expect(view.pendingInputCount, 2);
      expect(_receipts(inspector), hasLength(1));
      view.close();
      await Future.wait([
        input,
        deferredCommand,
      ]).timeout(const Duration(seconds: 3));
      release.complete();
      await command.completed;
      expect(_receipts(inspector), hasLength(1));
      expect(provider.requests, isEmpty);
      expect(executions, 0);
    },
  );

  for (final panels in [false, true]) {
    test(
      'second TUI cancels and steers shared work (panels=$panels)',
      () async {
        final first = await connect(panels: !panels);
        first.enter('initial input');
        await waitFor(() => provider.requests.length == 1);
        final second = await connect(panels: panels);
        expect(second.view.busy, isTrue);
        expect(second.view.canCancel, isTrue);
        if (panels) expect(second.frame.busy, isTrue);
        first.io.feedBytes('private draft'.codeUnits);
        await waitFor(() => first.editor.draftText == 'private draft');
        expect(second.editor.draftText, isEmpty);

        // This client has submitted nothing, but Escape still cancels the turn.
        second.editor.inject(EscapeKey());
        await waitFor(() => !second.view.busy);
        expect(
          session.host.session.turns.single.stopReason,
          StopReason.cancelled,
        );
        expect(first.editor.draftText, 'private draft');
        expect(
          _receipts(inspector).single.state,
          SessionRequestState.cancelled,
        );
        if (panels) await waitFor(() => !second.frame.busy);

        first.editor.loadEditState('', 0);
        first.enter('next turn');
        await waitFor(() => provider.requests.length == 2);
        second.enter('steering from second');
        await waitFor(() => provider.requests.length == 3);
        expect(session.inputHistory, [
          'initial input',
          'next turn',
          'steering from second',
        ]);
        final receipts = _receipts(inspector);
        expect(receipts, hasLength(3));
        expect(receipts.map((r) => r.id).toSet(), hasLength(3));
        expect(receipts.map((r) => r.inputId).toSet(), hasLength(3));

        // Ctrl+C detaches only the first frontend and creates no receipt.
        first.editor.inject(ControlKey(ControlCode.ctrlC));
        expect(await first.done.timeout(const Duration(seconds: 3)), 0);
        expect(second.view.busy, isTrue);
        expect(_receipts(inspector), hasLength(3));
        provider.requests.last.add(
          const MessageComplete(
            content: [TextBlock('shared reply')],
            stopReason: 'end_turn',
          ),
        );
        await provider.requests.last.close();
        await waitFor(() => !second.view.busy);
        expect(_receipts(inspector).every((r) => r.terminal), isTrue);
        expect(session.host.session.lastReply, 'shared reply');
        expect(second.editor.isEditing, isTrue);
        second.enter('/quit');
        expect(await second.done.timeout(const Duration(seconds: 3)), 0);
        expect(_receipts(inspector), hasLength(3));
      },
    );

    test(
      'foreign command activity gates unsent input (panels=$panels)',
      () async {
        final release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        session.host.commands.publish(
          Command(
            name: 'wait',
            description: '',
            handler: (_) => release.future,
          ),
        );
        final command = inspector.submitRequest(
          '/wait',
          id: inspector.requestWindow.id('external-command'),
        );
        final client = await connect(panels: panels);
        expect(inspector.status.running, isFalse);
        expect(client.view.busy, isTrue);
        expect(client.view.canCancel, isFalse);
        expect(inspector.status.acceptsInput, isFalse);
        if (panels) expect(client.frame.busy, isTrue);
        client.enter('after the command');
        await waitFor(() => client.view.pendingInputCount == 1);
        expect(provider.requests, isEmpty);
        expect(
          _receipts(inspector),
          hasLength(1),
          reason: 'An unsent line has no runtime request yet',
        );
        release.complete();
        await command.completed;
        await waitFor(() => provider.requests.length == 1);
        expect(client.view.pendingInputCount, 0);
        expect(_receipts(inspector), hasLength(2));
        provider.requests.single.add(
          const MessageComplete(
            content: [TextBlock('done')],
            stopReason: 'end_turn',
          ),
        );
        await provider.requests.single.close();
        await waitFor(() => !client.view.busy);
        expect(session.inputHistory, ['after the command']);
        if (panels) await waitFor(() => !client.frame.busy);
      },
    );

    test('second TUI cancels an external command (panels=$panels)', () async {
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      session.host.commands.publish(
        Command(
          name: 'wait',
          description: '',
          handler: (_) => release.future,
          cancel: release.complete,
        ),
      );
      final command = inspector.submitRequest(
        '/wait',
        id: inspector.requestWindow.id('external-command'),
      );
      final client = await connect(panels: panels);
      expect(client.view.busy, isTrue);
      expect(client.view.canCancel, isTrue);
      client.editor.inject(EscapeKey());
      expect((await command.completed).state, SessionRequestState.cancelled);
      await waitFor(() => !client.view.busy);
      expect(_receipts(inspector), hasLength(1));
    });

    test(
      'rejected and failed actions are never resubmitted (panels=$panels)',
      () async {
        var executions = 0;
        session.host.commands.publish(
          Command(
            name: 'fail',
            description: '',
            handler: (_) {
              executions++;
              throw StateError('failed command');
            },
          ),
        );
        final client = await connect(panels: panels);
        client.enter('/missing');
        await waitFor(() => _receipts(inspector).length == 1);
        expect(_receipts(inspector).single.state, SessionRequestState.rejected);
        client.enter('/fail');
        await waitFor(
          () =>
              _receipts(inspector).length == 2 &&
              _receipts(inspector).every((r) => r.terminal),
        );
        expect(_receipts(inspector).last.state, SessionRequestState.failed);
        expect(executions, 1);
        client.enter('fresh action');
        await waitFor(() => provider.requests.length == 1);
        provider.requests.single.add(
          const MessageComplete(
            content: [TextBlock('done')],
            stopReason: 'end_turn',
          ),
        );
        await provider.requests.single.close();
        await waitFor(() => !client.view.busy);
        expect(_receipts(inspector), hasLength(3));
        expect(executions, 1);
        expect(client.io.written.toString(), contains('unknown command'));
        expect(client.io.written.toString(), contains('Command failed'));
      },
    );
  }
}
