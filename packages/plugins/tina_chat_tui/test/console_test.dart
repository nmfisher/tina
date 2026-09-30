import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_self_update/tina_self_update.dart';
import 'package:tina_console/testing.dart';

class Updates implements UpdateStatusSource {
  final notifications = StreamController<void>.broadcast();
  @override
  UpdateStatus status =
      const UpdateStatus(UpdatePhase.available, tag: 'v0.9.1');
  @override
  Stream<void> get changes => notifications.stream;
  @override
  Future<void> checkInBackground() async {}
}

class Io implements Stdio {
  final input = StreamController<List<int>>(sync: true);
  final output = StringBuffer();
  void feed(String value) => input.add(value.codeUnits);
  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 80;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) => const Stream.empty();
}

class Mode implements ModeControl {
  @override
  PermissionMode mode = PermissionMode.ask;
}

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 30));
const call = ToolUse(id: 'a', name: 'bash', input: {'command': 'echo hello'});
void main() {
  late Io io;
  late Screen screen;
  late LineEditor editor;
  late ConsoleContext context;
  late ChatTuiPlugin chat;
  late ModeTuiPlugin modes;
  late ModePlugin control;
  setUp(() {
    io = Io();
    screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    context = ConsoleContext(screen: screen, editor: editor);
    chat = ChatTuiPlugin(
        model: 'provider/test-model',
        now: () => DateTime(2026, 9, 28, 3, 4, 5));
    chat.attachConsole(context);
    control = ModePlugin();
    modes = ModeTuiPlugin(policy: control)..attachConsole(context);
  });
  tearDown(() {
    chat.closeSession();
    modes.closeSession();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  });
  String transcript() => screen.chat.snapshotLines().join('\n');
  String visible() {
    final vt = VirtualTerminal(width: 80, height: 24)
      ..feed(io.output.toString());
    return List.generate(24, vt.rowText).join('\n');
  }

  test('estimated spend shares the strip with update status and trips the cap',
      () async {
    chat.closeSession();
    var estimated = 15;
    chat = ChatTuiPlugin(
        model: 'test',
        tokenCap: 100,
        sessionTokens: () => 60,
        sessionEstimatedTokens: () => estimated);
    chat.attachConsole(context);
    final source = Updates();
    final update = UpdateTuiPlugin(source)..attachConsole(context);
    addTearDown(() {
      update.closeSession();
      unawaited(source.notifications.close());
    });
    await tick();
    expect(visible(), contains('update ⬆ v0.9.1 · /update'));
    expect(visible(), contains('Σ 60 +~15 est / 100 · 75%'));
    chat.repaintConsole();
    expect(visible(), contains('update ⬆ v0.9.1'));
    estimated = 40;
    chat.repaintConsole();
    expect(visible(), contains('SPEND LIMIT TRIPPED'));
    expect(visible(), contains('update ⬆ v0.9.1'));
    update.detachConsole();
    expect(visible(), isNot(contains('update ⬆')));
    expect(visible(), contains('SPEND LIMIT TRIPPED'));
    update.attachConsole(context);
    chat.detachConsole();
    expect(visible(), contains('update ⬆ v0.9.1'));
    expect(visible(), isNot(contains('SPEND LIMIT TRIPPED')));
  });
  test(
      'update state changes repaint without a turn and detach removes the subscription',
      () async {
    final source = Updates();
    final update = UpdateTuiPlugin(source)..attachConsole(context);
    addTearDown(() {
      update.closeSession();
      unawaited(source.notifications.close());
    });
    source.status = const UpdateStatus(UpdatePhase.failed, reason: 'HTTP 429');
    source.notifications.add(null);
    await tick();
    expect(visible(), contains('update check failed — HTTP 429'));
    expect(visible(), contains('Σ 0'));
    source.status = const UpdateStatus(UpdatePhase.current);
    source.notifications.add(null);
    await tick();
    expect(visible(), isNot(contains('update check')));
    update.detachConsole();
    source.status = const UpdateStatus(UpdatePhase.available, tag: 'v9.0.0');
    source.notifications.add(null);
    await tick();
    expect(visible(), isNot(contains('v9.0.0')));
  });
  test(
      'Shift-Tab cycles the command authority without submitting or losing a draft',
      () async {
    final line = editor.readLine('unused');
    await tick();
    io.feed('draft\x1b[Z');
    await tick();
    expect(control.mode, PermissionMode.readOnly);
    expect(transcript(), isNot(contains('mode:')));
    expect(io.output.toString(), contains('mode: read-only'));
    await control.commands.single.handler('ask');
    modes.repaintConsole();
    io.feed('\x1b[Z');
    await tick();
    expect(control.mode, PermissionMode.readOnly);
    io.feed(' intact\r');
    expect(await line, 'draft intact');
    modes.detachConsole();
    final next = editor.readLine('unused');
    await tick();
    io.feed('\x1b[Z\r');
    expect(await next, '');
    expect(control.mode, PermissionMode.readOnly);
  });
  test('Shift-Tab works during a turn but yields to approval key ownership',
      () async {
    editor.beginCancelMonitor(() {}, onQueueSubmit: (_) {});
    io.feed('queued\x1b[Z');
    await tick();
    expect(control.mode, PermissionMode.readOnly);
    final read = editor.readKey(globalKeys: true);
    await tick();
    io.feed('\x1b[Z');
    expect(await read, ControlKey(ControlCode.backtab));
    expect(control.mode, PermissionMode.readOnly);
    editor.endInputCaptureWindow();
    final line = editor.readLine('unused');
    await tick();
    io.feed('\r');
    expect(await line, 'queued');
  });
  test(
      'timestamped Markdown, folded reasoning/tools and model prompt match legacy look',
      () {
    chat.entry(const InputRecordedEntry(turnId: 't', text: 'hello'),
        LogEvent.appended);
    chat.watch(const SawThinking('consider this', startsBlock: true));
    chat.watch(const SawText('## Answer\n\n**bold** and `code`'));
    chat.entry(
        const MessageAppendedEntry(
            turnId: 't',
            message: Message(
                role: Role.assistant,
                content: [TextBlock('## Answer\n\n**bold** and `code`')],
                reasoning: [ReasoningBlock('consider this')])),
        LogEvent.appended);
    chat.observe(const ToolStarted(call));
    chat.observe(const ToolOutput(call, 'hello\n'));
    chat.observe(const ToolFinished(
        call, ToolResult('hello\n', elapsed: Duration(milliseconds: 41))));
    expect(transcript(), contains('03:04  hello'));
    expect(transcript(), contains('▸ reasoning  13 chars'));
    expect(transcript(), contains('→ bash · echo hello  ok · 41ms'));
    expect(transcript(), contains('Answer'));
    expect(transcript(), isNot(contains('**bold**')));
    expect(chat.blocks.where((b) => b.kind == ChatBlockKind.reasoning),
        hasLength(1));
    expect(editor.promptBuilder!(), contains('test-model > '));
    expect(transcript(), isNot(contains('tina:')));
    screen.resize(ScreenLayout.fromSize(25, 8, split: false));
    chat.repaintConsole();
    expect(
        chat.renderer
            .render(chat.blocks.first,
                RenderContext(width: 40, theme: screen.theme))
            .first
            .runs
            .first
            .text,
        '03:04 ');
  });
  test(
      'Ctrl-B expands actual output in place, preserves draft, and yields to approval',
      () async {
    chat.observe(const ToolStarted(call));
    chat.observe(const ToolFinished(call, ToolResult('retained output')));
    expect(transcript(), isNot(contains('retained output')));
    final line = editor.readLine('unused');
    await tick();
    io.feed('draft\x02');
    await tick();
    io.feed('\r');
    await tick();
    expect(transcript(), contains('retained output'));
    final approval = editor.readKey(globalKeys: true);
    await tick();
    io.feed('\r');
    expect(await approval, ControlKey(ControlCode.enter));
    expect(
        chat.blocks
            .where((b) => b.kind == ChatBlockKind.toolCall)
            .single
            .folded,
        false);
    io.feed('\x1b');
    await tick();
    io.feed(' intact\r');
    expect(await line, 'draft intact');
  });
  test(
      'replay renders original timestamps, calls, errors and reasoning without executing',
      () {
    chat.detachConsole();
    final loop =
        AgentLoop(provider: ScriptedProvider([]), plugins: [], seedLog: [
      const MessageAppendedEntry(
          turnId: 'old',
          at: '2026-09-28T03:04:05',
          message:
              Message(role: Role.user, content: [TextBlock('old prompt')])),
      MessageAppendedEntry(
          turnId: 'old',
          message: Message(
              role: Role.assistant,
              content: [call.toBlock()],
              reasoning: [ReasoningBlock('old thought')])),
      const MessageAppendedEntry(
          turnId: 'old',
          message: Message(role: Role.user, content: [
            ToolResultBlock(
                toolUseId: 'a', content: 'Permission denied', isError: true)
          ])),
    ]);
    chat.mountOn(loop);
    chat.attachConsole(context);
    expect(transcript(), contains('03:04  old prompt'));
    expect(transcript(), contains('failed · Permission denied'));
    expect(transcript(), contains('▸ reasoning'));
    expect(chat.blocks.where((b) => b.kind == ChatBlockKind.toolCall),
        hasLength(1));
  });
  test('completion corrects draft, results deduplicate, repeated call ids work',
      () {
    chat.watch(const SawText('draft answer'));
    chat.entry(
        const MessageAppendedEntry(
            turnId: 't',
            message: Message(
                role: Role.assistant, content: [TextBlock('correct answer')])),
        LogEvent.appended);
    expect(transcript(), isNot(contains('draft answer')));
    expect('correct answer'.allMatches(transcript()), hasLength(1));
    for (var i = 0; i < 2; i++) {
      chat.entry(
          MessageAppendedEntry(
              turnId: '$i',
              message:
                  Message(role: Role.assistant, content: [call.toBlock()])),
          LogEvent.appended);
      chat.observe(const ToolStarted(call));
      chat.observe(const ToolFinished(call, ToolResult('hello')));
      chat.entry(
          MessageAppendedEntry(
              turnId: '$i',
              message: const Message(role: Role.user, content: [
                ToolResultBlock(toolUseId: 'a', content: 'hello')
              ])),
          LogEvent.appended);
    }
    expect(chat.blocks.where((b) => b.kind == ChatBlockKind.toolCall),
        hasLength(2));
  });
  test(
      'page keys and wheel reach resumed scrollback without changing the draft',
      () async {
    for (var i = 0; i < 40; i++) {
      chat.writeNotice('history row $i');
    }
    final line = editor.readLine('unused');
    await tick();
    io.feed('draft');
    await tick();
    expect(screen.chat.isTailPinned, true);
    io.output.clear();
    io.feed('\x1b[5~' * 40);
    await tick();
    expect(screen.chat.isTailPinned, false);
    expect(io.output.toString(), contains('history row 0'));
    io.feed('\x1b[6~' * 40);
    await tick();
    expect(screen.chat.isTailPinned, true);
    expect(io.output.toString(), contains('history row 39'));
    io.feed(' intact\r');
    expect(await line, 'draft intact');
  });

  test('tool output is bounded and terminal controls cannot escape into rows',
      () {
    chat.observe(const ToolStarted(call));
    chat.observe(ToolOutput(call, '\x1b[2J${'x' * 70000}'));
    chat.observe(const ToolFinished(call, ToolResult('done')));
    final body =
        chat.blocks.where((b) => b.kind == ChatBlockKind.toolCall).single.body;
    final text = body.expand((line) => line.runs).map((r) => r.text).join();
    expect(text.length, lessThan(66000));
    expect(text, isNot(contains('\x1b')));
    chat.observe(const ToolOutput(call, 'late text'));
    expect(transcript(), isNot(contains('late text')));
  });
  test('prompt and timestamp layout fit small widths and both themes', () {
    for (final theme in [const Theme.dark(), const Theme.light()]) {
      for (final width in [1, 2, 10, 12, 20, 80, 120]) {
        final context = RenderContext(width: width, theme: theme);
        final block = ChatBlock.user('hello long line with wide 界 text');
        final lines = chat.renderer.render(block, context);
        expect(lines, isNotEmpty);
        if (width >= 3) {
          for (final line in lines) {
            expect(plainWidth(line.runs.map((r) => r.text).join()),
                lessThanOrEqualTo(width));
          }
        }
      }
    }
  });
}
