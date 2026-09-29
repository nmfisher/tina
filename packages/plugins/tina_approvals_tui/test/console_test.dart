import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_console/testing.dart';

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

Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late Io io;
  late Screen screen;
  late LineEditor editor;
  late ApprovalTuiPlugin ui;
  late ApprovalsPlugin service;
  setUp(() {
    io = Io();
    screen =
        Screen(io: io, layout: ScreenLayout.fromSize(80, 24, split: false));
    editor = LineEditor(screen: screen, escapeTimeout: Duration.zero);
    ui = ApprovalTuiPlugin()
      ..attachConsole(ConsoleContext(screen: screen, editor: editor));
    service = ApprovalsPlugin(channel: ui);
  });
  tearDown(() {
    service.closeSession();
    ui.closeSession();
    editor.close(reportLatency: false);
    screen.dispose();
    unawaited(io.input.close());
  });

  VirtualTerminal visible() =>
      VirtualTerminal(width: screen.layout.width, height: screen.layout.height)
        ..feed(io.output.toString());
  String all() =>
      List.generate(screen.layout.height, visible().rowText).join('\n');
  String input() => visible().rowText(screen.input.bounds.row);
  Future<ApprovalDecision> ask(
          {ApprovalKind kind = ApprovalKind.confirmation}) =>
      service.request(
          operation: 'Send message?',
          target: '/tmp/outside',
          reason:
              'Your message contains grok, this is a no-no. Are you sure you want to proceed?',
          kind: kind);

  for (final size in [(80, 10), (80, 24), (120, 30)]) {
    test('Yes/No replaces the input and restores the draft at $size', () async {
      screen.resize(ScreenLayout.fromSize(size.$1, size.$2, split: false));
      screen.chat.writeln('Previous conversation');
      final line = editor.readLine('test-model > ');
      io.feed('draft');
      await tick();
      expect(input(), contains('test-model > draft'));
      final decision = ask();
      await tick();
      expect(input(), contains('[x] Yes   [ ] No'));
      expect(input(), isNot(contains('test-model')));
      expect(input(), isNot(contains('draft')));
      final vt = visible();
      final above =
          List.generate(screen.input.bounds.row, vt.rowText).join('\n');
      expect(above, contains('Your message contains grok'));
      io.feed('\x1b[C'); // right selects No
      await tick();
      expect(input(), contains('[ ] Yes   [x] No'));
      io.feed('\r');
      expect(await decision, ApprovalDecision.deny);
      await tick();
      expect(input(), contains('test-model > draft'));
      final restored = visible();
      expect(List.generate(screen.layout.height, restored.rowText).join('\n'),
          contains('Previous conversation'));
      expect(editor.editState.buffer, 'draft');
      io.feed('\r');
      expect(await line, 'draft');
    });
  }

  test('tool choices stay on the input row across resize and details',
      () async {
    final decision = ask(kind: ApprovalKind.permission);
    await tick();
    expect(input(), contains('❯ Approve Send message??'));
    expect(all(), contains('❯ [y] allow once'));
    io.feed('\x1b[B');
    await tick();
    io.output.clear();
    screen.resize(ScreenLayout.fromSize(20, 6, split: false));
    ui.repaintConsole();
    expect(all(), contains('❯ [n] deny once'));
    io.feed('\t');
    await tick();
    expect(ui.asker!.current, isNotNull);
    io.feed('\r'); // details back, never approval
    await tick();
    expect(all(), contains('❯ [n] deny once'));
    io.output.clear();
    screen.resize(ScreenLayout.fromSize(120, 30, split: true));
    ui.repaintConsole();
    expect(all(), contains('❯ [n] deny once'));
    io.feed('\x1b');
    expect(await decision, ApprovalDecision.deny);
    await tick();
    expect(input(), isNot(contains('[x]')));
  });

  test('queued questions replace each other and close restores the draft',
      () async {
    final line = editor.readLine('test-model > ');
    io.feed('draft');
    await tick();
    final first = ask();
    final second = ask(kind: ApprovalKind.permission);
    await tick();
    io.feed('\r');
    expect(await first, ApprovalDecision.allow);
    await tick();
    expect(all(), contains('❯ [y] allow once'));
    ui.detachConsole();
    expect(await second, ApprovalDecision.deny);
    await tick();
    expect(input(), contains('test-model > draft'));
    io.feed('\r');
    expect(await line, 'draft');
  });

  test('external cancellation restores the input while the key read unwinds',
      () async {
    final line = editor.readLine('test-model > ');
    io.feed('draft');
    await tick();
    final decision = ask();
    await tick();
    service.closeSession();
    expect(await decision, ApprovalDecision.deny);
    await tick();
    expect(input(), contains('test-model > draft'));
    io.feed('\r');
    expect(await line, 'draft');
  });
}
