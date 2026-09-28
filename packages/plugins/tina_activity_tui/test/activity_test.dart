import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_activity_tui/tina_activity_tui.dart';

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

class Output implements Terminal {
  Output(this.screen);
  final Screen screen;
  @override
  void writeln([String? text]) =>
      screen.frame(() => screen.chat.writeln(text ?? ''));
  @override
  Future<String> ask(String prompt) => throw UnimplementedError();
}

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 30));
const call = ToolUse(id: 'a', name: 'third_party_tool', input: {});

void main() {
  late Io io;
  late Screen screen;
  late LineEditor editor;
  late ActivityTuiPlugin plugin;
  setUp(() {
    io = Io();
    screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    plugin = ActivityTuiPlugin(terminal: Output(screen));
    plugin.attachConsole(ConsoleContext(screen: screen, editor: editor));
  });
  tearDown(() {
    plugin.closeSession();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  });
  String chat() => screen.chat.snapshotLines().join('\n');

  test('generic streaming is bounded, sanitized, and stops at completion', () {
    plugin.observe(const ToolStarted(call));
    plugin.observe(const ToolOutput(call, '\x1b[2Jlive progress\n'));
    expect(chat(), contains('live progress'));
    expect(chat(), isNot(contains('\x1b')));
    plugin.observe(ToolOutput(call, 'x' * 70000));
    expect(chat(), contains('[further live output hidden]'));
    expect(plugin.model.records.single.output.length, 65536);
    plugin.observe(const ToolFinished(call, ToolResult('result summary')));
    expect(chat(), contains('third_party_tool — done'));
    plugin.observe(const ToolOutput(call, 'late text'));
    expect(chat(), isNot(contains('late text')));
  });
  test('F4 browsing preserves drafts and Enter expands without submitting',
      () async {
    plugin.observe(const ToolStarted(call));
    plugin.observe(const ToolFinished(call, ToolResult('inspect this result')));
    final prompt = editor.readLine('› ');
    await tick();
    io.feed('draft');
    await tick();
    io.feed('\x1bOS');
    await tick(); // F4
    expect(plugin.isOpen, true);
    io.feed('\r');
    await tick();
    expect(plugin.model.records.single.expanded, true);
    expect(plugin.visibleLines.join('\n'), contains('inspect this result'));
    screen.resize(ScreenLayout.fromSize(20, 6, split: false));
    plugin.repaintConsole();
    expect(plugin.visibleLines.length,
        lessThanOrEqualTo(dialogArea(screen.layout).height));
    expect(
        plugin.visibleLines
            .every((s) => visibleWidth(s) <= dialogArea(screen.layout).width),
        true);
    io.feed('\x1b');
    await tick();
    expect(plugin.isOpen, false);
    io.feed(' intact\r');
    expect(await prompt, 'draft intact');
  });
  test('approval reader owns Enter even while the browser is open', () async {
    plugin.observe(const ToolStarted(call));
    plugin.toggle();
    final pending = editor.readKey(globalKeys: true);
    await tick();
    plugin.repaintConsole();
    io.feed('\r');
    expect(await pending, ControlKey(ControlCode.enter));
    expect(plugin.model.records.single.expanded, false);
    plugin.detachConsole();
    final prompt = editor.readLine('› ');
    await tick();
    io.feed('\x1bOS');
    await tick();
    expect(plugin.isOpen, false);
    io.feed('normal\r');
    expect(await prompt, 'normal');
  });
  test('expanding the last visible row brings its details into view', () async {
    for (var i = 0; i < 3; i++) {
      final call = ToolUse(id: 'call-$i', name: 'tool-$i', input: const {});
      plugin.observe(ToolStarted(call));
      plugin.observe(ToolFinished(call, const ToolResult('done')));
    }
    screen.resize(ScreenLayout.fromSize(40, 8, split: false));
    final prompt = editor.readLine('› ');
    await tick();
    io.feed('\x1bOS');
    await tick();
    io.feed('\r');
    await tick();
    expect(plugin.visibleLines.join('\n'), contains('Call: call-2'));
    io.feed('\x1bOS');
    await tick();
    io.feed('\r');
    await prompt;
  });
  test('progress replaces status and bounded history retains child details',
      () {
    plugin.observe(const ToolStarted(call));
    for (var i = 0; i < 25; i++) {
      plugin.observe(ToolProgress(call, 'child abc · running step $i'));
    }
    expect(plugin.model.records.single.progressHistory.length, 20);
    expect(plugin.model.records.single.progress, contains('step 24'));
    plugin.observe(const ToolFinished(call, ToolResult('child done')));
    plugin.observe(const ToolProgress(call, 'late status'));
    expect(
        plugin.model.records.single.progress, isNot(contains('late status')));
  });
  test('errors are readable and denied edits never claim to be applied', () {
    const edit = ToolUse(id: 'e', name: 'edit', input: {
      'filePath': 'hello.dart',
      'oldString': 'old',
      'newString': 'new',
      'api_key': 'hidden'
    });
    plugin.observe(const ToolStarted(edit));
    plugin.observe(const ToolFinished(
        edit,
        ToolResult(
            '{"code":"edit_conflict","message":"old text missing","recovery":"Read current file"}',
            isError: true)));
    final row = plugin.model.records.single;
    expect(row.summary, 'old text missing');
    expect(chat(), contains('old text missing'));
    final details = row.details().join('\n');
    expect(details, contains('Recovery: Read current file'));
    expect(details, contains('not confirmed applied'));
    expect(details, isNot(contains('hidden')));
    expect(details, contains('- old'));
    expect(details, contains('+ new'));
  });
  test('line diff preserves shared lines and bounds large replacements', () {
    expect(replacementDiff('one\nold\nlast', 'one\nnew\nlast'),
        ['  one', '- old', '+ new', '  last']);
    expect(
        replacementDiff(List.filled(500, 'a').join('\n'),
                List.filled(500, 'b').join('\n'))
            .length,
        lessThan(165));
  });
  test(
      'history replays completed and denied calls without executing or printing',
      () {
    final loop =
        AgentLoop(provider: ScriptedProvider([]), plugins: [], seedLog: [
      MessageAppendedEntry(
          turnId: 'one',
          message: Message(role: Role.assistant, content: [call.toBlock()])),
      MessageAppendedEntry(
          turnId: 'one',
          message: const Message(role: Role.user, content: [
            ToolResultBlock(toolUseId: 'a', content: 'denied', isError: true)
          ])),
    ]);
    plugin.mountOn(loop);
    expect(plugin.model.records.single.state, 'error');
    expect(plugin.model.records.single.summary, 'denied');
    expect(chat(), isNot(contains('denied')));
  });
}
