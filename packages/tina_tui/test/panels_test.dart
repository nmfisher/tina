import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart' show VirtualTerminal;
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_tui/tina_tui.dart' hide ApprovalDecision;
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

class AttachCheck extends AgentPlugin implements ConsoleContribution {
  AttachCheck(this.model);
  final String model;
  @override
  String get id => 'acme/attach-check';
  @override
  void attachConsole(ConsoleContext context) {
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
    session = TuiSession.wrap(TuiAssembly.start(
        options: AssemblyOptions(
            configPath: config.path, workingDirectory: dir.path),
        registerPlugins: (registry) => registry.register(
            'acme/attach-check', (context) => AttachCheck(context.model),
            description: 'Test plugin registration.'),
        providerFactory: (model) {
          final p = Provider(model);
          providers.add(p);
          return p;
        }));
    io = FakeIo();
    screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(120, 24, split: false),
        ansi: AnsiCapable.yes);
    sizes = StreamController();
    app = runApp(session,
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

  Future<void> spawn(String model) async {
    await session.commands['spawn']!.handler(model);
    await Future<void>.delayed(const Duration(milliseconds: 35));
  }

  PanelFrame getFrame() => editor.focusManager!.focused as PanelFrame;

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
      'settings opens during generation and saves without stopping the request',
      () async {
    await keys('keep working\r');
    final provider = providers.first;
    await waitFor(() => provider.requests.length == 1);
    await keys('/settings\r');
    await waitFor(() => editor.isReadingKey);
    expect(io.written.toString(), contains('Generation settings'));
    expect(session.host.session.loop.running, true);
    expect(provider.closed, false);
    await keys('Generation\r');
    await keys('2048\r');
    expect(File('${dir.path}/config').readAsStringSync(),
        contains('max_output = 2048'));
    expect(provider.requests, hasLength(1));
    expect(provider.closed, false);
    await keys('\x1b');
    await waitFor(() => !editor.isReadingKey);
    expect(session.host.session.loop.running, true);
    await keys('draft survives');
    provider.answer(0, 'finished normally');
    await waitFor(() => !session.host.session.loop.running);
    expect(editor.editState.buffer, 'draft survives');
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

  test('shutdown releases settings even with an unsaved draft', () async {
    await keys('keep working\r');
    final provider = providers.first;
    await waitFor(() => provider.requests.length == 1);
    await keys('/quit\r/settings\r');
    await waitFor(() => editor.isReadingKey);
    await keys('Theme\r');
    await keys('dark\r');
    expect(io.written.toString(), contains('unsaved changes'));
    provider.answer(0, 'finished');
    expect(await app.timeout(const Duration(seconds: 3)), 0);
  });

  test('settings and a background read-only edit share one dialog owner',
      () async {
    await session.commands['mode']!.handler('read-only');
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
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(approvalUi(session).asker!.current, isNull,
        reason: 'settings retains input until dismissed');
    expect(File('${dir.path}/reviewed.txt').existsSync(), false);
    await keys('\x1b');
    expect(session.host.session.loop.running, true);
    await waitFor(() => approvalUi(session).asker!.current != null);
    expect(approvalUi(session).asker!.current!.reason, contains('read-only'));
    await keys('y');
    await waitFor(() => provider.requests.length == 2);
    expect(File('${dir.path}/reviewed.txt').readAsStringSync(),
        'approved contents');
    expect(session.assembly.tools.mode.label, 'read-only');
    provider.answer(1, 'finished');
    await waitFor(() => !session.host.session.loop.running);
    await keys('chat draft');
    expect(editor.editState.buffer, 'chat draft');
  });

  test('Always entered in the UI is reused on later turns for the same file',
      () async {
    await session.commands['mode']!.handler('read-only');
    final provider = providers.first;
    Future<void> write(int index, String path, String content) async {
      provider.streams[index]
          .add(ToolCallStart(id: 'write-$index', name: 'write'));
      provider.streams[index].add(MessageComplete(content: [
        ToolUseBlock(id: 'write-$index', name: 'write', input: {
          'filePath': path,
          'content': content,
        })
      ], stopReason: 'tool_use'));
      await provider.streams[index].close();
    }

    await keys('first write\r');
    await waitFor(() => provider.requests.length == 1);
    await write(0, 'remembered.txt', 'first');
    await waitFor(() => approvalUi(session).asker!.current != null);
    expect(approvalUi(session).asker!.current!.details['permission_scope'],
        'file');
    await keys('a');
    await waitFor(() => provider.requests.length == 2);
    final target = File('${dir.path}/remembered.txt');
    expect(target.readAsStringSync(), 'first');
    expect(session.assembly.tools.sandbox.grants.patterns,
        [target.resolveSymbolicLinksSync()]);
    provider.answer(1, 'saved');
    await waitFor(() => !session.host.session.loop.running);

    await keys('write again\r');
    await waitFor(() => provider.requests.length == 3);
    await write(2, './remembered.txt', 'second');
    await waitFor(() => provider.requests.length == 4);
    expect(approvalUi(session).asker!.current, isNull);
    expect(target.readAsStringSync(), 'second');
    expect(session.assembly.tools.sandbox.grants.length, 1);
    provider.answer(3, 'saved again');
    await waitFor(() => !session.host.session.loop.running);

    await keys('write another file\r');
    await waitFor(() => provider.requests.length == 5);
    await write(4, 'other.txt', 'denied');
    await waitFor(() => approvalUi(session).asker!.current != null);
    await keys('n');
    await waitFor(() => provider.requests.length == 6);
    expect(File('${dir.path}/other.txt').existsSync(), false);
    expect(session.assembly.tools.sandbox.grants.length, 1);
    provider.answer(5, 'declined');
    await waitFor(() => !session.host.session.loop.running);
  });

  for (final network in [false, true]) {
    test(
        'UI Always remembers the exact command${network ? ' with network' : ''} on later turns',
        () async {
      await session.commands['mode']!.handler('read-only');
      final provider = providers.first;
      Future<void> command(int index, String text) async {
        provider.streams[index]
            .add(ToolCallStart(id: 'exec-$index', name: 'exec'));
        provider.streams[index].add(MessageComplete(content: [
          ToolUseBlock(id: 'exec-$index', name: 'exec', input: {
            'program': '/bin/echo',
            'args': [text],
            if (network) 'network': true,
            if (network) 'network_reason': 'test session network approval',
          })
        ], stopReason: 'tool_use'));
        await provider.streams[index].close();
      }

      await keys('run command\r');
      await waitFor(() => provider.requests.length == 1);
      await command(0, 'remembered command');
      await waitFor(() => approvalUi(session).asker!.current != null);
      expect(approvalUi(session).asker!.current!.details['permission_scope'],
          'command');
      expect(approvalUi(session).asker!.current!.kind, ApprovalKind.permission);
      expect(
          approvalUi(session).asker!.current!.details['required_permissions'],
          ['execution', if (network) 'network']);
      if (network) {
        await waitFor(
            () => io.written.toString().contains('with network access'));
        expect(io.written.toString(),
            contains('allow this command with network access'));
      }
      await keys('a');
      await waitFor(() => provider.requests.length == 2);
      expect(session.assembly.tools.processRunner.grants.length, 1);
      provider.answer(1, 'ran');
      await waitFor(() => !session.host.session.loop.running);

      await keys('run again\r');
      await waitFor(() => provider.requests.length == 3);
      await command(2, 'remembered command');
      await waitFor(() => provider.requests.length == 4);
      expect(approvalUi(session).asker!.current, isNull);
      final results = session.host.session.loop.log
          .whereType<MessageAppendedEntry>()
          .expand((entry) => entry.message.content)
          .whereType<ToolResultBlock>();
      expect(results, hasLength(2));
      expect(results.every((result) => !result.isError), true);
      expect(results.last.content, contains('remembered command'));
      provider.answer(3, 'ran again');
      await waitFor(() => !session.host.session.loop.running);

      await keys('run different command\r');
      await waitFor(() => provider.requests.length == 5);
      await command(4, 'different arguments');
      await waitFor(() => approvalUi(session).asker!.current != null);
      await keys('n');
      await waitFor(() => provider.requests.length == 6);
      expect(session.assembly.tools.processRunner.grants.length, 1);
      provider.answer(5, 'declined');
      await waitFor(() => !session.host.session.loop.running);
    });
  }

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
      'pasted multiline input survives recall and panel restore without stray cells',
      () async {
    final terminal = VirtualTerminal(width: 120, height: 24);
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
    await spawn('other');
    await keys('\x07\t\r');
    expect(editor.editState.buffer, text);
    terminal.feed(io.written.toString());
    // The root panel has a border while split. Its left rail must survive;
    // a raw newline from the restored draft used to overwrite column zero.
    final frame = getFrame();
    for (var row = frame.bounds.row + 1; row < frame.bounds.bottom; row++) {
      expect(terminal.charAt(row, frame.bounds.col), '│', reason: 'row $row');
    }
    await keys('\x15');
    expect(editor.editState.buffer, isEmpty);
  });

  test('closing a spawned panel clears the complete bottom rail', () async {
    final terminal = VirtualTerminal(width: 120, height: 24);
    await spawn('other');
    terminal.feed(io.written.toString());
    io.written.clear();
    final railRow = screen.layout.stripRow - 1;
    expect(terminal.charAt(railRow, 119), '┘');
    await keys('\x18');
    terminal.feed(io.written.toString());
    for (var col = 0; col < 120; col++) {
      expect(terminal.charAt(railRow, col), ' ', reason: 'column $col');
    }
    expect(getFrame().border, false);
    expect(screen.input.bounds.isEmpty, false);
  });

  test(
      'spawn, cycle, resize and close preserve independent drafts and sessions',
      () async {
    final mainId = session.host.session.id;
    await keys('main draft');
    await spawn('other');
    final otherId = getFrame().conversationId;
    expect(otherId, isNot(mainId));
    expect(getFrame().label, contains('other'));
    expect(screen.input.bounds.col, greaterThan(50));
    await keys('other draft');
    await keys('\x07\t\r'); // Ctrl+G, Tab, Enter
    expect(getFrame().conversationId, mainId);
    expect(editor.editState.buffer, 'main draft');
    await keys('\x17\t\r'); // Ctrl+W follows the same focus ring
    expect(getFrame().conversationId, otherId);
    expect(editor.editState.buffer, 'other draft');
    sizes.add(ScreenLayout.fromSize(40, 8, split: false));
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(screen.input.bounds.col, lessThan(3));
    expect(editor.editState.buffer, 'other draft');
    await keys('\x07\t\r');
    expect(editor.editState.buffer, 'main draft');
    await keys('\x07\t\r');
    await keys('\r');
    await waitFor(() => providers.last.requests.isNotEmpty);
    expect(providers.first.requests, isEmpty);
    await keys('\x18'); // Ctrl+X cancels/closes the running child
    await waitFor(() => providers.last.closed);
    expect(getFrame().conversationId, mainId);
    expect(editor.editState.buffer, 'main draft');
    final store = SessionStore.open(defaultSessionStorePath(dir.path));
    try {
      expect(store.list().map((s) => s.id), contains(otherId));
      expect(store.list().map((s) => s.id), isNot(contains(mainId)),
          reason: 'the main panel only had an unsent draft');
      expect(
          store
              .readEntries(otherId)
              .whereType<InputRecordedEntry>()
              .single
              .text,
          'other draft');
    } finally {
      store.close();
    }
  });

  test(
      'line scrolling targets the focused conversation and preserves both drafts',
      () async {
    for (var i = 0; i < 40; i++)
      session.terminal.writeln('main history row $i');
    final mainChat = screen.chat;
    await keys('main draft\x1b[1;3A');
    expect(mainChat.debugScrollOffset, 1);
    await spawn('other');
    final otherChat = screen.chat;
    await keys('child transcript\r');
    await waitFor(() => providers.last.requests.length == 1);
    providers.last.answer(
        0, List.generate(40, (i) => 'child history row $i').join('\n\n'));
    await waitFor(() => !getFrame().busy);
    await keys('other draft\x1b[1;9A');
    expect(otherChat.debugScrollOffset, 1);
    expect(mainChat.debugScrollOffset, 1);
    expect(editor.editState.buffer, 'other draft');
    await keys('\x07');
    await keys('\x1b[1;9A');
    expect(otherChat.debugScrollOffset, 1,
        reason: 'the focus ring owns arrows while cycling');
    await keys('\t\r');
    expect(screen.chat, same(mainChat));
    expect(editor.editState.buffer, 'main draft');
    await keys('\x1b\x1b[B');
    expect(mainChat.debugScrollOffset, 0);
    expect(otherChat.debugScrollOffset, 1);
    expect(editor.editState.buffer, 'main draft');
    await keys('\x07\t\r');
    expect(screen.chat, same(otherChat));
    expect(editor.editState.buffer, 'other draft');
    await keys('\x1b[1;9B');
    expect(otherChat.debugScrollOffset, 0);
  });

  test('new input steers only the submitting session while another panel runs',
      () async {
    await keys('first\r');
    await waitFor(() => providers.first.requests.length == 1);
    await keys('second\rmain draft');
    await waitFor(() => providers.first.requests.length == 2);
    await spawn('other');
    await keys('independent\rchild draft');
    await waitFor(() => providers.last.requests.length == 1);
    expect(
        screen.chat.snapshotLines().join('\n'), isNot(contains('main answer')));
    expect(editor.editState.buffer, 'child draft');
    providers.last.answer(0, 'child answer');
    providers.first.answer(1, 'main second answer');
    await keys('\x07\t\r');
    expect(editor.editState.buffer, 'main draft');
    expect(
        screen.chat.snapshotLines().join('\n'), contains('main second answer'));
    expect(screen.chat.snapshotLines().join('\n'),
        isNot(contains('child answer')));
    expect(
        session.host.session.loop.log
            .whereType<InputRecordedEntry>()
            .map((e) => e.text),
        ['first', 'second']);
  });

  test('cross-panel approvals serialize and keep focus until answered',
      () async {
    final mainId = session.host.session.id;
    await keys('saved main draft');
    await spawn('other');
    await keys('grok\r');
    await waitFor(() => editor.isReadingKey);
    final other = screen.chat;
    final service = session.host.plugins.whereType<ApprovalsPlugin>().single;
    final decision = service.request(
        operation: 'Root question',
        target: '',
        reason: 'Confirm the root action',
        kind: ApprovalKind.confirmation);
    await keys('\x07'); // cannot cycle focus away from a pending approval
    expect(screen.chat, same(other));
    await keys('\x1b[B\r'); // No to grok
    await waitFor(() => !identical(screen.chat, other) && editor.isReadingKey);
    expect(screen.input.buffer, 'saved main draft');
    await keys('\r'); // Yes to the queued root question
    expect(await decision, ApprovalDecision.allow);
    await waitFor(() => !editor.isReadingKey);
    expect(getFrame().conversationId, mainId);
    expect(editor.editState.buffer, 'saved main draft');
    expect(providers.every((p) => p.requests.isEmpty), true);
  });

  test(
      'parked panels remain reachable and cancelling navigation restores input',
      () async {
    final mainId = session.host.session.id;
    await keys('main draft');
    await spawn('second');
    await keys('second draft');
    await spawn('third');
    final thirdId = getFrame().conversationId;
    await keys('third draft');
    await keys('\x07\t'); // preview the offscreen first panel
    expect(screen.input.bounds.isEmpty, true);
    await keys('\x1b'); // cancel the preview
    expect(getFrame().conversationId, thirdId);
    expect(screen.input.bounds.isEmpty, false);
    expect(editor.editState.buffer, 'third draft');
    await keys('\x07\t\r');
    expect(getFrame().conversationId, mainId);
    expect(editor.editState.buffer, 'main draft');
    await keys('\x07\t\r');
    expect(editor.editState.buffer, 'second draft');
    await keys('\x0f'); // maximize
    expect(screen.input.bounds.width, greaterThan(100));
    await keys('\x18'); // close second, focus third
    expect(getFrame().conversationId, thirdId);
    expect(editor.editState.buffer, 'third draft');
    await spawn('fourth');
    expect(getFrame().label, '4: fourth');
  });

  test('failed panel attachment leaves the original panel usable', () async {
    final mainId = session.host.session.id;
    await keys('saved draft');
    await spawn('bad');
    expect(providers.last.closed, true);
    expect(getFrame().conversationId, mainId);
    expect(editor.editState.buffer, 'saved draft');
    expect(screen.input.bounds.isEmpty, false);
    expect(screen.chat.snapshotLines().join('\n'),
        contains('Could not open panel'));
    await spawn('other');
    await keys('/spawn\r'); // inherit the focused model, not the launch model
    expect(getFrame().label, endsWith(': other'));
    expect(providers.last.model, 'other');
    expect(providers, hasLength(4));
  });
}
