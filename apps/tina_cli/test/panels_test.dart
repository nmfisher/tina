import 'package:tina/tui.dart';
import 'package:tina/src/console_catalog.dart';
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart' show VirtualTerminal;
import 'package:tina_engine_2/tina_engine_2.dart';
import 'app_test.dart' show FakeIo, approvalUi;
import 'turn_rendering_test.dart' show waitFor;

class Provider implements LlmProvider {
  Provider(this.model);
  @override
  final String model;
  final requests = <List<Message>>[];
  final streams = <StreamController<StreamEvent>>[];
  bool closed = false;
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    requests.add(List.of(messages));
    final stream = StreamController<StreamEvent>();
    streams.add(stream);
    return stream.stream;
  }

  void answer(int index, String text) {
    streams[index].add(
        MessageComplete(content: [TextBlock(text)], stopReason: 'end_turn'));
    unawaited(streams[index].close());
  }

  @override
  void close() {
    closed = true;
    for (final stream in streams) {
      unawaited(stream.close());
    }
  }
}

class AttachCheck extends AgentPlugin {
  AttachCheck(this.model);
  final String model;
  @override
  String get id => 'acme/attach-check';
  @override
  List<ToolSchema> get tools => const [
        ToolSchema(
            name: 'wait_cleanup',
            description: 'Hold cleanup for input delivery testing',
            inputSchema: {})
      ];
}

class AttachCheckView implements ConsoleContribution {
  AttachCheckView(this.model);
  final String model;
  ConsoleContext? console;
  @override
  void attachConsole(ConsoleContext context) {
    console = context;
    context.settings.registerSection(
        id: 'acme/attach-check', title: model, build: () => []);
    if (model == 'bad') throw StateError('fixture attach failure');
  }

  @override
  void detachConsole() {}
  @override
  void repaintConsole() {}
}

void main() {
  late Directory dir;
  late FakeIo io;
  late Screen screen;
  late LineEditor editor;
  late TuiSession session;
  late Future<int> app;
  late StreamController<ScreenLayout> sizes;
  final providers = <Provider>[];
  final checkViews = <AttachCheckView>[];
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('tina-panels-');
    final config = File('${dir.path}/config')..writeAsStringSync('''
[default]
model = "main"
[providers.local]
name = "Local testing"
base_url = "http://localhost:1/v1"
models = ["main|Main model", "other|Other model"]
[plugins]
enabled = ["tina/chat-tui", "tina/panels-tui", "tina/tools", "tina/mode-tui", "tina/persistence", "tina/grok-guard", "tina/session-controls", "acme/attach-check"]
''');
    providers.clear();
    checkViews.clear();
    session = TuiSession.wrap(
        SessionAssembly.start(
            options: AssemblyOptions(
                configPath: config.path, workingDirectory: dir.path),
            registerPlugins: (registry) => registry.register(
                'acme/attach-check', (context) => AttachCheck(context.model),
                description: 'Test plugin registration.'),
            providerFactory: (model) {
              final p = Provider(model);
              providers.add(p);
              return p;
            }), viewFactory: (plugin, {required connection}) {
      if (plugin is AttachCheck) {
        final view = AttachCheckView(plugin.model);
        checkViews.add(view);
        return view;
      }
      return createConsoleView(plugin, connection: connection);
    });
    io = FakeIo();
    screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(120, 24, split: false),
        ansi: AnsiCapable.yes);
    sizes = StreamController();
    app = runTui(session,
        screen: screen,
        resizes: sizes.stream,
        editorFor: (s) =>
            editor = LineEditor(screen: s, escapeTimeout: Duration.zero));
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });
  tearDown(() async {
    io.feedBytes('\x03\x03\x03'.codeUnits);
    await app.timeout(const Duration(seconds: 4));
    io.closeInput();
    await sizes.close();
    dir.deleteSync(recursive: true);
  });
  Future<void> keys(String text) async {
    io.feedBytes(text.codeUnits);
    await Future<void>.delayed(const Duration(milliseconds: 35));
  }

  PanelFrame getFrame() => editor.focusManager!.focused as PanelFrame;

  Future<void> panelControls() async {
    await keys('\x07\x1b[B\r'); // cycle down to the status bar and focus it
    await keys('\r'); // open the panel controls
  }


  test('minimizing the last panel can be undone from status controls',
      () async {
    final frame = getFrame();
    await keys('saved draft');
    await panelControls();
    await keys('m');
    expect(screen.input.bounds.isEmpty, true);
    expect(frame.canFocus, false);
    await keys('\r');
    expect(getFrame(), same(frame));
    expect(screen.input.bounds.isEmpty, false);
    expect(editor.editState.buffer, 'saved draft');
  });


  test('Escape in status controls cancels work and restores the chat draft',
      () async {
    final frame = getFrame();
    await keys('running request\r');
    await waitFor(() => providers.first.requests.length == 1);
    await keys('unsent draft');
    await panelControls();
    await keys('m');
    expect(session.host.session.loop.running, true);
    expect(providers.first.closed, false);
    await keys('\x1b');
    expect(getFrame(), same(frame));
    expect(editor.editState.buffer, 'unsent draft');
    await waitFor(() => !frame.busy);
    expect(session.host.session.turns.single.stopReason, StopReason.cancelled);
  });

  test('dismissing slash completion restores the idle app transcript cells',
      () async {
    await keys('conversation before popup\r');
    await waitFor(() => providers.first.requests.length == 1);
    providers.first.answer(
        0, List.generate(30, (i) => 'retained answer row $i').join('\n'));
    await waitFor(() => !getFrame().busy);
    final terminal = VirtualTerminal(width: 120, height: 24)
      ..feed(io.written.toString());
    io.written.clear();
    final chat = screen.chat.bounds;
    final before = [
      for (var row = chat.row; row < screen.input.bounds.row; row++)
        terminal.rowText(row)
    ];
    await keys('/');
    terminal.feed(io.written.toString());
    io.written.clear();
    expect(editor.isCompleting, true);
    await keys('\x1b');
    terminal.feed(io.written.toString());
    expect(editor.isCompleting, false);
    expect([
      for (var row = chat.row; row < screen.input.bounds.row; row++)
        terminal.rowText(row)
    ], before);
  });

  for (final cancelFirst in [false, true]) {
    test(
        'queued messages remain visible until cleanup delivers them (cancel=$cancelFirst)',
        () async {
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      session.host.session.loop.registerContextExecutor('wait_cleanup',
          (_, context) async {
        started.complete();
        await release.future;
        return const ToolResult('cleanup finished');
      });
      await keys('first request\r');
      final provider = providers.first;
      await waitFor(() => provider.requests.length == 1);
      provider.streams[0]
          .add(const ToolCallStart(id: 'wait', name: 'wait_cleanup'));
      provider.streams[0].add(const MessageComplete(
          content: [ToolUseBlock(id: 'wait', name: 'wait_cleanup', input: {})],
          stopReason: 'tool_use'));
      await provider.streams[0].close();
      await started.future;
      if (cancelFirst) await keys('\x1b');
      io.written.clear();
      await keys('replacement one\rreplacement two\r');
      expect(provider.requests, hasLength(1),
          reason: 'cleanup has not released input yet');
      expect(screen.chat.snapshotLines().join('\n'),
          contains('Message queued; waiting for current work.'));
      final vt = VirtualTerminal(width: 120, height: 24)
        ..feed(io.written.toString());
      expect(vt.rowText(screen.layout.stripRow), contains('2 messages queued'));
      expect(editor.editState.buffer, isEmpty,
          reason: 'Enter accepted both messages');
      expect(
          session.host.session.loop.log
              .whereType<InputRecordedEntry>()
              .map((e) => e.text),
          ['first request']);
      release.complete();
      await waitFor(() => provider.requests.length == 2);
      provider.answer(1, 'first replacement answer');
      if (cancelFirst) {
        await waitFor(() => provider.requests.length == 3);
        provider.answer(2, 'second replacement answer');
      } else {
        // Steering coalesces accepted inputs into one request, retaining both
        // user entries. The UI must not claim one is still queued afterward.
        expect(
            provider.requests.last
                .expand((m) => m.content)
                .whereType<TextBlock>()
                .map((b) => b.text),
            containsAll(['replacement one', 'replacement two']));
      }
      await waitFor(() => !session.host.session.loop.running);
      expect(
          session.host.session.loop.log
              .whereType<InputRecordedEntry>()
              .map((e) => e.text),
          ['first request', 'replacement one', 'replacement two']);
      vt.feed(io.written.toString());
      expect(vt.rowText(screen.layout.stripRow), isNot(contains('queued')));
    });
  }

  for (final burst in [false, true]) {
    const replacement = 'fresh request';
    test('Escape cancels a response and the next Enter sends (burst=$burst)',
        () async {
      await keys('first request\r');
      final provider = providers.first;
      await waitFor(() => provider.requests.length == 1);
      if (burst) {
        editor.inject(EscapeKey());
        editor.inject(CharInput('f'));
        editor.inject(CharInput('resh request'));
        editor.inject(ControlKey(ControlCode.enter));
      } else {
        await keys('\x1b');
        await waitFor(() => !session.host.session.loop.running);
        await keys('$replacement\r');
      }
      await waitFor(() => provider.requests.length == 2);
      expect(
          provider.requests.last.last.content
              .whereType<TextBlock>()
              .single
              .text,
          replacement);
      provider.answer(1, 'new answer');
      await waitFor(() => !session.host.session.loop.running);
    });

    test('Escape dismisses an approval and the next Enter sends (burst=$burst)',
        () async {
      await session.commands['mode']!.handler('ask');
      await keys('first request\r');
      final provider = providers.first;
      await waitFor(() => provider.requests.length == 1);
      provider.streams[0].add(const ToolCallStart(id: 'write', name: 'write'));
      provider.streams[0].add(const MessageComplete(content: [
        ToolUseBlock(id: 'write', name: 'write', input: {
          'filePath': 'escape-denied.txt',
          'content': 'must not be written'
        })
      ], stopReason: 'tool_use'));
      await provider.streams[0].close();
      await waitFor(
          () => approvalUi(session).interaction.pending.firstOrNull != null);
      if (burst) {
        editor.inject(EscapeKey());
        editor.inject(CharInput('f'));
        editor.inject(CharInput('resh request'));
        editor.inject(ControlKey(ControlCode.enter));
      } else {
        await keys('\x1b');
        await waitFor(
            () => approvalUi(session).interaction.pending.firstOrNull == null);
        await keys('$replacement\r');
      }
      // A replacement submitted during approval cleanup must start a new turn
      // immediately, without needing an additional Enter or provider response.
      await waitFor(() => provider.requests.any((messages) => messages.any(
          (message) => message.content
              .whereType<TextBlock>()
              .any((block) => block.text == replacement))));
      provider.answer(provider.requests.length - 1, 'new answer');
      await waitFor(() => !session.host.session.loop.running);
    });
  }

  test('commands opt into concurrent dispatch through their live registration',
      () async {
    var concurrent = false, queued = false;
    session.commands.publish(Command(
        name: 'peek',
        description: 'fixture view',
        allowWhileRunning: true,
        handler: (_) => concurrent = true));
    session.commands.publish(Command(
        name: 'change',
        description: 'fixture mutation',
        handler: (_) => queued = true));
    await keys('keep working\r');
    final provider = providers.first;
    await waitFor(() => provider.requests.length == 1);
    await keys('/change\r/peek\r');
    expect(concurrent, true);
    expect(queued, false);
    expect(provider.requests, hasLength(1));
    provider.answer(0, 'finished');
    await waitFor(() => queued);
    expect(session.inputHistory, ['keep working']);
  });

  test(
      'settings saves during generation and Escape closes settings without cancelling',
      () async {
    await keys('keep working\r');
    final provider = providers.first;
    await waitFor(() => provider.requests.length == 1);
    await keys('/settings\r');
    await waitFor(() => editor.isReadingKey);
    expect(io.written.toString(), contains('Models'));
    expect(session.host.session.loop.running, true);
    expect(provider.closed, false);
    // Global scope is explicit; the default Session scope must not edit config.
    await keys('\t\tGeneration\r');
    await keys('local\r');
    await keys('2048\r');
    expect(File('${dir.path}/config').readAsStringSync(),
        contains('max_output = 2048'));
    expect(provider.requests, hasLength(1));
    expect(provider.closed, false);
    // Esc backs the editor out; the request underneath keeps running.
    await keys('\x1b');
    await waitFor(() => !editor.isReadingKey);
    expect(session.host.session.loop.running, true,
        reason: 'closing Settings must not cancel the running request');
    expect(provider.requests, hasLength(1));
    await keys('draft survives');
    expect(editor.editState.buffer, 'draft survives');
    // Esc at the prompt still cancels the request.
    await keys('\x1b');
    await waitFor(() => !session.host.session.loop.running);
    expect(session.host.session.turns.single.stopReason, StopReason.cancelled);
    expect(session.inputHistory, ['keep working']);
  });

  test('plugin toggles made during a request wait until it ends', () async {
    await keys('keep working\r');
    final provider = providers.first;
    await waitFor(() => provider.requests.length == 1);
    await keys('/settings\r');
    await waitFor(() => editor.isReadingKey);
    await keys('Plugins\r');
    await keys('tina/grok-guard\r');
    final manager = session.assembly.pluginManager;
    expect(manager.waitingForIdle, true);
    expect(manager.pending, contains('tina/grok-guard'));
    expect(manager.loaded, contains('tina/grok-guard'));
    provider.answer(0, 'finished');
    await waitFor(() => !manager.loaded.contains('tina/grok-guard'));
    expect(editor.isReadingKey, true);
    await keys('\x1b\x1b');
    await waitFor(() => !editor.isReadingKey);
    await keys('still editable');
    expect(editor.editState.buffer, 'still editable');
  });

  test('shutdown releases settings even with an unconfirmed field', () async {
    await keys('keep working\r');
    final provider = providers.first;
    await waitFor(() => provider.requests.length == 1);
    await keys('/settings\r');
    await waitFor(() => editor.isReadingKey);
    final before = File('${dir.path}/config').readAsStringSync();
    await keys('Mode and auto approval\r');
    await keys('classifier instruction\r\r');
    await keys('unconfirmed instruction');
    expect(io.written.toString(), contains('unconfirmed instruction'));
    await session.assembly.handleCommand('/quit');
    expect(await app.timeout(const Duration(seconds: 3)), 0);
    expect(File('${dir.path}/config').readAsStringSync(), before);
  });

  test('settings defers a queued background approval to its own Esc',
      () async {
    await session.commands['mode']!.handler('ask');
    await keys('edit after reading\r');
    final provider = providers.first;
    await waitFor(() => provider.requests.length == 1);
    await keys('/settings\r');
    await waitFor(() => editor.isReadingKey);
    provider.streams.first.add(const ToolCallStart(id: 'write', name: 'write'));
    provider.streams.first.add(const MessageComplete(content: [
      ToolUseBlock(
          id: 'write',
          name: 'write',
          input: {'filePath': 'reviewed.txt', 'content': 'approved contents'})
    ], stopReason: 'tool_use'));
    await provider.streams.first.close();
    await waitFor(() => approvalUi(session).interaction.pending.isNotEmpty);
    expect(approvalUi(session).interaction.pending, hasLength(1),
        reason: 'the runtime retains the question while Settings owns input');
    expect(File('${dir.path}/reviewed.txt').existsSync(), false);
    // Esc closes Settings only. The turn keeps running; the queued approval
    // presents as soon as the keyboard is free.
    await keys('\x1b');
    expect(session.host.session.loop.running, true,
        reason: 'closing Settings must not cancel the awaiting turn');
    await waitFor(() => io.written.toString()
        .contains('Allow workspace writes for this session'));
    // Esc at the approval prompt cancels the turn (global prompt path).
    await keys('\x1b');
    await waitFor(() => !session.host.session.loop.running);
    expect(approvalUi(session).interaction.pending, isEmpty);
    expect(provider.requests, hasLength(1));
    expect(File('${dir.path}/reviewed.txt').existsSync(), false);
    expect(session.host.session.turns.single.stopReason, StopReason.cancelled);
    expect(session.assembly.tools.mode.label, 'approve');
    await keys('chat draft');
    expect(editor.editState.buffer, 'chat draft');
  });

  test(
    'workspace approval in the UI covers later files for this session',
    () async {
      final provider = providers.first;
      final initialGrants = session.assembly.tools.commandApprovals.entries;
      Future<void> write(int index, String path) async {
        provider.streams[index].add(
          ToolCallStart(id: 'w$index', name: 'write'),
        );
        provider.streams[index].add(
          MessageComplete(
            content: [
              ToolUseBlock(
                id: 'w$index',
                name: 'write',
                input: {'filePath': path, 'content': path},
              ),
            ],
            stopReason: 'tool_use',
          ),
        );
        await provider.streams[index].close();
      }

      await keys('first write\r');
      await waitFor(() => provider.requests.length == 1);
      await write(0, 'first.txt');
      await waitFor(() => approvalUi(session).interaction.pending.isNotEmpty);
      expect(
        approvalUi(
          session,
        ).interaction.pending.single.details['workspace_write_grant'],
        true,
      );
      expect(File('${dir.path}/first.txt').existsSync(), false);
      await keys('y');
      await waitFor(() => provider.requests.length == 2);
      expect(File('${dir.path}/first.txt').readAsStringSync(), 'first.txt');
      provider.answer(1, 'saved');
      await waitFor(() => !session.host.session.loop.running);

      await keys('another file\r');
      await waitFor(() => provider.requests.length == 3);
      await write(2, 'second.txt');
      await waitFor(() => provider.requests.length == 4);
      expect(approvalUi(session).interaction.pending, isEmpty);
      expect(File('${dir.path}/second.txt').readAsStringSync(), 'second.txt');
      expect(session.assembly.tools.commandApprovals.entries, initialGrants);
      provider.answer(3, 'saved again');
      await waitFor(() => !session.host.session.loop.running);
    },
  );

  test('model picker updates the active panel without changing its session',
      () async {
    final id = getFrame().conversationId;
    expect(await session.commands['model']!.complete!(''),
        ['local/main', 'local/other'],
        reason: 'unconfigured catalog providers should not clutter the picker');
    await keys('/model\r');
    await waitFor(() => editor.isReadingKey);
    expect(io.written.toString(), contains('Local testing'));
    expect(io.written.toString(), contains('filter models…'));
    await keys('local/other\r');
    await waitFor(
        () => !editor.isReadingKey && getFrame().label.endsWith('local/other'));
    expect(getFrame().conversationId, id);
    expect(session.host.model, 'local/other');
    expect(providers.first.closed, true);
    await keys('draft after switching');
    await waitFor(() => editor.editState.buffer == 'draft after switching');
  });

  test('clear removes rendered history and leaves the input usable', () async {
    await keys('remember this\r');
    await waitFor(() => providers.first.requests.isNotEmpty);
    providers.first.answer(0, 'old answer');
    await waitFor(() => session.host.session.turns.isNotEmpty);
    await keys('/clear\r');
    expect(
        screen.chat.snapshotLines().join('\n'), isNot(contains('old answer')));
    expect(session.host.session.loop.derive().messages, isEmpty);
    await keys('fresh draft');
    expect(editor.editState.buffer, 'fresh draft');
  });

  test(
      'pasted multiline input survives recall without stray cells',
      () async {
    final text =
        List.generate(8, (i) => 'Line $i\nSecond $i\rAnother $i').join('\n');
    await keys('\x1b[200~$text\x1b[201~');
    expect(editor.editState.buffer, text);
    expect(screen.input.cursor, lessThanOrEqualTo(screen.input.buffer.length));
    await keys('\r');
    await waitFor(() => providers.first.requests.isNotEmpty);
    expect(
        providers.first.requests.single.last.content
            .whereType<TextBlock>()
            .single
            .text,
        text);
    providers.first.answer(0, 'answer');
    await waitFor(() => !session.host.session.loop.running);
    await keys('\x1b[A');
    expect(editor.editState.buffer, text);
    await keys('\x15');
    expect(editor.editState.buffer, isEmpty);
  });

  test('/close on the only panel keeps it open and points at /quit', () async {
    final frame = getFrame();
    await keys('/close\r');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(getFrame(), same(frame),
        reason: 'the last panel never closes; the conversation survives');
    expect(screen.chat.snapshotLines().join('\n'),
        contains('This is the last panel. Use /quit to exit.'));
  });

  test('opening conversations from inside the TUI is gone: /spawn refused',
      () async {
    await keys('/spawn\r');
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(screen.chat.snapshotLines().join('\n'),
        contains('unknown command: /spawn'));
    // The published panel commands are exactly /close now.
    expect(session.commands['close'], isNotNull);
    expect(session.commands['spawn'], isNull);
  });
}
