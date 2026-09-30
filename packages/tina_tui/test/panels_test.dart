import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart' show VirtualTerminal;
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_tui/tina_tui.dart' hide ApprovalDecision;
import 'app_test.dart' show FakeIo;
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
base_url = "http://localhost:1/v1"
models = ["main", "other"]
[plugins]
enabled = ["tina/chat-tui", "tina/panels-tui", "tina/mode-tui", "tina/persistence", "tina/grok-guard", "tina/session-controls", "acme/attach-check"]
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

  test('model picker updates the active panel without changing its session',
      () async {
    final id = getFrame().conversationId;
    await keys('/model\r');
    await waitFor(() => editor.isReadingKey);
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
      expect(store.list().map((s) => s.id), containsAll([mainId, otherId]));
      expect(
          store
              .readEntries(otherId)
              .whereType<InputRecordedEntry>()
              .single
              .text,
          'other draft');
      expect(
          store.readEntries(mainId).whereType<InputRecordedEntry>(), isEmpty);
    } finally {
      store.close();
    }
  });

  test('two panels run concurrently and queue only into the submitting session',
      () async {
    await keys('first\rsecond\rmain draft');
    await waitFor(() => providers.first.requests.length == 1);
    await spawn('other');
    await keys('independent\rchild draft');
    await waitFor(() => providers.last.requests.length == 1);
    providers.first.answer(0, 'main answer');
    await waitFor(() => providers.first.requests.length == 2);
    expect(
        screen.chat.snapshotLines().join('\n'), isNot(contains('main answer')));
    expect(editor.editState.buffer, 'child draft');
    providers.last.answer(0, 'child answer');
    providers.first.answer(1, 'main second answer');
    await keys('\x07\t\r');
    expect(editor.editState.buffer, 'main draft');
    expect(screen.chat.snapshotLines().join('\n'), contains('main answer'));
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
