import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_context_tui/tina_context_tui.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

class TestIo implements Stdio {
  final input = StreamController<List<int>>(sync: true);
  final output = StringBuffer();
  void feed(String value) => input.add(value.codeUnits);
  @override
  Stream<List<int>> get stdin => input.stream;
  @override
  void write(String value) => output.write(value);
  @override
  int get terminalColumns => 100;
  @override
  bool get hasTerminal => false;
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
}

class TestTerminal implements Terminal {
  final output = <String>[];
  @override
  void writeln([String? text]) => output.add(text ?? '');
  @override
  Future<String> ask(String prompt) => throw UnimplementedError();
}

Message text(String value) =>
    Message(role: Role.user, content: [TextBlock(value)]);
Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late Directory dir;
  late File mirror;
  late ContextPlugin context;
  late ContextTuiPlugin viewer;
  late AgentLoop loop;
  late TestIo io;
  late Screen screen;
  late LineEditor editor;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tina-context-view-');
    mirror = File('${dir.path}/live.json');
    context = ContextPlugin(mirrorFile: mirror);
    loop = AgentLoop(
        provider:
            ScriptedProvider([scriptedReply('done'), scriptedReply('again')]),
        plugins: [
          context
        ],
        seedLog: [
          const TurnStartedEntry(turnId: 'old', seq: 0),
          MessageAppendedEntry(
              turnId: 'old', seq: 1, message: text('original history')),
          const TurnEndedEntry(
              turnId: 'old', seq: 2, reason: TurnStopReason.complete),
        ]);
    loop.mountPlugin(context);
    io = TestIo();
    screen = Screen.withBackend(
        io: io,
        backend: AnsiBackend(io: io, ansi: AnsiCapable.yes),
        layout: ScreenLayout.fromSize(100, 24, split: false));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    viewer = ContextTuiPlugin(context: context, terminal: TestTerminal());
    viewer.attachConsole(ConsoleContext(screen: screen, editor: editor));
  });
  tearDown(() {
    viewer.closeSession();
    context.closeSession();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
    dir.deleteSync(recursive: true);
  });
  String visible() => viewer.visibleLines.join('\n');

  test(
      'pending malformed mirror remains distinct from accepted context and is never applied',
      () {
    mirror.writeAsStringSync('{pending invalid edit');
    final entries = loop.log.length;
    viewer.toggle();
    expect(visible(), contains('original history'));
    expect(visible(), contains('Pending file changes (not accepted)'));
    expect(visible(), contains('excludes system prompt'));
    expect(visible(), contains('Budget target: 32000 tokens'));
    expect(visible(), isNot(contains('{pending invalid edit')));
    expect(mirror.readAsStringSync(), '{pending invalid edit');
    expect(loop.log.length, entries);
    expect(context.workingContext.revision, 0);
    mirror.writeAsBytesSync([0xff, 0xfe]);
    viewer.repaintConsole();
    expect(visible(), contains('original history'));
    expect(visible(), contains('(not accepted)'));
    expect(mirror.readAsBytesSync(), [0xff, 0xfe]);
    mirror.deleteSync();
    viewer.repaintConsole();
    expect(visible(), contains('Missing or unreadable (not accepted)'));
    expect(mirror.existsSync(), false);
  });

  test('latest edit shows removals and additions after replacement and resume',
      () async {
    final before = context.workingContext;
    context.replaceWorkingContext(
        expectedRevision: before.revision,
        expectedThroughSeq: before.throughSeq,
        messages: [text('concise summary')]);
    final prompt = editor.readLine('› ');
    await tick();
    io.feed('draft');
    await tick();
    viewer.toggle();
    expect(visible(), contains('concise summary'));
    expect(visible(), isNot(contains('original history')));
    io.feed('t');
    await tick();
    expect(visible(), contains('- original history'));
    expect(visible(), contains('+ concise summary'));
    expect(visible(), contains('Revision 1'));
    final restored = ContextPlugin();
    final resumed = AgentLoop(
        provider: ScriptedProvider([]), plugins: [restored], seedLog: loop.log);
    resumed.mountPlugin(restored);
    expect(restored.latestChange!.before.messages.single.toJson(),
        text('original history').toJson());
    expect(restored.latestChange!.after.messages.single.toJson(),
        text('concise summary').toJson());
    restored.closeSession();
    io.feed('\x1b');
    await tick();
    expect(viewer.isOpen, false);
    io.feed(' intact\r');
    expect(await prompt, 'draft intact');
  });

  test('rejection remains visible after an unchanged synchronization',
      () async {
    mirror.writeAsStringSync('{invalid');
    await loop.runTurn(const Input('task', id: 'new'));
    expect(context.lastEditReceipt!.status, ContextEditStatus.rejected);
    await loop.runTurn(const Input('next', id: 'next'));
    expect(context.lastReceipt!.status, ContextEditStatus.unchanged);
    viewer.toggle();
    expect(visible(), contains('Context edit rejected'));
    expect(visible(), contains('invalid, stale, or protected'));
    expect(context.workingContext.revision, 0);
  });

  test('accepted receipt and changed messages follow validated file edits',
      () async {
    final data = jsonDecode(mirror.readAsStringSync()) as Map;
    data['messages'] = [text('short summary').toJson()];
    mirror.writeAsStringSync(jsonEncode(data));
    await loop.runTurn(const Input('task', id: 'new'));
    viewer.toggle();
    expect(visible(), contains('revision 1'));
    expect(visible(), contains('Last prepared request: ~'));
    expect(visible(), contains('response reserve: 2048'));
    expect(visible(), contains('Latest accepted edit: ~'));
    expect(visible(), contains('short summary'));
    expect(visible(), contains('Context edit accepted.'));
    expect(visible(), isNot(contains('original history')));
  });

  test(
      'approval keys take priority, resizing stays bounded and detaching removes modal',
      () async {
    viewer.toggle();
    final key = editor.readKey(globalKeys: true);
    await tick();
    viewer.repaintConsole();
    io.feed('\r');
    expect(await key, ControlKey(ControlCode.enter));
    expect(viewer.isOpen, true);
    screen.resize(ScreenLayout.fromSize(20, 6, split: false));
    viewer.repaintConsole();
    final area = dialogArea(screen.layout);
    expect(viewer.visibleLines.length, lessThanOrEqualTo(area.height));
    expect(
        viewer.visibleLines.every((s) => visibleWidth(s) <= area.width), true);
    viewer.detachConsole();
    final prompt = editor.readLine('› ');
    await tick();
    io.feed('normal\r');
    expect(await prompt, 'normal');
    expect(viewer.isOpen, false);
  });

  test(
      'diff retains shared boundaries and represents rewrites without hiding payloads',
      () {
    final diff = contextMessageDiff([text('start'), text('old'), text('end')],
        [text('start'), text('new'), text('end')]);
    expect(diff, [
      '1 leading messages unchanged',
      '- user',
      '- old',
      '+ user',
      '+ new',
      '1 trailing messages unchanged'
    ]);
    expect(describeContextMessage(text('x' * 20000)).last,
        contains('preview truncated'));
  });

  test('resumed comparison ignores abandoned edits and clears with context',
      () {
    final initial = context.workingContext;
    context.replaceWorkingContext(
        expectedRevision: initial.revision,
        expectedThroughSeq: initial.throughSeq,
        messages: [text('accepted summary')]);
    final abandonedLog = <SessionEntry>[
      ...loop.log,
      const TurnStartedEntry(turnId: 'abandoned', seq: 4),
      MessageAppendedEntry(
          turnId: 'abandoned', seq: 5, message: text('unfinished task')),
      WorkingContextSnapshot(
          revision: 2,
          throughSeq: 5,
          originTurnId: 'abandoned',
          messages: [text('uncommitted summary')]).toEntry().withSeq(6),
    ];
    ContextPlugin restore(List<SessionEntry> log) {
      final plugin = ContextPlugin();
      final restored = AgentLoop(
          provider: ScriptedProvider([]), plugins: [plugin], seedLog: log);
      restored.mountPlugin(plugin);
      addTearDown(plugin.closeSession);
      return plugin;
    }

    final resumed = restore(abandonedLog);
    expect(resumed.workingContext.revision, 2);
    expect(resumed.latestChange!.after.revision, 1);
    expect(resumed.latestChange!.after.messages.single.toJson(),
        text('accepted summary').toJson());
    expect(
        restore([...abandonedLog, const ContextClearedEntry(seq: 7)])
            .latestChange,
        isNull);
  });
}
