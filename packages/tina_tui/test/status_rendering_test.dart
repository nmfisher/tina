import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_approvals_tui/tina_approvals_tui.dart';
import 'package:tina_chat_tui/tina_chat_tui.dart';
import 'package:tina_console/testing.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

class _Io implements Stdio {
  _Io(this.terminalColumns);
  final output = StringBuffer();
  @override
  final int terminalColumns;
  @override
  bool get hasTerminal => true;
  @override
  Stream<List<int>> get stdin => const Stream.empty();
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal signal) =>
      const Stream.empty();
  @override
  void write(String text) => output.write(text);
}

void main() {
  for (final (width, height) in [(80, 10), (80, 24), (274, 40)]) {
    test(
        'approval and multiline tools keep one bottom status at ${width}x$height',
        () async {
      final io = _Io(width);
      final screen = Screen(
          io: io,
          layout: ScreenLayout.fromSize(width, height, split: false),
          ansi: AnsiCapable.yes);
      final editor = LineEditor(screen: screen);
      final keys = StreamController<InputEvent>();
      final keyIterator = StreamIterator(keys.stream);
      final context = ConsoleContext(
          screen: screen,
          editor: editor,
          readKey: (_) async =>
              await keyIterator.moveNext() ? keyIterator.current : null);
      final chat = ChatTuiPlugin(model: 'test')..attachConsole(context);
      final ui = ApprovalTuiPlugin()..attachConsole(context);
      final approvals = ApprovalsPlugin(channel: ui);
      final terminal = VirtualTerminal(width: width, height: height);
      addTearDown(() async {
        approvals.closeSession();
        ui.closeSession();
        chat.closeSession();
        editor.close(reportLatency: false);
        screen.dispose();
        await keyIterator.cancel();
        await keys.close();
      });
      void checkStatus() {
        // ONLCR on real Linux PTYs turns a leaked LF into CRLF. Unlike a
        // clamped cursor, this harness scrolls at the bottom of the terminal.
        terminal.feed(io.output.toString().replaceAll('\n', '\r\n'));
        io.output.clear();
        final rows = List.generate(height, terminal.rowText);
        expect(terminal.scrollCount, 0,
            reason: 'a physical scroll leaves an old status above the new one');
        expect(rows.where((row) => row.contains('mode: auto')), hasLength(1));
        expect(rows.last, contains('mode: auto'));
        expect(terminal.charAt(height - 1, 0), ' ');
        expect(terminal.charAt(height - 1, width - 1), ' ');
      }

      screen.redrawFrame();
      screen.setModeLabel('mode: auto');
      screen.setStatusLines(const [
        RenderLine(runs: [RenderRun('v0.9.25 · session regression', null)])
      ]);
      checkStatus();
      final command = ToolUse(id: 'multiline', name: 'bash', input: {
        'command': "python3 - <<'PY'\n${"print('lr_pairs')\n" * 40}PY"
      });
      chat.observe(ToolStarted(command));
      checkStatus();
      final pending = approvals.request(
          operation: 'write',
          target: '/tmp/pairs.py',
          reason: 'read-only mode',
          details: {
            'tool': {
              'name': 'edit',
              'input': {
                'filePath': '/tmp/pairs.py',
                'oldString': 'if lr_before != OLD99_LR:',
                'newString': 'if sorted(map(tuple, lr_before)) != '
                    'sorted(map(tuple, OLD99_LR)):\n'
                    '    raise RuntimeError("gloria lr_pairs do not match")'
              }
            }
          });
      await Future<void>.delayed(Duration.zero);
      expect(ui.asker!.currentDialog, isNotNull);
      checkStatus();
      // Status updates while the approval owns the input must stay on the
      // bottom row, including a narrow terminal and a changing token count.
      for (var i = 0; i < 5; i++) {
        screen.setStatusLines([
          const RenderLine(
              runs: [RenderRun('v0.9.25 · session regression', null)]),
          RenderLine(align: StatusAlign.right, runs: [
            RenderRun(
                'Σ ${formatInteger(4169731 + i)} / 100,000,000 · 4%', null)
          ])
        ]);
        ui.repaintConsole();
        checkStatus();
      }
      keys.add(CharInput('n'));
      expect(await pending, ApprovalDecision.deny);
      await Future<void>.delayed(Duration.zero);
      expect(ui.asker!.currentDialog, isNull);
      chat.observe(ToolFinished(command, const ToolResult('done')));
      chat.writeNotice('Finished.');
      chat.repaintConsole();
      checkStatus();
    });
  }
}
