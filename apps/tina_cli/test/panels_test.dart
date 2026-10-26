import 'package:tina/tui.dart';
import 'package:tina/src/console_catalog.dart';
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart' show VirtualTerminal;
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_persistence/tina_persistence.dart';
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

  Future<void> spawn(String model) async {
    await checkViews
        .firstWhere((view) => view.console != null)
        .console!
        .panels!
        .spawn(model);
    await Future<void>.delayed(const Duration(milliseconds: 35));
  }

  PanelFrame getFrame() => editor.focusManager!.focused as PanelFrame;

  Future<void> panelControls() async {
    await keys('\x07\x1b[B\r'); // cycle down to the status bar and focus it
    await keys('\r'); // open the panel controls
  }

  test('panel controls replace the slash command and preserve drafts',
      () async {
    expect(session.commands['panels'], isNull);
    final main = getFrame();
    await keys('main draft');
    await spawn('other');
    await keys('child draft');
    await spawn('main');
    final third = getFrame();
    final terminal = VirtualTerminal(width: 120, height: 24)
      ..feed(io.written.toString());
    io.written.clear();
    expect(terminal.rowText(screen.layout.stripRow),
        contains('3 panels (2 hidden)'));
    await panelControls();
    terminal.feed(io.written.toString());
    io.written.clear();
    expect(terminal.rowText(screen.layout.stripRow), contains('Enter panels'));
    expect(terminal.cursorVisible, false);
    await keys('m'); // minimize the first conversation
    expect(main.canFocus, false);
    expect(editor.focusManager!.focused, isNot(isA<PanelFrame>()));
    await keys('\r'); // restore the first conversation and focus its draft
    expect(getFrame(), same(main));
    expect(main.canFocus, true);
    expect(editor.editState.buffer, 'main draft');
    await panelControls();
    await keys('\x1b[B\x1b[Bx'); // maximize the third (currently hidden) panel
    expect(screen.chat.bounds.width, greaterThan(100));
    await keys('x'); // toggle back to split
    expect(screen.chat.bounds.width, lessThan(70));
    await keys('\r');
    expect(getFrame(), same(third));
    expect(editor.editState.buffer, isEmpty);
    expect(providers.every((p) => p.requests.isEmpty), true,
        reason: 'status/panel selection must never submit chat input');
  });

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

  test('minimizing the active split panel preserves both drafts', () async {
    await keys('main draft');
    await spawn('other');
    final child = getFrame();
    await keys('child draft');
    await panelControls();
    await keys('\x1b[Bm');
    expect(child.canFocus, false);
    expect(editor.editState.buffer, 'main draft');
    await keys('\r');
    expect(getFrame(), same(child));
    expect(editor.editState.buffer, 'child draft');
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
    await waitFor(() => io.written.toString().contains('[y] allow once'));
    // Esc at the approval prompt cancels the turn (global prompt path).
    await keys('\x1b');
    await waitFor(() => !session.host.session.loop.running);
    expect(approvalUi(session).interaction.pending, isEmpty);
    expect(provider.requests, hasLength(1));
    expect(File('${dir.path}/reviewed.txt').existsSync(), false);
    expect(session.host.session.turns.single.stopReason, StopReason.cancelled);
    expect(session.assembly.tools.mode.label, 'ask');
    await keys('chat draft');
    expect(editor.editState.buffer, 'chat draft');
  });

  test('Always entered in the UI is reused on later turns for the same file',
      () async {
    await session.commands['mode']!.handler('ask');
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
    await waitFor(
        () => approvalUi(session).interaction.pending.firstOrNull != null);
    expect(
        approvalUi(session)
            .interaction
            .pending
            .firstOrNull!
            .details['permission_scope'],
        'file');
    await keys('a\r');
    await waitFor(() => provider.requests.length == 2);
    final target = File('${dir.path}/remembered.txt');
    expect(target.readAsStringSync(), 'first');
    expect(session.assembly.tools.commandApprovals.coversAccess(
        'write', target.resolveSymbolicLinksSync()), true);
    provider.answer(1, 'saved');
    await waitFor(() => !session.host.session.loop.running);

    await keys('write again\r');
    await waitFor(() => provider.requests.length == 3);
    await write(2, './remembered.txt', 'second');
    await waitFor(() => provider.requests.length == 4);
    expect(approvalUi(session).interaction.pending.firstOrNull, isNull);
    expect(target.readAsStringSync(), 'second');
    expect(session.assembly.tools.commandApprovals.entries
        .where((entry) => entry['kind'] == 'access').length, 1);
    provider.answer(3, 'saved again');
    await waitFor(() => !session.host.session.loop.running);

    await keys('write another file\r');
    await waitFor(() => provider.requests.length == 5);
    await write(4, 'other.txt', 'denied');
    await waitFor(
        () => approvalUi(session).interaction.pending.firstOrNull != null);
    await keys('n');
    await waitFor(() => provider.requests.length == 6);
    expect(File('${dir.path}/other.txt').existsSync(), false);
    expect(session.assembly.tools.commandApprovals.entries
        .where((entry) => entry['kind'] == 'access').length, 1);
    provider.answer(5, 'declined');
    await waitFor(() => !session.host.session.loop.running);
  });

  for (final selectAlways in [false, true]) {
    for (final access in ['confined', 'network', 'outside sandbox']) {
      final network = access == 'network';
      final outside = access == 'outside sandbox';
      Iterable<Map<String, Object?>> sessionGrants() =>
          session.assembly.tools.commandApprovals.entries
              .where((entry) => entry['scope'] == 'session');
      int rememberedCommands() => outside
          ? sessionGrants().length
          : session.assembly.tools.processRunner.grants.length;
      test(
          'UI Always (${selectAlways ? 'arrows and Enter' : 'shortcut'}) remembers the exact command ($access) on later turns, even after failure',
          () async {
        await session.commands['mode']!.handler('ask');
        final provider = providers.first;
        Future<void> command(int index, String text) async {
          provider.streams[index]
              .add(ToolCallStart(id: 'exec-$index', name: 'exec'));
          provider.streams[index].add(MessageComplete(content: [
            ToolUseBlock(id: 'exec-$index', name: 'exec', input: {
              // Explicitly request writes so this fixture exercises approval.
              'program': outside ? '/usr/bin/false' : '/usr/bin/printf',
              'args': ['%s\\n', text],
              if (!outside) 'access': 'workspace-write',
              if (network) 'network': true,
              if (network) 'network_reason': 'test session network approval',
              if (outside) 'outside_sandbox': true,
              if (outside) 'sandbox_reason': 'test unconfined session approval',
            })
          ], stopReason: 'tool_use'));
          await provider.streams[index].close();
        }

        await keys('run command\r');
        await waitFor(() => provider.requests.length == 1);
        await command(0, 'remembered command');
        await waitFor(
            () => approvalUi(session).interaction.pending.firstOrNull != null);
        expect(
            approvalUi(session)
                .interaction
                .pending
                .firstOrNull!
                .details['permission_scope'],
            'command');
        expect(approvalUi(session).interaction.pending.firstOrNull!.kind,
            ApprovalKind.permission);
        expect(
            approvalUi(session)
                .interaction
                .pending
                .firstOrNull!
                .details['required_permissions'],
            [
              'execution',
              if (!outside) 'workspaceWrite',
              if (network || outside) 'network',
              if (outside) 'unconfined'
            ]);
        if (network) {
          await waitFor(
              () => io.written.toString().contains('with network access'));
          expect(io.written.toString(),
              contains('Remember…'));
        }
        // Exercise both the shortcut and selecting Always with Enter.
        await keys(
            selectAlways ? '\x1b[B\x1b[B\r\r' : 'a\r');
        await waitFor(() => provider.requests.length == 2);
        expect(rememberedCommands(), 1);
        if (outside) {
          expect(sessionGrants().single['scope'], 'session');
          expect(session.assembly.tools.processRunner.grants.length, 0,
              reason: 'host approvals use the revocable scoped store');
        }
        provider.answer(1, 'ran');
        await waitFor(() => !session.host.session.loop.running);

        await keys('run again\r');
        await waitFor(() => provider.requests.length == 3);
        await command(2, 'remembered command');
        await waitFor(() => provider.requests.length == 4);
        expect(approvalUi(session).interaction.pending.firstOrNull, isNull);
        final results = session.host.session.loop.log
            .whereType<MessageAppendedEntry>()
            .expand((entry) => entry.message.content)
            .whereType<ToolResultBlock>();
        expect(results, hasLength(2));
        expect(results.every((result) => result.isError == outside), true);
        expect(results.last.content,
            contains(outside ? 'exit code: 1' : 'remembered command'));
        provider.answer(3, 'ran again');
        await waitFor(() => !session.host.session.loop.running);

        await keys('run different command\r');
        await waitFor(() => provider.requests.length == 5);
        await command(4, 'different arguments');
        await waitFor(
            () => approvalUi(session).interaction.pending.firstOrNull != null);
        await keys('n');
        await waitFor(() => provider.requests.length == 6);
        expect(rememberedCommands(), 1);
        provider.answer(5, 'declined');
        await waitFor(() => !session.host.session.loop.running);
      });
    }
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
    await keys('\x07\t\t\r');
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

  test('shell draft has one prompt marker across panel focus changes',
      () async {
    await keys('!echo hello');
    final mainFrame = getFrame();
    expect(screen.input.buffer, 'echo hello');
    expect(screen.input.prompt, contains(' ! '));
    await spawn('other');
    await keys('normal draft!');
    expect(screen.input.buffer, 'normal draft!');
    expect(screen.input.prompt, contains(' > '));

    final terminal = VirtualTerminal(width: 120, height: 24)
      ..feed(io.written.toString());
    final row = terminal.rowText(mainFrame.inputRect.row);
    expect(row, contains('main ! echo hello'));
    expect(row, isNot(contains('! !echo')));
    expect(mainFrame.inputBuffer, '!echo hello');

    await keys('\x07\t\t\r');
    expect(editor.editState.buffer, '!echo hello');
    expect(screen.input.buffer, 'echo hello');
    expect(screen.input.cursor, 'echo hello'.length);
    expect(screen.input.prompt, contains(' ! '));
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
    await keys('\x07\t\t\r'); // skip status controls to reach the root
    expect(getFrame().conversationId, mainId);
    expect(editor.editState.buffer, 'main draft');
    await keys('\x17\t\r'); // Ctrl+W follows the same focus ring
    expect(getFrame().conversationId, otherId);
    expect(editor.editState.buffer, 'other draft');
    sizes.add(ScreenLayout.fromSize(40, 8, split: false));
    await Future<void>.delayed(const Duration(milliseconds: 35));
    expect(screen.input.bounds.col, lessThan(3));
    expect(editor.editState.buffer, 'other draft');
    await keys('\x07\t\t\r');
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
      expect(
          store.readEntries(otherId).whereType<TurnEndedEntry>(), hasLength(1),
          reason: 'the owner drains cancellation before closing persistence');
    } finally {
      store.close();
    }
  });

  test('closing the initial panel retains application ownership until exit',
      () async {
    await spawn('other');
    await keys('\x07\t\t\r'); // focus the initial panel
    expect(getFrame().conversationId, session.host.session.id);
    await keys('\x18');
    expect(providers.first.closed, isFalse,
        reason:
            'the initial assembly still supplies new sessions and settings');
    await spawn('third');
    expect(getFrame().label, contains('third'));
    await keys('\x03');
    expect(await app.timeout(const Duration(seconds: 3)), 0);
    expect(providers.every((provider) => provider.closed), isTrue);
  });

  test(
      'line scrolling targets the focused conversation and preserves both drafts',
      () async {
    for (var i = 0; i < 40; i++)
      session.terminal.writeln('main history row $i');
    final mainChat = screen.chat;
    await waitFor(() =>
        mainChat.snapshotLines().join('\n').contains('main history row 39'));
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
    await keys('\t\t\r');
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
    await keys('\x07\t\t\r');
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

  test('Escape cancels only the active conversation and preserves both drafts',
      () async {
    await keys('main request\r');
    await waitFor(() => providers.first.requests.length == 1);
    await keys('main draft');
    await spawn('other');
    await keys('child request\rchild draft');
    await waitFor(() => providers.last.requests.length == 1);
    final child = getFrame();
    await keys('\x1b');
    await waitFor(() => !child.busy);
    expect(editor.editState.buffer, 'child draft');
    expect(providers.last.streams.single.hasListener, false);
    expect(providers.first.streams.single.hasListener, true);
    expect(session.host.session.loop.running, true);
    await keys('\x07\t\t\r');
    expect(editor.editState.buffer, 'main draft');
    providers.first.answer(0, 'main finished');
    await waitFor(() => !session.host.session.loop.running);
    expect(session.host.session.turns.single.stopReason, StopReason.complete);
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
    await keys('\x07\t\t'); // skip status and preview the offscreen first panel
    expect(screen.input.bounds.isEmpty, true);
    await keys('\x1b'); // cancel the preview
    expect(getFrame().conversationId, thirdId);
    expect(screen.input.bounds.isEmpty, false);
    expect(editor.editState.buffer, 'third draft');
    await keys('\x07\t\t\r');
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
    await keys('/spawn\r'); // use the current configured conversation default
    expect(getFrame().label, endsWith(': main'));
    expect(providers.last.model, 'main');
    expect(providers, hasLength(4));
  });
}
